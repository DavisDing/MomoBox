import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Decorative packaging from the approved hero, unrelated to inventory data.
class MomoStillLife extends StatelessWidget {
  const MomoStillLife({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: const Size(120, 150),
      painter: _StillLifePainter(
        Theme.of(context).brightness == Brightness.dark,
      ),
    ),
  );
}

class _StillLifePainter extends CustomPainter {
  const _StillLifePainter(this.dark);
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 120, size.height / 150);
    final paint = Paint();
    canvas.drawOval(
      const Rect.fromLTWH(9, 129, 104, 13),
      paint
        ..color = const Color(0xFF51674B).withValues(alpha: .1)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    paint.maskFilter = null;
    canvas.save();
    canvas.translate(40, 89);
    canvas.rotate(-.25);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-25, -35, 49, 91),
        const Radius.circular(5),
      ),
      paint..color = dark ? const Color(0xFFD5D8C5) : const Color(0xFFFAFBF2),
    );
    final top =
        Path()
          ..moveTo(-25, -35)
          ..lineTo(-13, -53)
          ..lineTo(14, -53)
          ..lineTo(24, -35)
          ..close();
    canvas.drawPath(top, paint..color = const Color(0xFFE1E6D2));
    canvas.drawRect(
      const Rect.fromLTWH(-13, -56, 27, 5),
      paint..color = const Color(0xFF8D9E76),
    );
    canvas.drawRect(
      const Rect.fromLTWH(-25, -13, 49, 56),
      paint..color = const Color(0xFF6E805A),
    );
    _label(
      canvas,
      'ORGANIC',
      const Offset(-19, -8),
      7,
      const Color(0xFFF6F7E9),
    );
    _label(canvas, 'milk', const Offset(-17, 4), 19, const Color(0xFFF6F7E9));
    _label(
      canvas,
      'EVERYDAY',
      const Offset(-19, 30),
      5,
      const Color(0xFFE1E7CC),
    );
    canvas.restore();
    canvas.save();
    canvas.translate(94, 111);
    canvas.rotate(.16);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-18, -29, 36, 62),
        const Radius.circular(9),
      ),
      paint..color = const Color(0xFFCFB58C),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-17, -36, 34, 15),
        const Radius.circular(4),
      ),
      paint..color = const Color(0xFFB9A47E),
    );
    for (var x = -14.0; x < 16; x += 3) {
      canvas.drawLine(
        Offset(x, -34),
        Offset(x, -22),
        paint
          ..color = const Color(0xFF9E8E70)
          ..strokeWidth = .7,
      );
    }
    canvas.drawRect(
      const Rect.fromLTWH(-18, -7, 36, 29),
      paint..color = const Color(0xFFF3EEDB),
    );
    _label(canvas, 'C', const Offset(-7, -3), 21, const Color(0xFF86886A));
    canvas.restore();
    final leaf =
        Path()
          ..moveTo(67, 24)
          ..quadraticBezierTo(84, 2, 109, 19)
          ..quadraticBezierTo(87, 39, 67, 24)
          ..close();
    canvas.drawPath(leaf, paint..color = const Color(0xFF9BAC7E));
    canvas.save();
    canvas.translate(83, 26);
    canvas.rotate(math.pi / 5);
    canvas.drawOval(
      const Rect.fromLTWH(-5, 0, 13, 32),
      paint..color = const Color(0xFF7E9467),
    );
    canvas.restore();
    canvas.restore();
  }

  void _label(
    Canvas canvas,
    String text,
    Offset offset,
    double size,
    Color color,
  ) {
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: text,
        style: TextStyle(fontFamily: 'Roboto', fontSize: size, color: color),
      ),
    )..layout();
    painter.paint(canvas, offset);
    painter.dispose();
  }

  @override
  bool shouldRepaint(_StillLifePainter oldDelegate) => oldDelegate.dark != dark;
}
