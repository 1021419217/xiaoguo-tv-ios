import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_device.dart';
import '../../drama_feed.dart';
import '../../explore_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../cover_blur.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../detail/detail_page.dart';
import '../widgets/bar_button.dart';
import '../widgets/category_tabs.dart';
import 'hero_carousel.dart';
import '../widgets/choice_panel.dart';
import '../widgets/drama_grid.dart';
import '../widgets/follow_button.dart';
import '../widgets/frosted_header.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/page_header.dart';
import '../widgets/pull_refresh.dart';
import '../widgets/source_bar.dart';
import '../widgets/swipe_category_layer.dart';
import '../widgets/status_view.dart';
import 'source_actions.dart';
import '../widgets/cover_backdrop.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key, required this.store});
  final LocalStore store;

  @override
  State<ExplorePage> createState() => ExplorePageState();
}

class ExplorePageState extends State<ExplorePage> {
  ExploreFeed? _explore;
  final _scroll = ScrollController();

  /// 真 PageView 每个分类页各自持有滚动/刷新控制器，避免多页共用一个
  /// ScrollController 导致的 "multiple ScrollPositions" 崩溃。
  final _pageScrolls = <String, ScrollController>{};
  final _pageRefreshKeys = <String, GlobalKey<PullRefreshState>>{};

  ScrollController _scrollFor(String tabId) =>
      _pageScrolls.putIfAbsent(tabId, () => ScrollController());
  GlobalKey<PullRefreshState> _refreshKeyFor(String tabId) =>
      _pageRefreshKeys.putIfAbsent(
        tabId,
        () => GlobalKey<PullRefreshState>(),
      );

  final _search = TextEditingController();
  final _tabsKey = GlobalKey<CategoryTabsState<String>>();
  final _refreshKey = GlobalKey<PullRefreshState>();

  /// 手机端顶栏是浮在内容上的磨砂层，需要知道自己多高，才能给内容留出首屏空白。
  final _headerKey = GlobalKey();
  double _headerH = 0;
  double _headerWidth = 0;
  String _shown = '';

  /// 下滑列表时收起顶栏第一行（站源/搜索），只留分类栏可见，
  /// 把这一行的高度让给作品；回到顶部或快速上滑时恢复。
  /// 触发逻辑对齐上游 AppShell._scrolled：下滑即收，上滑需速度达标。
  bool _barsHidden = false;
  static const _revealVelocity = 400.0;
  final _scrollClock = Stopwatch()..start();
  VelocityTracker _scrollVelocity =
      VelocityTracker.withKind(PointerDeviceKind.touch);

  /// 与上游同款滚动判定：到顶恢复、下滑收起、快速上滑恢复。
  /// 用 ScrollNotification 拿到真实 delta 与速度，而非自己算位移差。
  bool _scrolled(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    if (notification is ScrollStartNotification) {
      _scrollVelocity = VelocityTracker.withKind(PointerDeviceKind.touch);
    }
    if (metrics.pixels <= metrics.minScrollExtent) {
      if (_barsHidden) setState(() => _barsHidden = false);
    } else if (notification is ScrollUpdateNotification &&
        !metrics.outOfRange) {
      _scrollVelocity.addPosition(
        _scrollClock.elapsed,
        Offset(0, metrics.pixels),
      );
      final delta = notification.scrollDelta ?? 0;
      if (delta > 0) {
        if (!_barsHidden) setState(() => _barsHidden = true);
      } else if (delta < 0) {
        final velocity =
            _scrollVelocity.getVelocityEstimate()?.pixelsPerSecond.dy ?? 0;
        if (-velocity >= _revealVelocity && _barsHidden) {
          setState(() => _barsHidden = false);
        }
      }
    }
    return false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _explore ??= ExploreFeed(AppScope.of(context).repository, widget.store);
  }

  @override
  void dispose() {
    _explore?.dispose();
    _scroll.dispose();
    for (final controller in _pageScrolls.values) {
      controller.dispose();
    }
    _pageScrolls.clear();
    _pageRefreshKeys.clear();
    _search.dispose();
    super.dispose();
  }

