import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class TimelineTransport extends StatelessWidget {
  final bool playing;

  final int durationMs;

  final ValueListenable<int>
      position;

  final double volume;

  final VoidCallback
      onPlayPause;

  final VoidCallback
      onBackFive;

  final VoidCallback
      onForwardFive;

  final ValueChanged<double>
      onVolumeChanged;

  const TimelineTransport({
    super.key,
    required this.playing,
    required this.durationMs,
    required this.position,
    required this.volume,
    required this.onPlayPause,
    required this.onBackFive,
    required this.onForwardFive,
    required this.onVolumeChanged,
  });

  String _format(
    int milliseconds,
  ) {
    final duration =
        Duration(
      milliseconds:
          milliseconds,
    );

    final minutes =
        duration.inMinutes;

    final seconds =
        duration.inSeconds
            .remainder(60);

    final millis =
        duration.inMilliseconds
            .remainder(1000);

    return '$minutes:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${millis.toString().padLeft(3, '0')}';
  }

  IconData _volumeIcon() {
    if (volume <= 0) {
      return Icons.volume_off_rounded;
    }

    if (volume < 0.5) {
      return Icons.volume_down_rounded;
    }

    return Icons.volume_up_rounded;
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Container(
      decoration:
          const BoxDecoration(
        color:
            Color(
          0xFF11131A,
        ),
        border: Border(
          top: BorderSide(
            color:
                Color(
              0xFF282B34,
            ),
          ),
        ),
      ),
      padding:
          const EdgeInsets.symmetric(
        horizontal: 20,
        vertical: 9,
      ),
      child: Row(
        children: [
          //
          // LEFT: COMPACT VOLUME
          //
          Expanded(
            child: Row(
              children: [
                Icon(
                  _volumeIcon(),
                  size: 19,
                  color:
                      Colors.white60,
                ),

                const SizedBox(
                  width: 5,
                ),

                SizedBox(
                  width: 82,
                  child: SliderTheme(
                    data:
                        SliderTheme.of(
                      context,
                    ).copyWith(
                      trackHeight: 2.5,
                      thumbShape:
                          const RoundSliderThumbShape(
                        enabledThumbRadius:
                            5,
                      ),
                      overlayShape:
                          const RoundSliderOverlayShape(
                        overlayRadius:
                            11,
                      ),
                    ),
                    child: Slider(
                      min: 0,
                      max: 1,
                      value:
                          volume.clamp(
                        0.0,
                        1.0,
                      ),
                      onChanged:
                          onVolumeChanged,
                    ),
                  ),
                ),

                const SizedBox(
                  width: 12,
                ),

                const Text(
                  'Space: Play / Pause',
                  style: TextStyle(
                    color:
                        Colors.white24,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

          //
          // CENTER: PLAYER
          //
          Row(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              IconButton(
                tooltip:
                    '-5 seconds',
                onPressed:
                    onBackFive,
                icon:
                    const Icon(
                  Icons.replay_5_rounded,
                ),
              ),

              const SizedBox(
                width: 8,
              ),

              FilledButton(
                onPressed:
                    onPlayPause,
                style:
                    FilledButton.styleFrom(
                  backgroundColor:
                      const Color(
                    0xFF31536B,
                  ),
                  foregroundColor:
                      Colors.white,
                  shape:
                      const CircleBorder(),
                  padding:
                      const EdgeInsets.all(
                    15,
                  ),
                ),
                child: Icon(
                  playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 27,
                ),
              ),

              const SizedBox(
                width: 8,
              ),

              IconButton(
                tooltip:
                    '+5 seconds',
                onPressed:
                    onForwardFive,
                icon:
                    const Icon(
                  Icons.forward_5_rounded,
                ),
              ),

              const SizedBox(
                width: 16,
              ),

              ValueListenableBuilder<int>(
                valueListenable:
                    position,
                builder: (
                  context,
                  current,
                  child,
                ) {
                  return Text(
                    _format(
                      current,
                    ),
                    style:
                        const TextStyle(
                      fontSize: 14,
                      fontWeight:
                          FontWeight.w700,
                    ),
                  );
                },
              ),

              const Padding(
                padding:
                    EdgeInsets.symmetric(
                  horizontal: 6,
                ),
                child: Text(
                  '/',
                  style: TextStyle(
                    color:
                        Colors.white30,
                  ),
                ),
              ),

              Text(
                _format(
                  durationMs,
                ),
                style:
                    TextStyle(
                  color:
                      Colors.white
                          .withValues(
                    alpha: 0.45,
                  ),
                  fontSize: 13,
                ),
              ),
            ],
          ),

          //
          // RIGHT: EMPTY FOR CENTERING
          //
          const Expanded(
            child: SizedBox(),
          ),
        ],
      ),
    );
  }
}