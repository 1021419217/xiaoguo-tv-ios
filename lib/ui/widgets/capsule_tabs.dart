import 'package:flutter/material.dart';

/// 统一的胶囊分段控件：模块页、下载页、追剧页共用同一套外观与手感。
///
/// 关键点（上一版几个页面的痛点都在这里）：
/// * 段宽由「文字 + 左右内边距」自己撑开，没有固定高度也没有固定宽度，
///   所以胶囊永远完整包住文字，字号放大也不会露出半截；
/// * 高亮是每段自己的背景，可选的 [animation] 让它跟随分页动画交叉淡入淡出，
///   宽度始终等于某一段的真实宽度，不会出现「指示器正在两段之间」的中间态；
/// * 轨道、描边、字重、圆角全部一致，任何一页看起来都是同一套东西。
class CapsuleTabs extends StatefulWidget {
  const CapsuleTabs({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.animation,
    this.scrollable = false,
    this.expand = false,
    this.track = true,
    this.fontSize = 13.5,
    this.padding = const EdgeInsets.symmetric(horizontal: 14),
    this.margin = EdgeInsets.zero,
    this.height = 42,
    this.stretch = false,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  /// 与 `TabController.animation` 绑定：左右滑动分页时高亮跟着淡入淡出。
  final Animation<double>? animation;

  /// 标签过多时横向滚动，并在切换后把当前段滚进可视区。
  final bool scrollable;

  /// 各段等分铺满整行（用于数量固定、需要撑满的场合）。
  final bool expand;

  /// 是否绘制外层轨道底色。嵌在其它胶囊容器里时可以关掉。
  final bool track;

  final double fontSize;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final double height;

  /// 让轨道横向铺满父级宽度（内容仍靠左），用于需要跟下方卡片等宽对齐的页面。
  final bool stretch;

  @override
  State<CapsuleTabs> createState() => _CapsuleTabsState();
}

class _CapsuleTabsState extends State<CapsuleTabs> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};

  @override
  void didUpdateWidget(covariant CapsuleTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index && widget.scrollable) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reveal() {
    final target = _keys[widget.index]?.currentContext;
    if (target == null || !mounted) return;
    Scrollable.ensureVisible(
      target,
      alignment: 0.5,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _segment(BuildContext context, int i, double weight) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    final dim = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: dark ? 0.86 : 0.92,
    );
    final selected = weight > 0.5;
    return Semantics(
      selected: selected,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (i != widget.index) widget.onChanged(i);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          height: widget.height - 6,
          padding: EdgeInsets.only(
            left: widget.padding.left,
            right: widget.padding.right,
          ),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: ink.withValues(alpha: 0.12 * weight),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: ink.withValues(alpha: 0.14 * weight)),
          ),
          child: Text(
            widget.labels[i],
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: widget.fontSize,
              height: 1.15,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: -0.1,
              color: Color.lerp(dim, ink, weight),
            ),
          ),
        ),
      ),
    );
  }

  Widget _layout(BuildContext context, double position) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    final segments = [
      for (var i = 0; i < widget.labels.length; i++)
        KeyedSubtree(
          key: _keys.putIfAbsent(i, GlobalKey.new),
          child: _segment(
            context,
            i,
            (1 - (position - i).abs()).clamp(0.0, 1.0),
          ),
        ),
    ];
    final row = widget.expand
        ? Row(
            children: [
              for (final segment in segments) Expanded(child: segment),
            ],
          )
        : Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: segments);
    final content = widget.scrollable
        ? SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: segments,
            ),
          )
        : Padding(padding: const EdgeInsets.all(3), child: row);
    if (!widget.track) return Padding(padding: widget.margin, child: content);
    return Padding(
      padding: widget.margin,
      child: ConstrainedBox(
        constraints: widget.stretch
            ? const BoxConstraints(minWidth: double.infinity)
            : const BoxConstraints(),
        child: Container(
          decoration: BoxDecoration(
            color: ink.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: ink.withValues(alpha: 0.08)),
          ),
          child: content,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final animation = widget.animation;
    if (animation == null) return _layout(context, widget.index.toDouble());
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => _layout(context, animation.value),
    );
  }
}
