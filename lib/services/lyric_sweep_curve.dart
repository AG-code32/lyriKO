import 'dart:math' as math;

/// Pure visual time remapping. The audio player and stored word timestamps are
/// never modified. Points are [timeFraction, highlightedFraction].
class LyricSweepCurve {
  static const modes = <String>['linear', 'easeIn', 'easeOut', 'easeInOut', 'syllables', 'automation'];

  static List<List<double>> parsePoints(dynamic raw) {
    if (raw is! List) return const [[0, 0], [1, 1]];
    final points = <List<double>>[];
    for (final item in raw) {
      if (item is List && item.length >= 2 && item[0] is num && item[1] is num) {
        points.add([(item[0] as num).toDouble().clamp(0.0, 1.0),
          (item[1] as num).toDouble().clamp(0.0, 1.0)]);
      }
    }
    points.sort((a, b) => a[0].compareTo(b[0]));
    if (points.length < 2) return const [[0, 0], [1, 1]];
    return points;
  }

  static List<List<double>> preset(String mode) => List.generate(17, (i) {
    final t = i / 16.0;
    return [t, transform(t, mode)];
  });

  static double transform(double fraction, String mode,
      {String text = '', String syllables = '', List<double> weights = const [],
      List<List<double>> points = const []}) {
    final t = fraction.clamp(0.0, 1.0);
    if (mode == 'automation') {
      final ordered = parsePoints(points);
      for (var i = 1; i < ordered.length; i++) {
        final a = ordered[i - 1], b = ordered[i];
        if (t <= b[0]) {
          final f = ((t - a[0]) / math.max(1e-9, b[0] - a[0])).clamp(0.0, 1.0);
          return (a[1] + (b[1] - a[1]) * f).clamp(0.0, 1.0);
        }
      }
      return 1.0;
    }
    if (mode == 'easeIn') return t * t;
    if (mode == 'easeOut') return 1.0 - (1.0 - t) * (1.0 - t);
    if (mode == 'easeInOut') return t * t * (3.0 - 2.0 * t);
    if (mode != 'syllables') return t;
    final parts = syllables.split('|');
    if (parts.length < 2 || parts.join() != text ||
        parts.length != weights.length || weights.any((w) => w <= 0)) return t;
    final totalWeight = weights.fold<double>(0.0, (a, b) => a + b);
    final totalChars = parts.join().length;
    if (totalWeight <= 0 || totalChars == 0) return t;
    var elapsed = 0.0;
    var chars = 0;
    for (var i = 0; i < parts.length; i++) {
      final next = elapsed + weights[i] / totalWeight;
      if (t <= next || i == parts.length - 1) {
        final inside = ((t - elapsed) / math.max(1e-9, next - elapsed)).clamp(0.0, 1.0);
        return ((chars + inside * parts[i].length) / totalChars).clamp(0.0, 1.0);
      }
      elapsed = next;
      chars += parts[i].length;
    }
    return 1.0;
  }

  static List<double> parseWeights(dynamic value) => value is List
      ? value.whereType<num>().map((e) => e.toDouble()).toList()
      : const <double>[];
}
