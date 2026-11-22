import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';

/// 与首页同款的「左右跟手翻页切换分类」层。
///
/// 只把**内容区**包进来（顶栏、搜索框、分类胶囊留在外面），传分类数量 /
/// 当前序号，手指横向拖动时内容 **1:1 跟手平移**，松手时按位移 + 速度判断
/// 吸附到相邻分类：翻页则当前内容顺势推出、新内容从另一侧滑入；不翻则回弹。
/// 观感对齐上游 PageView 的「翻书」手感，但不改各页的内容构建结构（六个页面
/// 共用本组件，改这一处即可全体升级）。
///
/// 切换时不弹分类名提示（按用户要求去掉），只在成功翻页时给一次轻震动。
/// [reservedTop] 让首页大海报那一段的横滑留给海报自己的 PageView 翻封面。
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
  });

  final int itemCount;
  final int index;
  final List<String> labels;
  final ValueChanged<int> onIndexChanged;
  final Widget child;

  /// 提示胶囊距内容区顶部的距离（保留接口兼容，当前不再渲染提示）。
  final double hintTop;

  /// 落在该 y（相对本层，向下为正）以内的按下不参与「切分类」手势。
  /// 首页的大海报要靠它把自己的横滑让出来：手指按在海报上时由海报翻页，
  /// 按在海报下方才是切分类。返回 0 表示整层都可切分类。
  final double Function()? reservedTop;

  @override
  State<SwipeCategoryLayer> createState() => _SwipeCategoryLayerState();
}

class _SwipeCategoryLayerState extends State<SwipeCategoryLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// 手指拖动中的实时位移；松手后由 [_settle] 接管。
  double _dx = 0;
  double _settleFrom = 0;
  double _settleTo = 0;

  /// 0=空闲；1=推出当前页（第一段）；2=新页滑入（第二段）。
  int _phase = 0;
  int _pendingDelta = 0;

  @override
  void initState() {
    super.initState();
    _settle.addStatusListener(_onSettleStatus);
  }

  @override
  void dispose() {
    _settle.removeStatusListener(_onSettleStatus);
    _settle.dispose();
    super.dispose();
  }

  /// 动画到位时推进状态机，避免在回调里嵌套/递归启动动画。
  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (_phase == 1) {
      if (_pendingDelta == 0) {
        _finish();
        return;
      }
      // 第一段（旧页推出）完成：切页，再从对称位置把新页滑回原位。
      widget.onIndexChanged(widget.index + _pendingDelta);
      _phase = 2;
      _settleFrom = -_settleTo;
      _settleTo = 0;
      _settle
        ..duration = const Duration(milliseconds: 240)
        ..forward(from: 0);
    } else if (_phase == 2) {
      _finish();
    }
  }

  void _finish() {
    if (!mounted) return;
    setState(() {
      _dx = 0;
      _phase = 0;
      _pendingDelta = 0;
    });
  }

  void _onUpdate(DragUpdateDetails details) {
    if (_phase != 0) return;
    final width = MediaQuery.sizeOf(context).width;
    var next = _dx + details.delta.dx;
    // 到头/到尾时越拉越紧（阻尼），给出「没有下一页」的反馈。
    final atStart = widget.index <= 0 && next > 0;
    final atEnd = widget.index >= widget.itemCount - 1 && next < 0;
    if (atStart || atEnd) {
      next *= 0.28;
      next = next.clamp(-width * 0.35, width * 0.35);
    }
    if (next != _dx) setState(() => _dx = next);
  }

  void _onEnd(DragEndDetails details) {
    if (_phase != 0) return;
    final width = MediaQuery.sizeOf(context).width;
    final velocity = details.primaryVelocity ?? 0;
    // 位移过 1/3 屏，或快速划动（>420px/s），都判定为翻页。
    final passed = _dx.abs() > width / 3;
    final flick = velocity.abs() > 420;
    var delta = 0;
    if (passed || flick) {
      delta = _dx < 0 || velocity < 0 ? 1 : -1;
      final next = widget.index + delta;
      if (next < 0 || next >= widget.itemCount) delta = 0;
    }
    _startSettle(delta, width);
  }

  void _startSettle(int delta, double width) {
    _settleFrom = _dx;
    // 单内容架构无法让相邻两页同时可见，所以不做「滑出整屏留白」。
    // 翻页时把当前内容顺势推到 38% 屏宽处切页，再把新内容从反向平滑收回，
    // 得到「旧页被推走、新页滑进来」的过场，又不出现大白屏。
    _settleTo = delta == 0
        ? 0.0
        : (delta > 0 ? -width * 0.38 : width * 0.38);
    _pendingDelta = delta;
    _phase = 1;
    if (delta != 0) unawaited(HapticFeedback.selectionClick());
    _settle
      ..duration = Duration(milliseconds: delta == 0 ? 220 : 200)
      ..forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount < 2 ||
        AppScope.formFactorOf(context) == FormFactor.television) {
      return widget.child;
    }
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        _CategoryDragRecognizer:
            GestureRecognizerFactoryWithHandlers<_CategoryDragRecognizer>(
              () => _CategoryDragRecognizer(reservedTop: widget.reservedTop),
              (recognizer) => recognizer
                ..reservedTop = widget.reservedTop
                ..onUpdate = _onUpdate
                ..onEnd = _onEnd
                ..onCancel = () {
                  if (_dx != 0 && _phase == 0) {
                    _startSettle(0, MediaQuery.sizeOf(context).width);
                  }
                },
            ),
      },
      // 跟手期间不做淡出变暗，避免「晃一下」的观感；只有内容真实平移。
      child: AnimatedBuilder(
        animation: _settle,
        child: widget.child,
        builder: (context, content) {
          final dx = _phase == 0
              ? _dx
              : _settleFrom + (_settleTo - _settleFrom) * _settle.value;
          if (dx == 0) return content!;
          return Transform.translate(
            offset: Offset(dx, 0),
            child: content!,
          );
        },
      ),
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
