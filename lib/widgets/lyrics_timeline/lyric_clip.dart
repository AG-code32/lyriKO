import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/timeline_lyric_line.dart';

class LyricClip extends StatelessWidget {
  final TimelineLyricLine line;

  final bool selected;
  final bool hovered;

  final VoidCallback onTap;

  final void Function(
    PointerEnterEvent event,
  ) onEnter;

  final void Function(
    PointerExitEvent event,
  ) onExit;

  final GestureDragStartCallback
      onMoveStart;

  final GestureDragUpdateCallback
      onMoveUpdate;

  final GestureDragEndCallback
      onMoveEnd;

  final GestureDragUpdateCallback
      onResizeLeft;

  final GestureDragUpdateCallback
      onResizeRight;

  const LyricClip({
    super.key,
    required this.line,
    required this.selected,
    required this.hovered,
    required this.onTap,
    required this.onEnter,
    required this.onExit,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onResizeLeft,
    required this.onResizeRight,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    Color background;

    if (line.isInstrumental) {
      background =
          hovered
              ? const Color(
                  0xFF6A5230,
                )
              : const Color(
                  0xFF5A4528,
                );
    } else if (selected) {
      background =
          const Color(
        0xFF4B3F72,
      );
    } else if (hovered) {
      background =
          const Color(
        0xFF2D3A58,
      );
    } else {
      background =
          const Color(
        0xFF25304A,
      );
    }

    return MouseRegion(
      cursor:
          SystemMouseCursors.grab,
      onEnter:
          onEnter,
      onExit:
          onExit,
      child: GestureDetector(
        onTap:
            onTap,
        onHorizontalDragStart:
            onMoveStart,
        onHorizontalDragUpdate:
            onMoveUpdate,
        onHorizontalDragEnd:
            onMoveEnd,
        child: AnimatedContainer(
          duration:
              const Duration(
            milliseconds: 100,
          ),
          decoration: BoxDecoration(
            color:
                background,
            borderRadius:
                BorderRadius.circular(
              8,
            ),
            border: Border.all(
              width:
                  selected
                      ? 2
                      : 1,
              color:
                  selected
                      ? const Color(
                          0xFFC4B4FF,
                        )
                      : hovered
                          ? Colors.white38
                          : Colors.white24,
            ),
            boxShadow:
                selected
                    ? [
                        BoxShadow(
                          color:
                              const Color(
                                0xFF8D72D8,
                              ).withValues(
                                alpha:
                                    0.22,
                              ),
                          blurRadius:
                              10,
                        ),
                      ]
                    : null,
          ),
          child: Stack(
            children: [
              //
              // LEFT HANDLE
              //
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 12,
                child: MouseRegion(
                  cursor:
                      SystemMouseCursors
                          .resizeLeftRight,
                  child:
                      GestureDetector(
                    behavior:
                        HitTestBehavior.opaque,
                    onHorizontalDragUpdate:
                        onResizeLeft,
                    child:
                        _ResizeHandle(
                      left: true,
                      highlighted:
                          selected ||
                              hovered,
                    ),
                  ),
                ),
              ),

              //
              // LYRIC TEXT
              //
              Positioned.fill(
                left: 18,
                right: 15,
                child: Align(
                  alignment:
                      line.isInstrumental
                          ? Alignment.center
                          : Alignment.centerLeft,
                  child: Text(
                    line.text,
                    textAlign:
                        line.isInstrumental
                            ? TextAlign.center
                            : TextAlign.left,
                    maxLines: 2,
                    overflow:
                        TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize:
                          line.isInstrumental
                              ? 24
                              : 13,
                      fontWeight:
                          FontWeight.w700,
                      color:
                          line.isInstrumental
                              ? const Color(
                                  0xFFFFD58A,
                                )
                              : Colors.white,
                    ),
                  ),
                ),
              ),

              //
              // RIGHT HANDLE
              //
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 12,
                child: MouseRegion(
                  cursor:
                      SystemMouseCursors
                          .resizeLeftRight,
                  child:
                      GestureDetector(
                    behavior:
                        HitTestBehavior.opaque,
                    onHorizontalDragUpdate:
                        onResizeRight,
                    child:
                        _ResizeHandle(
                      left: false,
                      highlighted:
                          selected ||
                              hovered,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResizeHandle
    extends StatelessWidget {
  final bool left;
  final bool highlighted;

  const _ResizeHandle({
    required this.left,
    required this.highlighted,
  });

  @override
  Widget build(
    BuildContext context,
  ) {
    return Container(
      decoration: BoxDecoration(
        color:
            Colors.white.withValues(
          alpha:
              highlighted
                  ? 0.13
                  : 0.06,
        ),
        borderRadius:
            BorderRadius.horizontal(
          left:
              left
                  ? const Radius.circular(
                      7,
                    )
                  : Radius.zero,
          right:
              !left
                  ? const Radius.circular(
                      7,
                    )
                  : Radius.zero,
        ),
      ),
      child: Center(
        child: Container(
          width: 2,
          height: 28,
          decoration: BoxDecoration(
            color:
                Colors.white38,
            borderRadius:
                BorderRadius.circular(
              1,
            ),
          ),
        ),
      ),
    );
  }
}