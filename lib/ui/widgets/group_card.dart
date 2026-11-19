import 'package:flutter/material.dart';

import 'focus_ring.dart';

/// 由单色生成「亮面 → 暗面」的两段渐变，用于彩色图标。
List<Color> tintGradient(Color? base) {
  final hsl = HSLColor.fromColor(base ?? const Color(0xFF5B8DEF));
  Color at(double delta) => hsl
      .withLightness((hsl.lightness + delta).clamp(0.0, 1.0))
      .withSaturation((hsl.saturation * 1.06).clamp(0.0, 1.0))
      .toColor();
  return [at(.12), at(-.06)];
}

/// 半透明浅色分组卡：浮在氛围背景上，卡片后面能透出底色。
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // 用 Material 承载底色而不是 Container：ListTile / InkWell 的水波纹只会画在
    // 最近的 Material 上，套一层带底色的 Container 会把水波纹盖在下面。
    return Material(
      color: Colors.white.withValues(alpha: .078),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: Colors.white.withValues(alpha: .06)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.only(left: 57),
                child: Divider(
                  height: .5,
                  thickness: .5,
                  color: Colors.white.withValues(alpha: .075),
                ),
              ),
            children[i],
          ],
        ],
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
    return TileFocus(
      builder: (focusNode) => ListTile(
        focusNode: focusNode,
        minTileHeight: subtitle == null ? 60 : 72,
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
        horizontalTitleGap: 14,
        leading: icon == null
            ? null
            : SizedBox(
                width: 24,
                height: 24,
                child: ShaderMask(
                  blendMode: BlendMode.srcIn,
                  shaderCallback: (bounds) => LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: tintGradient(iconColor),
                  ).createShader(bounds),
                  child: Icon(icon, size: 22, color: Colors.white),
                ),
              ),
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
            color: Colors.white,
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
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
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
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