  void _measureHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 下滑时顶栏第一行会收起，这时量到的是矮高度。首屏留白必须按展开态算，
      // 否则回到顶部时内容少让出一行，第一排封面被顶栏压掉一截（且已经在最顶，
      // 上滑也拉不动，看起来像卡住）。
      if (_barsHidden) return;
      final box = _headerKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final height = box.size.height;
      if (height <= 0) return;
      // 展开动画会经过中间值，只往大里记；宽度变了（旋转 / 分屏）就重新量。
      if ((box.size.width - _headerWidth).abs() > 1) {
        _headerWidth = box.size.width;
        setState(() => _headerH = height);
        return;
      }
      if (height > _headerH + 0.5) setState(() => _headerH = height);
    });
  }

  Future<void> refresh() async {
    final explore = _explore;
    if (explore != null) {
      final controller = _scrollFor(explore.tab.id);
      if (controller.hasClients) controller.jumpTo(0);
    } else if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    await explore?.refresh();
  }

  void reselect() {
    final explore = _explore;
    final controller = explore == null ? _scroll : _scrollFor(explore.tab.id);
    if (!controller.hasClients) return;
    if (controller.offset <= 0) {
      final key = explore == null ? _refreshKey : _refreshKeyFor(explore.tab.id);
      unawaited(key.currentState?.show());
      return;
    }
    unawaited(
      controller.animateTo(
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
    final controller = _scrollFor(id);
    if (!controller.hasClients || controller.offset <= 0) return;
    unawaited(
      controller.animateTo(
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
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _tabsKey.currentState?.revealSelected(),
      );
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
    // 换分类 / 换站源等于换了一页，顶栏也要回到展开态：
    // 收起态的矮顶栏会让新页首屏留白少算一行。
    // 注意这里在 build 流程里，直接改字段即可（顶栏在本方法之后才构建），
    // 不能 setState，否则会报 "setState() called during build"。
    _barsHidden = false;
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
                              ? '站源以模块的形式提供，请在 设置 › 模块 安装。'
                              : '请联系管理员安装站源模块。',
                          icon: Icons.extension_off_rounded,
                        )
                      : const StatusView(
                          title: '暂无可用站源',
                          message: '请在 设置 › 模块 中开启站源，或联系管理员开放权限。',
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
      // 分类栏：底边叠一条刷新缓冲进度条（对齐上游 CategoryTabs 同款）。
      // 加载时淡入、完成淡出；颜色继承主题 progressIndicatorTheme
      // （深色纯白 / 浅色主题色），与玻璃界面风格一致，不写死上游的紫色。
      // 绑 anyLoading：切站源会全量重建所有分类 feed、PageView 会预加载相邻页，
      // 这些都算「进入新站源」的加载过程，进度条都要亮（与上游一致）。
      final tabsLoading = explore.anyLoading;
      final tabs = Stack(
        children: [
          Padding(
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
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: ExcludeSemantics(
                excluding: !tabsLoading,
                child: AnimatedOpacity(
                  opacity: tabsLoading ? 1 : 0,
                  duration: Motion.of(context, Motion.medium),
                  curve: Motion.standard,
                  child: TickerMode(
                    enabled: tabsLoading,
                    child: const LinearProgressIndicator(minHeight: 2),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
      // 手机端下滑时把站源/搜索行收起，只留分类栏可见（上游 HideOnScroll
      // 同款观感）；桌面/电视端布局不同，原样保留整行。
      Widget collapsibleBar(Widget bar) {
        if (form != FormFactor.phone) return bar;
        return ClipRect(
          child: AnimatedAlign(
            // 与上游 HideOnScroll 一致：底边对齐，收起时第一行往上退出，
            // 只把分类栏留在顶部。
            alignment: Alignment.bottomCenter,
            heightFactor: _barsHidden ? 0 : 1,
            duration: Motion.of(context, Motion.medium),
            curve: Motion.standard,
            child: bar,
          ),
        );
      }

      final header = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!television)
            collapsibleBar(
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
                        tooltip:
                            blur.mode != CoverBlur.off ? '显示封面' : '模糊封面',
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
        final heroBottom = _hero(explore) == null
            ? 0.0
            : topInset + 12 + 196;
        return Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                // 滚动通知从内层列表冒泡上来，驱动顶栏的收起/恢复。
                child: NotificationListener<ScrollNotification>(
                  onNotification: _scrolled,
                  child: _swipeTabs(
                    explore,
                    form,
                    _content(explore, inset, false, tabs, topInset: topInset),
                    // 提示胶囊落在大海报下方（和追剧页一样贴在列表顶部），
                    // 不再压在海报标题上。
                    hintTop: heroBottom > 0 ? heroBottom + 6 : topInset + 6,
                    heroBottom: heroBottom,
                    buildPage: (feedExplore, tabId) => _content(
                      feedExplore,
                      inset,
                      false,
                      tabs,
                      topInset: topInset,
                      pageTabId: tabId,
                      pageScroll: _scrollFor(tabId),
                      pageRefreshKey: _refreshKeyFor(tabId),
                    ),
                  ),
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
                  hintTop: _hero(explore) == null ? 12 : 16 + 208 + 6,
                  heroBottom: _hero(explore) == null ? 0 : 16 + 208,
                  buildPage: (feedExplore, tabId) => _content(
                    feedExplore,
                    inset,
                    television,
                    tabs,
                    pageTabId: tabId,
                    pageScroll: _scrollFor(tabId),
                    pageRefreshKey: _refreshKeyFor(tabId),
                  ),
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
    double heroBottom = 0,
    // 真 PageView 需要的信息：由调用点传入，用于按 tab 独立构建每一页。
    Widget Function(ExploreFeed explore, String tabId)? buildPage,
  }) {
    final tabs = explore.tabs;
    final index = tabs.indexWhere((tab) => tab.id == explore.tab.id);
    if (!_swipes(form) || index < 0) return child;
    if (buildPage == null) {
      // 兜底：调用点还没迁移到 per-index 构建，走旧的快滑层。
      return SwipeCategoryLayer(
        key: ValueKey(explore.source?.id),
        itemCount: tabs.length,
        index: index,
        labels: [for (final tab in tabs) tab.name],
        onIndexChanged: (i) => explore.select(tabs[i].id),
        hintTop: hintTop,
        child: child,
      );
    }
    // 相邻页可能从未被点开，先确保它们的 feed 已建立、开始加载。
    for (final tab in tabs) {
      explore.ensureFeed(tab.id);
    }
    return SwipeCategoryLayer(
      key: ValueKey(explore.source?.id),
      itemCount: tabs.length,
      index: index,
      labels: [for (final tab in tabs) tab.name],
      onIndexChanged: (i) => explore.select(tabs[i].id),
      hintTop: hintTop,
      itemBuilder: (context, page) {
        final tab = tabs[page];
        return KeyedSubtree(
          key: ValueKey('page-${tab.id}'),
          child: buildPage(explore, tab.id),
        );
      },
    );
  }

  void _toTop() {
    // 回顶后顶栏一定是展开的，先把它恢复，留白才和实际顶栏高度对得上。
    if (_barsHidden) setState(() => _barsHidden = false);
    final explore = _explore;
    if (explore != null) {
      final controller = _scrollFor(explore.tab.id);
      if (controller.hasClients) controller.jumpTo(0);
      return;
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget _content(
    ExploreFeed explore,
    double inset,
    bool television,
    Widget tabs, {
    // 手机端顶栏是浮层时，内容首部留出的空白，避免初始内容被磨砂顶栏压住。
    double topInset = 0,
    // 真 PageView 的某一页：按 tab id 独立取数据、用独立滚动/刷新控制器。
    String? pageTabId,
    ScrollController? pageScroll,
    GlobalKey<PullRefreshState>? pageRefreshKey,
  }) {
    final tabId = pageTabId ?? explore.tab.id;
    final isPage = pageTabId != null;
    final feed = isPage
        ? (explore.feedFor(tabId) ?? explore.feed!)
        : explore.feed!;
    final hero = isPage ? _heroFor(explore, tabId) : _hero(explore);
    final items = isPage ? explore.itemsFor(tabId) : explore.items;
    if (feed.items.isEmpty) {
      final status = FadeSwitcher(child: _status(feed, explore.source));
      return topInset > 0
          ? Padding(
              padding: EdgeInsets.only(top: topInset),
              child: status,
            )
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
      // per-page 覆盖：切到某分类自己的数据/滚动位置/刷新状态。
      pageTabId: isPage ? tabId : null,
      pageScroll: pageScroll,
      pageRefreshKey: pageRefreshKey,
    );
  }

  /// 站点要人机验证时，直接在应用内起一个 WebView 过验证，拿到 cookie 后重试。
  Future<void> _verify(SourceSite? site, DramaFeed feed) async {
    final baseUrl = verifyBaseUrl(site, feed.error);
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (host.isEmpty) {
      _tell('拿不到站点地址，无法验证');
      return;
    }
    final repository = AppScope.of(context).repository;
    final solved = await AppDevice.solveChallenge(baseUrl, host);
    if (!mounted) return;
    if (solved == null) {
      _tell('没有拿到通行 cookie，可以再点一次「去验证」');
      return;
    }
    // 先取出待抓队列：saveChallenge 会清空页缓存和这个队列，必须提前拿。
    final pending = await repository.pendingWebPages();
    final blocked = await repository.blockedUrl(host);
    final urls = [
      ...pending,
      if (blocked.isNotEmpty && !pending.contains(blocked)) blocked,
    ];
    final saved = await repository.saveChallenge(
      host,
      solved.cookie,
      userAgent: solved.userAgent,
    );
    if (!mounted) return;
    if (!saved) _tell('验证结果没能写入，请再试一次');

    // 关键一步：Go 的客户端指纹和真 WebKit 对不上，光有 cookie 重发还是会被拦。
    // 把刚才被挑战的页面 URL 交给那台验证过的 WKWebView，用同一指纹抓回 HTML，
    // 注入 Go 页缓存——模块下次取页命中缓存，就绕开了 TLS 指纹这一关。
    var primed = 0;
    for (final url in urls) {
      final pageHost = Uri.tryParse(url)?.host ?? host;
      final html = await AppDevice.webFetch(url, pageHost);
      if (html == null || html.isEmpty) continue;
      if (await repository.setWebPage(url, html)) primed++;
    }
    if (!mounted) return;
    if (primed > 0) {
      _tell('已载入 $primed 页，正在重试…');
    }
    await feed.reload(force: true);
  }

  void _tell(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1800),
        content: Text(text),
      ),
    );
  }

  Widget _status(DramaFeed feed, SourceSite? site) {
    if (feed.loading) {
      return const StatusView.loading(key: ValueKey('loading'));
    }
    if (feed.error.isNotEmpty) {
      // Cloudflare 这类「站点要求浏览器验证」的错误，纯 HTTP 客户端过不去，
      // 给一个「去验证」入口，比反复点重试有用。
      final needsVerify =
          verifyBaseUrl(site, feed.error).isNotEmpty &&
          needsBrowserVerify(feed.error);
      final message = needsVerify
          ? '${feed.error}\n点「去验证」在应用内完成一次验证，通过后会自动重试。'
          : feed.error;
      final theme = Theme.of(context);
      return StatusView(
        key: const ValueKey('error'),
        title: '暂时无法加载',
        message: message,
        messageChild: RetryCountdown(
          text: message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          onExpired: () => feed.reload(force: true),
        ),
        icon: Icons.cloud_off_rounded,
        action: needsVerify ? '去验证' : '重试',
        onAction: needsVerify
            ? () => unawaited(_verify(site, feed))
            : () => feed.reload(force: true),
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

  Widget _pageBackdrop(Drama drama) {
    final surface = Theme.of(context).colorScheme.surface;
    return IgnorePointer(
      child: CoverBackdrop(
        drama: drama,
        sigma: 48,
        opacity: 0.22,
        overlay: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, 0.45, 1],
          colors: [
            surface.withValues(alpha: 0.72),
            surface.withValues(alpha: 0.92),
            surface,
          ],
        ),
      ),
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
    double topInset, {
    String? pageTabId,
    ScrollController? pageScroll,
    GlobalKey<PullRefreshState>? pageRefreshKey,
  }) {
    final scroll = pageScroll ?? _scroll;
    final refreshKey = pageRefreshKey ?? _refreshKey;
    final ranks = pageTabId == null ? null : explore.ranksFor(pageTabId);
    int? rankOf(Drama drama) =>
        ranks == null ? explore.rankOf(drama) : ranks[drama.id];
    final showScore = pageTabId == null
        ? !explore.recommending
        : !explore.recommendingFor(pageTabId);
    final heroSection = hero == null
        ? const SizedBox(key: ValueKey('none'), width: double.infinity)
        : Padding(
            key: hero.key,
            padding: EdgeInsets.fromLTRB(inset, phone ? 12 : 16, inset, 0),
            child: hero,
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scrollView = CustomScrollView(
          controller: scroll,
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
                      key: ValueKey(pageTabId ?? explore.tab.id),
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
                rankOf: rankOf,
                autofocus:
                    television && hero == null && ShellForeground.of(context),
                heroScope: 'drama',
                showScore: showScore,
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
              sliver: SliverToBoxAdapter(
                child: FeedFooter(
                  feed: feed,
                  onVerify: verifyBaseUrl(explore.source, feed.error).isEmpty
                      ? null
                      : () => unawaited(_verify(explore.source, feed)),
                ),
              ),
            ),
          ],
        );
        return Stack(
          children: [
            if (!television && items.isNotEmpty)
              Positioned.fill(child: _pageBackdrop(items.first)),
            AutoLoadMore(
              feed: feed,
              child: television
                  ? scrollView
                  : PullRefresh(
                      key: refreshKey,
                      // 圈从顶栏下沿弹出。不偏移的话它从 y=0 开始，
                      // 整段生命周期都在磨砂顶栏背后，等于看不见。
                      edgeOffset: topInset,
                      onRefresh: explore.refresh,
                      child: scrollView,
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

  /// 首页顶部大海报：当前分类最靠前、带封面的几部剧。
  /// 观看记录仍然只从「追剧 → 最近观看」进入，海报只展示公开内容，
  /// 别人拿到手机看不到观看痕迹。
  Widget? _hero(ExploreFeed explore) => _heroFor(explore, explore.tab.id);

  /// 指定 tab 的海报：真 PageView 每页独立构建，每个分类页都显示轮播大海报
  /// （对齐 2.6.3 基线观感），只有电视端保持纯网格。
  Widget? _heroFor(ExploreFeed explore, String tabId) {
    final form = AppScope.formFactorOf(context);
    // 电视靠遥控器方向键，轮播翻页反而碍事，保持原来的纯网格。
    if (form == FormFactor.television) return null;
    // 恢复 2.6.3 基线观感：每个分类页都显示轮播大海报，不再用
    // featuredFor 的「仅推荐页且无续看」门槛卡住（有观看记录就没海报）。
    // 海报与网格共用 itemsFor 同一批数据，和基线行为完全一致。
    final items = <Drama>[];
    for (final drama in explore.itemsFor(tabId)) {
      if (drama.cover.isEmpty) continue;
      items.add(drama);
      if (items.length == 5) break;
    }
    if (items.isEmpty) return null;
    return HeroCarousel(
      key: ValueKey('hero-$tabId'),
      items: items,
      onOpen: _open,
      height: form == FormFactor.phone ? 196 : 208,
    );
  }
}
