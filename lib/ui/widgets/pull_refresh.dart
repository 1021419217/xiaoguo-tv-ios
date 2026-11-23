import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/motion.dart';

/// 自定义下拉刷新（对齐 guoapp 上游 2.0.4+116）：
/// 往回推时先把指示器收起再滚动内容，松手未过触发点则取消刷新。
/// 下拉过程中顶部弹出一个圆形进度按钮，过阈值松手触发 [onRefresh]。
class PullRefresh extends StatefulWidget {
  const PullRefresh({
    super.key,
    required this.onRefresh,
    this.edgeOffset = 0,
    required this.child,
  });
  final RefreshCallback onRefresh;
  final double edgeOffset;
  final Widget child;

  @override
  State<PullRefresh> createState() => PullRefreshState();
}

class PullRefreshState extends State<PullRefresh>
    with SingleTickerProviderStateMixin {
  static const _size = 40.0;
  static const _displacement = 40.0;
  static const _reach = .25;

  late final _pull = AnimationController(vsync: this, upperBound: 1.5);
  double? _dragged;
  double _threshold = 1;
  Future<void>? _refresh;
  late ScrollBehavior _behavior;

  bool get _refreshing => _refresh != null;

  Future<void> show() => _refresh ??= _run();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final inherited = ScrollConfiguration.of(context);
    _behavior = inherited.copyWith(
      physics: _PullPhysics(this, parent: inherited.getScrollPhysics(context)),
    );
  }

  @override
  void dispose() {
    _pull.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    _dragged = null;
    setState(() {});
    unawaited(
      _pull.animateTo(
        1,
        duration: Motion.of(context, Motion.short),
        curve: Motion.standard,
      ),
    );
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        await _pull.animateTo(
          0,
          duration: Motion.of(context, Motion.medium),
          curve: Motion.exit,
        );
        if (mounted) setState(() => _refresh = null);
      }
    }
  }

  bool _onScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (notification.depth != 0 ||
        metrics.axisDirection != AxisDirection.down ||
        _refreshing) {
      return false;
    }
    final dragged = _dragged;
    if (notification is ScrollStartNotification) {
      if (notification.dragDetails != null && metrics.extentBefore == 0) {
        _dragged = 0;
        _threshold = metrics.viewportDimension * _reach;
      } else {
        // 不在顶部开始的滚动（例如从中间往上滑）不能沿用上一次下拉的残留量，
        // 否则 _consume 会持续吃掉向上位移，表现就是滑到某处卡住、进度条还在涨。
        _dragged = null;
      }
      return false;
    }
    if (dragged == null) return false;
    switch (notification) {
      case OverscrollNotification(dragDetails: null) ||
          ScrollUpdateNotification(dragDetails: null) ||
          ScrollEndNotification():
        _release(dragged);
    }
    return false;
  }

  double _consume(ScrollMetrics position, double offset) {
    final dragged = _dragged;
    if (dragged == null || position.axisDirection != AxisDirection.down) {
      return 0;
    }
    final room = math.max(position.pixels - position.minScrollExtent, 0.0);
    final used = offset > room
        ? offset - room
        : (offset < 0 ? math.max(offset, -dragged) : 0.0);
    if (used == 0) return 0;
    _dragged = dragged + used;
    _pull.value = _dragged! / _threshold;
    return used;
  }

  void _release(double dragged) {
    _dragged = null;
    if (dragged >= _threshold) {
      unawaited(show());
      return;
    }
    unawaited(
      _pull.animateTo(
        0,
        duration: Motion.of(context, Motion.medium),
        curve: Motion.exit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ScrollConfiguration(
          behavior: _behavior,
          child: Stack(
            children: [
              widget.child,
              Positioned.fill(
                top: widget.edgeOffset,
                child: IgnorePointer(
                  child: ClipRect(
                    child: AnimatedBuilder(
                      animation: _pull,
                      builder: (context, _) => _indicator(context),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _indicator(BuildContext context) {
    final pulled = _pull.value;
    if (pulled == 0 && !_refreshing) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topCenter,
      child: Transform.translate(
        offset: Offset(0, pulled * (_displacement + _size) - _size),
        child: Opacity(
          opacity: _refreshing ? 1 : (pulled * 1.5).clamp(0, 1),
          child: RefreshProgressIndicator(
            value: _refreshing ? null : pulled.clamp(0, 1) * .75,
            semanticsLabel: MaterialLocalizations.of(
              context,
            ).refreshIndicatorSemanticLabel,
          ),
        ),
      ),
    );
  }
}

/// 与上游 2.0.4+116 完全一致：继承 ScrollPhysics，靠 ScrollConfiguration
/// 注入到 physics 链里。ScrollPhysics.applyPhysicsToUserOffset 的默认实现是
/// `parent?.applyPhysicsToUserOffset(...) ?? offset`，会逐层转发，所以即使
/// 调用方显式传了 AlwaysScrollableScrollPhysics，本类仍在链路中被调用。
class _PullPhysics extends ScrollPhysics {
  const _PullPhysics(this.state, {super.parent});
  final PullRefreshState state;

  @override
  _PullPhysics applyTo(ScrollPhysics? ancestor) =>
      _PullPhysics(state, parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      super.applyPhysicsToUserOffset(
        position,
        offset - state._consume(position, offset),
      );
}
