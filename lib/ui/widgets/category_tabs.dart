import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../theme/motion.dart';
import 'bar_button.dart';
import 'choice_panel.dart';
import 'focus_ring.dart';

class CategoryTabs<T> extends StatefulWidget {
  const CategoryTabs({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.onShowAll,
    this.autoReveal = true,
    this.progress,
  });
  final List<ChoiceOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final void Function(BuildContext anchor)? onShowAll;
  final bool autoReveal;

  /// 选中位置的连续进度（0 到 `options.length - 1`）。
  ///
  /// 传了就每帧按它插值下划线位置，让下划线跟着外层 TabBarView / PageView
  /// 一起走；不传则仍是「选中值变了再滑过去」的老行为。
  final double? progress;

  @override
  State<CategoryTabs<T>> createState() => CategoryTabsState<T>();
}

class CategoryTabsState<T> extends State<CategoryTabs<T>> {
  final _scroll = ScrollController();
  final _keys = <T, GlobalKey>{};
  final _row = GlobalKey();
  bool _overflows = false;
  Rect? _indicator;
  bool _sliding = false;

  /// progress 模式下首帧量不到位置时只补一次重建，避免空转。
  bool _primed = false;

  @override
  void didUpdateWidget(covariant CategoryTabs<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 跟手横条（progress != null）禁止自动滚动分类条：滑动时 selected 每帧
    // 跟着 PageView 变，无条件居中会和跟手下划线打架，表现为整条弹跳。
    // 只有「全部分类」面板选完才走 revealSelected() 主动定位一次。
    if (widget.autoReveal &&
        widget.progress == null &&
        oldWidget.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  void revealSelected() => _reveal();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 贴边最小滚动（2.5.5+50 的用户认可版本）：选中项已经可见就完全不动，
  /// 只有确实滚出视口时才贴边滚一下。不再无条件 alignment:0.5 居中——
  /// 那会在长分类条上产生大幅弹跳，用户明确要求去掉。
  void _reveal() {
    final context = _keys[widget.selected]?.currentContext;
    if (context == null || !mounted) return;
    final box = context.findRenderObject();
    final viewport = _scroll.position.context.storageContext.findRenderObject();
    if (box is! RenderBox || viewport is! RenderBox) return;
    final left = box.localToGlobal(Offset.zero, ancestor: viewport).dx;
    final width = _scroll.position.viewportDimension;
    final right = left + box.size.width;
    if (left >= -16 && right <= width + 16) return;
    final atStart = left < 0;
    Scrollable.ensureVisible(
      context,
      alignment: atStart ? 0 : 1,
      alignmentPolicy: atStart
          ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
          : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
    );
  }

  bool _metricsChanged(ScrollMetricsNotification notification) {
    final overflows = notification.metrics.maxScrollExtent > 0;
    if (overflows != _overflows) setState(() => _overflows = overflows);
    return false;
  }

  /// 某个 tab 在行内的矩形（线宽贴合文字宽度，与上游一致）。
  Rect? _tabRect(int index, double inset) {
    if (index < 0 || index >= widget.options.length) return null;
    final tab = _keys[widget.options[index].value]?.currentContext
        ?.findRenderObject();
    final row = _row.currentContext?.findRenderObject();
    if (tab is! RenderBox || row is! RenderBox || !tab.hasSize) return null;
    final origin = tab.localToGlobal(Offset.zero, ancestor: row);
    return Rect.fromLTWH(
      origin.dx + inset,
      0,
      (tab.size.width - inset * 2).clamp(8.0, double.infinity),
      0,
    );
  }

  /// 按连续进度在相邻两个 tab 之间插值下划线位置。
  Rect? _progressRect(double value, double inset) {
    final count = widget.options.length;
    if (count == 0) return null;
    final last = count - 1;
    final position = value.clamp(0.0, last.toDouble());
    final from = position.floor();
    final to = from + 1 <= last ? from + 1 : from;
    final fraction = position - from;
    final a = _tabRect(from, inset);
    if (a == null) return null;
    if (fraction == 0 || from == to) return a;
    final b = _tabRect(to, inset);
    if (b == null) return a;
    return Rect.fromLTRB(
      a.left + (b.left - a.left) * fraction,
      0,
      a.right + (b.right - a.right) * fraction,
      0,
    );
  }

  /// 测量选中 tab 在行内的位置，供那条下划线定位/滑动。
  /// inset 用左右 padding，使线宽贴合文字宽度（与上游一致）。
  void _measure(double inset) {
    if (!mounted) return;
    final at = widget.options.indexWhere(
      (option) => option.value == widget.selected,
    );
    final rect = _tabRect(at, inset);
    if (rect == null) return;
    if (rect == _indicator) return;
    setState(() {
      // 首次定位不做滑动动画，之后切换才让线从旧位置滑到新位置。
      _sliding = _indicator != null;
      _indicator = rect;
    });
  }

  @override
  Widget build(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // 下划线不走主题强调色（紫色在高斯模糊界面里会跳色），改用与选中
    // 文字 / 玻璃胶囊描边同一套中性高光：深色模式近白、浅色模式深灰。
    final lineColor = colors.onSurface.withValues(alpha: dark ? 0.9 : 0.82);
    final (height, fontSize, padding, fade) = switch (form) {
      FormFactor.phone => (48.0, 15.0, 16.0, 20.0),
      FormFactor.pad || FormFactor.window => (48.0, 14.0, 14.0, 40.0),
      FormFactor.television => (44.0, 16.0, 16.0, 48.0),
    };
    _keys.removeWhere(
      (value, _) => !widget.options.any((option) => option.value == value),
    );
    final television = form == FormFactor.television;
    // 有连续进度时每帧插值，不再走「测量后动画」那条路。
    final progress = widget.progress;
    if (progress == null) {
      // 帧后测量选中 tab 的位置，驱动那条下划线定位 / 滑动。
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure(padding));
    }
    final interpolated = progress == null
        ? null
        : _progressRect(progress, padding);
    if (progress != null &&
        interpolated == null &&
        widget.options.isNotEmpty &&
        !_primed) {
      // 首帧 tab 还没布局，量不到位置；只补一帧再画一次，不会形成循环。
      _primed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    final indicator = interpolated ?? _indicator;
    final sliding = interpolated != null ? false : _sliding;
    // 手机 / 平板端「全部分类」常驻右端并与标签栏垂直居中对齐，
    // 不再依赖标签是否溢出——随时可点，位置固定，用起来才顺手。
    // 电视端仍按遥控器习惯，仅在标签溢出时于左端显示。
    Widget? showAll;
    final onShowAll = widget.onShowAll;
    if (onShowAll != null) {
      if (television) {
        if (_overflows) {
          showAll = Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Builder(
              builder: (anchor) => BarButton(
                icon: Icons.grid_view_rounded,
                tooltip: '全部分类',
                onPressed: () => onShowAll(anchor),
              ),
            ),
          );
        }
      } else {
        showAll = _AllCategoriesChip(onShowAll: onShowAll);
      }
    }
    return Container(
      height: height,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        children: [
          if (television) ?showAll,
          Expanded(
            child: Stack(
              children: [
                NotificationListener<ScrollMetricsNotification>(
                  onNotification: _metricsChanged,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.only(
                      left: form == FormFactor.phone ? 4 : 0,
                    ),
                    child: Stack(
                      key: _row,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final option in widget.options)
                              KeyedSubtree(
                                key: _keys.putIfAbsent(
                                  option.value,
                                  GlobalKey.new,
                                ),
                                child: _Tab(
                                  label: option.label,
                                  selected: option.value == widget.selected,
                                  fontSize: fontSize,
                                  padding: padding,
                                  onTap: () => widget.onSelected(option.value),
                                ),
                              ),
                          ],
                        ),
                        // 上游机制：一条线测量选中项后，从左滑到右；线宽贴合
                        // 文字宽度。颜色走中性高光而非主题色，融入玻璃界面。
                        if (indicator != null)
                          AnimatedPositioned(
                            duration: sliding
                                ? Motion.of(context, Motion.medium)
                                : Duration.zero,
                            curve: Motion.standard,
                            left: indicator.left,
                            width: indicator.width,
                            bottom: 0,
                            height: 3,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: lineColor,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // 手机端右端已有固定的「全部分类」胶囊与细分隔线，不需要
                // 再叠渐隐：深色主题下那层半透明 surface 会在标签与胶囊之间
                // 留下一小块暗阴影，浅色主题下则是一块白板。直接不绘制。
                if (_overflows && form != FormFactor.phone)
                  Positioned(
                    top: 0,
                    right: 0,
                    bottom: 0,
                    width: fade,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              colors.surface.withValues(alpha: 0),
                              colors.surface,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (!television) ?showAll,
        ],
      ),
    );
  }
}

/// 分类条按标签配图标：火（推荐/热门）、时钟（最新）、柱状（排行）、网格（分类）。
/// 匹配不到就返回 null，只显示文字，避免给每个站源分类乱配图标。
IconData? _tabIcon(String label) {
  if (label.contains('推荐') || label.contains('热门')) {
    return Icons.local_fire_department_rounded;
  }
  if (label.contains('最新') || label.contains('最近')) {
    return Icons.schedule_rounded;
  }
  if (label.contains('排行') || label.contains('榜单')) {
    return Icons.bar_chart_rounded;
  }
  if (label.contains('分类') || label.contains('全部')) {
    return Icons.grid_view_rounded;
  }
  return null;
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.fontSize,
    required this.padding,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final double fontSize;
  final double padding;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 与上游一致：文字不做彩色点亮，只在 onSurface / onSurfaceVariant 之间
    // 平滑过渡，靠加粗 + 底部那条线来定位选中项。
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: FocusRing(
        radius: 8,
        offset: -3,
        child: InkWell(
          onTap: onTap,
          focusColor: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: padding),
            child: Center(
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(
                  end: selected ? colors.onSurface : colors.onSurfaceVariant,
                ),
                duration: Motion.of(context, Motion.medium),
                curve: Motion.standard,
                builder: (context, color, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_tabIcon(label) case final icon?) ...[
                      Icon(icon, size: fontSize + 1, color: color),
                      const SizedBox(width: 3),
                    ],
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: color,
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

/// 分类栏右端的「全部分类」入口：与顶栏站源 / 搜索胶囊同一套低对比磨砂
/// 玻璃（均匀半透明 + 轻模糊 + 极细描边），不再用实心底，避免配色跳脱。
/// 左侧一道极细分隔线，固定居右、垂直居中。
class _AllCategoriesChip extends StatelessWidget {
  const _AllCategoriesChip({required this.onShowAll});
  final void Function(BuildContext anchor) onShowAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    return Builder(
      builder: (anchor) => Padding(
        padding: const EdgeInsets.only(left: 8, right: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 1,
              height: 22,
              color: ink.withValues(alpha: dark ? 0.14 : 0.10),
            ),
            const SizedBox(width: 10),
            Tooltip(
              message: '全部分类',
              child: Semantics(
                button: true,
                label: '全部分类',
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(19),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onShowAll(anchor),
                    borderRadius: BorderRadius.circular(19),
                    splashColor: ink.withValues(alpha: 0.10),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(19),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: Container(
                          height: 38,
                          padding: const EdgeInsets.symmetric(horizontal: 13),
                          decoration: BoxDecoration(
                            color: ink.withValues(alpha: dark ? 0.09 : 0.06),
                            borderRadius: BorderRadius.circular(19),
                            border: Border.all(
                              color: ink.withValues(alpha: dark ? 0.12 : 0.10),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.grid_view_rounded,
                                size: 16,
                                color: ink.withValues(alpha: 0.92),
                              ),
                              const SizedBox(width: 7),
                              Text(
                                '全部分类',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                  color: ink.withValues(alpha: 0.92),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
