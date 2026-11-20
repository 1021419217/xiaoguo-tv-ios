import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'focus_ring.dart';
import 'frosted_glass.dart';

/// 首页同款磨砂顶栏：内容从背后透出并被模糊，不铺色、不收边。
///
/// 早期这里铺了一层 0.66→0.34 的 surface 渐变并加了一道底边线，真机上
/// 顶栏区域变成一块偏蓝的色板、下缘一条硬线，和下面的深色背景割裂成
/// 「上半蓝、下半黑」。现在只保留极淡的均匀色，页面背景从上到下连续。
///
/// [child] 是顶栏内容（标题、按钮等）；作为 AppBar.flexibleSpace 使用时要
/// 传 [fill] = true，此时只铺一层模糊玻璃，文字与图标由 AppBar 自己绘制。
class FrostedHeader extends StatelessWidget {
  const FrostedHeader({super.key, this.child, this.fill = false});

  final Widget? child;
  final bool fill;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
      child: fill ? const SizedBox.expand() : (child ?? const SizedBox.expand()),
    ),
  );
}

/// 玻璃标题胶囊：与顶栏「编辑 / 清空」等 ActionPill 完全同一套玻璃件
/// （同 42 高、同 999 圆角、同模糊、同受光、同细亮边），只是内容换成文字。
/// 之前这里自己手搓了一层平涂渐变，和旁边两枚按钮明显不是一个风格。
/// 外层 Row + Spacer 保证在 AppBar / Expanded 的紧约束下仍按文字宽度收缩。
class GlassTitle extends StatelessWidget {
  const GlassTitle({
    super.key,
    required this.title,
    this.count,
    this.expand = true,
    this.plain = false,
  });

  final String title;
  final String? count;

  /// 裸大标题模式：对齐短剧之家设置页「返回圆钮 + 大号粗体标题」的层级，
  /// 不套胶囊底。只给 tab 根页（设置）用，其余页面仍用统一玻璃胶囊。
  final bool plain;

  /// 是否用 Spacer 占满整行。嵌在一行里（标题后面还要放筛选胶囊）时传 false，
  /// 否则内部 Spacer 会把后面的胶囊挤出去。
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    if (plain) {
      return Row(
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              color: ink,
            ),
          ),
          if (count case final value?) ...[
            const SizedBox(width: 8),
            Text(
              '· $value',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: ink.withValues(alpha: 0.55),
              ),
            ),
          ],
          if (expand) const Spacer(),
        ],
      );
    }
    return Row(
      children: [
        Semantics(
          header: true,
          child: FrostedGlass(
            radius: 999,
            height: 42,
            blur: 12,
            elevated: false,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: ink,
                    ),
                  ),
                ),
                if (count case final value?) ...[
                  const SizedBox(width: 6),
                  Text(
                    '· $value',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ink.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (expand) const Spacer(),
      ],
    );
  }
}

/// 玻璃筛选胶囊：替代原来实心的 ChoiceChip / Material 色块，
/// 选中时用主题色低透明度玻璃，未选中用中性磨砂玻璃。
class GlassChip extends StatelessWidget {
  const GlassChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
    this.height = 42,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : colors.onSurface;
    final primary = colors.primary;
    return FocusRing(
      radius: 999,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Material(
            color: Colors.transparent,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Container(
                height: height,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: selected
                      ? primary.withValues(alpha: dark ? 0.24 : 0.18)
                      : ink.withValues(alpha: 0.10),
                  border: Border.all(
                    color: selected
                        ? primary.withValues(alpha: 0.42)
                        : ink.withValues(alpha: 0.16),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: selected ? primary : ink,
                      ),
                    ),
                    if (badge case final value?)
                      Text(
                        value,
                        style: TextStyle(
                          fontSize: 12,
                          color: (selected ? primary : ink).withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
