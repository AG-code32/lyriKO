import 'dart:math';

import 'package:flutter/services.dart';

class LyricsSource {
  final String id;
  final String title;
  final String assetPath;

  const LyricsSource({
    required this.id,
    required this.title,
    required this.assetPath,
  });
}

class LyricsMatchCandidate {
  final String songId;
  final String title;
  final double score;
  final int lineIndex;
  final String matchedText;

  const LyricsMatchCandidate({
    required this.songId,
    required this.title,
    required this.score,
    required this.lineIndex,
    required this.matchedText,
  });
}

class LyricsMatchResult {
  final LyricsMatchCandidate? bestMatch;
  final List<LyricsMatchCandidate> candidates;

  const LyricsMatchResult({
    required this.bestMatch,
    required this.candidates,
  });
}

class LyricsMatcherService {
  static const List<LyricsSource> _sources = [
    LyricsSource(
      id: 'game_over',
      title: 'Game Over',
      assetPath: 'assets/lyrics/Lyric1.txt',
    ),
    LyricsSource(
      id: 'mattel',
      title: 'Mattel',
      assetPath: 'assets/lyrics/Lyric2.txt',
    ),
    LyricsSource(
      id: 'nobody',
      title: 'Nobody',
      assetPath: 'assets/lyrics/Lyric3.txt',
    ),
  ];

  Future<LyricsMatchResult> match(
    String recognizedText,
  ) async {
    final normalizedQuery =
        _normalize(recognizedText);

    if (normalizedQuery.isEmpty) {
      return const LyricsMatchResult(
        bestMatch: null,
        candidates: [],
      );
    }

    final results =
        <LyricsMatchCandidate>[];

    for (final source in _sources) {
      final rawLyrics =
          await rootBundle.loadString(
        source.assetPath,
      );

      final lines = rawLyrics
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();

      final result =
          _findBestWindow(
        source: source,
        lines: lines,
        query: normalizedQuery,
      );

      results.add(result);
    }

    results.sort(
      (a, b) =>
          b.score.compareTo(a.score),
    );

    final best =
        results.isNotEmpty
            ? results.first
            : null;

    return LyricsMatchResult(
      bestMatch: best,
      candidates: results,
    );
  }

  LyricsMatchCandidate _findBestWindow({
    required LyricsSource source,
    required List<String> lines,
    required String query,
  }) {
    double bestScore = 0.0;
    int bestLineIndex = -1;
    String bestText = '';

    // Probamos ventanas de varias líneas porque Whisper
    // normalmente devuelve fragmentos de varias frases.
    const maxWindowSize = 5;

    for (var start = 0;
        start < lines.length;
        start++) {
      for (var windowSize = 1;
          windowSize <= maxWindowSize;
          windowSize++) {
        final end =
            start + windowSize;

        if (end > lines.length) {
          break;
        }

        final windowLines =
            lines.sublist(
          start,
          end,
        );

        final windowText =
            windowLines.join(' ');

        final normalizedWindow =
            _normalize(windowText);

        if (normalizedWindow.isEmpty) {
          continue;
        }

        final score =
            _calculateSimilarity(
          query,
          normalizedWindow,
        );

        if (score > bestScore) {
          bestScore = score;
          bestLineIndex = start;
          bestText = windowText;
        }
      }
    }

    return LyricsMatchCandidate(
      songId: source.id,
      title: source.title,
      score: bestScore,
      lineIndex: bestLineIndex,
      matchedText: bestText,
    );
  }

  double _calculateSimilarity(
    String query,
    String candidate,
  ) {
    final queryTokens =
        query.split(' ');

    final candidateTokens =
        candidate.split(' ');

    final tokenScore =
        _tokenSimilarity(
      queryTokens,
      candidateTokens,
    );

    final bigramScore =
        _bigramSimilarity(
      queryTokens,
      candidateTokens,
    );

    final editScore =
        _editSimilarity(
      query,
      candidate,
    );

    // Tokens pesan más porque Whisper puede equivocarse
    // en algunas palabras pero conservar las importantes.
    return (
      tokenScore * 0.50 +
      bigramScore * 0.30 +
      editScore * 0.20
    ).clamp(0.0, 1.0);
  }

  double _tokenSimilarity(
    List<String> a,
    List<String> b,
  ) {
    if (a.isEmpty || b.isEmpty) {
      return 0.0;
    }

    final aCounts =
        <String, int>{};

    final bCounts =
        <String, int>{};

    for (final token in a) {
      aCounts[token] =
          (aCounts[token] ?? 0) + 1;
    }

    for (final token in b) {
      bCounts[token] =
          (bCounts[token] ?? 0) + 1;
    }

    var intersection = 0;

    for (final entry
        in aCounts.entries) {
      final otherCount =
          bCounts[entry.key] ?? 0;

      intersection += min(
        entry.value,
        otherCount,
      );
    }

    final precision =
        intersection / b.length;

    final recall =
        intersection / a.length;

    if (precision + recall == 0) {
      return 0.0;
    }

    return 2 *
        precision *
        recall /
        (precision + recall);
  }

  double _bigramSimilarity(
    List<String> a,
    List<String> b,
  ) {
    final aBigrams =
        _wordBigrams(a);

    final bBigrams =
        _wordBigrams(b);

    if (aBigrams.isEmpty ||
        bBigrams.isEmpty) {
      return 0.0;
    }

    final intersection =
        aBigrams
            .intersection(bBigrams)
            .length;

    return (
      2 * intersection /
      (aBigrams.length +
          bBigrams.length)
    );
  }

  Set<String> _wordBigrams(
    List<String> tokens,
  ) {
    final result = <String>{};

    for (var i = 0;
        i < tokens.length - 1;
        i++) {
      result.add(
        '${tokens[i]} ${tokens[i + 1]}',
      );
    }

    return result;
  }

  double _editSimilarity(
    String a,
    String b,
  ) {
    if (a == b) {
      return 1.0;
    }

    if (a.isEmpty || b.isEmpty) {
      return 0.0;
    }

    final distance =
        _levenshtein(
      a,
      b,
    );

    final maxLength =
        max(
      a.length,
      b.length,
    );

    return (
      1.0 -
      distance / maxLength
    ).clamp(0.0, 1.0);
  }

  int _levenshtein(
    String a,
    String b,
  ) {
    var previous =
        List<int>.generate(
      b.length + 1,
      (index) => index,
    );

    for (var i = 1;
        i <= a.length;
        i++) {
      final current =
          List<int>.filled(
        b.length + 1,
        0,
      );

      current[0] = i;

      for (var j = 1;
          j <= b.length;
          j++) {
        final cost =
            a[i - 1] ==
                    b[j - 1]
                ? 0
                : 1;

        current[j] = min(
          min(
            current[j - 1] + 1,
            previous[j] + 1,
          ),
          previous[j - 1] +
              cost,
        );
      }

      previous = current;
    }

    return previous[b.length];
  }

  String _normalize(
    String input,
  ) {
    return input
        .toLowerCase()
        .replaceAll('’', "'")
        .replaceAll(
          RegExp(r'\([^)]*\)'),
          ' ',
        )
        .replaceAll(
          RegExp(r'[^a-z0-9\s]'),
          ' ',
        )
        .replaceAll(
          RegExp(r'\s+'),
          ' ',
        )
        .trim();
  }
}