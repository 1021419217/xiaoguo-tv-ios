import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../drama_feed.dart';
import '../../explore_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../cover_blur.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../detail/detail_page.dart';
import '../history/history_page.dart';
import '../widgets/bar_button.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/drama_grid.dart';
import '../widgets/follow_button.dart';
import '../widgets/frosted_header.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/page_header.dart';
import '../widgets/source_bar.dart';
import '../widgets/swipe_category_layer.dart';
import '../widgets/status_view.dart';
import 'source_actions.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key, required this.store});
  final LocalStore store;

  @override
  State<ExplorePage> createState() => ExplorePageState();
}

class ExplorePageState extends State<ExplorePage> {
  ExploreFeed? _explore;
  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _tabsKey = GlobalKey();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();

  /// 手机端顶栏是浮在内容上的磨砂层，需要知道自己多高，才能给内容留出首屏空白。
  final _headerKey = GlobalKey();
  double _headerH = 0;
  String _shown = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _explore ??= ExploreFeed(AppScope.of(context).repository, widget.store);
  }

  @override
  void dispose() {
    _explore?.dispose();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }


  void _measureHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _headerKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final height = box.size.height;
      if ((height - _headerH).abs() < 0.5) return;
      setState(() => _headerH = height);
    });
  }

  Future<void> refresh() async {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _explore?.refresh();
  }

  void reselect() {
    if (!_scroll.hasClients) return;
    if (_scroll.offset <= 0) {
      unawaited(_refreshKey.currentState?.show());
      return;
    }
    unawaited(
      _scroll.animateTo(
        0,
        duration: Motion.of(context, Motion.long),
        curve: Motion.enter,
      ),
    );
  }

  void _selectTab(String id) {
    if (id != _explore!.tab.id) {
      unawaited(HapticFeedback.selectionClick());
      _explore!.select(id);
      return;
    }
    if (!_scroll.hasClients || _scroll.offset <= 0) return;
    unawaited(
      _scroll.animateTo(
        0,
        duration: Motion.of(context, Motion.long),
        curve: Motion.enter,
      ),
    );
  }

  void _open(Drama drama, {bool autoplay = false}) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama, autoplay: autoplay),
  );

  Future<void> _pickCategory(BuildContext anchor) async {
    final explore = _explore!;
    final value = await showChoicePanel<String>(
      context: anchor,
      title: '全部分类',
      options: [for (final tab in explore.tabs) ChoiceOption(tab.id, tab.name)],
      selected: explore.tab.id,
      grid: ChoiceGrid.categories,
    );
    if (value != null) {
      unawaited(HapticFeedback.selectionClick());
      explore.select(value);
    }
  }

  void _searchSubmitted(SourceSite source, String query) {
    if (query.trim().isEmpty) return;
    _search.clear();
    openSearch(context, widget.store, source, query: query);
  }

  void _resetScroll(ExploreFeed explore, {required bool deferred}) {
    final source = '${explore.source?.id}|';
    final shown = '$source${explore.tab.id}';
    if (shown == _shown) return;
    final switched = _shown.startsWith(source);
    _shown = shown;
    if (deferred && switched) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _toTop());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_explore!, widget.store]),
    builder: (context, _) {
      final explore = _explore!;
      final source = explore.source;
      final form = AppScope.formFactorOf(context);
      final television = form == FormFactor.television;
      final desktop = form == FormFactor.window;
      _resetScroll(explore, deferred: _swipes(form));
      if (source == null) {
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                if (!television) const PageHeader(title: '发现'),
                Expanded(
                  child: SourceSite.values.isEmpty
                      ? StatusView(
                          title: '还没有安装站源',
                          message: widget.store.profile.admin
                              ? '站源以模块的形式提供，请在「模块」页安装。'
                              : '请联系管理员安装站源模块。',
                          icon: Icons.extension_off_rounded,
                        )
                      : const StatusView(
                          title: '暂无可用站源',
                          message: '请在站源管理中开启站源，或联系管理员开放权限。',
                          icon: Icons.public_off_rounded,
                        ),
                ),
              ],
            ),
          ),
        );
      }
      final inset = switch (form) {
        FormFactor.phone => 16.0,
        FormFactor.pad || FormFactor.window => 24.0,
        FormFactor.television => televisionInset,
      };
      final tabs = Padding(
        padding: EdgeInsets.symmetric(
          horizontal: form == FormFactor.phone ? 0 : inset,
        ),
        child: CategoryTabs<String>(
          key: _tabsKey,
          options: [
            for (final tab in explore.tabs) ChoiceOption(tab.id, tab.name),
          ],
          selected: explore.tab.id,
          onSelected: _selectTab,
          onShowAll: _pickCategory,
        ),
      );
      final header = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!television)
            SourceBar(
              source: source.name,
              searchController: _search,
              onSwitchSource: (anchor) => pickSource(anchor, widget.store),
              onOpenSearch: () => openSearch(context, widget.store, source),
              onSearchSubmitted: (query) => _searchSubmitted(source, query),
              leading: [
                if (widget.store.blurCoversButton)
                  if (CoverBlurScope.of(context) case final blur?)
                    BarButton(
                      icon: blur.mode != CoverBlur.off
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      tooltip: blur.mode != CoverBlur.off ? '显示封面' : '模糊封面',
                      onPressed: blur.onToggle,
                    ),
              ],
              actions: [
                if (desktop)
                  BarButton(
                    icon: Icons.refresh_rounded,
                    tooltip: '刷新',
                    onPressed: explore.refresh,
                  ),
              ],
            ),
          if (!television || explore.feed!.items.isEmpty) tabs,
        ],
      );
      // 手机端：顶栏浮在内容之上做磨砂，内容延伸到屏幕顶（含状态栏），
      // 初始用留白让开顶栏，滚动后卡片从顶栏背后经过并被模糊透出，
      // 与底栏导航的「内容透过模糊」完全同一套逻辑。
      if (form == FormFactor.phone) {
        final topPad = MediaQuery.paddingOf(context).top;
        final topInset = _headerH > 0 ? _headerH : topPad + 112;
        _measureHeader();
        return Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: _swipeTabs(
                  explore,
                  form,
                  _content(explore, inset, false, tabs, topInset: topInset),
                  hintTop: topInset + 4,
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: FrostedHeader(
                  key: _headerKey,
                  child: SafeArea(bottom: false, child: header),
                ),
              ),
            ],
          ),
        );
      }
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 顶栏整体铺一层磨砂玻璃；电视端保留原本的实心顶栏。
              if (television) header else FrostedHeader(child: header),
              Expanded(
                child: _swipeTabs(
                  explore,
                  form,
                  _content(explore, inset, television, tabs),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  bool _swipes(FormFactor form) =>
      form == FormFactor.phone || form == FormFactor.pad;

  Widget _swipeTabs(
    ExploreFeed explore,
    FormFactor form,
    Widget child, {
    double hintTop = 12,
  }) {
    final tabs = explore.tabs;
    final index = tabs.indexWhere((tab) => tab.id == explore.tab.id);
    if (!_swipes(form) || index < 0) return child;
    return SwipeCategoryLayer(
      key: ValueKey(explore.source?.id),
      itemCount: tabs.length,
      index: index,
      labels: [for (final tab in tabs) tab.name],
      onIndexChanged: (index) => explore.select(tabs[index].id),
      hintTop: hintTop,
      child: child,
    );
  }

  void _toTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget _content(
    ExploreFeed explore,
    double inset,
    bool television,
    Widget tabs, {
    // 手机端顶栏是浮层时，内容首部留出的空白，避免初始内容被磨砂顶栏压住。
    double topInset = 0,
  }) {
    final feed = explore.feed!;
    final hero = _hero(explore);
    final items = explore.items;
    if (feed.items.isEmpty) {
      final status = FadeSwitcher(child: _status(feed));
      return topInset > 0
          ? Padding(padding: EdgeInsets.only(top: topInset), child: status)
          : status;
    }
    final phone = AppScope.formFactorOf(context) == FormFactor.phone;
    final desktop = AppScope.formFactorOf(context) == FormFactor.window;
    return _grid(
      explore,
      feed,
      hero,
      items,
      inset,
      television,
      tabs,
      phone,
      desktop,
      topInset,
    );
  }

  Widget _status(DramaFeed feed) {
    if (feed.loading) {
      return const StatusView.loading(key: ValueKey('loading'));
    }
    if (feed.error.isNotEmpty) {
      return StatusView(
        key: const ValueKey('error'),
        title: '暂时无法加载',
        message: feed.error,
        icon: Icons.cloud_off_rounded,
        action: '重试',
        onAction: () => feed.reload(force: true),
      );
    }
    return StatusView(
      key: const ValueKey('empty'),
      title: '这里还没有剧',
      message: '换一个分类看看',
      icon: Icons.inbox_outlined,
      action: '刷新',
      onAction: () => feed.reload(force: true),
    );
  }

  Widget _grid(
    ExploreFeed explore,
    DramaFeed feed,
    Widget? hero,
    List<Drama> items,
    double inset,
    bool television,
    Widget tabs,
    bool phone,
    bool desktop,
    double topInset,
  ) {
    final heroSection = hero == null
        ? const SizedBox(key: ValueKey('none'), width: double.infinity)
        : Padding(
            key: hero.key,
            padding: EdgeInsets.fromLTRB(inset, phone ? 12 : 16, inset, 0),
            child: hero,
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scroll = CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // 顶栏留白：随内容一起滚动，滚动后卡片进入顶栏背后被模糊透出。
            if (topInset > 0)
              SliverToBoxAdapter(child: SizedBox(height: topInset)),
            if (television)
              SliverPadding(
                padding: const EdgeInsets.only(top: 8),
                sliver: SliverToBoxAdapter(child: tabs),
              ),
            SliverToBoxAdapter(
              child: television
                  ? heroSection
                  : AnimatedSize(
                      key: ValueKey(explore.tab.id),
                      duration: Motion.of(context, Motion.long),
                      curve: Motion.enter,
                      alignment: Alignment.topCenter,
                      clipBehavior: Clip.none,
                      child: FadeSwitcher(
                        alignment: Alignment.topCenter,
                        child: heroSection,
                      ),
                    ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, desktop ? 20 : 16, inset, 0),
              sliver: DramaSliverGrid(
                width: constraints.maxWidth - inset * 2,
                items: items,
                rankOf: explore.rankOf,
                autofocus:
                    television && hero == null && ShellForeground.of(context),
                heroScope: 'drama',
                showScore: !explore.recommending,
                exploreBlur: true,
                onOpen: _open,
                onMore: (drama) => quickFollow(context, widget.store, drama),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                8,
                inset,
                // 底部留出悬浮胶囊导航的空间。
                television ? 27 : (phone ? 100 : 16),
              ),
              sliver: SliverToBoxAdapter(child: FeedFooter(feed: feed)),
            ),
          ],
        );
        return Stack(
          children: [
            AutoLoadMore(
              feed: feed,
              child: television
                  ? scroll
                  : RefreshIndicator(
                      key: _refreshKey,
                      onRefresh: explore.refresh,
                      child: scroll,
                    ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  excluding: !feed.loading,
                  child: AnimatedOpacity(
                    opacity: feed.loading ? 1 : 0,
                    duration: Motion.of(context, Motion.medium),
                    curve: Motion.standard,
                    child: TickerMode(
                      enabled: feed.loading,
                      child: const LinearProgressIndicator(minHeight: 2),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 「继续观看 / 今日推荐」不再首屏铺大封面，只留一条轻量入口，
  /// 点进去（二级详情页）才显示大封面和内容。
  /// 「最近观看」在首页只留一个不含任何内容的入口，不显示剧名、集数与封面，
  /// 避免别人拿到手机就能看出在看什么；点进去（历史页）才展示具体内容。
  Widget? _hero(ExploreFeed explore) {
    if (explore.resume != null) {
      return _ResumeBar(
        key: const ValueKey('resume-entry'),
        title: '最近观看',
        meta: '',
        onTap: () => openPage<void>(
          context,
          (_) => HistoryPage(store: widget.store),
        ),
      );
    }
    if (explore.featured case final drama?) {
      return _ResumeBar(
        key: ValueKey(('featured', drama.id)),
        title: '今日推荐 · ${drama.title}',
        meta: [
          if (drama.category.isNotEmpty) drama.category,
          if (drama.episodes > 0) '共 ${drama.episodes} 集',
        ].join(' · '),
        onTap: () => _open(drama),
        onPlay: () => _open(drama, autoplay: true),
      );
    }
    return null;
  }
}

/// 轻量入口条：不展示任何封面与剧集信息，点整条进二级页查看内容。
class _ResumeBar extends StatelessWidget {
  const _ResumeBar({
    super.key,
    required this.title,
    required this.meta,
    required this.onTap,
    this.onPlay,
  });

  final String title;
  final String meta;
  final VoidCallback onTap;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      shape: StadiumBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (onPlay case final play?)
                SizedBox(
                  width: 34,
                  height: 34,
                  child: IconButton(
                    onPressed: play,
                    padding: EdgeInsets.zero,
                    icon: const Icon(
                      Icons.play_circle_fill_rounded,
                      size: 28,
                      color: Colors.white,
                    ),
                    tooltip: '播放',
                  ),
                )
              else
                Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
