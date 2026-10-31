import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/lyric_sweep_curve.dart';

class SweepAutomationEditor extends StatefulWidget {
  const SweepAutomationEditor({super.key, required this.phrase, required this.durationMs, required this.initialPoints});
  final String phrase;
  final int durationMs;
  final List<List<double>> initialPoints;
  @override
  State<SweepAutomationEditor> createState() => _SweepAutomationEditorState();
}

class _SweepAutomationEditorState extends State<SweepAutomationEditor> {
  late List<List<double>> points;
  int selected = 1;
  double preview = 0.5;
  Offset windowOffset = Offset.zero;
  @override
  void initState() {
    super.initState();
    points = LyricSweepCurve.parsePoints(widget.initialPoints).map((p) => List<double>.from(p)).toList();
  }
  void move(Offset pos, Size size) {
    if (selected <= 0 || selected >= points.length - 1) return;
    final x = (pos.dx / size.width).clamp(points[selected-1][0] + 0.005, points[selected+1][0] - 0.005);
    final y = (1 - pos.dy / size.height).clamp(points[selected-1][1], points[selected+1][1]);
    setState(() => points[selected] = [x, y]);
  }
  void add(Offset pos, Size size) {
    final x = (pos.dx / size.width).clamp(0.0, 1.0);
    final y = (1 - pos.dy / size.height).clamp(0.0, 1.0);
    for (var i=1; i<points.length; i++) {
      if (x > points[i-1][0]+0.005 && x < points[i][0]-0.005) {
        setState(() {points.insert(i, [x, y.clamp(points[i-1][1], points[i][1])]); selected=i;});
        return;
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    final duration = widget.durationMs / 1000.0;
    return Transform.translate(
      offset: windowOffset,
      child: AlertDialog(
      title: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => setState(() => windowOffset += details.delta),
        child: Row(children: [
          const Icon(Icons.drag_indicator, size: 19, color: Color(0xFFB28BFF)),
          const SizedBox(width: 8),
          Expanded(child: Text('Sweep automation — ${widget.phrase}',
            maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      content: SizedBox(width: 690, child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Presets — drag points, double-click to add, select and delete to remove'),
        const SizedBox(height: 10),
        Wrap(spacing: 6, children: [
          for (final entry in const [('linear','Linear'), ('easeIn','Accelerate'),
            ('easeOut','Decelerate'), ('easeInOut','Slow → fast → slow')])
            OutlinedButton(onPressed: () => setState(() {
              points = LyricSweepCurve.preset(entry.$1); selected = 8;
            }), child: Text(entry.$2)),
        ]),
        const SizedBox(height: 12),
        SizedBox(height: 230, child: LayoutBuilder(builder: (context, box) {
          final size = Size(box.maxWidth, 230);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTapDown: (d) => add(d.localPosition, size),
            onPanStart: (d) {
              var best=double.infinity;
              for(var i=0;i<points.length;i++) {
                final distance=(Offset(points[i][0]*size.width,
                    (1-points[i][1])*size.height)-d.localPosition).distance;
                if(distance<best) {best=distance;selected=i;}
              }
              if(best>28) selected=-1;
              setState(() {});
            },
            onPanUpdate: (d) => move(d.localPosition, size),
            child: CustomPaint(size:size,
              painter: SweepCurvePainter(points:points, selected:selected, preview:preview)),
          );
        })),
        const SizedBox(height: 8),
        Row(children: [
          Text('Point ${selected+1}/${points.length}'), const SizedBox(width: 12),
          if (selected>=0 && selected<points.length) ...[
            Text('Time ${(points[selected][0]*duration).toStringAsFixed(2)} s'),
            const SizedBox(width: 12),
            Text('Sweep ${(points[selected][1]*100).toStringAsFixed(1)}%'),
          ],
          const Spacer(),
          TextButton.icon(onPressed: selected>0 && selected<points.length-1
              ? () => setState(() {points.removeAt(selected);selected=math.min(selected,points.length-2);})
              : null, icon:const Icon(Icons.delete_outline),label:const Text('Delete point')),
        ]),
        if (selected > 0 && selected < points.length - 1) ...[
          Row(children: [
            const SizedBox(width: 55, child: Text('Time')),
            Expanded(child: Slider(
              value: points[selected][0],
              min: points[selected-1][0] + 0.005,
              max: points[selected+1][0] - 0.005,
              onChanged: (v) => setState(() => points[selected][0] = v),
            )),
            SizedBox(width: 70, child: Text('${(points[selected][0]*duration).toStringAsFixed(2)} s')),
          ]),
          Row(children: [
            const SizedBox(width: 55, child: Text('Sweep')),
            Expanded(child: Slider(
              value: points[selected][1],
              min: points[selected-1][1],
              max: points[selected+1][1],
              onChanged: (v) => setState(() => points[selected][1] = v),
            )),
            SizedBox(width: 70, child: Text('${(points[selected][1]*100).toStringAsFixed(1)}%')),
          ]),
        ],
        Slider(value:preview, onChanged:(v)=>setState(()=>preview=v)),
        Text('Preview: ${(preview*duration).toStringAsFixed(2)} s / '
          '${(LyricSweepCurve.transform(preview,'automation',points:points)*100).toStringAsFixed(1)}% highlighted'),
        const SizedBox(height: 6),
        const Text('Changes highlighting only. Audio duration and speed never change.',
          style:TextStyle(fontSize:12)),
      ])),
      actions: [
        TextButton(onPressed:()=>Navigator.pop(context),child:const Text('CANCEL')),
        FilledButton(onPressed:()=>Navigator.pop(context,points),child:const Text('APPLY')),
      ],
    ),
    );
  }
}

class SweepCurvePainter extends CustomPainter {
  const SweepCurvePainter({required this.points, this.selected=-1, this.preview=-1});
  final List<List<double>> points;
  final int selected;
  final double preview;
  @override
  void paint(Canvas canvas, Size size) {
    final grid=Paint()..color=const Color(0xFF414052)..strokeWidth=0.7;
    for(var i=0;i<=4;i++) {
      final x=size.width*i/4, y=size.height*i/4;
      canvas.drawLine(Offset(x,0),Offset(x,size.height),grid);
      canvas.drawLine(Offset(0,y),Offset(size.width,y),grid);
    }
    final curve=Paint()..color=const Color(0xFFB28BFF)
      ..strokeWidth=2.5..style=PaintingStyle.stroke;
    final path=Path();
    for(var i=0;i<=150;i++) {
      final t=i/150.0;
      final y=LyricSweepCurve.transform(t,'automation',points:points);
      if(i==0) path.moveTo(0,size.height*(1-y));
      else path.lineTo(size.width*t,size.height*(1-y));
    }
    canvas.drawPath(path,curve);
    for(var i=0;i<points.length;i++) {
      canvas.drawCircle(Offset(points[i][0]*size.width,(1-points[i][1])*size.height),
        i==selected?6:4,Paint()..color=i==selected?Colors.white:const Color(0xFFB28BFF));
    }
    if(preview>=0) canvas.drawLine(Offset(size.width*preview,0),
      Offset(size.width*preview,size.height),Paint()..color=const Color(0xFF6CDDE7));
  }
  @override
  bool shouldRepaint(covariant SweepCurvePainter old)=>true;
}
