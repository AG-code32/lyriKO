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
    'LYRIKO_SERVER_URL',
    defaultValue: '',
  );
  static const String _defaultToken = String.fromEnvironment(
    'LYRIKO_SERVER_TOKEN',
    defaultValue: '',
  );

  static const FlutterSecureStorage _store = FlutterSecureStorage();
  static const String _urlKey = 'lyriko.server.url.v1';
  static const String _tokenKey = 'lyriko.server.token.v1';

  // Recognition stays native to iOS; only the library/editor use the server.
  bool get enabled => Platform.isMacOS || Platform.isIOS;

  Future<bool> isConfigured() async {
    if (!enabled) return false;
    final url = await getBaseUrl();
    final storedToken = (await _store.read(key: _tokenKey))?.trim() ?? '';
    return url.isNotEmpty &&
        (storedToken.isNotEmpty || _defaultToken.isNotEmpty);
  }

  Future<String> getBaseUrl() async {
    final value = (await _store.read(key: _urlKey))?.trim();
    return value != null && value.isNotEmpty ? value : _defaultUrl;
  }

  /// Token resolved from secure settings, falling back to --dart-define.
  Future<String> getAuthToken() async {
    final stored = (await _store.read(key: _tokenKey))?.trim() ?? '';
    return stored.isNotEmpty ? stored : _defaultToken;
  }

  Future<bool> hasStoredToken() async =>
      (await _store.read(key: _tokenKey))?.isNotEmpty ?? false;

  Future<void> saveSettings({required String url, String? token}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        !(uri.scheme == 'https' ||
            (uri.scheme == 'http' &&
                (uri.host == '127.0.0.1' || uri.host == 'localhost')))) {
      throw const FormatException(
        'Usa una URL HTTPS válida (HTTP solo para localhost).',
      );
    }
    if (uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException(
        'Introduce solo la dirección base del servidor.',
      );
    }
    await _store.write(
      key: _urlKey,
      value: uri.toString().replaceAll(RegExp(r'/$'), ''),
    );
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
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final raw = await response.transform(utf8.decoder).join();
      if (response.statusCode == 409) {
        String detail = 'Conflict (409)';
        try {
          final parsed = jsonDecode(raw);
          if (parsed is Map && parsed['detail'] != null) {
            final value = parsed['detail'];
            detail = value is String ? value : jsonEncode(value);
          }
        } catch (_) {
          if (raw.trim().isNotEmpty) detail = raw.trim();
        }
        throw StateError('HTTP 409: $detail');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw StateError(
          'Acceso denegado (${response.statusCode}). Revisa el token.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: $raw', uri: uri);
      }
      final result = jsonDecode(raw);
      if (result is! Map)
        throw const FormatException('Respuesta API no válida');
      return Map<String, dynamic>.from(result);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<Map<String, dynamic>>> songs() async {
    final data = await _request('GET', '/api/songs');
    final entries = data['songs'];
    if (entries is! List) throw const FormatException('Catálogo inválido');
    return entries
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<Map<String, dynamic>?> songForPath(String jsonPath) async {
    final filename = jsonPath.replaceAll('\\', '/').split('/').last;
    final basename = filename.replaceFirst(
      RegExp(r'\.json$', caseSensitive: false),
      '',
    ).trim().toLowerCase();
    final catalog = await songs();

    // macOS stores remote lyrics as <server-song-id>.json. Resolve the ID
    // directly instead of treating the local cache path as a song title.
    for (final song in catalog) {
      final id = song['id']?.toString().trim().toLowerCase() ?? '';
      if (id.isNotEmpty && id == basename) return song;
    }

    // Preserve the original lookup for bundled files named
    // "Artist - Title.json" (including the iOS editor).
    for (final song in catalog) {
      final artist = song['artist']?.toString().trim() ?? '';
      final title = song['title']?.toString().trim() ?? '';
      if ('$artist - $title'.trim().toLowerCase() == basename) return song;
    }
    return null;
  }

  Future<Map<String, dynamic>> lyrics(String songId) =>
      _request('GET', '/api/songs/${Uri.encodeComponent(songId)}/lyrics');

  Future<int> saveLyrics(
    String songId,
    int version,
    Map<String, dynamic> json,
  ) async {
    final result = await _request(
      'PUT',
      '/api/songs/${Uri.encodeComponent(songId)}/lyrics',
      body: {'version': version, 'lyrics': json},
    );
    return (result['version'] as num).toInt();
  }

  Future<List<double>> waveform(String songId) async {
    final result = await _request(
      'GET',
      '/api/songs/${Uri.encodeComponent(songId)}/waveform',
    );
    final samples = result['samples'];
    if (samples is! List) throw const FormatException('Waveform inválido');
    return samples.whereType<num>().map((n) => n.toDouble()).toList();
  }

  Future<String> audioUrl(String songId) async {
    final result = await _request(
      'GET',
      '/api/songs/${Uri.encodeComponent(songId)}/audio-access',
    );
    final path = result['url']?.toString();
    if (path == null || !path.startsWith('/api/')) {
      throw const FormatException('Enlace de audio no válido');
    }
    return '${await getBaseUrl()}$path';
  }
  Future<Map<String, dynamic>> importedMetadataSuggestion(String id) =>
      _request('GET', '/api/imported-audio/${Uri.encodeComponent(id)}/metadata-suggestion');

  /// List audio indexed on the Windows server, separately from synchronized songs.
  Future<Map<String, dynamic>> importedAudio({int limit = 5000, int offset = 0}) =>
      _request('GET', '/api/imported-audio?limit=$limit&offset=$offset');

  Future<List<Map<String, dynamic>>> newImportedAudio() async {
    final result = await _request('GET', '/api/imported-audio/inbox');
    final entries = result['songs'];
    return entries is List
        ? entries.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : [];
  }

  Future<void> acknowledgeImportedAudio(List<String> ids, {bool dismiss = false}) async {
    if (ids.isEmpty) return;
    await _request('POST', '/api/imported-audio/inbox/ack',
      body: {'ids': ids, 'state': dismiss ? 'dismissed' : 'seen'});
  }

  /// Scan a folder relative to LYRIKO_IMPORT_ROOT configured on Windows.
  Future<Map<String, dynamic>> updateImportedMetadata(
          String id, String title, String artist) =>
      _request('PATCH', '/api/imported-audio/${Uri.encodeComponent(id)}/metadata',
          body: {'title': title, 'artist': artist});

  Future<Map<String, dynamic>> previewImportedLyrics(String id) =>
      _request('GET', '/api/imported-audio/${Uri.encodeComponent(id)}/lyrics-preview');

  Future<Map<String, dynamic>> approveImportedLyrics(String id, int providerId) =>
      _request('POST', '/api/imported-audio/${Uri.encodeComponent(id)}/lyrics-approve',
          body: {'providerId': providerId});

  Future<Map<String, dynamic>> importAudioFolder(String relativeFolder) =>
      _request('POST', '/api/imported-audio/scan',
          body: {'folder': relativeFolder});

}
