import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../services/synced_lyrics_service.dart';

class SongPreviewScreen
    extends StatefulWidget {
  final String jsonPath;

  const SongPreviewScreen({
    super.key,
    required this.jsonPath,
  });

  @override
  State<SongPreviewScreen> createState() =>
      _SongPreviewScreenState();
}

class _SongPreviewScreenState
    extends State<SongPreviewScreen> {
  final SyncedLyricsService
      _lyricsService =
      SyncedLyricsService();

  final AudioPlayer _player =
      AudioPlayer();

  final ItemScrollController
      _scrollController =
      ItemScrollController();

  StreamSubscription<Duration>?
      _positionSubscription;

  StreamSubscription<PlayerState>?
      _stateSubscription;

  SyncedLyricsSong? _song;

  String? _audioPath;

  int _positionMs = 0;
  int _activeLineIndex = 0;
  int _lastScrolledIndex = -1;

  bool _loading = true;
  bool _playing = false;

  String? _error;

  @override
  void initState() {
    super.initState();

    _load();
  }

  Future<void> _load() async {
    try {
      final song =
          await _lyricsService.loadSong(
        widget.jsonPath,
      );

      final audioPath =
          await _resolveAudioPath(
        song,
      );

      if (audioPath == null) {
        throw StateError(
          'The reference audio could not be found.\n\n'
          'This song does not contain audioPath '
          'in its JSON.',
        );
      }

      if (!await File(
        audioPath,
      ).exists()) {
        throw StateError(
          'Audio file not found:\n$audioPath',
        );
      }

      await _player.setFilePath(
        audioPath,
      );

      _positionSubscription =
          _player.positionStream.listen(
        (position) {
          if (!mounted) {
            return;
          }

          final milliseconds =
              position.inMilliseconds;

          final active =
              _lyricsService
                  .findActiveLineIndex(
            song,
            milliseconds,
          );

          final changed =
              active !=
                  _activeLineIndex;

          setState(() {
            _positionMs =
                milliseconds;

            if (active >= 0) {
              _activeLineIndex =
                  active;
            }
          });

          if (changed &&
              active >= 0) {
            _scrollToLine(
              active,
            );
          }
        },
      );

      _stateSubscription =
          _player
              .playerStateStream
              .listen(
        (state) {
          if (!mounted) {
            return;
          }

          setState(() {
            _playing =
                state.playing;
          });
        },
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _song = song;
        _audioPath = audioPath;
        _loading = false;
      });

      WidgetsBinding.instance
          .addPostFrameCallback(
        (_) {
          if (!mounted) {
            return;
          }

          _scrollToLine(
            0,
            force: true,
          );
        },
      );
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<String?> _resolveAudioPath(
    SyncedLyricsSong song,
  ) async {
    final direct =
        song.audioPath;

    if (direct != null &&
        direct.isNotEmpty &&
        await File(
          direct,
        ).exists()) {
      return direct;
    }

    //
    // Compatibility for Nobody:
    // its older JSON was created before
    // audioPath was stored.
    //
    if (song.title
            .toLowerCase()
            .trim() ==
        'nobody') {
      const oldFolder =
          r'F:\Nueva carpeta\Avenged Sevenfold - Life Is But A Dream (2023) Mp3 320kbps (PMEDIA)';

      final directory =
          Directory(
        oldFolder,
      );

      if (await directory.exists()) {
        await for (final entity
            in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) {
            continue;
          }

          final lower =
              entity.path
                  .toLowerCase();

          if (lower.endsWith(
                '.mp3',
              ) &&
              lower.contains(
                'nobody',
              )) {
            return entity.path;
          }
        }
      }
    }

    return null;
  }

  Future<void> _togglePlay() async {
    if (_player.playing) {
      await _player.pause();
      return;
    }

    if (_player.processingState ==
        ProcessingState.completed) {
      await _player.seek(
        Duration.zero,
      );
    }

    await _player.play();
  }

  Future<void> _seekTo(
    double value,
  ) async {
    final song =
        _song;

    if (song == null) {
      return;
    }

    final target =
        value
            .round()
            .clamp(
              0,
              song.durationMs,
            );

    await _player.seek(
      Duration(
        milliseconds:
            target,
      ),
    );
  }

  void _scrollToLine(
    int index, {
    bool force = false,
  }) {
    if (!_scrollController
        .isAttached) {
      return;
    }

    if (!force &&
        _lastScrolledIndex ==
            index) {
      return;
    }

    _lastScrolledIndex =
        index;

    _scrollController.scrollTo(
      index: index,
      alignment: 0.45,
      duration:
          const Duration(
        milliseconds: 350,
      ),
      curve:
          Curves.easeOutCubic,
    );
  }

  String _formatTime(
    int milliseconds,
  ) {
    final totalSeconds =
        milliseconds ~/ 1000;

    final minutes =
        totalSeconds ~/ 60;

    final seconds =
        totalSeconds % 60;

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _positionSubscription
        ?.cancel();

    _stateSubscription
        ?.cancel();

    _player.dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    if (_loading) {
      return const Scaffold(
        backgroundColor:
            Color(
          0xFF080808,
        ),
        body: Center(
          child:
              CircularProgressIndicator(),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor:
            const Color(
          0xFF080808,
        ),
        appBar: AppBar(
          backgroundColor:
              const Color(
            0xFF080808,
          ),
        ),
        body: Center(
          child: Padding(
            padding:
                const EdgeInsets.all(
              32,
            ),
            child:
                SelectableText(
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
        ),
      );
    }

    final song =
        _song!;

    return Scaffold(
      backgroundColor:
          const Color(
        0xFF080808,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets
                      .fromLTRB(
                20,
                16,
                24,
                8,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed:
                        () {
                      Navigator.pop(
                        context,
                      );
                    },
                    icon:
                        const Icon(
                      Icons
                          .arrow_back_rounded,
                    ),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment
                              .start,
                      children: [
                        Text(
                          song.title,
                          style:
                              const TextStyle(
                            fontSize:
                                23,
                            fontWeight:
                                FontWeight
                                    .w700,
                          ),
                        ),
                        Text(
                          song.artist,
                          style:
                              const TextStyle(
                            color:
                                Colors
                                    .white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets
                            .symmetric(
                      horizontal:
                          12,
                      vertical:
                          6,
                    ),
                    decoration:
                        BoxDecoration(
                      borderRadius:
                          BorderRadius
                              .circular(
                        20,
                      ),
                      color:
                          Colors.white
                              .withValues(
                        alpha:
                            0.06,
                      ),
                    ),
                    child:
                        const Text(
                      'SYNC PREVIEW',
                      style:
                          TextStyle(
                        fontSize:
                            10,
                        color:
                            Colors
                                .white54,
                        fontWeight:
                            FontWeight
                                .w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child:
                  ScrollablePositionedList
                      .builder(
                itemScrollController:
                    _scrollController,
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal:
                      48,
                  vertical:
                      160,
                ),
                itemCount:
                    song.lines.length,
                itemBuilder: (
                  context,
                  index,
                ) {
                  final active =
                      index ==
                          _activeLineIndex;

                  return Padding(
                    padding:
                        const EdgeInsets
                            .symmetric(
                      vertical:
                          11,
                    ),
                    child: Text(
                      song.lines[
                              index]
                          .text,
                      textAlign:
                          TextAlign
                              .center,
                      style:
                          TextStyle(
                        color:
                            active
                                ? Colors
                                    .white
                                : Colors
                                    .white30,
                        fontSize:
                            active
                                ? 32
                                : 24,
                        fontWeight:
                            active
                                ? FontWeight
                                    .w700
                                : FontWeight
                                    .w500,
                        height:
                            1.25,
                      ),
                    ),
                  );
                },
              ),
            ),

            Container(
              padding:
                  const EdgeInsets
                      .fromLTRB(
                28,
                16,
                28,
                26,
              ),
              decoration:
                  const BoxDecoration(
                color:
                    Color(
                  0xFF101010,
                ),
              ),
              child: Column(
                children: [
                  Slider(
                    value:
                        _positionMs
                            .toDouble()
                            .clamp(
                              0,
                              song.durationMs
                                  .toDouble(),
                            ),
                    min: 0,
                    max:
                        song.durationMs >
                                0
                            ? song
                                .durationMs
                                .toDouble()
                            : 1,
                    onChanged:
                        _seekTo,
                  ),

                  Row(
                    children: [
                      Text(
                        _formatTime(
                          _positionMs,
                        ),
                        style:
                            const TextStyle(
                          color:
                              Colors
                                  .white54,
                        ),
                      ),

                      const Spacer(),

                      IconButton.filled(
                        onPressed:
                            _togglePlay,
                        icon:
                            Icon(
                          _playing
                              ? Icons
                                  .pause_rounded
                              : Icons
                                  .play_arrow_rounded,
                          size:
                              34,
                        ),
                      ),

                      const Spacer(),

                      Text(
                        _formatTime(
                          song.durationMs,
                        ),
                        style:
                            const TextStyle(
                          color:
                              Colors
                                  .white54,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(
                    height: 8,
                  ),

                  Text(
                    _audioPath ?? '',
                    maxLines: 1,
                    overflow:
                        TextOverflow
                            .ellipsis,
                    style:
                        const TextStyle(
                      color:
                          Colors.white24,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}