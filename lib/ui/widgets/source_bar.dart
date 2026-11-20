import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../theme/poster_palette.dart';
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
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // 形状保持胶囊不动，仅配色接入实时海报取色：玻璃底与地球徽标跟随
    // 当前海报色相，文字仍用反色保证可读；没取到色 / 关闭跟随时退回白/墨玻璃。
    final ink = dark ? Colors.white : colors.onSurface;
    final glass =
        PosterPalette.instance.buttonTint ?? (dark ? Colors.white : colors.onSurface);
    return Builder(
      builder: (anchor) => Tooltip(
        message: '切换站源',
        child: Semantics(
          button: true,
          label: '当前站源 $source，点击切换',
          child: Material(
            color: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onSwitchSource(anchor),
              borderRadius: BorderRadius.circular(22),
              splashColor: glass.withValues(alpha: 0.10),
              child: Container(
                height: 42,
                padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      glass.withValues(alpha: dark ? 0.16 : 0.09),
                      glass.withValues(alpha: dark ? 0.07 : 0.04),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: glass.withValues(alpha: dark ? 0.26 : 0.16),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: glass.withValues(alpha: 0.22),
                      ),
                      child: Icon(
                        Icons.public_rounded,
                        size: 17,
                        color: glass,
                      ),
                    ),
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
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶栏搜索钮：对齐短剧之家那种圆形毛玻璃图标钮。
///
/// 直接复用 [BarButton]，自动继承统一调好的玻璃档位（0.20 填充 / 0.28 描边），
/// 与全 App 其它圆形操作钮同款。搜索功能 [onPressed] 原样透传，不变。
class _SearchPill extends StatelessWidget {
  const _SearchPill({required this.tooltip, required this.onPressed});
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => BarButton(
        icon: Icons.search_rounded,
        tooltip: tooltip,
        onPressed: onPressed,
      );
}
