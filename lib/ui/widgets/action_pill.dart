import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'focus_ring.dart';

/// 「有新版可升」用的薄荷绿。
///
/// 刻意不跟随种子色：界面本来就是「近黑灰阶 + 中性白高光」，
/// 彩色只承担语义（红=破坏性）。用这条低饱和绿既能在深底上读清，
/// 又不会和用户的 6 种主题色（橙/玫红/琥珀/青绿/海蓝/蓝紫）撞架。
const _infoGreen = Color(0xFF34D399);

enum ActionTone {
  /// 普通操作：低对比玻璃胶囊。
  neutral,

  /// 主操作：反色强调（深色主题下为白底黑字）。顶栏「完成/编辑」在用。
  accent,

  /// 安装：实心柔白。比 accent 低一档亮度，近黑底上不再是一块发光板，
  /// 但仍是四档里最亮的一枚，扫一眼就知道「这个该装」。
  install,

  /// 有新版可升：薄荷绿描边 + 淡绿底，和「安装」「重装」一眼区分开。
  info,

  /// 破坏性操作：只降饱和度的红描边，不铺整块红底。
  danger,
}

/// 全应用统一的操作胶囊：顶栏的「编辑 / 清空 / 全选 / 完成」、模块卡片的
/// 「导出 / 更新 / 卸载」、列表里的「清除已结束」都用它。
///
/// 一套尺寸（34 高、13 号字、6 号图标间距）、一套圆角（999）、一套五种色调，
/// 按钮挨着按钮时视觉重量一致，不会出现 Material 默认字按钮夹在玻璃胶囊中间
/// 那种风格割裂。五种色调分工：neutral=普通、accent=顶栏主操作、install=安装、
/// info=有新版可升、danger=破坏性。
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
    this.frosted = false,
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

  /// 毛玻璃。参数对齐首页搜索胶囊（sigma 16 + 对角渐变 + 细描边），
  /// 只在背后有东西可透的地方开（模块卡片底色是 0.72 半透明）。
  final bool frosted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : colors.onSurface;
    final active = onPressed != null;
    final (background, border, foreground) = switch (tone) {
      ActionTone.accent => (
        ink.withValues(alpha: active ? 0.92 : 0.16),
        Colors.transparent,
        dark ? const Color(0xFF111114) : colors.surface,
      ),
      ActionTone.install => (
        // 柔白 #D8D6DE：冷调灰白，比纯白暗两档（纯白 0xFFF2F2F5），
        // 近黑底上不再发光，但仍比灰胶囊亮，是四档里最显眼的一枚。
        const Color(0xFFD8D6DE).withValues(alpha: active ? 1 : 0.30),
        Colors.transparent,
        const Color(0xFF111114),
      ),
      ActionTone.info => (
        _infoGreen.withValues(alpha: active ? 0.14 : 0.05),
        _infoGreen.withValues(alpha: active ? 0.38 : 0.12),
        _infoGreen.withValues(alpha: active ? 1 : 0.42),
      ),
      ActionTone.danger => (
        colors.error.withValues(alpha: active ? 0.10 : 0.04),
        colors.error.withValues(alpha: active ? 0.32 : 0.12),
        colors.error.withValues(alpha: active ? 0.92 : 0.36),
      ),
      ActionTone.neutral => (
        ink.withValues(alpha: active ? 0.10 : 0.04),
        ink.withValues(alpha: active ? 0.16 : 0.08),
        ink.withValues(alpha: active ? 0.92 : 0.30),
      ),
    };
    // 毛玻璃模式下：底色交给渐变 + BackdropFilter，Material 只负责水波纹。
    // 三档透明度拉开差距，否则安装/重装都是白玻璃，看不出层级。
    final frostedTop = switch (tone) {
      ActionTone.install => 0.34,
      ActionTone.info => 0.26,
      _ => 0.15,
    };
    final inkColor = frosted && (tone == ActionTone.install || tone == ActionTone.neutral)
        ? ink.withValues(alpha: 0.96)
        : foreground;

    final body = SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 6,
          children: [
            Icon(icon, size: 16, color: inkColor),
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.1,
                color: inkColor,
              ),
            ),
          ],
        ),
      ),
    );

    Widget surface = Material(
      color: frosted ? Colors.transparent : background,
      shape: frosted ? const StadiumBorder() : StadiumBorder(side: BorderSide(color: border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        focusNode: focusNode,
        autofocus: autofocus,
        onTap: onPressed,
        customBorder: const StadiumBorder(),
        child: body,
      ),
    );

    if (frosted) {
      surface = ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  background.withValues(alpha: active ? frostedTop : frostedTop * 0.5),
                  background.withValues(alpha: active ? frostedTop * 0.38 : frostedTop * 0.20),
                ],
              ),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: border),
            ),
            child: surface,
          ),
        ),
      );
    }

    return FocusRing(radius: 999, child: surface);
  }
}
