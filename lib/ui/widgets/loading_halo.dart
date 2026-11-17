import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放器中央键的缓冲光晕：贴着按钮外沿流转的一段弧光。
///
/// 以前缓冲时会在按钮正中叠一个系统 [CircularProgressIndicator]——颜色跟着
/// 主题走，压在深色画面里发灰发棕，尺寸还和暂停图标打架。换成一圈弧光后又
/// 一度把直径放到按钮外 10dp，看着像凭空多出一个大圈。现在弧光只比按钮大
/// 几 dp、线更细，并带一点外发光，"贴边流转"的感觉更干净。
class LoadingHalo extends StatefulWidget {
  const LoadingHalo({
    super.key,
    required this.size,
    this.color = Colors.white,
    this.period = const Duration(milliseconds: 2400),
  });

  /// 直径，一般比按钮直径大 8 左右，让弧光贴在按钮外沿。
  final double size;
  final Color color;

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
      painter: _HaloPainter(widget.color),
    ),
  );
}

class _HaloPainter extends CustomPainter {
  const _HaloPainter(this.color);

  final Color color;

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
      oldDelegate.color != color;
}
