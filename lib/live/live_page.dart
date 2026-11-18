import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/app_scope.dart';
import '../ui/widgets/capsule_tabs.dart';
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
const _allId = '__all';

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
  List<LiveChannel> _channels = const [];
  List<LiveChannel> _lastGood = const [];
  String _lastGoodPlatform = '';
  bool _loading = true;
  bool _failed = false;
  String? _error;
  int _generation = 0;
  final _pager = PageController();
  int _page = 0;

  /// 「全部频道」合并进度：已拉完的分类数 / 总分类数。
  int _progressDone = 0;
  int _progressTotal = 0;

  List<LiveSource> get _sources => LiveSource.visible(widget.greenMode);

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
      setState(() {
        _platform = platforms.isEmpty ? '' : _allId;
        _progressTotal = platforms.length;
      });
      if (platforms.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      await _loadAll();
    } catch (error) {
      if (!mounted || token != _generation) return;
      setState(() {
        _loading = false;
        _failed = true;
        _error = '$error';
      });
    }
  }

  /// 一次性把所有分类的频道合并去重，边拉边显示，避免用户对着空页面等。
  Future<void> _loadAll() async {
    final source = _source;
    if (source == null) return;
    final token = _generation;
    setState(() {
      _loading = true;
      _failed = false;
      _error = null;
      _progressDone = 0;
      _channels = _lastGoodPlatform == _allId ? _lastGood : const [];
    });
    try {
      final channels = await widget.repository.allChannels(
        source,
        onProgress: (merged, done, total) {
          if (!mounted || token != _generation) return;
          setState(() {
            _channels = merged;
            _progressDone = done;
            _progressTotal = total;
          });
        },
      );
      if (!mounted || token != _generation) return;
      setState(() {
        _channels = channels;
        _lastGood = channels;
        _lastGoodPlatform = _allId;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || token != _generation) return;
      setState(() {
        _loading = false;
        _channels = _lastGoodPlatform == _allId ? _lastGood : const [];
        _failed = _channels.isEmpty;
        _error = '$error';
      });
    }
  }

  void _selectSource(LiveSource source) {
    if (source.id == _source?.id) return;
    _resetPages();
    widget.repository.clear();
    setState(() {
      _source = source;
      _platform = '';
      _channels = const [];
      _lastGood = const [];
      _lastGoodPlatform = '';
    });
    unawaited(_loadPlatforms());
  }

  void _selectPlatform(String id) {
    if (id == _platform) return;
    _resetPages();
    if (id == _favouritesId) {
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
    if (id != _allId) return;
    if (_lastGoodPlatform == _allId && _lastGood.isNotEmpty) {
      ++_generation;
      setState(() {
        _platform = _allId;
        _channels = _lastGood;
        _loading = false;
        _failed = false;
        _error = null;
      });
      return;
    }
    unawaited(_loadAll());
  }

  /// 换分类或换源后回到第一页：否则停在第 7 页会看到空白。
  void _resetPages() {
    _page = 0;
    if (_pager.hasClients) _pager.jumpToPage(0);
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

  /// 顶栏只放标题与刷新。分类从标题行里挪出来单独占一行——上一版把
  /// 「收藏 / 全部频道 / 源名」全塞进顶栏，小屏上会横向滚动，太挤。
  Widget _platformBar() {
    final favourites = widget.store.favourites.length;
    final merging = _progressTotal > 0 && _loading && _platform == _allId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          CapsuleTabs(
            labels: [
              favourites == 0 ? '收藏' : '收藏 $favourites',
              merging ? '全部频道 $_progressDone/$_progressTotal' : '全部频道',
            ],
            index: _platform == _favouritesId ? 0 : 1,
            onChanged: (index) =>
                _selectPlatform(index == 0 ? _favouritesId : _allId),
          ),
          const Spacer(),
          if (_sources.length > 1)
            GlassChip(
              label: _source?.name ?? '直播源',
              selected: false,
              height: 32,
              onTap: () => unawaited(_pickSource(_sources)),
            ),
        ],
      ),
    );
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
    if (_failed && _channels.isEmpty) {
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
          LinearProgressIndicator(
            minHeight: 2,
            value: _progressTotal > 0 ? _progressDone / _progressTotal : null,
          ),
        Expanded(child: _channelBody(context)),
      ],
    );
  }

  Widget _channelBody(BuildContext context) {
    if (_loading && _channels.isEmpty) {
      return StatusView.loading(
        title: _progressTotal > 0
            ? '正在合并频道 $_progressDone/$_progressTotal'
            : '正在加载频道',
      );
    }
    if (_channels.isEmpty) {
      final favourite = _platform == _favouritesId;
      return StatusView(
        title: favourite ? '还没有收藏频道' : '暂时没有可用的频道',
        message: favourite ? '在播放页点收藏，之后可以在这里快速找到。' : '下拉刷新或稍后重试。',
        icon: favourite ? Icons.star_border_rounded : Icons.tv_off_rounded,
      );
    }
    // 电视与桌面窗口沿用纵向网格（遥控器 / 滚轮），手机与平板改成横向分页：
    // 全部频道有上千个，一直往下滑太累，横滑一屏一页更省力。
    final wide = switch (AppScope.formFactorOf(context)) {
      FormFactor.television || FormFactor.window => true,
      _ => false,
    };
    if (wide) return _grid(_channels, bottom: 24 + widget.bottomInset);
    return LayoutBuilder(
      builder: (context, constraints) {
        const inset = 16.0, gap = 10.0, cell = 220.0, tile = 64.0;
        final columns = math.max(
          1,
          ((constraints.maxWidth - inset * 2) / (cell + gap)).ceil(),
        );
        // 翻页角标放在顶部：放右下会被底栏导航和最后一行频道卡片压住。
        int rowsFor(double top) => math.max(
          1,
          ((constraints.maxHeight - top - 12 - widget.bottomInset + gap) /
                  (tile + gap))
              .floor(),
        );
        final plainPages = math.max(
          1,
          (_channels.length / (columns * rowsFor(12))).ceil(),
        );
        final badge = plainPages > 1;
        final top = badge ? 30.0 : 12.0;
        final rows = rowsFor(top);
        final perPage = columns * rows;
        final pages = math.max(1, (_channels.length / perPage).ceil());
        return Stack(
          children: [
            PageView.builder(
              controller: _pager,
              itemCount: pages,
              onPageChanged: (page) {
                if (page == _page) return;
                unawaited(HapticFeedback.selectionClick());
                setState(() => _page = page);
              },
              itemBuilder: (context, page) {
                final from = page * perPage;
                final to = math.min(from + perPage, _channels.length);
                return _grid(
                  _channels.sublist(from, to),
                  top: top,
                  bottom: 12 + widget.bottomInset,
                  scrollable: false,
                );
              },
            ),
            if (badge)
              Positioned(
                right: 16,
                top: 0,
                child: IgnorePointer(
                  child: _PageBadge(page: _page, pages: pages),
                ),
              ),
          ],
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
    physics: scrollable ? null : const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 220,
      mainAxisExtent: 64,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
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

/// 右下角的翻页指示：`2 / 7`。频道上千时圆点会糊成一片，数字更清楚。
class _PageBadge extends StatelessWidget {
  const _PageBadge({required this.page, required this.pages});

  final int page;
  final int pages;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
    ),
    child: Text(
      '${page + 1} / $pages',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
  );
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel, required this.onTap});
  final LiveChannel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final initial = channel.name.isEmpty
        ? '#'
        : channel.name.substring(0, 1);
    return FocusRing(
      radius: 18,
      child: Material(
        color: colors.surfaceContainerHigh.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.primary.withValues(alpha: 0.16),
                  ),
                  child: Text(
                    initial,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: colors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (channel.number.isNotEmpty)
                        Text(
                          channel.number,
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  Icons.play_circle_outline_rounded,
                  size: 22,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
