/// The Veritag mark, painted rather than shipped as a bitmap so it stays sharp
/// at any size the UI asks for.
///
/// **L'impronta** — a tapered whorl coiling into a solid core with two broken
/// ridges outside it: a fingerprint, a brushstroke and the coil of an NFC
/// antenna at once. The geometry below is the same one in `brand/make_mark.py`
/// (which generates the SVG for the web and the launcher icons); the two are
/// kept in step by hand, so change both or neither.
library brand;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const _box = 64.0;
const _centre = Offset(32, 32);
const _coreR = 4.2;

/// turns, radius out, radius in, start angle°, width out, width in
const List<List<double>> _ridges = [
  [1.85, 22.0, 6.5, 200, 5.8, 2.2], // the whorl
  [0.50, 29.0, 26.5, 44, 4.4, 1.9], // ridge, lower right
  [0.34, 29.0, 27.0, 196, 4.4, 1.9], // ridge, upper left
];

const _gradFrom = Offset(18, 2);
const _gradTo = Offset(46, 62);
const _gradColors = [Color(0xFF7C5CFF), Color(0xFF9A82FF), Color(0xFFD8B46A)];
const _gradStops = [0.0, 0.45, 1.0];

class VeritagMark extends StatelessWidget {
  const VeritagMark({super.key, this.size = 38});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _MarkPainter()),
      );
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / _box;
    final path = Path()..fillType = ui.PathFillType.nonZero;

    for (final r in _ridges) {
      final pts = _spiral(r[0], r[1], r[2], r[3], 96);
      final ring = _outline(pts, r[4], r[5]);
      path.addPolygon(ring.map((p) => p * k).toList(), true);
      // Round caps: a polygon has none, so cap both ends with a disc.
      path.addOval(Rect.fromCircle(center: pts.first * k, radius: r[4] / 2 * k));
      path.addOval(Rect.fromCircle(center: pts.last * k, radius: r[5] / 2 * k));
    }
    path.addOval(Rect.fromCircle(center: _centre * k, radius: _coreR * k));

    canvas.drawPath(
      path,
      Paint()
        ..isAntiAlias = true
        ..shader = ui.Gradient.linear(
          _gradFrom * k,
          _gradTo * k,
          _gradColors,
          _gradStops,
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _MarkPainter oldDelegate) => false;
}

List<Offset> _spiral(double turns, double rOut, double rIn, double a0, int n) {
  return List.generate(n + 1, (i) {
    final t = i / n;
    final a = (a0 + 360 * turns * t) * math.pi / 180;
    final r = rOut + (rIn - rOut) * t;
    return _centre + Offset(r * math.cos(a), r * math.sin(a));
  });
}

/// Both sides of a stroke whose width goes from [w0] to [w1] along [pts].
List<Offset> _outline(List<Offset> pts, double w0, double w1) {
  final left = <Offset>[], right = <Offset>[];
  final n = pts.length - 1;
  for (var i = 0; i <= n; i++) {
    final w = (w0 + (w1 - w0) * (i / n)) / 2;
    final d = i == 0
        ? pts[1] - pts[0]
        : i == n
            ? pts[n] - pts[n - 1]
            : pts[i + 1] - pts[i - 1];
    final len = d.distance == 0 ? 1.0 : d.distance;
    final normal = Offset(-d.dy / len, d.dx / len);
    left.add(pts[i] + normal * w);
    right.add(pts[i] - normal * w);
  }
  return [...left, ...right.reversed];
}
