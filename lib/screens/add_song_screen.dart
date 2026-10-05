import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/lyrics_sync_builder_service.dart';
import '../services/synced_lyrics_service.dart';

class AddSongScreen
    extends StatefulWidget {
  const AddSongScreen({
    super.key,
  });

  @override
  State<AddSongScreen>
      createState() =>
          _AddSongScreenState();
}

class _AddSongScreenState
    extends State<AddSongScreen> {
  final LyricsSyncBuilderService
      _builder =
      LyricsSyncBuilderService();

  final SyncedLyricsService
      _lyricsService =
      SyncedLyricsService();

  final TextEditingController
      _titleController =
      TextEditingController();

  final TextEditingController
      _artistController =
      TextEditingController();

  final TextEditingController
      _lyricsController =
      TextEditingController();

  String? _audioPath;

  String? _status;

  String? _error;

  String? _createdJsonPath;

  bool _building = false;

  int get _lineCount =>
      _builder
          .cleanLyrics(
            _lyricsController.text,
          )
          .length;

  Future<void> _pickAudio() async {
    final file =
        await FilePicker.pickFile(
      dialogTitle:
          'Select song audio',

      type:
          FileType.custom,

      allowedExtensions: [
        'mp3',
        'wav',
        'flac',
        'm4a',
        'aac',
        'ogg',
      ],
    );

    if (file == null ||
        file.path == null ||
        file.path!.isEmpty) {
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _audioPath =
          file.path;

      _error = null;

      _status = null;

      _createdJsonPath =
          null;
    });
  }

  Future<bool>
      _checkDuplicate({
    required String artist,
    required String title,
  }) async {
    final existing =
        await _lyricsService
            .findExistingSong(
      artist: artist,
      title: title,
    );

    if (existing == null) {
      return false;
    }

    if (!mounted) {
      return true;
    }

    final calibrated =
        existing
            .manualCalibrationCount;

    await showDialog<void>(
      context: context,
      builder: (
        dialogContext,
      ) {
        return AlertDialog(
          title:
              const Text(
            'Song already exists',
          ),
          content: Column(
            mainAxisSize:
                MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Text(
                existing.title,
                style:
                    const TextStyle(
                  fontSize: 18,
                  fontWeight:
                      FontWeight.w700,
                ),
              ),
              const SizedBox(
                height: 3,
              ),
              Text(
                existing.artist,
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                ),
              ),
              const SizedBox(
                height: 18,
              ),
              const Text(
                'This song is already in your Lyriko library.',
              ),
              if (calibrated >
                  0) ...[
                const SizedBox(
                  height: 12,
                ),
                Text(
                  '$calibrated lyric lines have manual calibration.',
                  style:
                      const TextStyle(
                    color:
                        Colors.greenAccent,
                    fontWeight:
                        FontWeight.w600,
                  ),
                ),
                const SizedBox(
                  height: 8,
                ),
                const Text(
                  'The existing calibration will not be overwritten.',
                  style:
                      TextStyle(
                    color:
                        Colors.white54,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed:
                  () {
                Navigator.pop(
                  dialogContext,
                );
              },
              child:
                  const Text(
                'OK',
              ),
            ),
          ],
        );
      },
    );

    return true;
  }

  Future<void> _generate() async {
    if (_building) {
      return;
    }

    final title =
        _titleController
            .text
            .trim();

    final artist =
        _artistController
            .text
            .trim();

    final lyrics =
        _lyricsController.text;

    final audioPath =
        _audioPath;

    if (title.isEmpty ||
        artist.isEmpty ||
        audioPath == null ||
        audioPath.isEmpty ||
        _builder
            .cleanLyrics(
              lyrics,
            )
            .isEmpty) {
      setState(() {
        _error =
            'Title, artist, audio and lyrics are required.';
      });

      return;
    }

    //
    // -------------------------------------------------
    // DUPLICATE CHECK
    // -------------------------------------------------
    //
    // This happens BEFORE CTC.
    //
    // Therefore:
    // - no 20 minute unnecessary alignment
    // - no JSON overwrite
    // - no fingerprint DB modification
    // - no danger to Nobody calibration
    //
    final duplicate =
        await _checkDuplicate(
      artist: artist,
      title: title,
    );

    if (duplicate) {
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _building = true;

      _error = null;

      _status =
          'Generating automatic CTC sync...';

      _createdJsonPath =
          null;
    });

    final result =
        await _builder
            .buildSong(
      SongBuildRequest(
        title: title,
        artist: artist,
        audioPath: audioPath,
        lyricsText: lyrics,
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _building = false;

      if (result.success) {
        _status =
            '${result.message}\n'
            'Completed in '
            '${result.elapsed.inSeconds}s';

        _createdJsonPath =
            result.jsonPath;
      } else {
        _status = null;

        _error =
            result.message;
      }
    });
  }

  @override
  void dispose() {
    _titleController.dispose();

    _artistController.dispose();

    _lyricsController.dispose();

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

      appBar: AppBar(
        backgroundColor:
            const Color(
          0xFF080808,
        ),
        title:
            const Text(
          'Add Song',
        ),
      ),

      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(
              maxWidth: 900,
            ),
            child:
                SingleChildScrollView(
              padding:
                  const EdgeInsets
                      .fromLTRB(
                28,
                20,
                28,
                40,
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment
                        .stretch,
                children: [
                  const Text(
                    'Create synchronized lyrics',
                    style:
                        TextStyle(
                      color:
                          Colors.white,
                      fontSize: 28,
                      fontWeight:
                          FontWeight
                              .w800,
                    ),
                  ),

                  const SizedBox(
                    height: 8,
                  ),

                  const Text(
                    'Select the reference audio and paste the lyrics. '
                    'Lyriko will generate an automatic CTC synchronization. '
                    'You can preview it first and calibrate only if necessary.',
                    style:
                        TextStyle(
                      color:
                          Colors.white54,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),

                  const SizedBox(
                    height: 28,
                  ),

                  Row(
                    children: [
                      Expanded(
                        child:
                            TextField(
                          controller:
                              _artistController,
                          enabled:
                              !_building,
                          decoration:
                              const InputDecoration(
                            labelText:
                                'Artist',
                            border:
                                OutlineInputBorder(),
                          ),
                        ),
                      ),

                      const SizedBox(
                        width: 16,
                      ),

                      Expanded(
                        child:
                            TextField(
                          controller:
                              _titleController,
                          enabled:
                              !_building,
                          decoration:
                              const InputDecoration(
                            labelText:
                                'Song title',
                            border:
                                OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(
                    height: 18,
                  ),

                  OutlinedButton.icon(
                    onPressed:
                        _building
                            ? null
                            : _pickAudio,
                    icon:
                        const Icon(
                      Icons
                          .audio_file_rounded,
                    ),
                    label: Padding(
                      padding:
                          const EdgeInsets
                              .symmetric(
                        vertical: 14,
                      ),
                      child: Text(
                        _audioPath ==
                                null
                            ? 'SELECT AUDIO'
                            : _audioPath!,
                        maxLines: 1,
                        overflow:
                            TextOverflow
                                .ellipsis,
                      ),
                    ),
                  ),

                  const SizedBox(
                    height: 18,
                  ),

                  TextField(
                    controller:
                        _lyricsController,
                    enabled:
                        !_building,
                    minLines: 16,
                    maxLines: 26,
                    onChanged:
                        (_) {
                      setState(
                        () {},
                      );
                    },
                    decoration:
                        const InputDecoration(
                      labelText:
                          'Paste lyrics',
                      alignLabelWithHint:
                          true,
                      hintText:
                          'Paste the lyrics here exactly in singing order...',
                      border:
                          OutlineInputBorder(),
                    ),
                  ),

                  const SizedBox(
                    height: 10,
                  ),

                  Text(
                    '$_lineCount lyric lines detected',
                    textAlign:
                        TextAlign.right,
                    style:
                        const TextStyle(
                      color:
                          Colors.white38,
                      fontSize: 12,
                    ),
                  ),

                  const SizedBox(
                    height: 24,
                  ),

                  FilledButton.icon(
                    onPressed:
                        _building
                            ? null
                            : _generate,
                    icon:
                        _building
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth:
                                      2,
                                ),
                              )
                            : const Icon(
                                Icons
                                    .auto_awesome_rounded,
                              ),
                    label: Padding(
                      padding:
                          const EdgeInsets
                              .symmetric(
                        vertical: 16,
                      ),
                      child: Text(
                        _building
                            ? 'GENERATING...'
                            : 'GENERATE SONG',
                        style:
                            const TextStyle(
                          fontWeight:
                              FontWeight
                                  .w700,
                        ),
                      ),
                    ),
                  ),

                  if (_status !=
                      null) ...[
                    const SizedBox(
                      height: 22,
                    ),
                    Container(
                      padding:
                          const EdgeInsets
                              .all(
                        16,
                      ),
                      decoration:
                          BoxDecoration(
                        color:
                            Colors.greenAccent
                                .withValues(
                          alpha: 0.08,
                        ),
                        borderRadius:
                            BorderRadius
                                .circular(
                          12,
                        ),
                        border:
                            Border.all(
                          color:
                              Colors.greenAccent
                                  .withValues(
                            alpha: 0.25,
                          ),
                        ),
                      ),
                      child: Text(
                        _status!,
                        style:
                            const TextStyle(
                          color:
                              Colors.greenAccent,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],

                  if (_createdJsonPath !=
                      null) ...[
                    const SizedBox(
                      height: 8,
                    ),
                    SelectableText(
                      _createdJsonPath!,
                      style:
                          const TextStyle(
                        color:
                            Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                  ],

                  if (_error !=
                      null) ...[
                    const SizedBox(
                      height: 22,
                    ),
                    Container(
                      padding:
                          const EdgeInsets
                              .all(
                        16,
                      ),
                      decoration:
                          BoxDecoration(
                        color:
                            Colors.redAccent
                                .withValues(
                          alpha: 0.08,
                        ),
                        borderRadius:
                            BorderRadius
                                .circular(
                          12,
                        ),
                        border:
                            Border.all(
                          color:
                              Colors.redAccent
                                  .withValues(
                            alpha: 0.25,
                          ),
                        ),
                      ),
                      child:
                          SelectableText(
                        _error!,
                        style:
                            const TextStyle(
                          color:
                              Colors.redAccent,
                          height: 1.4,
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