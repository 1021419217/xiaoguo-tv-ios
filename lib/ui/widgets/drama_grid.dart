import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cover_shape.dart';
import '../../drama_feed.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../theme/motion.dart';
import 'drama_tile.dart';
import 'focus_ring.dart';
import 'motion/motion_widgets.dart';

(int, double, double) _gridLayout(
  BuildContext context,
  double width, {
  bool wide = false,
}) => switch (AppScope.formFactorOf(context)) {
  FormFactor.phone =>
    wide ? (2, 12.0, 20.0) : (3, 10.0, 22.0),
  FormFactor.television => (
    ((width + 20) / (wide ? 200 : 120)).floor().clamp(3, 8),
    20.0,
    24.0,
  ),
  FormFactor.window => (
    math.max(2, ((width + 18) / (wide ? 300 : 178)).floor()),
    18.0,
    24.0,
  ),
  FormFactor.pad => (
    (width / (wide ? 280 : 180)).floor().clamp(3, 9),
    18.0,
    22.0,
  ),
};

double dramaTileWidth(
  BuildContext context,
  double width, {
  bool wide = false,
}) {
  final (columns, spacing, _) = _gridLayout(context, width, wide: wide);
  return (width - (columns - 1) * spacing) / columns;
}

/// 横竖混排源在手机竖屏固定两列瀑布流；其它形态仍按屏宽算列数。
bool usePosterMasonry(BuildContext context, String source) =>
    AppScope.formFactorOf(context) == FormFactor.phone &&
    CoverShapes.isMixed(source);

/// 单张封面的排版比例：已知实际宽高比就用它（格子跟着图片走，不裁切），
/// 未知时按竖版兜底；下载完成前封面组件读到真实比例会再纠正。
double posterAspect(String source, String dramaId) {
  final ratio = CoverShapes.ratioOf(source, dramaId);
  if (ratio <= 0) return 2 / 3;
  return ratio;
}

/// 两列瀑布流：每格按自身高度落进较短的一栏，和「发现」页同一套排法。
class PosterMasonry extends StatelessWidget {
  const PosterMasonry({
    super.key,
    required this.width,
    required this.count,
    required this.heightAt,
    required this.itemBuilder,
    this.spacing = 10,
    this.padding = EdgeInsets.zero,
  });

  final double width;
  final int count;

  /// 预估格子高度，只用于决定落进哪一栏。
  final double Function(int index, double tileWidth) heightAt;
  final Widget Function(BuildContext context, int index, double tileWidth)
  itemBuilder;
  final double spacing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final tileWidth = (width - padding.horizontal - spacing) / 2;
    final left = <Widget>[];
    final right = <Widget>[];
    var leftHeight = 0.0;
    var rightHeight = 0.0;
    for (var index = 0; index < count; index++) {
      final cell = Padding(
        padding: EdgeInsets.only(bottom: spacing),
        child: itemBuilder(context, index, tileWidth),
      );
      final height = heightAt(index, tileWidth) + spacing;
      if (leftHeight <= rightHeight) {
        left.add(cell);
        leftHeight += height;
      } else {
        right.add(cell);
        rightHeight += height;
      }
    }
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: tileWidth, child: Column(children: left)),
          SizedBox(width: spacing),
          SizedBox(width: tileWidth, child: Column(children: right)),
        ],
      ),
    );
  }
}

SliverGridDelegate dramaGridDelegate(
  BuildContext context,
  double width, {
  bool wide = false,
}) {
  final (columns, spacing, runSpacing) = _gridLayout(
    context,
    width,
    wide: wide,
  );
  final tile = dramaTileWidth(context, width, wide: wide);
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    crossAxisSpacing: spacing,
    mainAxisSpacing: runSpacing,
    mainAxisExtent: DramaTile.extentFor(context, tile, wide: wide),
  );
}

