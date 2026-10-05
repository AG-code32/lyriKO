import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/timeline_lyric_line.dart';
import 'lyric_clip.dart';
import 'timeline_playhead.dart';

class LyricsTrack extends StatefulWidget {
  final double width;
  final double height;

  final double pixelsPerSecond;

  final List<TimelineLyricLine> lines;

  final Set<int> selectedIndices;

  final int? hoveredIndex;

  final ValueListenable<int> playhead;

  final ValueChanged<int> onSelect;

  final ValueChanged<Set<int>> onSelectionChanged;

  final ValueChanged<int> onHover;

  final VoidCallback onExitHover;

  final void Function(
    int index,
    DragStartDetails details,
  ) onMoveStart;

  final void Function(
    int index,
    DragUpdateDetails details,
  ) onMoveUpdate;

  final VoidCallback onMoveEnd;

  final void Function(
    int index,
    DragUpdateDetails details,
  ) onResizeLeft;

  final void Function(
    int index,
    DragUpdateDetails details,
  ) onResizeRight;

  const LyricsTrack({
    super.key,
    required this.width,
    required this.height,
    required this.pixelsPerSecond,
    required this.lines,
    required this.selectedIndices,
    required this.hoveredIndex,
    required this.playhead,
    required this.onSelect,
    required this.onSelectionChanged,
    required this.onHover,
    required this.onExitHover,
    required this.onMoveStart,
    required this.onMoveUpdate,
    required this.onMoveEnd,
    required this.onResizeLeft,
    required this.onResizeRight,
  });

  @override
  State<LyricsTrack> createState() =>
      _LyricsTrackState();
}

