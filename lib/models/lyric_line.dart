class LyricLine {
  final Duration start;
  final Duration end;
  final String text;

  const LyricLine({
    required this.start,
    required this.end,
    required this.text,
  });

  bool isActive(Duration position) {
    return position >= start && position < end;
  }

  double progress(Duration position) {
    if (position <= start) {
      return 0.0;
    }

    if (position >= end) {
      return 1.0;
    }

    final totalMs =
        end.inMilliseconds - start.inMilliseconds;

    if (totalMs <= 0) {
      return 0.0;
    }

    final elapsedMs =
        position.inMilliseconds - start.inMilliseconds;

    return (elapsedMs / totalMs)
        .clamp(0.0, 1.0);
  }
}