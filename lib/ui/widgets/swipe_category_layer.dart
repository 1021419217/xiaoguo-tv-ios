import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../theme/motion.dart';

/// 与首页同款的「左右快滑切换分类」层。
///
/// 手感机制 1:1 移植自上游 guoapp 的 `SwipeSwitch`：
/// - 拖动时内容按 0.4 阻尼跟手（到头只有 0.12），有真实「拖页面」的反馈；
/// - 松手按位移（屏宽 22%）或速度（700dp/s）判定是否切页；
/// - 切换走两段式：旧页 150ms 滑出淡出，新页 250ms 从对侧滑入淡入，
///   曲线用上游同款 emphasizedDecelerate / emphasizedAccelerate；
/// - 数据未就绪时先 hold 住（半透明 + 收回），就绪后再播，避免切到空页。
///
/// 小果特有的增强：
/// - `reservedTop` 让首页大海报那一段的横滑交给海报自己的 PageView；
/// - 切换时不弹分类名提示胶囊（按用户要求去掉）。
class SwipeCategoryLayer extends StatefulWidget {
  const SwipeCategoryLayer({
    super.key,
    required this.itemCount,
    required this.index,
    required this.labels,
    required this.onIndexChanged,
    required this.child,
    this.hintTop = 12,
    this.reservedTop,
    this.ready = true,
    this.onEnter,
  });

  final int itemCount;
  final int index;
  final List<String> labels;
  final ValueChanged<int> onIndexChanged;
  final Widget child;

  /// 提示胶囊距内容区顶部的距离（保留参数以兼容调用点，不再显示提示）。
  final double hintTop;

  /// 落在该 y（相对本层，向下为正）以内的按下不参与「切分类」手势。
  /// 首页的大海报要靠它把自己的横滑让出来。
  final double Function()? reservedTop;

  /// 新页数据是否就绪。false 时先 hold 住旧页，就绪后再播切换动画。
  final bool ready;

  /// 旧页退出结束、新页进入之前的回调（上游同款，可选）。
  final VoidCallback? onEnter;

  @override
  State<SwipeCategoryLayer> createState() => _SwipeCategoryLayerState();
}

class _SwipeCategoryLayerState extends State<SwipeCategoryLayer>
    with TickerProviderStateMixin {
  // 与上游 SwipeSwitch 完全一致的三个手感常数。
  static const _distance = .22;
  static const _velocity = 700.0;
  static const _travel = .18;

  late final _offset = AnimationController.unbounded(vsync: this);
  late final _opacity = AnimationController(vsync: this, value: 1);
  double _drag = 0;
  double _width = 1;
  Widget? _leaving;
  int _run = 0;
  int _direction = 1;
  Timer? _wait;

  @override
  void didUpdateWidget(covariant SwipeCategoryLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _leaving ??= oldWidget.child;
      _direction = widget.index > oldWidget.index ? 1 : -1;
      widget.ready ? _proceed() : _hold();
    } else if (_wait != null && widget.ready) {
      _proceed();
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _offset.dispose();
    _opacity.dispose();
    super.dispose();
  }

  bool get _switching => _leaving != null;

  void _hold() {
    _run++;
    _wait?.cancel();
    // 上游等 1.5s 兜底；数据在此期间就绪会走 didUpdateWidget 分支提前切。
    _wait = Timer(const Duration(milliseconds: 1500), _proceed);
    final duration = Motion.of(context, Motion.medium);
    unawaited(_offset.animateTo(0, duration: duration, curve: Motion.enter));
    unawaited(_opacity.animateTo(.5, duration: duration, curve: Motion.enter));
  }

  void _proceed() {
    _wait?.cancel();
    _wait = null;
    if (mounted) unawaited(_play(_direction));
  }

  Future<void> _play(int direction) async {
    final run = ++_run;
    final travel = _width * _travel * direction;
    final exit = Motion.of(context, Motion.short);
    try {
      await Future.wait([
        _offset.animateTo(-travel, duration: exit, curve: Motion.exit).orCancel,
        _opacity.animateTo(0, duration: exit, curve: Motion.exit).orCancel,
      ]);
    } on TickerCanceled {
      return;
    }
    if (!mounted || run != _run) return;
    widget.onEnter?.call();
    setState(() => _leaving = null);
    _offset.value = travel;
    final enter = Motion.of(context, Motion.medium);
    unawaited(_offset.animateTo(0, duration: enter, curve: Motion.enter));
    unawaited(_opacity.animateTo(1, duration: enter, curve: Motion.enter));
  }

  void _start(DragStartDetails _) {
    if (_switching) return;
    _offset.stop();
    _drag = _offset.value / .4;
  }

  void _update(DragUpdateDetails details) {
    if (_switching) return;
    _drag += details.primaryDelta ?? 0;
    final open = _drag > 0
        ? widget.index > 0
        : widget.index < widget.itemCount - 1;
    if (!Motion.reduced(context)) _offset.value = _drag * (open ? .4 : .12);
  }

  void _end(DragEndDetails details) {
    if (_switching) return;
    final velocity = details.primaryVelocity ?? 0;
    final next =
        _drag < 0 && (_drag < -_width * _distance || velocity < -_velocity);
    final previous =
        _drag > 0 && (_drag > _width * _distance || velocity > _velocity);
    _drag = 0;
    final target = widget.index + (next ? 1 : (previous ? -1 : 0));
    if (target != widget.index && target >= 0 && target < widget.itemCount) {
      unawaited(HapticFeedback.selectionClick());
      widget.onIndexChanged(target);
      return;
    }
    _settle();
  }

  void _settle() {
    _drag = 0;
    if (_switching || _offset.value == 0) return;
    unawaited(
      _offset.animateTo(
        0,
        duration: Motion.of(context, Motion.long),
        curve: Motion.enter,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount < 2 ||
        AppScope.formFactorOf(context) == FormFactor.television) {
      return widget.child;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedWidth) _width = constraints.maxWidth;
        return RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: {
            _CategoryDragRecognizer:
                GestureRecognizerFactoryWithHandlers<_CategoryDragRecognizer>(
              () => _CategoryDragRecognizer(reservedTop: widget.reservedTop),
              (recognizer) => recognizer
                ..reservedTop = widget.reservedTop
                ..onStart = _start
                ..onUpdate = _update
                ..onEnd = _end
                ..onCancel = _settle,
            ),
          },
          child: AnimatedBuilder(
            animation: Listenable.merge([_offset, _opacity]),
            builder: (context, child) => Opacity(
              opacity: _opacity.value,
              child: Transform.translate(
                offset: Offset(_offset.value, 0),
                child: child,
              ),
            ),
            child: IgnorePointer(
              ignoring: _switching,
              child: _leaving ?? widget.child,
            ),
          ),
        );
      },
    );
  }
}

/// 横滑识别器：按下的位置落在 [reservedTop] 以内（大海报那一段）就不参与
/// 竞争，让海报自己的 PageView 接住这次横滑——手指按在大封面上翻封面，
/// 按在封面以下才是切分类。
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
