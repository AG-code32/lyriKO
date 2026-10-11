import 'dart:async';
import 'dart:io';

/// Reads the currently playing track from Spotify or Apple Music on macOS.
/// This is metadata detection, NOT system-audio recording or fingerprinting.
class MacOSMediaMetadata {
  const MacOSMediaMetadata({
    required this.source,
    required this.title,
    required this.artist,
    required this.positionMs,
  });

  final String source;
  final String title;
  final String artist;
  final int positionMs;
}

class MacOSMediaMetadataService {
  static const _separator = '\u001f';

  Future<MacOSMediaMetadata?> currentTrack() async {
    if (!Platform.isMacOS) return null;

    // Prefer Spotify when both apps happen to be open.
    final spotify = await _query('Spotify');
    if (spotify != null) return spotify;

    return _query('Music');
  }

  Future<MacOSMediaMetadata?> _query(String app) async {
    // App names are internal constants, not user input.
    final script =
        '''
if application "$app" is running then
  tell application "$app"
    if player state is playing then
      set trackTitle to name of current track
      set trackArtist to artist of current track
      set trackPosition to player position
      return trackTitle & (ASCII character 31) & trackArtist & (ASCII character 31) & (trackPosition as text)
    end if
  end tell
end if
return ""
''';

    ProcessResult result;
    try {
      result = await Process.run('/usr/bin/osascript', [
        '-e',
        script,
      ]).timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw StateError('Timed out reading $app playback metadata');
    } on ProcessException catch (e) {
      throw StateError('macOS could not run AppleScript: $e');
    }

    if (result.exitCode != 0) {
      final message = result.stderr.toString().trim();
      // macOS TCC: user denied Automation / Apple Events access.
      if (message.contains('-1743') ||
          message.toLowerCase().contains('not authorized') ||
          message.toLowerCase().contains(
            'not permitted to send apple events',
          )) {
        throw StateError(
          'macOS blocked access to $app. Enable Lyriko in '
          'System Settings > Privacy & Security > Automation. $message',
        );
      }
      // The player might not be installed or expose a scripting dictionary.
      // Continue with the other supported player.
      debugLog('Metadata unavailable from $app: $message');
      return null;
    }

    final raw = result.stdout.toString().trim();
    if (raw.isEmpty) return null;
    final parts = raw.split(_separator);
    if (parts.length != 3) {
      debugLog('Unexpected metadata response from $app');
      return null;
    }

    final title = parts[0].trim();
    final artist = parts[1].trim();
    final seconds = double.tryParse(parts[2].trim());
    if (title.isEmpty || seconds == null || !seconds.isFinite) return null;

    final rawPositionMs = (seconds * 1000).round();
    final safePositionMs = rawPositionMs < 0
        ? 0
        : (rawPositionMs > 2147483647 ? 2147483647 : rawPositionMs);
    return MacOSMediaMetadata(
      source: app,
      title: title,
      artist: artist,
      positionMs: safePositionMs,
    );
  }

  void debugLog(String message) {
    // Keep diagnostic messages available in `flutter run -d macos`.
    // ignore: avoid_print
    print('[Lyriko macOS metadata] $message');
  }
}
