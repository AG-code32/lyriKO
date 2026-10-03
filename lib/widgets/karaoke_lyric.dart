import 'package:flutter/material.dart';

class KaraokeLyric extends StatelessWidget {
  final String text;
  final double progress;
  final bool isActive;
  final bool isPast;

  const KaraokeLyric({
    super.key,
    required this.text,
    required this.progress,
    required this.isActive,
    required this.isPast,
  });

  @override
  Widget build(BuildContext context) {
    if (!isActive) {
      return AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: isPast ? 0.12 : 0.30,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            height: 1.25,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      );
    }

    final p = progress.clamp(0.0, 1.0);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(
        begin: 0.0,
        end: p,
      ),
      duration: const Duration(milliseconds: 90),
      curve: Curves.linear,
      builder: (context, value, child) {
        final edgeStart =
            (value - 0.04).clamp(0.0, 1.0);

        final edgeEnd =
            (value + 0.04).clamp(0.0, 1.0);

        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [
                Colors.white,
                Colors.white,
                Color(0xFF8A8A8A),
                Color(0xFF505050),
              ],
              stops: [
                0.0,
                edgeStart,
                edgeEnd,
                1.0,
              ],
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 34,
          height: 1.20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
          color: Colors.white,
        ),
      ),
    );
  }
}