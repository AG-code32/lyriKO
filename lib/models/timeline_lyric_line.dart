import 'dart:math' as math;

class TimelineLyricLine {
  final Map<String, dynamic> data;

  TimelineLyricLine({
    required this.data,
  });

  String get text =>
      data['text']?.toString() ?? '';

  set text(String value) {
    data['text'] = value;
  }

  int get startMs =>
      (data['startMs'] as num?)?.toInt() ?? 0;

  set startMs(int value) {
    data['startMs'] = value;
  }

  int get endMs =>
      (data['endMs'] as num?)?.toInt() ??
      startMs;

  set endMs(int value) {
    data['endMs'] = value;
  }

  int get originalStartMs =>
      (data['originalStartMs'] as num?)
          ?.toInt() ??
      startMs;

  int get originalEndMs =>
      (data['originalEndMs'] as num?)
          ?.toInt() ??
      endMs;

  int get durationMs =>
      math.max(
        0,
        endMs - startMs,
      ).toInt();

  bool get isInstrumental =>
      data['lineType'] == 'instrumental' ||
      data['manualLine'] == true ||
      text.trim() == '♪';

  bool get isCalibrated =>
      startMs != originalStartMs;
}