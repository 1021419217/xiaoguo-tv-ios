import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';

/// 与首页同款的「左右快滑切换分类」层。
///
/// 只把**内容区**包进来（顶栏、搜索框、分类胶囊留在外面），传分类数量 /
/// 当前序号，快滑时回调目标序号：拖动时内容带阻尼轻微跟手，
/// 松手后由切换动画把这一点位移平滑收回，同时新内容淡入。
/// 切换时不再浮出分类名提示胶囊（按用户要求去掉，避免多余弹窗）。
///
/// 这里刻意不做「整页侧滑 + 整体变暗」：那种做法在列表页会让标题、搜索
/// 框一起抖，而且淡到 0.55 再回来会闪一下。位移只在手指拖出的那一点上
/// 收敛，透明度最低只到 0.72，切换看起来是内容轻轻一沉而不是整页晃动。
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

  /// 提示胶囊距内容区顶部的距离（全剧TV 同款：贴在磨砂顶栏下方）。
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
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1.0,
  );
  double _dragX = 0;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _switch(int delta) {
    if (widget.itemCount < 2) return;
    final next = widget.index + delta;
    if (next < 0 || next >= widget.itemCount) return;
    // 快滑切分类成功时给一次轻震动；到头(越界)直接返回不震，
    // 让用户能从「有没有震」区分是否滑到了最后一个分类。
    unawaited(HapticFeedback.selectionClick());
    _anim.forward(from: 0);
    widget.onIndexChanged(next);
    setState(() {
      // 位移交还给动画，手指拖出的那一点直接归零，不会残留偏移。
      _dragX = 0;
    });
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
                ..onUpdate = (details) {
                  // 只跟手 0.08，最多 10dp：越像「拖页面」越容易和列表横滑打架。
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
      child: Stack(
        // 快滑切分类不再浮出分类名提示胶囊：用户反馈切换时弹出的提示
        // 多余、碍眼，这里只保留跟手位移 + 淡入的切换动效与轻震动。
        child: AnimatedBuilder(
          animation: _anim,
          child: widget.child,
          builder: (context, content) {
            final t = Curves.easeOutCubic.transform(_anim.value);
            // 位移从「手指松手时的那一点」线性收敛到 0，不额外跳一段，
            // 所以看不到整页被扯动；淡入从 0.72 起，切换不闪黑。
            final slide = _dragX * t * 0.6;
            return Transform.translate(
              offset: Offset(slide, 0),
              child: Opacity(opacity: 0.72 + 0.28 * t, child: content),
            );
          },
        ),
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
