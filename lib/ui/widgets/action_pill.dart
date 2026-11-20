import 'package:flutter/material.dart';

import 'frosted_glass.dart';

enum ActionTone {
  /// 普通操作：低对比玻璃胶囊。
  neutral,

  /// 主操作：反色强调（深色主题下为白底黑字）。
  accent,

  /// 破坏性操作：只降饱和度的红描边，不铺整块红底。
  danger,
}

/// 全应用统一的操作胶囊：顶栏的「编辑 / 清空 / 全选 / 完成」、模块卡片的
/// 「导出 / 更新 / 卸载」、列表里的「清除已结束」都用它。
///
/// 一套尺寸（34 高、13 号字、6 号图标间距）、一套圆角（999）、一套三种色调，
/// 按钮挨着按钮时视觉重量一致。外观统一走 [FrostedGlass] 磨砂玻璃：
/// 背景模糊 + 斜向受光 + 顶部弧光 + 雾面噪点 + 上亮下暗渐变细边。
class ActionPill extends StatelessWidget {
  const ActionPill({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.tone = ActionTone.neutral,
    this.height = 42,
    this.fontSize = 14,
    this.focusNode,
    this.autofocus = false,
    this.expanded = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final ActionTone tone;
  final double height;
  final double fontSize;
  final FocusNode? focusNode;
  final bool autofocus;

  /// 撑满可用宽度（用于底部操作条里平分两枚按钮）。
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : colors.onSurface;
    final active = onPressed != null;
    // 色调只决定图标/文字：accent 用反色深字，danger 保留红色语义，
    // 玻璃底本身恒为中性冷灰，不再随海报取色，也不整块铺红。
    final foreground = switch (tone) {
      ActionTone.accent => dark ? const Color(0xFF111114) : colors.surface,
      ActionTone.danger => colors.error.withValues(
        alpha: active ? 0.92 : 0.36,
      ),
      ActionTone.neutral => ink.withValues(alpha: active ? 0.92 : 0.30),
    };
    return FrostedGlass(
      radius: 999,
      height: height,
      blur: 12,
      selected: tone == ActionTone.accent,
      frosted: tone != ActionTone.danger,
      elevated: false,
      focusNode: focusNode,
      autofocus: autofocus,
      semanticLabel: label,
      onTap: onPressed,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 6,
        children: [
          Icon(icon, size: 16, color: foreground),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