KeyEventResult wrapGridRow(int index, int columns, int count, KeyEvent event) {
  if (event is KeyUpEvent) return KeyEventResult.ignored;
  final primary = FocusManager.instance.primaryFocus;
  final last = count - 1;
  switch (event.logicalKey) {
    case LogicalKeyboardKey.arrowRight
        when index % columns == columns - 1 || index == last:
      if (index < last) primary?.nextFocus();
      return KeyEventResult.handled;
    case LogicalKeyboardKey.arrowLeft when index % columns == 0 && index > 0:
      primary?.previousFocus();
      return KeyEventResult.handled;
    default:
      return KeyEventResult.ignored;
  }
}

Map<String, int> firstIndexById<T>(List<T> items, String Function(T) idOf) {
  final first = <String, int>{};
  for (final (index, item) in items.indexed) {
    first.putIfAbsent(idOf(item), () => index);
  }
  return first;
}

class DramaSliverGrid extends StatelessWidget {
  const DramaSliverGrid({
    super.key,
    required this.width,
    required this.items,
    required this.onOpen,
    this.onMore,
    this.rankOf,
    this.autofocus = false,
    this.entered,
    this.heroScope,
    this.showScore = false,
    this.exploreBlur = false,
  });
  final bool exploreBlur;
  final double width;
  final List<Drama> items;
  final ValueChanged<Drama> onOpen;
  final ValueChanged<Drama>? onMore;
  final int? Function(Drama drama)? rankOf;
  final bool autofocus;
  final Set<Object>? entered;
  final String? heroScope;
  final bool showScore;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: CoverShapes.revision,
    builder: (context, _, _) => _layout(context),
  );

  Widget _layout(BuildContext context) {
    final source = items.isEmpty ? '' : items.first.source;
    if (AppScope.formFactorOf(context) == FormFactor.phone &&
        CoverShapes.isMixed(source)) {
      return _masonry(context);
    }
    return _grid(context);
  }

  Widget _grid(BuildContext context) {
    final wide = items.isNotEmpty && CoverShapes.isLandscape(items.first.source);
    final (columns, _, _) = _gridLayout(context, width, wide: wide);
    final heroIndex = heroScope == null
        ? const <String, int>{}
        : firstIndexById(items, (drama) => drama.id);
    return SliverGrid.builder(
      gridDelegate: dramaGridDelegate(context, width, wide: wide),
      itemCount: items.length,
      itemBuilder: (context, index) => _cell(
        context,
        index,
        aspect: wide ? 16 / 9 : 2 / 3,
        columns: columns,
        heroIndex: heroIndex,
      ),
    );
  }

  Widget _masonry(BuildContext context) {
    const spacing = 10.0;
    final tileWidth = (width - 20 - spacing) / 2;
    final heroIndex = heroScope == null
        ? const <String, int>{}
        : firstIndexById(items, (drama) => drama.id);
    final left = <Widget>[];
    final right = <Widget>[];
    var leftHeight = 0.0;
    var rightHeight = 0.0;
    for (var index = 0; index < items.length; index++) {
      final drama = items[index];
      final ratio = CoverShapes.ratioOf(drama.id);
      final aspect = ratio > 0 ? ratio : 2 / 3;
      final cell = Padding(
        padding: const EdgeInsets.only(bottom: spacing),
        child: _cell(
          context,
          index,
          aspect: aspect,
          columns: 2,
          heroIndex: heroIndex,
        ),
      );
      final estimate = DramaTile.extentFor(
        context,
        tileWidth,
        wide: aspect > 1.25,
      );
      if (leftHeight <= rightHeight) {
        left.add(cell);
        leftHeight += estimate + spacing;
      } else {
        right.add(cell);
        rightHeight += estimate + spacing;
      }
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: tileWidth, child: Column(children: left)),
            const SizedBox(width: spacing),
            SizedBox(width: tileWidth, child: Column(children: right)),
          ],
        ),
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    int index, {
    required double aspect,
    required int columns,
    required Map<String, int> heroIndex,
    bool adaptive = false,
  }) {
    final drama = items[index];
    final tile = Focus(
      key: ValueKey(drama.id),
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) =>
          wrapGridRow(index, columns, items.length, event),
      child: DramaTile(
        drama: drama,
        aspect: aspect,
        adaptiveAspect: adaptive,
        wide: aspect > 1.25,
        rank: rankOf?.call(drama),
        autofocus: autofocus && index == 0,
        heroScope: heroIndex[drama.id] == index ? heroScope : null,
        showScore: showScore,
        exploreBlur: exploreBlur,
        onTap: () => onOpen(drama),
        onMore: onMore == null ? null : () => onMore!(drama),
      ),
    );
    final played = entered;
    if (played == null) return tile;
    return EnterOnce(
      key: ValueKey(drama.id),
      id: drama.id,
      played: played,
      index: index,
      child: tile,
    );
  }
}

