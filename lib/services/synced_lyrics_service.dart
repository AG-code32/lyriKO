import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class SyncedLyricWord {
  final String text;
  final int startMs;
  final int endMs;

  const SyncedLyricWord({
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  factory SyncedLyricWord.fromJson(
    Map<String, dynamic> json,
  ) {
    return SyncedLyricWord(
      text:
          json['text'].toString(),
      startMs:
          (json['startMs'] as num)
              .toInt(),
      endMs:
          (json['endMs'] as num)
              .toInt(),
    );
  }
}

class SyncedLyricLine {
  final int startMs;
  final int endMs;

  final String text;

  final List<SyncedLyricWord> words;

  const SyncedLyricLine({
    required this.startMs,
    required this.endMs,
    required this.text,
    required this.words,
  });

  factory SyncedLyricLine.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawWords =
        (json['words']
                as List<dynamic>?) ??
            const [];

    return SyncedLyricLine(
      startMs:
          (json['startMs']
                  as num)
              .toInt(),

      endMs:
          (json['endMs']
                  as num)
              .toInt(),

      text:
          json['text']
              .toString(),

      words:
          rawWords
              .map(
                (item) =>
                    SyncedLyricWord
                        .fromJson(
                  Map<String, dynamic>
                      .from(
                    item as Map,
                  ),
                ),
              )
              .toList(),
    );
  }
}

class SyncedLyricsSong {
  final String songId;
  final String title;
  final String artist;

  final List<SyncedLyricLine>
      lines;

  final int durationMs;

  const SyncedLyricsSong({
    required this.songId,
    required this.title,
    required this.artist,
    required this.lines,
    required this.durationMs,
  });
}

class SyncedLyricsService {
  String get _userProfile {
    final value =
        Platform.environment[
            'USERPROFILE'];

    if (value == null ||
        value.isEmpty) {
      throw StateError(
        'Could not determine '
        'USERPROFILE.',
      );
    }

    return value;
  }

  String get _developmentNobodyPath =>
      '$_userProfile\\Desktop\\fluter_projects\\Lyriko\\lyrics_app\\assets\\lyrics\\Avenged Sevenfold - Nobody.json';

  Future<String>
      _loadNobodyJson() async {
    //
    // During Windows development,
    // read directly from the project.
    //
    // This lets REBUILD SYNC update the
    // lyrics without rebuilding Flutter.
    //
    if (Platform.isWindows) {
      final file =
          File(
        _developmentNobodyPath,
      );

      if (await file.exists()) {
        return file.readAsString(
          encoding:
              utf8,
        );
      }
    }

    //
    // Production / fallback:
    // bundled Flutter asset.
    //
    return rootBundle.loadString(
      'assets/lyrics/Avenged Sevenfold - Nobody.json',
    );
  }

  Future<SyncedLyricsSong>
      loadNobody() async {
    final raw =
        await _loadNobodyJson();

    final json =
        jsonDecode(raw)
            as Map<String, dynamic>;

    final rawLines =
        json['lines']
            as List<dynamic>;

    final lines =
        rawLines
            .map(
              (item) =>
                  SyncedLyricLine
                      .fromJson(
                Map<String, dynamic>
                    .from(
                  item as Map,
                ),
              ),
            )
            .toList();

    final durationMs =
        json['durationMs'] !=
                null
            ? (json['durationMs']
                    as num)
                .toInt()
            : lines.isEmpty
                ? 0
                : lines.last.endMs;

    return SyncedLyricsSong(
      songId:
          json['songId']
                  ?.toString() ??
              'avenged-sevenfold-nobody',

      title:
          json['title']
                  ?.toString() ??
              'Nobody',

      artist:
          json['artist']
                  ?.toString() ??
              'Avenged Sevenfold',

      lines:
          lines,

      durationMs:
          durationMs,
    );
  }

  int findActiveLineIndex(
    SyncedLyricsSong song,
    int positionMs,
  ) {
    if (song.lines.isEmpty) {
      return -1;
    }

    if (positionMs >=
        song.durationMs) {
      return song.lines.length - 1;
    }

    for (var i = 0;
        i < song.lines.length;
        i++) {
      final line =
          song.lines[i];

      if (positionMs >=
              line.startMs &&
          positionMs <=
              line.endMs) {
        return i;
      }
    }

    return -1;
  }

  int findNearestLineIndex(
    SyncedLyricsSong song,
    int positionMs,
  ) {
    if (song.lines.isEmpty) {
      return -1;
    }

    for (var i = 0;
        i < song.lines.length;
        i++) {
      if (song.lines[i].startMs >=
          positionMs) {
        return i;
      }
    }

    return song.lines.length - 1;
  }
}