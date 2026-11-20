import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'bar_button.dart';
import 'page_header.dart';
import 'search_field.dart';

class SourceBar extends StatelessWidget {
  const SourceBar({
    super.key,
    required this.source,
    required this.onSwitchSource,
    required this.onOpenSearch,
    required this.onSearchSubmitted,
    this.searchController,
    this.televisionLeading,
    this.leading = const [],
    this.actions = const [],
  });
  final String source;
  final void Function(BuildContext anchor) onSwitchSource;
  final VoidCallback onOpenSearch;
  final ValueChanged<String> onSearchSubmitted;
  final TextEditingController? searchController;
  final Widget? televisionLeading;

  /// 小果 2.0 新增：左端附加操作（如封面模糊开关），保留以免破坏调用点。
  final List<Widget> leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    final hint = '在 $source 中搜索';
    final switcher = Builder(
      builder: (anchor) => BarButton(
        icon: Icons.public_rounded,
        tooltip: '切换站源',
        onPressed: () => onSwitchSource(anchor),
      ),
    );
    // 电视端保留实心圆钮（遥控器焦点更清晰）；手机端改用低对比磨砂胶囊。
    final tvSearch = BarButton(
      icon: Icons.search_rounded,
      tooltip: hint,
      onPressed: onOpenSearch,
    );
    // 站源名与换源合为一体：整颗胶囊都可点击，不用再去右上角找地球图标。
    final title = _SourceSwitcher(
      source: source,
      onSwitchSource: onSwitchSource,
    );
    return switch (form) {
      FormFactor.phone => PageHeader(
        title: source,
        titleChild: title,
        actions: [
          _actionRow([
            ...leading,
            ...actions,
            _SearchPill(tooltip: hint, onPressed: onOpenSearch),
          ]),
        ],
      ),
      FormFactor.pad || FormFactor.window => PageHeader(
        title: source,
        titleChild: title,
        actions: [
          ...leading,
          SizedBox(
            width: MediaQuery.sizeOf(context).width >= 900 ? 320 : 240,
            child: SearchField(
              hint: hint,
              controller: searchController,
              onSubmitted: onSearchSubmitted,
            ),
          ),
          const SizedBox(width: 4),
          ...actions,
        ],
      ),
      // 电视端保留独立的地球按钮，适配遥控器焦点遍历。
      FormFactor.television => SizedBox(
        height: 48,
        child: Row(
          spacing: 10,
          children: [
            ?televisionLeading,
            const Spacer(),
            Text(
              source,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            switcher,
            tvSearch,
            ...actions,
          ],
        ),
      ),
    };
  }

  /// 操作组等距 8px 排列，搜索胶囊在最右，与左侧换源胶囊同款呼应。
  Widget _actionRow(List<Widget?> items) {
    final children = items.whereType<Widget>().toList();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          children[i],
        ],
      ],
    );
  }
}

/// 站源切换胶囊：主题色地球徽标 + 当前站源名 + 下拉箭头，
/// 磨砂玻璃底与细白描边，和右侧搜索胶囊形成左右同款呼应。
/// 整块都可点击，点开即为全部站源列表，换源一步到位。
class _SourceSwitcher extends StatelessWidget {
  const _SourceSwitcher({required this.source, required this.onSwitchSource});
  final String source;
  final void Function(BuildContext anchor) onSwitchSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    // 形状仍是胶囊，但整块换成统一磨砂玻璃：背景模糊透色、左上受光、
    // 上亮下暗渐变亮边、顶部弧光与雾面颗粒，跟底栏/圆钮同一套质感。
    return Builder(
      builder: (anchor) => FrostedGlass(
        radius: 22,
        height: 42,
        blur: 16,
        padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
        tooltip: '切换站源',
        semanticLabel: '当前站源 $source，点击切换',
        onTap: () => onSwitchSource(anchor),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _GlassBadge(icon: Icons.public_rounded, ink: ink),
            const SizedBox(width: 9),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: Text(
                source,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: ink,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: ink.withValues(alpha: 0.55),
            ),
          ],
        ),
      ),
    );
  }
}

/// 胶囊左端的圆形玻璃徽标：与整块胶囊同款磨砂质感，
/// 但关掉背景模糊（避免胶囊内再嵌一层 BackdropFilter 的双重开销）。
class _GlassBadge extends StatelessWidget {
  const _GlassBadge({required this.icon, required this.ink});
  final IconData icon;
  final Color ink;

  @override
  Widget build(BuildContext context) => FrostedGlass(
    circle: true,
    width: 28,
    height: 28,
    selected: true,
    frosted: false,
    child: Center(
      child: Icon(icon, size: 17, weight: 700, color: ink),
    ),
  );
}

/// 顶栏搜索胶囊：保留「搜索」二字，与左侧换源胶囊左右同款磨砂玻璃。
/// 搜索功能 [onPressed] 原样透传，形状与交互都不变。
class _SearchPill extends StatelessWidget {
  const _SearchPill({required this.tooltip, required this.onPressed});
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    return FrostedGlass(
      radius: 21,
      height: 42,
      blur: 16,
      padding: const EdgeInsets.fromLTRB(6, 0, 11, 0),
      tooltip: tooltip,
      semanticLabel: tooltip,
      onTap: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GlassBadge(icon: Icons.search_rounded, ink: ink),
          const SizedBox(width: 7),
          Text(
            '搜索',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: ink.withValues(alpha: 0.92),
            ),
          ),
          const SizedBox(width: 2),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 17,
            color: ink.withValues(alpha: 0.5),
          ),
        ],
      ),
    );
  }
}
