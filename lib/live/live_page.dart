import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_device.dart';
import '../ui/app_scope.dart';
import '../local_store.dart';

import '../ui/widgets/bar_button.dart';
import '../ui/widgets/category_tabs.dart';
import '../ui/widgets/choice_panel.dart';
import '../ui/widgets/focus_ring.dart';
import '../ui/widgets/glass_app_bar.dart';
import '../ui/widgets/status_view.dart';
import 'live_models.dart';
import 'live_player_page.dart';
import 'live_repository.dart';
import 'live_sources.dart';
import 'live_store.dart';

/// 收藏分类的伪 ID：它不是真实分类，只在分类栏里代表「我的收藏」。
const _favouritesId = '__favourites';

/// 「全部频道」伪 ID：把源站所有分类的频道合并去重成一个列表。


/// 直播频道列表页。
///
/// 顶部是直播源与分类，下面是该分类的频道网格；点频道进入全屏播放。
/// 收藏与最近观看来自 [LiveStore]，按用户隔离保存。
class LivePage extends StatefulWidget {
  const LivePage({
    super.key,
    required this.repository,
    required this.store,
    this.greenMode = false,
    this.bottomInset = 0,
  });
  final LiveRepository repository;
  final LiveStore store;
  final bool greenMode;

  /// 作为底部导航 tab 使用时额外留出的底部空间，避免最后一排频道被导航条遮住。
  final double bottomInset;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  LiveSource? _source;
  String _platform = '';
  List<LivePlatform> _platforms = const [];
  List<LivePlatform> _visiblePlatforms = const [];
  List<LiveChannel> _channels = const [];
  List<LiveChannel> _lastGood = const [];
  String _lastGoodPlatform = '';
  bool _loading = true;
  bool _failed = false;
  String? _error;
  int _generation = 0;
  final _pager = PageController(initialPage: 1);
  final _emptyPlatforms = <String>{};

  /// 每个分类的频道列表缓存，只给「非当前页」用：横滑时相邻页直接出内容，
  /// 不再显示转圈。key 由 [_cacheKey] 生成（源 + 分类），切源时整体清空。
  final _pageCache = <String, List<LiveChannel>>{};

  /// 正在后台预取 / 已排队预取的 cache key，避免同一页被反复触发。
  final _prefetching = <String>{};
  final _pendingPrefetch = <String>{};

  /// 预取失败或为空的 key。没有它的话，页面每次重建都会再发一次请求，
  /// 断网时会变成一直空转；下拉刷新（force）会把它清掉。
  final _prefetchFailed = <String>{};

  String _liveKey(String name) => name
      .replaceAll(RegExp(r'[\s\u200b-\u200d\ufeff]+'), '')
      .toLowerCase();

  /// 缓存 key 带上直播源 id：不同源可能有同名分类，混用会把内容串在一起。
  String _cacheKey(String platformId) => '${_source?.id ?? ''}\u0000$platformId';

  List<LiveSource> get _sources => LiveSource.visible(widget.greenMode);

