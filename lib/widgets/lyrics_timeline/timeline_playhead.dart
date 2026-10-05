import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart';

class TimelinePlayhead extends StatelessWidget {
  final ValueListenable<int> position;
  final double pixelsPerSecond;
  final double height;

  const TimelinePlayhead({
    super.key,
    required this.position,
    required this.pixelsPerSecond,
    required this.height,
  });

  double _msToPixels(
    int milliseconds,
  ) {
    return milliseconds /
        1000.0 *
        pixelsPerSecond;
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return ValueListenableBuilder<int>(
      valueListenable: position,
      builder: (
        context,
        milliseconds,
        child,
      ) {
        return Positioned(
          left:
              _msToPixels(
                    milliseconds,
                  ) -
                  1.0,
          top: 0,
          width: 2,
          height: height,
          child: child!,
        );
      },
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color:
                const Color(
              0xFF67D8FF,
            ),
            boxShadow: [
              BoxShadow(
                color:
                    const Color(
                      0xFF67D8FF,
                    ).withValues(
                      alpha: 0.4,
                    ),
                blurRadius: 6,
              ),
            ],
          ),
        ),
      ),
    );
  }
}