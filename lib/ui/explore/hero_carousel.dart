import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../cover_shape.dart';
import '../../models.dart';
import '../widgets/cover_image.dart';

/// 首页顶部的「大海报」：把当前分类最靠前的几部剧做成可横滑的轮播。
///
/// 版式照 iDuanJu 的 PosterHero 来：整卡铺一层模糊封面做底、向页面底色压暗，
/// 前景是竖版封面 + 标题 + 标签 + 查看详情，右下角页码点，6 秒自动翻页。
/// 卡片内的横滑由 PageView 自己吃下（翻封面），外层的分类横滑用
/// `reservedTop` 把这一块让出来，两者互不抢手势。
class HeroCarousel extends StatefulWidget {
  const HeroCarousel({
    super.key,
    required this.items,
    required this.onOpen,
    this.height = 196,
  });

  final List<Drama> items;
  final ValueChanged<Drama> onOpen;
  final double height;

  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<HeroCarousel> {
  final _pages = PageController();
  Timer? _auto;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _restartAuto();
  }

  @override
  void didUpdateWidget(HeroCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.items.isEmpty ? '' : oldWidget.items.first.id;
    final after = widget.items.isEmpty ? '' : widget.items.first.id;
    if (before == after) return;
    _index = 0;
    if (_pages.hasClients) _pages.jumpToPage(0);
    _restartAuto();
  }

  @override
  void dispose() {
    _auto?.cancel();
    _pages.dispose();
    super.dispose();
  }

  /// 每次翻页都把计时重置，手动滑过之后仍有完整 6 秒。
  void _restartAuto() {
    _auto?.cancel();
    if (widget.items.length < 2) return;
    _auto = Timer(const Duration(seconds: 6), () {
      if (!mounted || !_pages.hasClients) return;
      final next = (_index + 1) % widget.items.length;
      unawaited(
        _pages.animateToPage(
          next,
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeInOutCubic,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    final item = items[_index.clamp(0, items.length - 1)];
    return ValueListenableBuilder<int>(
      valueListenable: CoverShapes.revision,
      builder: (context, _, _) => SizedBox(
        height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 420),
              child: KeyedSubtree(
                key: ValueKey(item.id),
                child: _backdrop(item),
              ),
            ),
            // 点开详情用 GestureDetector 包住 PageView：横向拖交给 PageView
            // 翻封面，轻点才是打开。以前上面盖一层 InkWell，把横滑全吃掉了。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onOpen(item),
              child: PageView.builder(
                controller: _pages,
                itemCount: items.length,
                onPageChanged: (index) {
                  setState(() => _index = index);
                  _restartAuto();
                },
                itemBuilder: (context, index) => _slide(items[index]),
              ),
            ),
            if (items.length > 1)
              Positioned(
                right: 14,
                bottom: 12,
                child: IgnorePointer(child: _dots(items.length)),
              ),
          ],
        ),
      ),
      ),
    );
  }

  Size _coverSize(Drama item) {
    final measured = CoverShapes.ratioOf(item.source, item.id);
    final wide =
        measured > 1.1 ||
        (measured <= 0 && CoverShapes.isLandscape(item.source));
    if (wide) return const Size(156, 88);
    final ratio = measured > 0 ? measured.clamp(0.45, 1.1) : 2 / 3;
    const height = 164.0;
    return Size((height * ratio).clamp(78, 132), height);
  }

  Widget _backdrop(Drama item) => Stack(
    fit: StackFit.expand,
    children: [
      if (item.cover.isEmpty)
        const ColoredBox(color: Color(0xFF1A1A1C))
      else
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 34, sigmaY: 34),
          child: Transform.scale(
            scale: 1.3,
            child: Opacity(
              opacity: .72,
              child: DramaCover(
                drama: item,
                radius: 0,
                details: false,
                crop: true,
              ),
            ),
          ),
        ),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0x33000000), Color(0xCC000000)],
          ),
        ),
      ),
    ],
  );

  Widget _slide(Drama item) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _coverSize(item).width,
          height: _coverSize(item).height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: DramaCover(
              drama: item,
              radius: 12,
              details: false,
              crop: true,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _eyebrow(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFFFC98A),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .6,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  height: 1.24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (item.description.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  item.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .72),
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
              const Spacer(),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final tag in _chips(item))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        tag,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );

  String _eyebrow(Drama item) {
    if (item.badge.isNotEmpty) return item.badge;
    if (item.episodes > 0) return '共 ${item.episodes} 集';
    return '热门推荐';
  }

  List<String> _chips(Drama item) {
    final chips = <String>[];
    if (item.score.isNotEmpty) chips.add('评分 ${item.score}');
    if (item.category.isNotEmpty) chips.add(item.category);
    for (final tag in item.tags) {
      if (chips.length >= 3) break;
      if (tag.isNotEmpty && !chips.contains(tag)) chips.add(tag);
    }
    if (chips.isEmpty && item.views.isNotEmpty) chips.add('${item.views} 次观看');
    return chips.take(3).toList();
  }

  Widget _dots(int count) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 4,
    children: [
      for (var index = 0; index < count; index++)
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          width: index == _index ? 14 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: index == _index
                ? Colors.white
                : Colors.white.withValues(alpha: .42),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
    ],
  );
}
