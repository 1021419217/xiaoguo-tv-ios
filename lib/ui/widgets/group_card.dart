import 'package:flutter/material.dart';

import 'focus_ring.dart';

/// 深灰分组圆角卡：只靠间距分组，不再画行间分隔线。
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 用 Material 承载底色而不是 Container：ListTile / InkWell 的水波纹只会画在
    // 最近的 Material 上，套一层带底色的 Container 会把水波纹盖在下面——
    // 设置页所有条目点下去都没有任何反馈，就是这个原因。
    return Material(
      color: colors.surfaceContainer.withValues(alpha: 0.72),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.value,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TileFocus(
      builder: (focusNode) => ListTile(
        focusNode: focusNode,
        minTileHeight: 56,
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 14, 6),
        horizontalTitleGap: 14,
        // 图标统一成中性底色的圆角方块：不再用彩色圆点，一屏不会散出四种色。
        leading: icon == null
            ? null
            : Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: colors.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: colors.onSurface.withValues(alpha: 0.08),
                  ),
                ),
                child: Icon(icon, size: 18, color: colors.onSurfaceVariant),
              ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            color: colors.onSurface,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.1,
                  color: colors.onSurfaceVariant.withValues(alpha: 0.95),
                ),
              ),
        trailing:
            trailing ??
            (value == null && onTap == null
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      if (value case final text?)
                        Text(
                          text,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colors.onSurfaceVariant,
                              ),
                        ),
                      if (onTap != null)
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: colors.onSurfaceVariant,
                        ),
                    ],
                  )),
        onTap: onTap,
        enabled: enabled,
      ),
    );
  }
}

/// 区块标题：12 号灰字 + 字距，起目录作用；右侧可挂「全部 ›」。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(4, 12, 4, 6),
  });
  final String title;

  /// 标题右侧的灰色计数，例如 `12`。
  final String? trailing;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.3,
      height: 1.4,
      color: colors.onSurfaceVariant,
    );
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text.rich(
                TextSpan(
                  text: title,
                  children: [
                    if (trailing case final trailing?)
                      TextSpan(
                        text: '  $trailing',
                        style: style.copyWith(
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ),
          if (action case final action?)
            FocusRing(
              radius: 999,
              child: TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.fromLTRB(8, 4, 2, 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: colors.onSurfaceVariant,
                  textStyle: style.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 2,
                  children: [
                    Text(action),
                    const Icon(Icons.chevron_right_rounded, size: 14),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