class _LyricsTrackState
    extends State<LyricsTrack> {
  Offset? _marqueeStart;
  Offset? _marqueeCurrent;

  bool _marqueeActive = false;

  double _msToPixels(
    int milliseconds,
  ) {
    return milliseconds /
        1000.0 *
        widget.pixelsPerSecond;
  }

  Rect _clipRect(
    int index,
  ) {
    final line =
        widget.lines[index];

    return Rect.fromLTWH(
      _msToPixels(
        line.startMs,
      ),
      22,
      math.max<double>(
        32,
        _msToPixels(
          line.durationMs,
        ),
      ),
      76,
    );
  }

  bool _pointHitsClip(
    Offset position,
  ) {
    for (var i = 0;
        i < widget.lines.length;
        i++) {
      if (_clipRect(i)
          .contains(position)) {
        return true;
      }
    }

    return false;
  }

  Offset _clampPosition(
    Offset position,
  ) {
    return Offset(
      position.dx.clamp(
        0.0,
        widget.width,
      ),
      position.dy.clamp(
        0.0,
        widget.height,
      ),
    );
  }

  Rect? get _marqueeRect {
    final start =
        _marqueeStart;

    final current =
        _marqueeCurrent;

    if (start == null ||
        current == null) {
      return null;
    }

    return Rect.fromLTRB(
      math.min(
        start.dx,
        current.dx,
      ),
      math.min(
        start.dy,
        current.dy,
      ),
      math.max(
        start.dx,
        current.dx,
      ),
      math.max(
        start.dy,
        current.dy,
      ),
    );
  }

  void _pointerDown(
    PointerDownEvent event,
  ) {
    if ((event.buttons &
            kPrimaryButton) ==
        0) {
      return;
    }

    final position =
        _clampPosition(
      event.localPosition,
    );

    //
    // If the click started on a clip, the clip itself
    // handles selection / drag / resize.
    //
    if (_pointHitsClip(
      position,
    )) {
      return;
    }

    setState(() {
      _marqueeActive =
          true;

      _marqueeStart =
          position;

      _marqueeCurrent =
          position;
    });

    //
    // Clicking empty space clears the current group.
    //
    widget.onSelectionChanged(
      <int>{},
    );
  }

  void _pointerMove(
    PointerMoveEvent event,
  ) {
    if (!_marqueeActive) {
      return;
    }

    if ((event.buttons &
            kPrimaryButton) ==
        0) {
      _finishMarquee();

      return;
    }

    final position =
        _clampPosition(
      event.localPosition,
    );

    setState(() {
      _marqueeCurrent =
          position;
    });

    final selection =
        _marqueeRect;

    if (selection == null) {
      return;
    }

    final selected =
        <int>{};

    for (var i = 0;
        i < widget.lines.length;
        i++) {
      final clip =
          _clipRect(i);

      if (selection.overlaps(
        clip,
      )) {
        selected.add(
          i,
        );
      }
    }

    widget.onSelectionChanged(
      selected,
    );
  }

  void _pointerUp(
    PointerUpEvent event,
  ) {
    if (!_marqueeActive) {
      return;
    }

    _finishMarquee();
  }

  void _pointerCancel(
    PointerCancelEvent event,
  ) {
    if (!_marqueeActive) {
      return;
    }

    _finishMarquee();
  }

  void _finishMarquee() {
    setState(() {
      _marqueeActive =
          false;

      _marqueeStart =
          null;

      _marqueeCurrent =
          null;
    });
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    final marquee =
        _marqueeRect;

    return Listener(
      behavior:
          HitTestBehavior.opaque,

      onPointerDown:
          _pointerDown,

      onPointerMove:
          _pointerMove,

      onPointerUp:
          _pointerUp,

      onPointerCancel:
          _pointerCancel,

      child: SizedBox(
        width:
            widget.width,

        height:
            widget.height,

        child: Stack(
          clipBehavior:
              Clip.hardEdge,

          children: [
            const Positioned.fill(
              child: ColoredBox(
                color:
                    Color(
                  0xFF15131D,
                ),
              ),
            ),

            //
            // LYRIC CLIPS
            //
            for (var i = 0;
                i <
                    widget.lines.length;
                i++)
              Positioned(
                left:
                    _msToPixels(
                  widget.lines[i]
                      .startMs,
                ),

                top:
                    22,

                width:
                    math.max<double>(
                  32,
                  _msToPixels(
                    widget.lines[i]
                        .durationMs,
                  ),
                ),

                height:
                    76,

                child:
                    RepaintBoundary(
                  child:
                      LyricClip(
                    line:
                        widget.lines[i],

                    selected:
                        widget
                            .selectedIndices
                            .contains(i),

                    hovered:
                        widget
                                .hoveredIndex ==
                            i,

                    onTap:
                        () =>
                            widget
                                .onSelect(
                      i,
                    ),

                    onEnter:
                        (_) =>
                            widget
                                .onHover(
                      i,
                    ),

                    onExit:
                        (_) =>
                            widget
                                .onExitHover(),

                    onMoveStart:
                        (
                      details,
                    ) =>
                            widget
                                .onMoveStart(
                      i,
                      details,
                    ),

                    onMoveUpdate:
                        (
                      details,
                    ) =>
                            widget
                                .onMoveUpdate(
                      i,
                      details,
                    ),

                    onMoveEnd:
                        (_) =>
                            widget
                                .onMoveEnd(),

                    onResizeLeft:
                        (
                      details,
                    ) =>
                            widget
                                .onResizeLeft(
                      i,
                      details,
                    ),

                    onResizeRight:
                        (
                      details,
                    ) =>
                            widget
                                .onResizeRight(
                      i,
                      details,
                    ),
                  ),
                ),
              ),

            //
            // MARQUEE / SELECTION RECTANGLE
            //
            if (_marqueeActive &&
                marquee != null)
              Positioned.fromRect(
                rect:
                    marquee,

                child:
                    IgnorePointer(
                  child:
                      Container(
                    decoration:
                        BoxDecoration(
                      color:
                          const Color(
                            0xFF846DCC,
                          ).withValues(
                            alpha:
                                0.15,
                          ),

                      border:
                          Border.all(
                        color:
                            const Color(
                              0xFFC4B4FF,
                            ).withValues(
                              alpha:
                                  0.9,
                            ),

                        width:
                            1.2,
                      ),

                      borderRadius:
                          BorderRadius.circular(
                        4,
                      ),
                    ),
                  ),
                ),
              ),

            //
            // PLAYHEAD ABOVE EVERYTHING
            //
            TimelinePlayhead(
              position:
                  widget.playhead,

              pixelsPerSecond:
                  widget
                      .pixelsPerSecond,

              height:
                  widget.height,
            ),
          ],
        ),
      ),
    );
  }
}