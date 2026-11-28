import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';

/// 「左右翻页切换分类」层，对齐上游短剧之家的 TabView(.page) 手感。
///
/// 两种模式：
/// * 传 [itemBuilder]：真 PageView —— 相邻两页同时贴在屏内、1:1 跟手、
///   松手由 PageScrollPhysics 连续吸附，与上游 SwiftUI TabView(.page) 同源。
/// * 只传 [child]：兼容旧调用点，走快滑淡入（供尚未迁移的页面临时使用）。
///
/// 顶栏、搜索框、分类条放在本层外面，只有内容区参与横向翻页。
class SwipeCategoryLayer extends StatefulWidget {
  const SwipeCategoryLayer({
    super.key,
    required this.itemCount,
    required this.index,
    this.labels = const [],
    required this.onIndexChanged,
    this.child,
    this.itemBuilder,
    this.hintTop = 12,
    this.reservedTop,
    this.progress,
    this.pager,
  });

  final int itemCount;
  final int index;
  final List<String> labels;
  final ValueChanged<int> onIndexChanged;

  /// 旧模式：单一内容，快滑淡入。
  final Widget? child;

  /// 新模式：按页构建内容，内部启用真 PageView。
  final IndexedWidgetBuilder? itemBuilder;

  /// 保留接口兼容（提示胶囊早已去掉，不再渲染）。
  final double hintTop;

  /// 旧模式专用：落在 [reservedTop] 以内的按下不参与切分类手势
  /// （首页大海报自己的 PageView 用）。真 PageView 模式由嵌套手势优先接管。
  final double Function()? reservedTop;

  /// 连续滑动进度出口（0..itemCount-1）。传入后用 ValueNotifier 每帧回传
  /// PageView 的实时位置，供外层分类条画「跟手蚯蚓横条」；不传则无影响。
  /// 用 notifier 而不是回调，是为了让外层只重建分类条、不牵动整页 setState。
  final ValueNotifier<double>? progress;

  /// 上游同款：外部（首页）持有并与分类条共用的 PageController。
  /// 传入时本层只使用不销毁；不传则自己建一个、自己 dispose。
  final PageController? pager;

  @override
  State<SwipeCategoryLayer> createState() => _SwipeCategoryLayerState();
}

