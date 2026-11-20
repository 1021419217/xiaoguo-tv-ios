import 'package:flutter/material.dart';

import '../theme/poster_palette.dart';
import 'focus_ring.dart';

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
/// 按钮挨着按钮时视觉重量一致，不会出现 Material 默认字按钮夹在玻璃胶囊中间
/// 那种风格割裂。
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
    // 胶囊玻璃底跟随海报色相，图标/文字仍用反色；danger 保留红色语义不参与。
    final tint = PosterPalette.instance.buttonTint ?? ink;
    // 主按钮保持「白底黑字」的视觉焦点，只掺一点海报色，不整块染色。
    final accentFill = Color.lerp(ink, tint, 0.24) ?? ink;
    final active = onPressed != null;
    final (background, border, foreground) = switch (tone) {
      ActionTone.accent => (
        accentFill.withValues(alpha: active ? 0.92 : 0.16),
        Colors.transparent,
        dark ? const Color(0xFF111114) : colors.surface,
      ),
      ActionTone.danger => (
        colors.error.withValues(alpha: active ? 0.10 : 0.04),
        colors.error.withValues(alpha: active ? 0.32 : 0.12),
        colors.error.withValues(alpha: active ? 0.92 : 0.36),
      ),
      ActionTone.neutral => (
        tint.withValues(alpha: active ? 0.14 : 0.04),
        tint.withValues(alpha: active ? 0.26 : 0.08),
        ink.withValues(alpha: active ? 0.92 : 0.30),
      ),
    };
    final pill = FocusRing(
      radius: 999,
      child: Material(
        color: background,
        shape: StadiumBorder(side: BorderSide(color: border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: focusNode,
          autofocus: autofocus,
          onTap: onPressed,
          customBorder: const StadiumBorder(),
          child: SizedBox(
            height: height,
            child: Padding(
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
            ),
          ),
        ),
      ),
    );
    return pill;
  }
}
