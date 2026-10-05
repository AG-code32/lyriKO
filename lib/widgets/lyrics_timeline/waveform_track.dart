import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'timeline_playhead.dart';

import 'package:flutter/foundation.dart';


class WaveformTrack extends StatelessWidget {
  final double width;
  final double height;

  final List<double> waveform;
  final bool loading;

  final ValueListenable<int>
      playhead;

  final double pixelsPerSecond;

  final ValueChanged<double>
      onSeekX;

  final ValueChanged<double>
      onScrubX;

  final VoidCallback
      onScrubStart;

  final VoidCallback
      onScrubEnd;

  const WaveformTrack({
    super.key,
    required this.width,
    required this.height,
    required this.waveform,
    required this.loading,
    required this.playhead,
    required this.pixelsPerSecond,
    required this.onSeekX,
    required this.onScrubX,
    required this.onScrubStart,
    required this.onScrubEnd,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return SizedBox(
      width: width,
      height: height,
      child: GestureDetector(
        behavior:
            HitTestBehavior.opaque,
        onTapDown: (
          details,
        ) {
          onSeekX(
            details.localPosition.dx,
          );
        },
        onHorizontalDragStart:
            (_) {
          onScrubStart();
        },
        onHorizontalDragUpdate:
            (
          details,
        ) {
          onScrubX(
            details.localPosition.dx,
          );
        },
        onHorizontalDragEnd:
            (_) {
          onScrubEnd();
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter:
                      _WaveformPainter(
                    waveform:
                        waveform,
                    loading:
                        loading,
                  ),
                ),
              ),
            ),

            TimelinePlayhead(
              position:
                  playhead,
              pixelsPerSecond:
                  pixelsPerSecond,
              height:
                  height,
            ),
          ],
        ),
      ),
    );
  }
}

class _WaveformPainter
    extends CustomPainter {
  final List<double> waveform;
  final bool loading;

  _WaveformPainter({
    required this.waveform,
    required this.loading,
  });

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color =
            const Color(
          0xFF111722,
        ),
    );

    if (waveform.isEmpty) {
      final painter =
          TextPainter(
        text:
            TextSpan(
          text:
              loading
                  ? 'Generating waveform...'
                  : 'Waveform unavailable',
          style:
              const TextStyle(
            color:
                Colors.white24,
            fontSize: 12,
          ),
        ),
        textDirection:
            TextDirection.ltr,
      )..layout();

      painter.paint(
        canvas,
        Offset(
          15,
          size.height / 2 -
              painter.height / 2,
        ),
      );

      return;
    }

    final middle =
        size.height / 2;

    final count =
        waveform.length;

    final columns =
        math.max(
      1,
      size.width.floor(),
    );

    final normalPaint =
        Paint()
          ..color =
              const Color(
            0xFF7193C1,
          );

    final peakPaint =
        Paint()
          ..color =
              const Color(
            0xFF91B9E8,
          );

    for (var x = 0;
        x < columns;
        x++) {
      final normalized =
          x /
              math.max(
                1,
                columns - 1,
              );

      final index =
          (normalized *
                  (count - 1))
              .round()
              .clamp(
                0,
                count - 1,
              );

      final amplitude =
          waveform[index]
              .clamp(
                0.0,
                1.0,
              );

      final barHeight =
          amplitude *
              size.height *
              0.4;

      canvas.drawLine(
        Offset(
          x.toDouble(),
          middle - barHeight,
        ),
        Offset(
          x.toDouble(),
          middle + barHeight,
        ),
        amplitude > 0.7
            ? peakPaint
            : normalPaint,
      );
    }

    canvas.drawLine(
      Offset(
        0,
        middle,
      ),
      Offset(
        size.width,
        middle,
      ),
      Paint()
        ..color =
            const Color(
          0xFF30405A,
        ),
    );
  }

  @override
  bool shouldRepaint(
    covariant _WaveformPainter
        oldDelegate,
  ) {
    return oldDelegate.waveform !=
            waveform ||
        oldDelegate.loading !=
            loading;
  }
}