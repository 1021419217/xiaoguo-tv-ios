import 'package:flutter/material.dart';

/// Rex 风格氛围背景：蓝灰 → 紫灰 → 酒红，叠几团柔和色斑。
/// 纯渐变实现，不用 BackdropFilter，滚动时零开销。
class RexBackdrop extends StatelessWidget {
  const RexBackdrop({super.key, required this.child, this.dim = true});

  final Widget child;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF2B3040), Color(0xFF2C2634), Color(0xFF3B2530)],
            ),
          ),
        ),
        Positioned(
          left: -160,
          right: -80,
          top: -220,
          height: 560,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0x8A5A6788), Color(0x005A6788)],
              ),
            ),
          ),
        ),
        Positioned(
          left: 120,
          right: -200,
          top: 140,
          height: 520,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0x7A4A3A52), Color(0x004A3A52)],
              ),
            ),
          ),
        ),
        Positioned(
          left: -200,
          right: 80,
          bottom: -180,
          height: 520,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0x8A5E2F34), Color(0x005E2F34)],
              ),
            ),
          ),
        ),
        if (dim)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x4D0C0D12), Color(0x000C0D12)],
                stops: [0, .26],
              ),
            ),
          ),
        child,
      ],
    );
  }
}
