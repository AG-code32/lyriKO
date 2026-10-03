import 'dart:ui';

import 'package:flutter/material.dart';

import '../data/demo_lyrics.dart';
import '../services/lyrics_sync_service.dart';
import '../widgets/karaoke_lyric.dart';

class LyricsScreen extends StatefulWidget {
  const LyricsScreen({super.key});

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  late final LyricsSyncService _syncService;

  final ScrollController _scrollController = ScrollController();

  late final List<GlobalKey> _lineKeys;

  int _currentLine = -1;

  @override
  void initState() {
    super.initState();

    _lineKeys = List.generate(
      demoLyrics.length,
      (_) => GlobalKey(),
    );

    _syncService = LyricsSyncService(
      lyrics: demoLyrics,
    );

    _syncService.positionStream.listen((position) {
      final newLine =
          _syncService.getCurrentLineIndex(position);

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
  }

  void _scrollToCurrentLine() {
    if (_currentLine < 0 ||
        _currentLine >= _lineKeys.length ||
        !_scrollController.hasClients) {
      return;
    }

    final currentContext =
        _lineKeys[_currentLine].currentContext;

    // Si Flutter tiene construida la línea,
    // usamos su posición real.
    if (currentContext != null) {
      Scrollable.ensureVisible(
        currentContext,
        alignment: 0.38,
        duration: const Duration(milliseconds: 550),
        curve: Curves.easeOutCubic,
      );

      return;
    }

    // Fallback:
    // si la línea está demasiado lejos y ListView.builder
    // todavía no la tiene construida, hacemos una aproximación.
    const estimatedItemHeight = 115.0;

    final estimatedOffset =
        _currentLine * estimatedItemHeight;

    final maxScroll =
        _scrollController.position.maxScrollExtent;

    _scrollController.animateTo(
      estimatedOffset.clamp(0.0, maxScroll),
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutCubic,
    );

    // Después del movimiento Flutter ya debería haber
    // construido esa zona. La centramos con precisión.
    Future.delayed(
      const Duration(milliseconds: 600),
      () {
        if (!mounted) return;

        final newContext =
            _lineKeys[_currentLine].currentContext;

        if (newContext == null) return;

        Scrollable.ensureVisible(
          newContext,
          alignment: 0.38,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      },
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
    final currentPosition =
        _syncService.position;

    final newPosition =
        currentPosition - const Duration(seconds: 5);

    if (newPosition.isNegative) {
      _syncService.seek(Duration.zero);
    } else {
      _syncService.seek(newPosition);
    }
  }

  void _seekForward() {
    final currentPosition =
        _syncService.position;

    _syncService.seek(
      currentPosition + const Duration(seconds: 5),
    );
  }

  void _togglePlayback() {
    setState(() {
      _syncService.toggle();
    });
  }

  void _reset() {
    // 1. Reiniciamos el tiempo.
    _syncService.reset();

    // 2. La primera línea vuelve a ser la activa.
    setState(() {
      _currentLine = 0;
    });

    // 3. Regresamos físicamente el ListView al inicio.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      _scrollController.animateTo(
        _scrollController.position.minScrollExtent,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _syncService.dispose();
    _scrollController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final position =
        _syncService.position;

    return Scaffold(
      backgroundColor: const Color(0xFF090909),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),

            Expanded(
              child: _buildLyrics(position),
            ),

            _buildControls(position),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(
        28,
        22,
        28,
        10,
      ),
      child: Column(
        children: [
          Text(
            'Demo Song',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 5),
          Text(
            'Lyrics Prototype',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white54,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLyrics(Duration position) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(
        horizontal: 32,
        vertical: 220,
      ),
      itemCount: demoLyrics.length,
      itemBuilder: (context, index) {
        final line =
            demoLyrics[index];

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

  Widget _buildControls(Duration position) {
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
        mainAxisAlignment:
            MainAxisAlignment.center,
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
              _syncService.isPlaying
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