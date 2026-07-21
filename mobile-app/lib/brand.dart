/// The Veritag mark, painted rather than shipped as a bitmap so it stays sharp
/// at any size the UI asks for.
///
/// **Il timbro** — a solid stamp with the tap carved out of its face: waves
/// struck through the block from the right, leaving a heavy mass and two arc
/// bands. The gesture the product rests on isn't drawn on the mark, it is what
/// has been taken out of it.
///
/// The geometry below is the same one in `brand/make_mark.py` (which generates
/// the SVG for the web and the launcher icons); the two are kept in step by
/// hand, so change both or neither.
library brand;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const _box = 64.0;
const _block = Rect.fromLTRB(5, 5, 59, 59);
const _blockRadius = 18.0;
const _waveCentre = Offset(66, 32);

/// Outside in, alternating: cut, keep, cut, keep, cut.
const _waves = [38.0, 31.0, 23.0, 15.0, 7.0];

const _gradFrom = Offset(6, 4);
const _gradTo = Offset(58, 60);
const _gradColors = [Color(0xFF9A82FF), Color(0xFF7C5CFF), Color(0xFFD8B46A)];
const _gradStops = [0.0, 0.5, 1.0];

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
    canvas.drawPath(
      _markPath(k),
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

Path _markPath(double k) {
  // Start from the whole plane and strike the waves through it in order — the
  // odd ones give the mass back, which is what leaves the two arc bands.
  var waves = Path()..addRect(Rect.fromLTWH(0, 0, _box * k, _box * k));
  for (var i = 0; i < _waves.length; i++) {
    final circle = Path()
      ..addOval(Rect.fromCircle(center: _waveCentre * k, radius: _waves[i] * k));
    waves = Path.combine(
      i.isEven ? PathOperation.difference : PathOperation.union,
      waves,
      circle,
    );
  }

  final block = Path()
    ..addRRect(RRect.fromRectAndRadius(
      Rect.fromLTRB(_block.left * k, _block.top * k, _block.right * k, _block.bottom * k),
      Radius.circular(_blockRadius * k),
    ));
  return Path.combine(PathOperation.intersect, block, waves);
}
