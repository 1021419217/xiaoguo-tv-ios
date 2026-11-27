import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放器缓冲指示：一段贴着圆边流转的细弧光。
///
/// 可嵌在中央键内部（[glow] = false，只画细弧，干净不抢镜），
/// 也可独立使用（[glow] = true，带一层很淡的辉光）。
class LoadingHalo extends StatefulWidget {
  const LoadingHalo({
    super.key,
    required this.size,
    this.color = Colors.white,
    this.glow = true,
    this.period = const Duration(milliseconds: 2400),
  });

  /// 直径。按钮内嵌时取按钮直径的 3/4 左右，弧线才不会顶到边框。
  final double size;
  final Color color;

  /// 是否绘制外发光。嵌在按钮里时关掉，避免辉光溢出圆形按钮边框。
  final bool glow;

  /// 转一圈的时长，慢一点更接近「呼吸 / 流转」而不是「转圈加载」。
  final Duration period;

  @override
  State<LoadingHalo> createState() => _LoadingHaloState();
}

class _LoadingHaloState extends State<LoadingHalo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: CurvedAnimation(parent: _spin, curve: Curves.linear),
    child: CustomPaint(
      size: Size.square(widget.size),
      painter: _HaloPainter(widget.color, glow: widget.glow),
    ),
  );
}

class _HaloPainter extends CustomPainter {
  const _HaloPainter(this.color, {this.glow = true});

  final Color color;
  final bool glow;

  /// 弧长：略过 1/3 圈，尾部渐隐，像一段光扫过去。
  static const double _sweep = math.pi * 1.25;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = math.max(1.4, size.width * .026);
    final radius = size.width / 2 - stroke;
    final center = (Offset.zero & size).center;
    final arc = Rect.fromCircle(center: center, radius: radius);
    final shade = SweepGradient(
      startAngle: 0,
      endAngle: _sweep,
      colors: [
        color.withValues(alpha: 0),
        color.withValues(alpha: .14),
        color.withValues(alpha: .55),
        color.withValues(alpha: .88),
      ],
      stops: const [0, .5, .85, 1],
      transform: const GradientRotation(-math.pi / 2),
    ).createShader(arc);

    // 外发光：同一段弧放大模糊，只留一层很淡的辉光，避免硬边。
    // 嵌在按钮里时关掉，辉光会溢出圆形按钮的边框。
    if (glow) {
      canvas.drawArc(
        arc,
        -math.pi / 2,
        _sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..shader = shade
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 2.2),
      );
    }

    canvas.drawArc(
      arc,
      -math.pi / 2,
      _sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = shade,
    );
  }

  @override
  bool shouldRepaint(covariant _HaloPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.glow != glow;
}