  List<LivePlatform> get _availableCategories => [
    for (final platform in _platforms)
      if (!_emptyPlatforms.contains(platform.id)) platform,
  ];

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_storeChanged);
    unawaited(_bootstrap());
  }

  /// 先加载外置直播源配置（live_sources.json），再决定是否拉取面板。
  Future<void> _bootstrap() async {
    await LiveSource.loadExternal();
    if (!mounted) return;
    final sources = _sources;
    setState(() {
      _source = sources.isEmpty ? null : sources.first;
      _loading = sources.isNotEmpty;
    });
    if (sources.isNotEmpty) unawaited(_loadPlatforms());
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    _pager.dispose();
    super.dispose();
  }

  void _storeChanged() {
    if (!mounted) return;
    // 只刷新收藏列表内容，不动当前分类，否则点收藏会跳回其它分类。
    if (_platform == _favouritesId) {
      setState(() => _channels = widget.store.favourites);
    } else {
      setState(() {});
    }
  }

  Future<void> _loadPlatforms({bool force = false}) async {
    final source = _source;
    if (source == null) return;
    _emptyPlatforms.clear();
    _pageCache.clear();
    _pendingPrefetch.clear();
    _prefetchFailed.clear();
    final token = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
      _error = null;
      _channels = const [];
    });
    try {
      final platforms = await widget.repository.platforms(source, force: force);
      if (!mounted || token != _generation) return;
      final visible = [
        for (final platform in platforms)
          if (platform.count >= 5) platform,
      ].take(10).toList();
      if (visible.isEmpty) visible.addAll(platforms.take(8));
      setState(() {
        _platforms = platforms;
        _visiblePlatforms = visible;
        _platform = '';
        _channels = const [];
        _loading = platforms.isNotEmpty;
      });
      if (platforms.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final first = visible.first;
      setState(() => _platform = first.id);
      if (_pager.hasClients) _pager.jumpToPage(1);
      await _loadPlatform(first);
      _prefetchNeighbors(1);
    } catch (error) {
      if (!mounted || token != _generation) return;
      setState(() {
        _loading = false;
        _failed = true;
        _error = '$error';
      });
    }
  }

  /// 只拉当前分类，不再把所有分类合并成一个「全部频道」。
  Future<void> _loadPlatform(
    LivePlatform platform, {
    bool force = false,
  }) async {
    final source = _source;
    if (source == null) return;
    final token = ++_generation;
    // 切分类时保留当前页，避免整块 PageView 被 loading 状态替换掉，
    // 导致刚滑到的分类又跳回第一页；新数据回来再原地替换。
    setState(() {
      _loading = true;
      _failed = false;
      _error = null;
    });
    try {
      final channels = await widget.repository.channels(
        source,
        platform,
        force: force,
      );
      if (!mounted || token != _generation) return;
      // 只在本分类内按主播名去重。原来跨分类共用一个 owner 表，会让先访问的
      // 分类抢走重名主播、后访问的分类内容莫名变少，而且和预取缓存对不上。
      final visible = <LiveChannel>[];
      final seen = <String>{};
      for (final channel in channels) {
        if (seen.add(_liveKey(channel.name))) visible.add(channel);
      }
      _emptyPlatforms.remove(platform.id);
      setState(() {
        _channels = visible;
        _lastGood = visible;
        _lastGoodPlatform = platform.id;
        _loading = false;
        _failed = visible.isEmpty;
        _pageCache[_cacheKey(platform.id)] = visible;
        _prefetchFailed.remove(_cacheKey(platform.id));
      });
      if (visible.isEmpty) unawaited(_removeEmptyCategory(platform));
      final at = _visiblePlatforms.indexWhere(
        (item) => item.id == platform.id,
      );
      if (mounted && at >= 0 && _pager.hasClients) {
        _pager.jumpToPage(at + 1);
      }
    } catch (error) {
      if (!mounted || token != _generation) return;
      setState(() {
        _loading = false;
        _channels = _lastGoodPlatform == platform.id ? _lastGood : const [];
        _failed = _channels.isEmpty;
        _error = '$error';
      });
      if (_channels.isEmpty) unawaited(_removeEmptyCategory(platform));
    }
  }

  Future<void> _removeEmptyCategory(LivePlatform platform) async {
    _emptyPlatforms.add(platform.id);
    final at = _visiblePlatforms.indexWhere((item) => item.id == platform.id);
    if (at < 0 || _visiblePlatforms.length <= 1) return;
    final next = [..._visiblePlatforms]..removeAt(at);
    final current = _platform == platform.id;
    if (!mounted) return;
    setState(() => _visiblePlatforms = next);
    if (current) {
      final target = next[at < next.length ? at : next.length - 1];
      _selectPlatform(target.id, fromSwipe: true);
      return;
    }
    if (_pager.hasClients && (_pager.page ?? 1).round() > next.length) {
      _pager.jumpToPage(next.length);
    }
  }

  Future<void> _refreshCurrent() async {
    final current = _platforms
        .where((platform) => platform.id == _platform)
        .firstOrNull;
    if (current != null) return _loadPlatform(current, force: true);
    return _loadPlatforms(force: true);
  }

  /// 刷新指定分类：当前页走原来的 [_loadPlatform]，非当前页只更新它自己的
  /// 缓存，不去动 [_channels]，避免把当前页内容冲掉。
  Future<void> _refreshPlatform(String id) async {
    if (id == _favouritesId) {
      if (mounted) setState(() {});
      return;
    }
    final platform = _platforms.where((item) => item.id == id).firstOrNull;
    if (platform == null) return;
    if (id == _platform) return _loadPlatform(platform, force: true);
    await _prefetchPlatform(id, force: true);
  }

  /// 后台预取某个分类的频道，只写 [_pageCache]。
  ///
  /// 刻意 **不碰** [_channels]、不递增 [_generation]：前者会把当前页数据
  /// 冲掉，后者会取消正在进行的请求，表现为「滑到哪页哪页白一下」。
  Future<void> _prefetchPlatform(String id, {bool force = false}) async {
    if (id == _favouritesId || id == _platform) return;
    final source = _source;
    if (source == null) return;
    final key = _cacheKey(id);
    if (_prefetching.contains(key)) return;
    if (!force && _pageCache.containsKey(key)) return;
    if (!force && _prefetchFailed.contains(key)) return;
    final platform = _platforms.where((item) => item.id == id).firstOrNull;
    if (platform == null) {
      // 分类对象都找不到，重试也没意义，标记掉避免每一帧都排队一次。
      _prefetchFailed.add(key);
      return;
    }
    _prefetching.add(key);
    if (force) _prefetchFailed.remove(key);
    final sourceId = source.id;
    try {
      final channels = await widget.repository.channels(
        source,
        platform,
        force: force,
      );
      if (!mounted || _source?.id != sourceId) return;
      // 平台内按名去重，与当前页展示形态保持一致。
      final seen = <String>{};
      final list = <LiveChannel>[
        for (final channel in channels)
          if (seen.add(_liveKey(channel.name))) channel,
      ];
      if (list.isEmpty) {
        // 空结果也写缓存：让这一页显示「暂时没有频道」，而不是一直骨架屏。
        _prefetchFailed.add(key);
        setState(() => _pageCache[key] = const []);
        return;
      }
      setState(() {
        _pageCache[key] = list;
        _prefetchFailed.remove(key);
      });
    } catch (_) {
      // 预取失败静默忽略，标记后不再自动重试；用户滑到该页下拉可手动刷新。
      if (mounted) _prefetchFailed.add(key);
    } finally {
      _prefetching.remove(key);
    }
  }

  /// 预取当前页左右各一页，滑过去就有内容。
  void _prefetchNeighbors(int page) {
    if (_visiblePlatforms.isEmpty) return;
    for (final at in [page - 1, page + 1]) {
      final id = _idAtPage(at);
      if (id == null) continue;
      unawaited(_prefetchPlatform(id));
    }
  }

  /// build 期间不能直接发请求，推到下一帧再预取；同一页只排一次。
  void _schedulePrefetch(String id) {
    if (id == _favouritesId) return;
    final key = _cacheKey(id);
    if (_pageCache.containsKey(key) ||
        _prefetchFailed.contains(key) ||
        _pendingPrefetch.contains(key)) {
      return;
    }
    _pendingPrefetch.add(key);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingPrefetch.remove(key);
      if (!mounted) return;
      unawaited(_prefetchPlatform(id));
    });
  }

  void _selectSource(LiveSource source) {
    if (source.id == _source?.id) return;
    if (_pager.hasClients) _pager.jumpToPage(1);
    widget.repository.clear();
    setState(() {
      _source = source;
      _platform = '';
      _emptyPlatforms.clear();
      _pageCache.clear();
      _pendingPrefetch.clear();
      _prefetchFailed.clear();
      _platforms = const [];
      _visiblePlatforms = const [];
      _channels = const [];
      _lastGood = const [];
      _lastGoodPlatform = '';
    });
    unawaited(_loadPlatforms());
  }

  void _selectPlatform(String id, {bool fromSwipe = false}) {
    if (id == _platform) return;
    if (id == _favouritesId) {
      if (!fromSwipe && _pager.hasClients) {
        _pager.animateToPage(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
      ++_generation;
      setState(() {
        _platform = _favouritesId;
        _channels = widget.store.favourites;
        _loading = false;
        _failed = false;
        _error = null;
      });
      return;
    }
    final platform = _platforms
        .where((platform) => platform.id == id)
        .firstOrNull;
    if (platform == null) return;
    // 预取过就直接把缓存铺上去：翻页瞬间看到的是这一页自己的内容，
    // 而不是上一页的残留或转圈；随后 _loadPlatform 再用最新结果覆盖。
    final cached = _pageCache[_cacheKey(id)];
    var at = _visiblePlatforms.indexWhere((item) => item.id == id);
    if (at < 0) {
      // 从「全部分类」里选的冷门分类临时放进顶栏，最多保留 11 个常用项。
      final next = [..._visiblePlatforms];
      if (next.length >= 11) next.removeLast();
      next.add(platform);
      at = next.length - 1;
      setState(() {
        _visiblePlatforms = next;
        _platform = id;
        if (cached != null) _channels = cached;
      });
    } else {
      setState(() {
        _platform = id;
        if (cached != null) _channels = cached;
      });
    }
    if (!fromSwipe && _pager.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pager.hasClients) return;
        _pager.animateToPage(
          at + 1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      });
    }
    unawaited(_loadPlatform(platform));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    // 与首页同一套顶栏逻辑：内容延伸到屏顶，从磨砂玻璃背后透出。
    extendBodyBehindAppBar: true,
    appBar: glassAppBar(
      titleSpacing: 16,
      title: '直播',
      actions: [
        if (_sources.length > 1)
          BarButton(
            icon: Icons.dns_outlined,
            tooltip: '切换直播源',
            onPressed: () => unawaited(_pickSource(_sources)),
          ),
        BarButton(
          icon: Icons.refresh_rounded,
          tooltip: '刷新',
          onPressed: _loading
              ? null
              : () => unawaited(_loadPlatforms(force: true)),
        ),
        const SizedBox(width: 20),
      ],
    ),
    // SafeArea 已经把「状态栏 + 顶栏」一起让出来了（extendBodyBehindAppBar
    // 会把顶栏高度并进 body 的 padding.top），再叠 kToolbarHeight 就会多出
    // 一条 56 点的纯黑空条——直播与设置页上方那块方块就是这么来的。
    body: SafeArea(top: true, bottom: false, child: _body(context)),
  );

  /// 分类条：与首页 / 追剧 / 历史同一套下划线 [CategoryTabs]，收藏排最前。
  /// 「全部分类」走分类条右端的固定入口，「切换直播源」收进顶栏图标，
  /// 不再在分类条尾部并排挤三个胶囊。
  Widget _platformBar() {
    final favourites = widget.store.favourites.length;
    final options = [
      ChoiceOption(
        _favouritesId,
        favourites == 0 ? '收藏' : '收藏 $favourites',
      ),
      for (final platform in _visiblePlatforms)
        ChoiceOption(platform.id, platform.name),
    ];
    Widget tabs(double? progress) => CategoryTabs<String>(
      options: options,
      selected: _platform,
      progress: progress,
      onSelected: _selectPlatform,
      onShowAll: _pickCategory,
    );
    // 与首页同款跟手横条：直接读 _pager 的连续位置。手机端才有 PageView，
    // 宽屏/电视走网格、_pager 无 client，此时退化为选中值驱动的普通横条。
    final pager = _pager;
    return AnimatedBuilder(
      animation: pager,
      builder: (context, _) {
        final p = pager.hasClients ? pager.page : null;
        return tabs(p == null ? null : p.clamp(0.0, (options.length - 1).toDouble()));
      },
    );
  }

  /// 全部分类：走与首页同一个 ChoicePanel（手机底部弹层、平板锚定面板），
  /// 不再自己拼一个 ListView 弹层。
  Future<void> _pickCategory(BuildContext anchor) async {
    final picked = await showChoicePanel<String>(
      context: anchor,
      title: '全部分类',
      options: [
        for (final platform in _availableCategories)
          ChoiceOption(platform.id, platform.name),
      ],
      selected: _platform,
      grid: ChoiceGrid.categories,
    );
    if (picked != null && mounted) _selectPlatform(picked);
  }

  Future<void> _pickSource(List<LiveSource> sources) async {
    final picked = await showModalBottomSheet<LiveSource>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final source in sources)
              ListTile(
                title: Text(source.name),
                subtitle: source.description.isEmpty
                    ? null
                    : Text(source.description),
                trailing: source.id == _source?.id
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(sheetContext, source),
              ),
          ],
        ),
      ),
    );
    if (picked != null) _selectSource(picked);
  }

  Widget _body(BuildContext context) {
    final sources = _sources;
    if (sources.isEmpty) {
      final filtered = LiveSource.all.isNotEmpty;
      return StatusView(
        title: '暂无可用的直播源',
        message: filtered
            ? '当前分级模式屏蔽了全部直播源，关闭后即可观看。'
            : '内置直播源未就绪，请完全退出应用后重新打开。',
        icon: Icons.live_tv_outlined,
      );
    }
    if (_platforms.isEmpty && _failed) {
      return StatusView(
        title: '直播源暂时不可用',
        message: _error,
        icon: Icons.cloud_off_rounded,
        action: '重试',
        onAction: () => unawaited(_loadPlatforms(force: true)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _platformBar(),
        if (_loading && _channels.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _channelBody(context)),
      ],
    );
  }

  Widget _categoryStatus() {
    final favourite = _platform == _favouritesId;
    final current = _platforms
        .where((platform) => platform.id == _platform)
        .firstOrNull;
    if (favourite) {
      return const StatusView(
        title: '还没有收藏频道',
        message: '在播放页点收藏，之后可以在这里快速找到。',
        icon: Icons.star_border_rounded,
      );
    }
    return StatusView(
      title: _error == null ? '这个分类暂时没有频道' : '这个分类暂时不可用',
      message: _error ?? '下拉刷新或点下面按钮重新抓取。',
      icon: Icons.tv_off_rounded,
      action: '重试',
      onAction: current != null
          ? () => _loadPlatform(current, force: true)
          : () => _loadPlatforms(force: true),
    );
  }

  Widget _channelBody(BuildContext context) {
    if (_platforms.isEmpty) {
      return _loading
          ? const StatusView.loading(title: '正在加载分类')
          : _categoryStatus();
    }
    // 电视与桌面窗口沿用纵向网格（遥控器 / 滚轮），手机与平板改成横向分页：
    // 全部频道有上千个，一直往下滑太累，横滑一屏一页更省力。
    final wide = switch (AppScope.formFactorOf(context)) {
      FormFactor.television || FormFactor.window => true,
      _ => false,
    };
    if (wide) {
      if (_channels.isEmpty) return _categoryStatus();
      return RefreshIndicator(
        onRefresh: _refreshCurrent,
        child: _grid(_channels, bottom: 24 + widget.bottomInset),
      );
    }
    return PageView.builder(
      controller: _pager,
      itemCount: _visiblePlatforms.length + 1,
      onPageChanged: (page) {
        unawaited(AppDevice.softTick());
        final id = _idAtPage(page);
        if (id == null) return;
        _selectPlatform(id, fromSwipe: true);
        _prefetchNeighbors(page);
      },
      itemBuilder: (context, page) {
        final id = _idAtPage(page);
        // 分类被移除时 PageView 可能还拿着旧索引问一帧，直接给空。
        if (id == null) return const SizedBox.shrink();
        if (id == _platform) return _currentPage();
        // 非当前页（手指正在拖过来的那一页）优先读缓存，让翻页真跟手。
        final cached = id == _favouritesId
            ? widget.store.favourites
            : _pageCache[_cacheKey(id)];
        if (cached == null) {
          _schedulePrefetch(id);
          return _channelSkeleton();
        }
        if (cached.isEmpty) {
          return id == _favouritesId ? _favouritesEmpty() : _emptyPage(id);
        }
        return RefreshIndicator(
          onRefresh: () => _refreshPlatform(id),
          child: _grid(
            cached,
            top: 12,
            bottom: 12 + widget.bottomInset,
          ),
        );
      },
    );
  }

  /// 页码 → 分类 id。0 是收藏页，1..n 对应 [_visiblePlatforms]。
  String? _idAtPage(int page) {
    if (page == 0) return _favouritesId;
    final index = page - 1;
    if (index < 0 || index >= _visiblePlatforms.length) return null;
    return _visiblePlatforms[index].id;
  }

  /// 当前页内容：保持改造前的加载 / 空态 / 网格三态判断。
  Widget _currentPage() {
    if (_loading && _channels.isEmpty) {
      return const StatusView.loading(title: '正在加载分类');
    }
    if (_channels.isEmpty) return _categoryStatus();
    return RefreshIndicator(
      onRefresh: _refreshCurrent,
      child: _grid(
        _channels,
        top: 12,
        bottom: 12 + widget.bottomInset,
      ),
    );
  }

  Widget _favouritesEmpty() => const StatusView(
    title: '还没有收藏频道',
    message: '在播放页点收藏，之后可以在这里快速找到。',
    icon: Icons.star_border_rounded,
  );

  /// 非当前页的空态：只针对这一页给重试，不影响当前页状态。
  Widget _emptyPage(String id) {
    final platform = _platforms.where((item) => item.id == id).firstOrNull;
    return StatusView(
      title: '这个分类暂时没有频道',
      message: '下拉刷新或稍后再试。',
      icon: Icons.tv_off_rounded,
      action: platform == null ? null : '重试',
      onAction: platform == null
          ? null
          : () => unawaited(_refreshPlatform(id)),
    );
  }

  /// 预取未就绪时的占位：与频道网格同构的灰块，比转圈更像「内容在路上」。
  Widget _channelSkeleton() {
    final colors = Theme.of(context).colorScheme;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + widget.bottomInset),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        mainAxisExtent: 172,
        crossAxisSpacing: 10,
        mainAxisSpacing: 12,
      ),
      itemCount: 6,
      itemBuilder: (context, index) => DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
      ),
    );
  }

  Widget _grid(
    List<LiveChannel> channels, {
    double top = 12,
    required double bottom,
    bool scrollable = true,
  }) => GridView.builder(
    padding: EdgeInsets.fromLTRB(16, top, 16, bottom),
    physics: scrollable
        ? const AlwaysScrollableScrollPhysics()
        : const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 280,
      mainAxisExtent: 172,
      crossAxisSpacing: 10,
      mainAxisSpacing: 12,
    ),
    itemCount: channels.length,
    itemBuilder: (context, index) {
      final channel = channels[index];
      return _ChannelTile(
        channel: channel,
        onTap: () => unawaited(_openChannel(channel)),
      );
    },
  );

  Future<void> _openChannel(LiveChannel channel) async {
    final source = _source;
    if (source == null) return;
    final index = _channels.indexOf(channel);
    await widget.store.remember(channel);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LivePlayerPage(
          repository: widget.repository,
          store: widget.store,
          source: source,
          channels: _channels,
          index: index,
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel, required this.onTap});
  final LiveChannel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 18,
      child: Material(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 104,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _cover(colors),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xB3000000)],
                        ),
                      ),
                    ),
                    const Positioned(
                      left: 8,
                      top: 8,
                      child: _LiveBadge(),
                    ),
                    if (channel.number.isNotEmpty)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Text(
                          channel.number,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 4),
                            ],
                          ),
                        ),
                      ),
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 7,
                      child: Text(
                        channel.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          shadows: [
                            Shadow(color: Colors.black87, blurRadius: 5),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          channel.group.isNotEmpty
                              ? channel.group
                              : channel.source.isNotEmpty
                              ? channel.source
                              : '直播中',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.play_circle_outline_rounded,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cover(ColorScheme colors) {
    final logo = channel.logo.trim();
    final fallback = _fallback(colors);
    if (logo.isEmpty) return fallback;
    return Image.network(
      logo,
      fit: BoxFit.cover,
      cacheWidth: 480,
      errorBuilder: (_, _, _) => fallback,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : fallback,
    );
  }

  Widget _fallback(ColorScheme colors) {
    final initial = channel.name.isEmpty ? '直播' : channel.name.characters.first;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primary.withValues(alpha: 0.42),
            colors.surfaceContainerHighest,
          ],
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.9),
            fontSize: 26,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xFFFF3B57),
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 6, color: Colors.white),
        SizedBox(width: 4),
        Text(
          'LIVE',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
      ],
    ),
  );
}

/// 全局共享的直播仓库：复用同一个 HttpClient 与频道缓存，避免每次进入直播页
/// 都新建连接池；进程退出时随应用一起释放。
LiveRepository? _shared;

LiveRepository sharedLiveRepository() => _shared ??= LiveRepository();

/// 按当前用户取直播收藏/最近观看存储；切换用户时重建，避免串号。
LiveStore? _liveStore;
String _liveStoreProfile = '';

LiveStore liveStoreFor(LocalStore owner) {
  if (_liveStore == null || _liveStoreProfile != owner.profile.id) {
    _liveStore?.dispose();
    _liveStore = LiveStore(owner.preferences, owner.profile.id)..load();
    _liveStoreProfile = owner.profile.id;
  }
  return _liveStore!;
}

/// 打开直播页（首页与我的页的入口都走这里）。
Future<void> openLive(
  BuildContext context, {
  required LocalStore store,
  bool greenMode = false,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => LivePage(
      repository: sharedLiveRepository(),
      store: liveStoreFor(store),
      greenMode: greenMode,
    ),
  ),
);
