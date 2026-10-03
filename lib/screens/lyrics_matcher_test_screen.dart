import 'package:flutter/material.dart';

import '../services/lyrics_matcher_service.dart';

class LyricsMatcherTestScreen
    extends StatefulWidget {
  const LyricsMatcherTestScreen({
    super.key,
  });

  @override
  State<LyricsMatcherTestScreen>
      createState() =>
          _LyricsMatcherTestScreenState();
}

class _LyricsMatcherTestScreenState
    extends State<LyricsMatcherTestScreen> {
  final LyricsMatcherService _matcher =
      LyricsMatcherService();

  static const String _whisperText = '''
Is me upon the seams
Now I know this might sound crazy
But I've smelled the plastic daisies
''';

  bool _loading = false;

  LyricsMatchResult? _result;

  String? _error;

  Future<void> _runMatcher() async {
    setState(() {
      _loading = true;
      _result = null;
      _error = null;
    });

    try {
      final result =
          await _matcher.match(
        _whisperText,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _result = result;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  String _percentage(
    double value,
  ) {
    return '${(value * 100).toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    final best =
        _result?.bestMatch;

    return Scaffold(
      backgroundColor:
          const Color(0xFF090909),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(
              maxWidth: 700,
            ),
            child: Padding(
              padding:
                  const EdgeInsets.all(
                32,
              ),
              child: Column(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                crossAxisAlignment:
                    CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Lyrics Matcher',
                    textAlign:
                        TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight:
                          FontWeight.w700,
                    ),
                  ),

                  const SizedBox(
                    height: 30,
                  ),

                  Container(
                    padding:
                        const EdgeInsets.all(
                      20,
                    ),
                    decoration:
                        BoxDecoration(
                      color:
                          Colors.white
                              .withValues(
                        alpha: 0.05,
                      ),
                      borderRadius:
                          BorderRadius.circular(
                        18,
                      ),
                    ),
                    child: const Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Whisper output',
                          style: TextStyle(
                            color:
                                Colors.white54,
                            fontSize: 13,
                          ),
                        ),

                        SizedBox(
                          height: 12,
                        ),

                        Text(
                          _whisperText,
                          style: TextStyle(
                            color:
                                Colors.white,
                            fontSize: 18,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(
                    height: 25,
                  ),

                  FilledButton.icon(
                    onPressed:
                        _loading
                            ? null
                            : _runMatcher,
                    icon: const Icon(
                      Icons.search_rounded,
                    ),
                    label: Padding(
                      padding:
                          const EdgeInsets.symmetric(
                        vertical: 15,
                      ),
                      child: Text(
                        _loading
                            ? 'MATCHING...'
                            : 'MATCH LYRICS',
                      ),
                    ),
                  ),

                  if (_loading) ...[
                    const SizedBox(
                      height: 25,
                    ),
                    const LinearProgressIndicator(),
                  ],

                  if (_error != null) ...[
                    const SizedBox(
                      height: 25,
                    ),
                    Text(
                      _error!,
                      style:
                          const TextStyle(
                        color: Colors.redAccent,
                      ),
                    ),
                  ],

                  if (best != null) ...[
                    const SizedBox(
                      height: 35,
                    ),

                    Text(
                      'Detected: ${best.title}',
                      textAlign:
                          TextAlign.center,
                      style:
                          const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight:
                            FontWeight.w700,
                      ),
                    ),

                    const SizedBox(
                      height: 8,
                    ),

                    Text(
                      'Match ${_percentage(best.score)}',
                      textAlign:
                          TextAlign.center,
                      style:
                          const TextStyle(
                        color:
                            Colors.white54,
                        fontSize: 16,
                      ),
                    ),

                    const SizedBox(
                      height: 8,
                    ),

                    Text(
                      'Starting lyric line: '
                      '${best.lineIndex}',
                      textAlign:
                          TextAlign.center,
                      style:
                          const TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),

                    const SizedBox(
                      height: 20,
                    ),

                    Text(
                      best.matchedText,
                      textAlign:
                          TextAlign.center,
                      style:
                          const TextStyle(
                        color:
                            Colors.white70,
                        fontSize: 16,
                        height: 1.5,
                      ),
                    ),

                    const SizedBox(
                      height: 30,
                    ),

                    const Divider(
                      color: Colors.white12,
                    ),

                    const SizedBox(
                      height: 15,
                    ),

                    const Text(
                      'All candidates',
                      style: TextStyle(
                        color:
                            Colors.white54,
                        fontSize: 13,
                      ),
                    ),

                    const SizedBox(
                      height: 10,
                    ),

                    ..._result!.candidates
                        .map(
                      (candidate) =>
                          Padding(
                        padding:
                            const EdgeInsets.symmetric(
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                candidate
                                    .title,
                                style:
                                    const TextStyle(
                                  color:
                                      Colors.white,
                                ),
                              ),
                            ),
                            Text(
                              _percentage(
                                candidate
                                    .score,
                              ),
                              style:
                                  const TextStyle(
                                color:
                                    Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}