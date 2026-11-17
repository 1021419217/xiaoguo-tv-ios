import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放器中央键的缓冲光晕：一圈缓慢自转的弧光。
///
/// 以前缓冲时会在按钮正中叠一个系统 [CircularProgressIndicator]——颜色跟着
/// 主题走，压在深色画面里发灰发棕，尺寸还和暂停图标打架。这里只在按钮外沿
/// 画一圈白色渐隐弧光，"流转"感有了，也不占按钮内部的位置。
class LoadingHalo extends StatefulWidget {
  const LoadingHalo({super.key, required this.size, this.color = Colors.white});

  /// 直径，一般比按钮直径大 20 左右，让弧光贴在按钮外沿。
  final double size;
  final Color color;

  @override
  State<LoadingHalo> createState() => _LoadingHaloState();
}

class _LoadingHaloState extends State<LoadingHalo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
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

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = size.width / 2 - 1.5;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: .16),
          color.withValues(alpha: .9),
          color.withValues(alpha: 0),
        ],
        stops: const [0, .55, .92, 1],
      ).createShader(rect);
    canvas.drawArc(
      Rect.fromCircle(center: rect.center, radius: radius),
      -math.pi / 2,
      math.pi * 1.75,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _HaloPainter oldDelegate) =>
      oldDelegate.color != color;
}
