import 'dart:async';

import 'package:flutter/material.dart';

import 'services/windows_media_session_service.dart';

void main() {
  WidgetsFlutterBinding
      .ensureInitialized();

  runApp(
    const MediaSessionTestApp(),
  );
}

class MediaSessionTestApp
    extends StatelessWidget {
  const MediaSessionTestApp({
    super.key,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return MaterialApp(
      debugShowCheckedModeBanner:
          false,

      theme:
          ThemeData.dark(),

      home:
          const MediaSessionTestScreen(),
    );
  }
}

class MediaSessionTestScreen
    extends StatefulWidget {
  const MediaSessionTestScreen({
    super.key,
  });

  @override
  State<MediaSessionTestScreen>
      createState() =>
          _MediaSessionTestScreenState();
}

class _MediaSessionTestScreenState
    extends State<MediaSessionTestScreen> {
  final WindowsMediaSessionService
      _mediaService =
      WindowsMediaSessionService();

  Timer? _timer;

  bool _initializing =
      true;

  bool _refreshing =
      false;

  String? _error;

  WindowsMediaSessionState?
      _currentSession;

  List<WindowsMediaSessionState>
      _sessions =
      [];

  @override
  void initState() {
    super.initState();

    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final initialized =
          await _mediaService
              .initialize();

      if (!initialized) {
        if (!mounted) {
          return;
        }

        setState(() {
          _initializing =
              false;

          _error =
              'Windows Media Session '
              'could not be initialized.';
        });

        return;
      }

      await _refresh();

      _timer =
          Timer.periodic(
        const Duration(
          seconds:
              1,
        ),
        (_) {
          _refresh();
        },
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _initializing =
            false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _initializing =
            false;

        _error =
            e.toString();
      });
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }

    _refreshing =
        true;

    try {
      final current =
          await _mediaService
              .getState();

      final sessions =
          await _mediaService
              .getSessions();

      print('');
      print(
        '==========================================',
      );
      print(
        'CURRENT WINDOWS MEDIA SESSION',
      );
      print(
        current,
      );
      print(
        '------------------------------------------',
      );
      print(
        'ALL WINDOWS MEDIA SESSIONS: '
        '${sessions.length}',
      );

      for (var i = 0;
          i < sessions.length;
          i++) {
        print(
          'SESSION ${i + 1}: '
          '${sessions[i]}',
        );
      }

      print(
        '==========================================',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _currentSession =
            current;

        _sessions =
            sessions;

        _error =
            null;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error =
            e.toString();
      });
    } finally {
      _refreshing =
          false;
    }
  }

  String _formatTime(
    int milliseconds,
  ) {
    if (milliseconds <
        0) {
      milliseconds =
          0;
    }

    final totalSeconds =
        milliseconds ~/
            1000;

    final hours =
        totalSeconds ~/
            3600;

    final minutes =
        (totalSeconds %
                3600) ~/
            60;

    final seconds =
        totalSeconds %
            60;

    if (hours > 0) {
      return '$hours:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  String _statusText(
    WindowsMediaPlaybackStatus
        status,
  ) {
    switch (status) {
      case WindowsMediaPlaybackStatus
            .playing:
        return 'PLAYING';

      case WindowsMediaPlaybackStatus
            .paused:
        return 'PAUSED';

      case WindowsMediaPlaybackStatus
            .stopped:
        return 'STOPPED';

      case WindowsMediaPlaybackStatus
            .changing:
        return 'CHANGING';

      case WindowsMediaPlaybackStatus
            .opened:
        return 'OPENED';

      case WindowsMediaPlaybackStatus
            .closed:
        return 'CLOSED';

      case WindowsMediaPlaybackStatus
            .unavailable:
        return 'UNAVAILABLE';

      case WindowsMediaPlaybackStatus
            .unknown:
        return 'UNKNOWN';
    }
  }

  Color _statusColor(
    WindowsMediaPlaybackStatus
        status,
  ) {
    switch (status) {
      case WindowsMediaPlaybackStatus
            .playing:
        return Colors.greenAccent;

      case WindowsMediaPlaybackStatus
            .paused:
        return Colors.orangeAccent;

      case WindowsMediaPlaybackStatus
            .stopped:
        return Colors.redAccent;

      default:
        return Colors.white54;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      backgroundColor:
          const Color(
        0xFF080808,
      ),

      appBar:
          AppBar(
        backgroundColor:
            const Color(
          0xFF101010,
        ),

        title:
            const Text(
          'Windows Media Sessions',
        ),
      ),

      body:
          _initializing
              ? const Center(
                  child:
                      CircularProgressIndicator(),
                )
              : _error != null
                  ? Center(
                      child:
                          Padding(
                        padding:
                            const EdgeInsets.all(
                          24,
                        ),

                        child:
                            Text(
                          _error!,
                          textAlign:
                              TextAlign.center,

                          style:
                              const TextStyle(
                            color:
                                Colors.redAccent,
                          ),
                        ),
                      ),
                    )
                  : _buildContent(),
    );
  }

  Widget _buildContent() {
    return ListView(
      padding:
          const EdgeInsets.all(
        24,
      ),

      children: [
        const Text(
          'CURRENT SESSION',
          style:
              TextStyle(
            color:
                Colors.white54,

            fontSize:
                12,

            fontWeight:
                FontWeight.bold,

            letterSpacing:
                1.2,
          ),
        ),

        const SizedBox(
          height:
              12,
        ),

        if (_currentSession !=
            null)
          _sessionCard(
            _currentSession!,
            current:
                true,
          ),

        const SizedBox(
          height:
              32,
        ),

        Text(
          'ALL SESSIONS (${_sessions.length})',
          style:
              const TextStyle(
            color:
                Colors.white54,

            fontSize:
                12,

            fontWeight:
                FontWeight.bold,

            letterSpacing:
                1.2,
          ),
        ),

        const SizedBox(
          height:
              12,
        ),

        if (_sessions.isEmpty)
          const Padding(
            padding:
                EdgeInsets.all(
              20,
            ),

            child:
                Text(
              'Windows returned no media sessions.',
              style:
                  TextStyle(
                color:
                    Colors.white54,
              ),
            ),
          ),

        for (var i = 0;
            i < _sessions.length;
            i++) ...[
          _sessionCard(
            _sessions[i],
            index:
                i + 1,
          ),

          const SizedBox(
            height:
                16,
          ),
        ],
      ],
    );
  }

  Widget _sessionCard(
    WindowsMediaSessionState
        state, {
    int? index,
    bool current = false,
  }) {
    final statusColor =
        _statusColor(
      state.playbackStatus,
    );

    return Container(
      padding:
          const EdgeInsets.all(
        20,
      ),

      decoration:
          BoxDecoration(
        color:
            Colors.white
                .withValues(
          alpha:
              0.05,
        ),

        borderRadius:
            BorderRadius.circular(
          14,
        ),

        border:
            Border.all(
          color:
              current
                  ? Colors.white
                      .withValues(
                      alpha:
                          0.25,
                    )
                  : Colors.white
                      .withValues(
                      alpha:
                          0.08,
                    ),
        ),
      ),

      child:
          Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,

        children: [
          Row(
            children: [
              Container(
                width:
                    10,
                height:
                    10,

                decoration:
                    BoxDecoration(
                  shape:
                      BoxShape.circle,

                  color:
                      statusColor,
                ),
              ),

              const SizedBox(
                width:
                    10,
              ),

              Expanded(
                child:
                    Text(
                  current
                      ? 'CURRENT SESSION'
                      : 'SESSION $index',

                  style:
                      const TextStyle(
                    color:
                        Colors.white,

                    fontSize:
                        16,

                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),

              Text(
                _statusText(
                  state
                      .playbackStatus,
                ),

                style:
                    TextStyle(
                  color:
                      statusColor,

                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ],
          ),

          const SizedBox(
            height:
                18,
          ),

          _info(
            'App',
            state.sourceAppId,
          ),

          _info(
            'Title',
            state.title,
          ),

          _info(
            'Artist',
            state.artist,
          ),

          _info(
            'Album artist',
            state.albumArtist,
          ),

          _info(
            'Album',
            state.albumTitle,
          ),

          _info(
            'Playback type',
            state.playbackType,
          ),

          _info(
            'Genres',
            state.genres.isEmpty
                ? ''
                : state.genres
                    .join(
                    ', ',
                  ),
          ),

          _info(
            'Track number',
            state.trackNumber ==
                    0
                ? ''
                : state.trackNumber
                    .toString(),
          ),

          _info(
            'Position',
            '${_formatTime(state.positionMs)} '
            '(${state.positionMs} ms)',
          ),

          _info(
            'Duration',
            '${_formatTime(state.durationMs)} '
            '(${state.durationMs} ms)',
          ),

          _info(
            'Start',
            '${state.startTimeMs} ms',
          ),

          _info(
            'End',
            '${state.endTimeMs} ms',
          ),
        ],
      ),
    );
  }

  Widget _info(
    String label,
    String value,
  ) {
    final shown =
        value.trim().isEmpty
            ? '—'
            : value;

    return Padding(
      padding:
          const EdgeInsets.only(
        bottom:
            8,
      ),

      child:
          Row(
        crossAxisAlignment:
            CrossAxisAlignment.start,

        children: [
          SizedBox(
            width:
                140,

            child:
                Text(
              label,

              style:
                  const TextStyle(
                color:
                    Colors.white38,
              ),
            ),
          ),

          Expanded(
            child:
                Text(
              shown,

              style:
                  const TextStyle(
                color:
                    Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}