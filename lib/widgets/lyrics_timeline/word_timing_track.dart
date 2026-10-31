import 'dart:math' as math;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../../models/timeline_lyric_line.dart';
import 'timeline_playhead.dart';

/// Desktop word lane: uses absolute song milliseconds for editable boundaries.
/// Existing CTC word timings are displayed using the same scaling as the
/// karaoke preview until the user edits them.
class WordTimingTrack extends StatelessWidget {
  final double width;
  final double height;
  final double pixelsPerSecond;
  final List<TimelineLyricLine> lines;
  final int? selectedLine;
  final int? selectedWord;
  final ValueListenable<int> playhead;
  final void Function(int line, int word) onSelect;
  final void Function(int line, int word, int deltaMs, String operation) onChange;
  final void Function(int line, int word, String edge)? onDoubleTapEdge;

  const WordTimingTrack({super.key, required this.width, required this.height,
    required this.pixelsPerSecond, required this.lines, required this.selectedLine,
    required this.selectedWord, required this.playhead, required this.onSelect,
    required this.onChange, this.onDoubleTapEdge});

  double _x(int ms) => ms / 1000 * pixelsPerSecond;

  @override
  Widget build(BuildContext context) {
    final clips = <Widget>[];
    for (var li = 0; li < lines.length; li++) {
      final line = lines[li];
      final source = line.data['words'];
      if (source is! List || source.isEmpty) continue;
      final originalDuration = line.originalEndMs - line.originalStartMs;
      int adjusted(int ms) => line.data['wordsEdited'] == true ? ms
        : originalDuration <= 0 ? line.startMs + ms - line.originalStartMs
        : line.startMs + ((ms - line.originalStartMs) * line.durationMs / originalDuration).round();
      for (var wi = 0; wi < source.length; wi++) {
        final raw = source[wi];
        if (raw is! Map || raw['startMs'] is! num || raw['endMs'] is! num) continue;
        // Parent phrase contains all words; the editor rescales boundaries
        // when its handles are dragged, so no words disappear.
        final start = adjusted((raw['startMs'] as num).toInt())
            .clamp(line.startMs, line.endMs).toInt();
        final end = adjusted((raw['endMs'] as num).toInt())
            .clamp(line.startMs, line.endMs).toInt();
        final left = _x(start);
        final clipWidth = math.max(3.0, _x(math.max(1, end - start)));
        final active = selectedLine == li && selectedWord == wi;
        clips.add(Positioned(
          left: left, top: 9, width: clipWidth, height: height - 18,
          child: Container(
            decoration: BoxDecoration(
              color: active ? const Color(0xFF356E73) : const Color(0xFF203A45),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: active ? const Color(0xFFB1FFF3) : const Color(0xFF4B7A84)),
            ),
            child: LayoutBuilder(builder: (context, constraints) {
              final handleWidth = math.min(7.0, constraints.maxWidth / 4);
              return Stack(children: [
                Positioned.fill(child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(li, wi),
                  onHorizontalDragStart: (_) => onSelect(li, wi),
                  onHorizontalDragUpdate: (details) => onChange(li, wi,
                    (details.delta.dx / pixelsPerSecond * 1000).round(), 'move'),
                  child: Center(child: Text('${raw['text'] ?? ''}', maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white))),
                )),
                Positioned(left: 0, top: 0, bottom: 0, width: handleWidth,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: GestureDetector(
                    onDoubleTap: () => onDoubleTapEdge?.call(li, wi, 'start'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (_) => onSelect(li, wi),
                    onHorizontalDragUpdate: (details) => onChange(li, wi,
                      (details.delta.dx / pixelsPerSecond * 1000).round(), 'start'),
                    child: Container(color: const Color(0x558FCFCB)),
                  ))),
                Positioned(right: 0, top: 0, bottom: 0, width: handleWidth,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeLeftRight,
                    child: GestureDetector(
                    onDoubleTap: () => onDoubleTapEdge?.call(li, wi, 'end'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (_) => onSelect(li, wi),
                    onHorizontalDragUpdate: (details) => onChange(li, wi,
                      (details.delta.dx / pixelsPerSecond * 1000).round(), 'end'),
                    child: Container(color: const Color(0x558FCFCB)),
                  ))),
              ]);
            }),
          ),
        ));
      }
    }
    return SizedBox(width: width, height: height, child: Stack(children: [
      Positioned.fill(child: Container(color: const Color(0xFF141B24))),
      ...clips,
      // One shared clock; no additional audio player.
      TimelinePlayhead(
        position: playhead, pixelsPerSecond: pixelsPerSecond, height: height,
      ),
    ]));
  }
}