class _SwipeCategoryLayerState extends State<SwipeCategoryLayer>
    with SingleTickerProviderStateMixin {
  PageController? _pages;

  /// 正在朝哪一页做程序化吸附。非 null 期间不把 PageView 的中间页回传上层。
  int? _animatingTo;

  @override
  void dispose() {
    if (widget.pager == null) _pages?.dispose();
    super.dispose();
  }

  bool get _usePages =>
      widget.itemBuilder != null &&
      widget.itemCount >= 2 &&
      AppScope.formFactorOf(context) != FormFactor.television;

  @override
  Widget build(BuildContext context) {
    if (widget.itemBuilder != null) {
      if (!_usePages) return widget.itemBuilder!(context, widget.index);
      return _pageView(context);
    }
    final content = widget.child;
    if (content == null) return const SizedBox.shrink();
    if (widget.itemCount < 2 ||
        AppScope.formFactorOf(context) == FormFactor.television) {
      return content;
    }
    return _legacy(context, content);
  }

  // ---------------------------------------------------------------------
  // 新模式：真 PageView（上游 TabView(.page) 同款）
  // ---------------------------------------------------------------------

  Widget _pageView(BuildContext context) {
    final index = widget.index.clamp(0, widget.itemCount - 1);
    final controller = _pages ??= widget.pager ?? PageController(initialPage: index);

    // 进页面 / 切站源重建时，把进度出口对齐到真实初始页。
    // 外层 notifier 初始固定 0，若当前不是第 0 页（记住上次分类、切站源后
    // 落到别的分类），下划线会停在错误位置——这就是首页横条"完全错误"。
    final notifier = widget.progress;
    if (notifier != null && !controller.hasClients) {
      if (notifier.value != index.toDouble()) notifier.value = index.toDouble();
    }

    // 点击分类胶囊等「外部改 index」：让 PageView 吸附过去。
    final current = controller.hasClients ? controller.page : null;
    if (current == null || (current - index).abs() > 0.02) {
      _requestPage(controller, index);
    }

    return NotificationListener<ScrollNotification>(
      // 用户手指接管滚动时，之前排队的程序化动画立即作废，
      // 否则它完成时的收尾会把用户刚翻到的那页当成中间页吞掉。
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _animatingTo = null;
        }
        // 每帧把 PageView 的连续位置喂给外层分类条，做跟手横条。
        // 用 notifier.value 直接赋值（相等时不通知），避免无谓重建。
        final notifier = widget.progress;
        if (notifier != null &&
            notification is ScrollNotification &&
            controller.hasClients) {
          final p = controller.page;
          if (p != null) {
            final value = p.clamp(0.0, (widget.itemCount - 1).toDouble());
            if (notifier.value != value) notifier.value = value;
          }
        }
        return false;
      },
      child: PageView.builder(
        controller: controller,
        itemCount: widget.itemCount,
        physics: const PageScrollPhysics(parent: BouncingScrollPhysics()),
        onPageChanged: (page) {
          // 程序化跨类目动画途中会依次经过中间页（0→3 会依次报 1、2）。
          // 这些不是用户意图，必须忽略：一旦回传上层，上层 index 被逐格
          // 改写，下一次 build 就把目标拉回中间页，表现为「点第 4 个只挪
          // 到第 2 个」。只有到达目标页才收尾并解除屏蔽。
          if (_animatingTo != null) {
            if (page == _animatingTo) _animatingTo = null;
            return;
          }
          if (page == widget.index) return;
          unawaited(HapticFeedback.selectionClick());
          widget.onIndexChanged(page);
        },
        itemBuilder: (context, page) => widget.itemBuilder!(context, page),
      ),
    );
  }

  /// 朝 [target] 吸附。build 每次都会来问一遍，所以必须去重：动画未完成
  /// 就重复调 animateToPage 会把进度重置回起点，永远走不到目标页。
  ///
  /// 跨多页时先瞬移到目标相邻页再动画最后一页（对齐 guoapp 上游 2.0.4+116
  /// 的 _follow）：一次跳 7 个类目走的是「一下就位 + 最后一小段滑动」，途中
  /// 不经过任何中间页，因此不会触发中间页的 onPageChanged 把目标拉回去。
  void _requestPage(PageController controller, int target) {
    if (_animatingTo == target) return;
    _animatingTo = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final now = controller.hasClients ? controller.page : null;
      if (now == null) {
        // 还没挂载（或拿不到 page）就先放掉占用标记，等下一次 build 重新排队，
        // 否则标记会一直卡住，之后所有吸附请求都会被当成「已在动画中」忽略。
        _animatingTo = null;
        return;
      }
      if ((now - target).abs() <= 0.02) {
        _animatingTo = null;
        return;
      }
      final from = now.round();
      if ((target - from).abs() > 1) {
        controller.jumpToPage(target > from ? target - 1 : target + 1);
      }
      unawaited(
        controller
            .animateToPage(
              target,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() {
              if (mounted && _animatingTo == target) _animatingTo = null;
            }),
      );
    });
  }

  // ---------------------------------------------------------------------
  // 旧模式：快滑 + 淡入（保留给未迁移的调用点）
  // ---------------------------------------------------------------------

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1.0,
  );
  double _dragX = 0;

  void _switch(int delta) {
    if (widget.itemCount < 2) return;
    final next = widget.index + delta;
    if (next < 0 || next >= widget.itemCount) return;
    unawaited(HapticFeedback.selectionClick());
    _anim.forward(from: 0);
    widget.onIndexChanged(next);
    setState(() => _dragX = 0);
  }

  Widget _legacy(BuildContext context, Widget content) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        _CategoryDragRecognizer:
            GestureRecognizerFactoryWithHandlers<_CategoryDragRecognizer>(
              () => _CategoryDragRecognizer(reservedTop: widget.reservedTop),
              (recognizer) => recognizer
                ..reservedTop = widget.reservedTop
                ..onUpdate = (details) {
                  final next = (_dragX + details.delta.dx * 0.08).clamp(
                    -10.0,
                    10.0,
                  );
                  if (next != _dragX) setState(() => _dragX = next);
                }
                ..onEnd = (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity.abs() < 220) {
                    if (_dragX != 0) setState(() => _dragX = 0);
                    return;
                  }
                  _switch(velocity < 0 ? 1 : -1);
                }
                ..onCancel = () {
                  if (_dragX != 0) setState(() => _dragX = 0);
                },
            ),
      },
      child: AnimatedBuilder(
        animation: _anim,
        child: content,
        builder: (context, content) {
          final t = Curves.easeOutCubic.transform(_anim.value);
          final slide = _dragX * t * 0.6;
          return Transform.translate(
            offset: Offset(slide, 0),
            child: Opacity(opacity: 0.72 + 0.28 * t, child: content),
          );
        },
      ),
    );
  }
}

/// 旧模式横滑识别器：按下的位置落在 [reservedTop] 以内就不参与竞争，
/// 让海报自己的 PageView 接住这次横滑。
class _CategoryDragRecognizer extends HorizontalDragGestureRecognizer {
  _CategoryDragRecognizer({this.reservedTop});

  double Function()? reservedTop;

  @override
  bool isPointerAllowed(PointerEvent event) {
    final top = reservedTop?.call() ?? 0;
    if (top > 0 && event.localPosition.dy < top) return false;
    return super.isPointerAllowed(event);
  }
}
