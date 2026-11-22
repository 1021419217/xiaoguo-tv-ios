import 'dart:async';
import 'dart:math' as math;

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
  final _search = TextEditingController();
  final _tabsKey = GlobalKey<CategoryTabsState<String>>();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();

  /// 手机端顶栏是浮在内容上的磨砂层，需要知道自己多高，才能给内容留出首屏空白。
  final _headerKey = GlobalKey();
  double _headerH = 0;
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
  }) {
    final tabs = explore.tabs;
    final index = tabs.indexWhere((tab) => tab.id == explore.tab.id);
    if (!_swipes(form) || index < 0) return child;
    return SwipeCategoryLayer(
      key: ValueKey(explore.source?.id),
      itemCount: tabs.length,
      index: index,
      labels: [for (final tab in tabs) tab.name],
      // 与上游 SwipeSwitch 调用点一致：新分类数据没到位时先 hold 住旧页，
      // 等加载完成再播切换动画，避免翻过去是一片 loading/空页。
      ready: switch (explore.feed) {
        final feed? => feed.items.isNotEmpty || !feed.loading,
        null => true,
      },
      onEnter: _toTop,
      onIndexChanged: (index) => explore.select(tabs[index].id),
      hintTop: hintTop,
      // 海报那一段的按下留给海报自己翻页；列表滚过去之后这段自动收窄。
      reservedTop: heroBottom <= 0
          ? null
          : () {
              final offset = _scroll.hasClients ? _scroll.offset : 0.0;
              return math.max(0, heroBottom - offset);
            },
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

  /// 首页顶部大海报：当前分类最靠前、带封面的几部剧。
  /// 观看记录仍然只从「追剧 → 最近观看」进入，海报只展示公开内容，
  /// 别人拿到手机看不到观看痕迹。
  Widget? _hero(ExploreFeed explore) {
    final form = AppScope.formFactorOf(context);
    // 电视靠遥控器方向键，轮播翻页反而碍事，保持原来的纯网格。
    if (form == FormFactor.television) return null;
    final items = <Drama>[];
    for (final drama in explore.items) {
      if (drama.cover.isEmpty) continue;
      items.add(drama);
      if (items.length == 5) break;
    }
    if (items.isEmpty) return null;
    return HeroCarousel(
      key: ValueKey('hero-${explore.tab.id}'),
      items: items,
      onOpen: _open,
      height: form == FormFactor.phone ? 196 : 208,
    );
  }
}
