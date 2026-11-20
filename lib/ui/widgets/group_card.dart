import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/type_scale.dart';
import 'bar_button.dart';
import 'focus_ring.dart';

/// 深灰分组圆角卡：项目之间用极细分隔线，卡片带真磨砂玻璃底色与细亮描边。
/// 色板固定为中性冷灰，不随海报或视频帧变化。
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 用 Material 承载底色而不是 Container：ListTile / InkWell 的水波纹只会画在
    // 最近的 Material 上，套一层带底色的 Container 会把水波纹盖在下面——
    // 设置页所有条目点下去都没有任何反馈，就是这个原因。
    // 模糊层放在 Material 外侧，只作用于卡片背后的内容，不影响水波纹。
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: GlassTones.card.withValues(alpha: 0.78),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: GlassTones.edge(0.55),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Divider(height: 1, color: colors.outlineVariant),
                  ),
                children[i],
              ],
            ],
          ),
        ),
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
    this.iconColor,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  /// 圆形图标底色；不传时用主题色的低饱和版本。
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final badge = iconColor ?? colors.primary;
    return TileFocus(
      builder: (focusNode) => ListTile(
        focusNode: focusNode,
        minTileHeight: subtitle == null ? 60 : 72,
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
        horizontalTitleGap: 14,
        leading: icon == null
            ? null
            : Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.4),
                    radius: 0.95,
                    colors: [
                      badge.withValues(alpha: 0.95),
                      badge.withValues(alpha: 0.62),
                    ],
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.20),
                    width: 1,
                  ),
                ),
                child: Icon(icon, size: 19, weight: 700, color: Colors.white),
              ),
        title: Text(
          title,
          style: TypeScale.title(15.5).copyWith(color: colors.onSurface),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                style: TypeScale.caption(12.5).copyWith(
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
        onTap: onTap == null
            ? null
            : () {
                unawaited(HapticFeedback.selectionClick());
                onTap!();
              },
        enabled: enabled,
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 8, 0),
  });
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: TypeScale.section(13).copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (action != null)
            FocusRing(
              radius: 999,
              child: TextButton(onPressed: onAction, child: Text(action!)),
            ),
        ],
      ),
    ),
  );
}
