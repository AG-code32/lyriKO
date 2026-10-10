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

  final VoidCallback onClearSelection;

  // Tell the parent to stop horizontal scrolling during marquee selection.
  final ValueChanged<bool> onMarqueeStateChanged;

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
    required this.onClearSelection,
    required this.onMarqueeStateChanged,
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
  int? _activeMarqueePointer;
  DateTime? _lastTouchUp;
  Offset? _lastTouchPosition;
  static const Duration _doubleTouchInterval = Duration(milliseconds: 360);
  static const double _doubleTouchRadius = 32;

  double get _clipTop =>
      defaultTargetPlatform == TargetPlatform.iOS ? 10 : 22;
  double get _clipHeight =>
      defaultTargetPlatform == TargetPlatform.iOS
          ? 146
          : 76;


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
      _clipTop,
      math.max<double>(
        32,
        _msToPixels(
          line.durationMs,
        ),
      ),
      _clipHeight,
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

  void _beginMarquee(Offset position, int pointer) {
    setState(() {
      _marqueeActive = true;
      _activeMarqueePointer = pointer;
      _marqueeStart = position;
      _marqueeCurrent = position;
    });
    widget.onMarqueeStateChanged(true);
    widget.onSelectionChanged(<int>{});
  }

  void _updateMarquee(Offset position) {
    setState(() => _marqueeCurrent = position);
    final rect = _marqueeRect;
    if (rect == null) return;
    final selected = <int>{};
    for (var i = 0; i < widget.lines.length; i++) {
      if (rect.overlaps(_clipRect(i))) selected.add(i);
    }
    widget.onSelectionChanged(selected);
  }

  void _pointerDown(PointerDownEvent event) {
    if ((event.buttons & kPrimaryButton) == 0) return;
    final position = _clampPosition(event.localPosition);

    if (event.kind == PointerDeviceKind.touch) {
      // A second touch held and dragged begins rectangle selection.
      // One touch continues to select/move lyrics normally.
      final now = DateTime.now();
      final isSecondTap = _lastTouchUp != null &&
          now.difference(_lastTouchUp!) <= _doubleTouchInterval &&
          _lastTouchPosition != null &&
          (position - _lastTouchPosition!).distance <= _doubleTouchRadius;
      _lastTouchUp = null;
      if (isSecondTap) {
        _beginMarquee(position, event.pointer);
      }
      return;
    }

    // Preserve the desktop click-and-drag marquee on empty space.
    if (_pointHitsClip(position)) return;
    _beginMarquee(position, event.pointer);
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_marqueeActive || event.pointer != _activeMarqueePointer) return;
    if ((event.buttons & kPrimaryButton) == 0) {
      _finishMarquee();
      return;
    }
    _updateMarquee(_clampPosition(event.localPosition));
  }

  void _pointerUp(PointerUpEvent event) {
    if (_marqueeActive && event.pointer == _activeMarqueePointer) {
      _finishMarquee();
      _lastTouchUp = null;
      return;
    }
    if (event.kind == PointerDeviceKind.touch) {
      _lastTouchUp = DateTime.now();
      _lastTouchPosition = _clampPosition(event.localPosition);
    }
  }

  void _pointerCancel(
    PointerCancelEvent event,
  ) {
    if (!_marqueeActive || event.pointer != _activeMarqueePointer) {
      return;
    }

    _finishMarquee();
  }

  void _finishMarquee() {
    widget.onMarqueeStateChanged(false);
    setState(() {
      _marqueeActive =
          false;
      _activeMarqueePointer = null;

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
            // Preserve the full-height touch surface for marquee selection,
            // but paint the lyric lane only at its original visual height.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onClearSelection,
                child: Column(
                  children: [
                    const SizedBox(
                      height: 166,
                      width: double.infinity,
                      child: ColoredBox(color: Color(0xFF15131D)),
                    ),
                    const Expanded(
                      child: ColoredBox(color: Color(0xFF0B0C12)),
                    ),
                  ],
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
                    _clipTop,

                width:
                    math.max<double>(
                  32,
                  _msToPixels(
                    widget.lines[i]
                        .durationMs,
                  ),
                ),

                height:
                    _clipHeight,

                child:
                    IgnorePointer(
                  ignoring: _marqueeActive,
                  child: RepaintBoundary(
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

                    onMoveStart: (details) {
                      if (!_marqueeActive) widget.onMoveStart(i, details);
                    },

                    onMoveUpdate: (details) {
                      if (!_marqueeActive) widget.onMoveUpdate(i, details);
                    },

                    onMoveEnd: (_) {
                      if (!_marqueeActive) widget.onMoveEnd();
                    },

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