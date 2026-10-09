import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const AndroidMediaSessionTestApp());
}

class AndroidMediaSessionTestApp extends StatelessWidget {
  const AndroidMediaSessionTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const AndroidMediaSessionTestScreen(),
    );
  }
}

class AndroidMediaSessionTestScreen extends StatefulWidget {
  const AndroidMediaSessionTestScreen({super.key});

  @override
  State<AndroidMediaSessionTestScreen> createState() =>
      _AndroidMediaSessionTestScreenState();
}

class _AndroidMediaSessionTestScreenState
    extends State<AndroidMediaSessionTestScreen>
    with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel(
    'lyriko/android_media_session',
  );

  Timer? _timer;
  bool _hasAccess = false;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _sessions = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAccessAndSessions();

    _timer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _refreshSessions(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshAccessAndSessions();
    }
  }

  Future<void> _refreshAccessAndSessions() async {
    try {
      final enabled =
          await _channel.invokeMethod<bool>('isNotificationAccessEnabled') ??
              false;

      if (!mounted) return;

      setState(() {
        _hasAccess = enabled;
        _loading = false;
        _error = null;
      });

      if (enabled) {
        await _refreshSessions();
      } else if (mounted) {
        setState(() => _sessions = const []);
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '${error.code}: ${error.message ?? ''}';
      });
    }
  }

  Future<void> _openNotificationAccess() async {
    await _channel.invokeMethod<bool>('openNotificationAccessSettings');
  }

  Future<void> _refreshSessions() async {
    if (!_hasAccess) return;

    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('getSessions');

      final sessions = (raw ?? const <dynamic>[])
          .map(
            (item) => Map<String, dynamic>.from(
              item as Map,
            ),
          )
          .toList(growable: false);

      if (!mounted) return;

      setState(() {
        _sessions = sessions;
        _error = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;

      setState(() {
        _error = '${error.code}: ${error.message ?? ''}';
      });
    }
  }

  String _formatMs(Object? value) {
    final milliseconds = switch (value) {
      int number => number,
      num number => number.toInt(),
      _ => 0,
    };

    final totalSeconds = milliseconds ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final millis = milliseconds.abs() % 1000;

    if (hours > 0) {
      return '$hours:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}.'
          '${millis.toString().padLeft(3, '0')}';
    }

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
  }

  String _text(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? '—' : text;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Android MediaSession test'),
        actions: [
          IconButton(
            onPressed: _refreshAccessAndSessions,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _AccessCard(
                    hasAccess: _hasAccess,
                    onOpenSettings: _openNotificationAccess,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Active sessions: ${_sessions.length}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: !_hasAccess
                        ? const Center(
                            child: Text(
                              'Enable notification access first.',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : _sessions.isEmpty
                            ? const Center(
                                child: Text(
                                  'No active media sessions.\n'
                                  'Start Spotify or YouTube, play something, '
                                  'then return here.',
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : ListView.separated(
                                itemCount: _sessions.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final session = _sessions[index];
                                  return _SessionCard(
                                    index: index,
                                    packageName:
                                        _text(session['packageName']),
                                    title: _text(session['title']),
                                    artist: _text(session['artist']),
                                    albumArtist:
                                        _text(session['albumArtist']),
                                    album: _text(session['album']),
                                    state: _text(session['state']),
                                    position: _formatMs(
                                      session['estimatedPositionMs'],
                                    ),
                                    rawPosition: _formatMs(
                                      session['rawPositionMs'],
                                    ),
                                    duration: _formatMs(
                                      session['durationMs'],
                                    ),
                                    speed: session['playbackSpeed']
                                            ?.toString() ??
                                        '—',
                                    age: _formatMs(
                                      session['elapsedSinceUpdateMs'],
                                    ),
                                  );
                                },
                              ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _AccessCard extends StatelessWidget {
  const _AccessCard({
    required this.hasAccess,
    required this.onOpenSettings,
  });

  final bool hasAccess;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              hasAccess ? Icons.check_circle : Icons.warning_amber_rounded,
              size: 30,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasAccess
                        ? 'Notification access enabled'
                        : 'Notification access required',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasAccess
                        ? 'Lyriko can query active Android media sessions.'
                        : 'Android requires notification-listener access '
                            'to inspect media sessions from other apps.',
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: onOpenSettings,
              child: Text(hasAccess ? 'Settings' : 'Enable'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.index,
    required this.packageName,
    required this.title,
    required this.artist,
    required this.albumArtist,
    required this.album,
    required this.state,
    required this.position,
    required this.rawPosition,
    required this.duration,
    required this.speed,
    required this.age,
  });

  final int index;
  final String packageName;
  final String title;
  final String artist;
  final String albumArtist;
  final String album;
  final String state;
  final String position;
  final String rawPosition;
  final String duration;
  final String speed;
  final String age;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Session ${index + 1}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            _row('App', packageName),
            _row('Title', title),
            _row('Artist', artist),
            _row('Album artist', albumArtist),
            _row('Album', album),
            _row('State', state),
            _row('Position', position),
            _row('Raw position', rawPosition),
            _row('Duration', duration),
            _row('Speed', speed),
            _row('Timeline age', age),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}
