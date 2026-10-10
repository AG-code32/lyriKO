import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// FastAPI client for Lyriko's private Windows server.
///
/// Settings are loaded from OS-backed secure storage on EVERY request,
/// so changing the Cloudflare Quick Tunnel URL never requires a rebuild.
/// The development --dart-define values remain a fallback only.
class LyrikoServerClient {
  static const String _defaultUrl = String.fromEnvironment(
    'LYRIKO_SERVER_URL', defaultValue: '',
  );
  static const String _defaultToken = String.fromEnvironment(
    'LYRIKO_SERVER_TOKEN', defaultValue: '',
  );

  static const FlutterSecureStorage _store = FlutterSecureStorage();
  static const String _urlKey = 'lyriko.server.url.v1';
  static const String _tokenKey = 'lyriko.server.token.v1';

  // Keep iPhone's current local Listen/Discover and lyric pipeline untouched.
  // We will enable iOS remote editing after its full integration is tested.
  bool get enabled => Platform.isMacOS;

  Future<String> getBaseUrl() async {
    final value = (await _store.read(key: _urlKey))?.trim();
    return value != null && value.isNotEmpty ? value : _defaultUrl;
  }

  Future<bool> hasStoredToken() async =>
      (await _store.read(key: _tokenKey))?.isNotEmpty ?? false;

  Future<void> saveSettings({
    required String url,
    String? token,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasAuthority ||
        !(uri.scheme == 'https' ||
          (uri.scheme == 'http' &&
              (uri.host == '127.0.0.1' || uri.host == 'localhost')))) {
      throw const FormatException(
        'Usa una URL HTTPS válida (HTTP solo para localhost).',
      );
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('Introduce solo la dirección base del servidor.');
    }
    await _store.write(key: _urlKey, value: uri.toString().replaceAll(RegExp(r'/$'), ''));
    if (token != null && token.trim().isNotEmpty) {
      await _store.write(key: _tokenKey, value: token.trim());
    }
  }

  Future<void> clearStoredSettings() async {
    await _store.delete(key: _urlKey);
    await _store.delete(key: _tokenKey);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final base = await getBaseUrl();
    final token = (await _store.read(key: _tokenKey))?.trim() ?? _defaultToken;
    if (base.isEmpty) {
      throw StateError('Configura la URL en Server Settings.');
    }
    if (token.isEmpty) {
      throw StateError('Configura el token en Server Settings.');
    }
    final uri = Uri.parse('$base$path');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.openUrl(method, uri);
      // Set all headers before writing the body.
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(const Duration(seconds: 25));
      final raw = await response.transform(utf8.decoder).join();
      if (response.statusCode == 409) {
        throw StateError('Conflicto de versión (409). Vuelve a abrir la canción antes de guardar.');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw StateError('Acceso denegado (${response.statusCode}). Revisa el token.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: $raw', uri: uri);
      }
      final result = jsonDecode(raw);
      if (result is! Map) throw const FormatException('Respuesta API no válida');
      return Map<String, dynamic>.from(result);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<Map<String, dynamic>>> songs() async {
    final data = await _request('GET', '/api/songs');
    final entries = data['songs'];
    if (entries is! List) throw const FormatException('Catálogo inválido');
    return entries.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<Map<String, dynamic>?> songForPath(String jsonPath) async {
    final file = jsonPath.replaceAll('\\', '/').split('/').last;
    final base = file.replaceFirst(RegExp(r'\.json$', caseSensitive: false), '');
    for (final song in await songs()) {
      final name = '${song['artist'] ?? ''} - ${song['title'] ?? ''}';
      if (name.toLowerCase() == base.toLowerCase()) return song;
    }
    return null;
  }

  Future<Map<String, dynamic>> lyrics(String songId) =>
      _request('GET', '/api/songs/${Uri.encodeComponent(songId)}/lyrics');

  Future<int> saveLyrics(String songId, int version, Map<String, dynamic> json) async {
    final result = await _request('PUT',
      '/api/songs/${Uri.encodeComponent(songId)}/lyrics',
      body: {'version': version, 'lyrics': json},
    );
    return (result['version'] as num).toInt();
  }

  Future<List<double>> waveform(String songId) async {
    final result = await _request('GET',
        '/api/songs/${Uri.encodeComponent(songId)}/waveform');
    final samples = result['samples'];
    if (samples is! List) throw const FormatException('Waveform inválido');
    return samples.whereType<num>().map((n) => n.toDouble()).toList();
  }

  Future<String> audioUrl(String songId) async {
    final result = await _request('GET',
      '/api/songs/${Uri.encodeComponent(songId)}/audio-access');
    final path = result['url']?.toString();
    if (path == null || !path.startsWith('/api/')) {
      throw const FormatException('Enlace de audio no válido');
    }
    return '${await getBaseUrl()}$path';
  }
}
