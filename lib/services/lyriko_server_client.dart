import 'dart:convert';
import 'dart:io';

/// Client for the Lyriko FastAPI instance on the Windows PC.
/// Remote editing is enabled on macOS only; the existing iOS/Android
/// audio recognition and offline/bundled lyric paths are left untouched.
class LyrikoServerClient {
  static const String baseUrl = String.fromEnvironment(
    'LYRIKO_SERVER_URL',
    defaultValue: 'http://192.168.1.28:8000',
  );
  static const String writeToken = String.fromEnvironment('LYRIKO_SERVER_TOKEN');

  bool get enabled => Platform.isMacOS;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = false,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.openUrl(method, _uri(path));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      if (authenticated) {
        if (writeToken.isEmpty) {
          throw StateError('Falta LYRIKO_SERVER_TOKEN para guardar en Windows.');
        }
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $writeToken');
      }
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 409) {
          throw StateError('Conflicto de versión (409): otra edición se guardó en el servidor. Vuelve a abrir la canción antes de guardar.');
        }
        throw HttpException('HTTP ${response.statusCode}: $raw', uri: _uri(path));
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('Respuesta API no válida');
      return Map<String, dynamic>.from(decoded);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<Map<String, dynamic>>> songs() async {
    final data = await _request('GET', '/api/songs', authenticated: true);
    final items = data['songs'];
    if (items is! List) throw const FormatException('Catálogo inválido');
    return items.whereType<Map>().map((x) => Map<String, dynamic>.from(x)).toList();
  }

  /// Map an asset path, e.g. assets/lyrics/Artist - Song.json,
  /// to its Windows server song record by title and artist.
  Future<Map<String, dynamic>?> songForPath(String jsonPath) async {
    final filename = jsonPath.replaceAll('\\', '/').split('/').last;
    final basename = filename.replaceFirst(RegExp(r'\.json$', caseSensitive: false), '');
    final songsList = await songs();
    for (final song in songsList) {
      final artist = song['artist']?.toString() ?? '';
      final title = song['title']?.toString() ?? '';
      if ('$artist - $title'.toLowerCase() == basename.toLowerCase()) return song;
    }
    return null;
  }

  Future<Map<String, dynamic>> lyrics(String songId) =>
      _request('GET', '/api/songs/${Uri.encodeComponent(songId)}/lyrics', authenticated: true);

  Future<int> saveLyrics(String songId, int version, Map<String, dynamic> json) async {
    final response = await _request(
      'PUT',
      '/api/songs/${Uri.encodeComponent(songId)}/lyrics',
      authenticated: true,
      body: {'version': version, 'lyrics': json},
    );
    return (response['version'] as num).toInt();
  }

  Future<List<double>> waveform(String songId) async {
    final data = await _request('GET', '/api/songs/${Uri.encodeComponent(songId)}/waveform', authenticated: true);
    final raw = data['samples'];
    if (raw is! List) throw const FormatException('Waveform inválido');
    return raw.whereType<num>().map((n) => n.toDouble()).toList();
  }

  String audioUrl(String songId) =>
      _uri('/api/songs/${Uri.encodeComponent(songId)}/audio').toString();
}
