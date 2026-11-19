import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/app_scope.dart';
import '../local_store.dart';

import '../ui/widgets/bar_button.dart';
import '../ui/widgets/frosted_header.dart';
import '../ui/widgets/focus_ring.dart';
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
  final _categoryScroll = ScrollController();
  final _categoryKeys = <String, GlobalKey>{};
  final _channelOwners = <String, String>{};
  final _emptyPlatforms = <String>{};

  String _liveKey(String name) => name
      .replaceAll(RegExp(r'[\s\u200b-\u200d\ufeff]+'), '')
      .toLowerCase();

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
    _categoryScroll.dispose();
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
    _channelOwners.clear();
    _emptyPlatforms.clear();
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
      _revealCategory(first.id);
      if (_pager.hasClients) _pager.jumpToPage(1);
      await _loadPlatform(first);
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
      final visible = <LiveChannel>[];
      for (final channel in channels) {
        final key = _liveKey(channel.name);
        final owner = _channelOwners[key];
        if (owner == null) {
          _channelOwners[key] = platform.id;
          visible.add(channel);
        } else if (owner == platform.id) {
          visible.add(channel);
        }
      }
      _emptyPlatforms.remove(platform.id);
      setState(() {
        _channels = visible;
        _lastGood = visible;
        _lastGoodPlatform = platform.id;
        _loading = false;
        _failed = visible.isEmpty;
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

  void _selectSource(LiveSource source) {
    if (source.id == _source?.id) return;
    if (_pager.hasClients) _pager.jumpToPage(1);
    widget.repository.clear();
    setState(() {
      _source = source;
      _platform = '';
      _channelOwners.clear();
      _emptyPlatforms.clear();
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
      _revealCategory(_favouritesId);
      return;
    }
    final platform = _platforms
        .where((platform) => platform.id == id)
        .firstOrNull;
    if (platform == null) return;
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
      });
    } else {
      setState(() => _platform = id);
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
    _revealCategory(id);
    unawaited(_loadPlatform(platform));
  }

  void _revealCategory(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_categoryScroll.hasClients || _visiblePlatforms.isEmpty) {
        return;
      }
      final key = _categoryKeys[id];
      final target = key?.currentContext;
      if (target != null) {
        if (_categoryVisible(target)) return;
        Scrollable.ensureVisible(
          target,
          alignment: 0.5,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      final index = id == _favouritesId
          ? 0
          : _visiblePlatforms.indexWhere((platform) => platform.id == id) + 1;
      if (index <= 0) return;
      final max = _categoryScroll.position.maxScrollExtent;
      final fallback = (max * index / _visiblePlatforms.length).clamp(0.0, max);
      _categoryScroll.animateTo(
        fallback,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  bool _categoryVisible(BuildContext child) {
    final box = child.findRenderObject();
    final viewport = _categoryScroll.position.context.storageContext
        .findRenderObject();
    if (box is! RenderBox || viewport is! RenderBox) return false;
    final left = box.localToGlobal(Offset.zero, ancestor: viewport).dx;
    final width = _categoryScroll.position.viewportDimension;
    return left >= -16 && left + box.size.width <= width + 16;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    // 与首页同一套顶栏逻辑：内容延伸到屏顶，从磨砂玻璃背后透出。
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      surfaceTintColor: Colors.transparent,
      flexibleSpace: const FrostedHeader(fill: true),
      titleSpacing: 16,
      title: const GlassTitle(title: '直播'),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: BarButton(
            icon: Icons.refresh_rounded,
            tooltip: '刷新',
            onPressed: _loading
                ? null
                : () => unawaited(_loadPlatforms(force: true)),
          ),
        ),
      ],
    ),
    // SafeArea 已经把「状态栏 + 顶栏」一起让出来了（extendBodyBehindAppBar
    // 会把顶栏高度并进 body 的 padding.top），再叠 kToolbarHeight 就会多出
    // 一条 56 点的纯黑空条——直播与设置页上方那块方块就是这么来的。
    body: SafeArea(top: true, bottom: false, child: _body(context)),
  );

  /// 分类条：收藏 + 源里每个分类各一枚，横向滚动；不再把所有分类
  /// 合并成一个「全部频道」。
  Widget _platformBar() {
    final favourites = widget.store.favourites.length;
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 62,
      child: Row(
        children: [
          Expanded(
            child: Stack(
              children: [
                ListView.separated(
                  controller: _categoryScroll,
                  scrollDirection: Axis.horizontal,
                  cacheExtent: 12000,
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                  itemCount: _visiblePlatforms.length + 1,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return KeyedSubtree(
                        key: _categoryKeys.putIfAbsent(
                          _favouritesId,
                          GlobalKey.new,
                        ),
                        child: GlassChip(
                          label: favourites == 0 ? '收藏' : '收藏 $favourites',
                          selected: _platform == _favouritesId,
                          height: 42,
                          onTap: () => _selectPlatform(_favouritesId),
                        ),
                      );
                    }
                    final platform = _visiblePlatforms[index - 1];
                    return KeyedSubtree(
                      key: _categoryKeys.putIfAbsent(
                        platform.id,
                        GlobalKey.new,
                      ),
                      child: GlassChip(
                        label: platform.name,
                        selected: _platform == platform.id,
                        height: 42,
                        onTap: () => _selectPlatform(platform.id),
                      ),
                    );
                  },
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  width: 24,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            colors.surface.withValues(alpha: 0),
                            colors.surface,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GlassChip(
            label: '全部分类',
            selected: false,
            height: 42,
            onTap: () => unawaited(_pickCategory()),
          ),
          const SizedBox(width: 8),
          if (_sources.length > 1) ...[
            GlassChip(
              label: _source?.name ?? '直播源',
              selected: false,
              height: 42,
              onTap: () => unawaited(_pickSource(_sources)),
            ),
            const SizedBox(width: 16),
          ],
        ],
      ),
    );
  }

  Future<void> _pickCategory() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.78,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  '全部分类',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _availableCategories.length,
                  itemBuilder: (context, index) {
                    final platform = _availableCategories[index];
                    return ListTile(
                      title: Text(platform.name),
                      subtitle: Text('${platform.count} 个频道'),
                      trailing: platform.id == _platform
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.pop(sheetContext, platform.id),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
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
        unawaited(HapticFeedback.selectionClick());
        final id = page == 0
            ? _favouritesId
            : _visiblePlatforms[page - 1].id;
        _selectPlatform(id, fromSwipe: true);
      },
      itemBuilder: (context, page) {
        final id = page == 0
            ? _favouritesId
            : _visiblePlatforms[page - 1].id;
        if (id != _platform) {
          return const Center(child: CircularProgressIndicator());
        }
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
      },
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