class AutoLoadMore extends StatefulWidget {
  const AutoLoadMore({super.key, required this.feed, required this.child});
  final DramaFeed feed;
  final Widget child;

  @override
  State<AutoLoadMore> createState() => _AutoLoadMoreState();
}

class _AutoLoadMoreState extends State<AutoLoadMore> {
  BuildContext? _scrollable;

  @override
  void initState() {
    super.initState();
    widget.feed.addListener(_feedChanged);
  }

  @override
  void didUpdateWidget(covariant AutoLoadMore oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feed == widget.feed) return;
    oldWidget.feed.removeListener(_feedChanged);
    widget.feed.addListener(_feedChanged);
  }

  @override
  void dispose() {
    widget.feed.removeListener(_feedChanged);
    super.dispose();
  }

  void _feedChanged() {
    if (!widget.feed.canLoadMore) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scrollable = _scrollable;
      if (!mounted || scrollable == null || !scrollable.mounted) return;
      final state = scrollable.findAncestorStateOfType<ScrollableState>();
      if (state?.position case final position?
          when position.hasContentDimensions) {
        _check(position, 0, scrollable);
      }
    });
  }

  bool _check(ScrollMetrics metrics, int depth, BuildContext? context) {
    if (depth != 0 || metrics.axis != Axis.vertical) return false;
    _scrollable = context;
    final feed = widget.feed;
    if (metrics.extentAfter < 600 && feed.canLoadMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) => feed.loadMore());
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) => _check(
          notification.metrics,
          notification.depth,
          notification.context,
        ),
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) => _check(
            notification.metrics,
            notification.depth,
            notification.context,
          ),
          child: widget.child,
        ),
      );
}

class FeedFooter extends StatelessWidget {
  const FeedFooter({super.key, required this.feed, this.onVerify});
  final DramaFeed feed;

  /// 分页失败且属于「站点要求浏览器验证」时，用这个入口替代「重试」。
  final VoidCallback? onVerify;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final needsVerify = onVerify != null && feed.error.contains('浏览器验证');
    return SizedBox(
      height: 72,
      child: FadeSwitcher(
        duration: Motion.short,
        child: KeyedSubtree(
          key: ValueKey(
            feed.loadingMore
                ? 0
                : feed.error.isNotEmpty
                ? 1
                : feed.hasMore
                ? 2
                : 3,
          ),
          child: Center(
            child: feed.loadingMore
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : feed.error.isNotEmpty
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          feed.error,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: caption,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FocusRing(
                        radius: 999,
                        child: TextButton(
                          onPressed: needsVerify
                              ? onVerify
                              : feed.hasMore
                              ? feed.loadMore
                              : () => feed.reload(force: true),
                          child: Text(needsVerify ? '去验证' : '重试'),
                        ),
                      ),
                    ],
                  )
                : feed.hasMore
                ? null
                : Text('已经到底了', style: caption),
          ),
        ),
      ),
    );
  }
}
