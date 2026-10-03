import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/song.dart';
import '../services/lyrics_sync_service.dart';
import '../services/song_loader_service.dart';
import '../widgets/karaoke_lyric.dart';

class LyricsScreen extends StatefulWidget {
  const LyricsScreen({super.key});

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  final SongLoaderService _songLoader =
      SongLoaderService();

  final ScrollController _scrollController =
      ScrollController();

  LyricsSyncService? _syncService;

  Song? _song;

  List<GlobalKey> _lineKeys = [];

  int _currentLine = -1;

  bool _loading = true;

  String? _error;

  @override
  void initState() {
    super.initState();

    _loadSong();
  }

  Future<void> _loadSong() async {
    try {
      final song = await _songLoader.loadFromAsset(
        'assets/lyrics/demo_song.json',
      );

      final syncService = LyricsSyncService(
        lyrics: song.lyrics,
      );

      _lineKeys = List.generate(
        song.lyrics.length,
        (_) => GlobalKey(),
      );

      syncService.positionStream.listen((position) {
        if (!mounted) return;

        final newLine =
            syncService.getCurrentLineIndex(position);

        if (newLine != _currentLine) {
          setState(() {
            _currentLine = newLine;
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToCurrentLine();
          });
        } else {
          setState(() {});
        }
      });

      if (!mounted) return;

      setState(() {
        _song = song;
        _syncService = syncService;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _scrollToCurrentLine() {
    if (_currentLine < 0 ||
        _currentLine >= _lineKeys.length ||
        !_scrollController.hasClients) {
      return;
    }

    final currentContext =
        _lineKeys[_currentLine].currentContext;

    if (currentContext != null) {
      Scrollable.ensureVisible(
        currentContext,
        alignment: 0.38,
        duration: const Duration(milliseconds: 550),
        curve: Curves.easeOutCubic,
      );

      return;
    }

    const estimatedItemHeight = 115.0;

    final estimatedOffset =
        _currentLine * estimatedItemHeight;

    final maxScroll =
        _scrollController.position.maxScrollExtent;

    _scrollController.animateTo(
      estimatedOffset.clamp(
        0.0,
        maxScroll,
      ),
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutCubic,
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');

    final seconds = duration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');

    return '$minutes:$seconds';
  }

  void _seekBackward() {
    final syncService = _syncService;

    if (syncService == null) return;

    final newPosition =
        syncService.position - const Duration(seconds: 5);

    syncService.seek(
      newPosition.isNegative
          ? Duration.zero
          : newPosition,
    );
  }

  void _seekForward() {
    final syncService = _syncService;

    if (syncService == null) return;

    syncService.seek(
      syncService.position +
          const Duration(seconds: 5),
    );
  }

  void _togglePlayback() {
    final syncService = _syncService;

    if (syncService == null) return;

    setState(() {
      syncService.toggle();
    });
  }

  void _reset() {
    final syncService = _syncService;

    if (syncService == null) return;

    syncService.reset();

    setState(() {
      _currentLine = 0;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }

      _scrollController.animateTo(
        _scrollController.position.minScrollExtent,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _syncService?.dispose();
    _scrollController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFF090909),
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF090909),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Error loading lyrics\n\n$_error',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
              ),
            ),
          ),
        ),
      );
    }

    final song = _song!;
    final syncService = _syncService!;
    final position = syncService.position;

    return Scaffold(
      backgroundColor: const Color(0xFF090909),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(song),

            Expanded(
              child: _buildLyrics(
                song,
                position,
              ),
            ),

            _buildControls(
              syncService,
              position,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(Song song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        28,
        22,
        28,
        10,
      ),
      child: Column(
        children: [
          Text(
            song.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            song.artist,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLyrics(
    Song song,
    Duration position,
  ) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(
        horizontal: 32,
        vertical: 220,
      ),
      itemCount: song.lyrics.length,
      itemBuilder: (context, index) {
        final line = song.lyrics[index];

        final isCurrent =
            index == _currentLine;

        final isPast =
            _currentLine >= 0 &&
            index < _currentLine;

        final progress = isCurrent
            ? line.progress(position)
            : 0.0;

        return Container(
          key: _lineKeys[index],
          constraints: const BoxConstraints(
            minHeight: 115,
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(
            vertical: 22,
            horizontal: 20,
          ),
          child: KaraokeLyric(
            text: line.text,
            progress: progress,
            isActive: isCurrent,
            isPast: isPast,
          ),
        );
      },
    );
  }

  Widget _buildControls(
    LyricsSyncService syncService,
    Duration position,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        30,
        18,
        30,
        30,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF090909),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _formatDuration(position),
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 14,
              fontFeatures: [
                FontFeature.tabularFigures(),
              ],
            ),
          ),

          const SizedBox(width: 25),

          IconButton(
            onPressed: _seekBackward,
            icon: const Icon(
              Icons.replay_5_rounded,
            ),
            color: Colors.white,
          ),

          const SizedBox(width: 10),

          IconButton.filled(
            onPressed: _togglePlayback,
            iconSize: 32,
            padding: const EdgeInsets.all(18),
            icon: Icon(
              syncService.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
            ),
          ),

          const SizedBox(width: 10),

          IconButton(
            onPressed: _seekForward,
            icon: const Icon(
              Icons.forward_5_rounded,
            ),
            color: Colors.white,
          ),

          const SizedBox(width: 25),

          IconButton(
            onPressed: _reset,
            icon: const Icon(
              Icons.restart_alt_rounded,
            ),
            color: Colors.white54,
          ),
        ],
      ),
    );
  }
}