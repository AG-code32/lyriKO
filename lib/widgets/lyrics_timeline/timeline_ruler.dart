import 'package:flutter/material.dart';

class TimelineRuler extends StatelessWidget {
  final double width;
  final double height;
  final double pixelsPerSecond;
  final int durationMs;
  final ValueChanged<double> onSeekX;

  const TimelineRuler({
    super.key,
    required this.width,
    required this.height,
    required this.pixelsPerSecond,
    required this.durationMs,
    required this.onSeekX,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return RepaintBoundary(
      child: SizedBox(
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
          child: CustomPaint(
            painter:
                _TimelineRulerPainter(
              pixelsPerSecond:
                  pixelsPerSecond,
              durationMs:
                  durationMs,
            ),
          ),
        ),
      ),
    );
  }
}

class _TimelineRulerPainter
    extends CustomPainter {
  final double pixelsPerSecond;
  final int durationMs;

  _TimelineRulerPainter({
    required this.pixelsPerSecond,
    required this.durationMs,
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
          0xFF11131A,
        ),
    );

    final majorPaint =
        Paint()
          ..color =
              const Color(
            0xFF647184,
          );

    final minorPaint =
        Paint()
          ..color =
              const Color(
            0xFF2C3340,
          );

    int majorSeconds;

    if (pixelsPerSecond >= 150) {
      majorSeconds = 1;
    } else if (pixelsPerSecond >= 80) {
      majorSeconds = 2;
    } else if (pixelsPerSecond >= 35) {
      majorSeconds = 5;
    } else {
      majorSeconds = 10;
    }

    final totalSeconds =
        (durationMs / 1000).ceil();

    final textPainter =
        TextPainter(
      textDirection:
          TextDirection.ltr,
    );

    for (var second = 0;
        second <= totalSeconds;
        second++) {
      final x =
          second *
              pixelsPerSecond;

      final major =
          second % majorSeconds == 0;

      canvas.drawLine(
        Offset(
          x,
          major ? 24 : 35,
        ),
        Offset(
          x,
          size.height,
        ),
        major
            ? majorPaint
            : minorPaint,
      );

      if (!major) {
        continue;
      }

      final minutes =
          second ~/ 60;

      final seconds =
          second % 60;

      textPainter.text =
          TextSpan(
        text:
            '$minutes:${seconds.toString().padLeft(2, '0')}',
        style:
            const TextStyle(
          color:
              Color(
            0xFF8993A3,
          ),
          fontSize: 10,
        ),
      );

      textPainter.layout();

      textPainter.paint(
        canvas,
        Offset(
          x + 3,
          4,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(
    covariant _TimelineRulerPainter
        oldDelegate,
  ) {
    return oldDelegate
                .pixelsPerSecond !=
            pixelsPerSecond ||
        oldDelegate.durationMs !=
            durationMs;
  }
}