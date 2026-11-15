import 'dart:async';

import 'package:flutter/material.dart';

import '../local_store.dart';

import '../ui/widgets/bar_button.dart';
import '../ui/widgets/frosted_header.dart';
import '../ui/widgets/focus_ring.dart';
import '../ui/widgets/status_view.dart';
import '../ui/widgets/swipe_category_layer.dart';
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

  Future<void> _open(int index) async {
    final source = _source;
    final channel = _channels[index];
    if (source == null) return;
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

  @override
  Widget build(BuildContext context) => Scaffold(
    // 与首页同一套顶栏逻辑：内容延伸到屏顶，从磨砂玻璃背后透出。
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      surfaceTintColor: Colors.transparent,
      flexibleSpace: const FrostedHeader(fill: true),
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
    body: SafeArea(
      top: true,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.only(top: kToolbarHeight),
        child: _body(context),
      ),
    ),
  );

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
    if (_failed) {
      return StatusView(
        title: '直播源暂时不可用',
        message: _error,
        icon: Icons.cloud_off_rounded,
        action: '重试',
        onAction: () => unawaited(_loadPlatforms(force: true)),
      );
    }
    // 与首页一致：左右快滑在「收藏 / 各平台分类」之间切换。
    // 电视端组件会自动跳过手势，遥控器方向键行为不变。
    // 分类栏固定为「收藏 / 全部频道」：源站的 130 个秀场分类不再铺开，
    // 全部频道已按主播名去重合并，观感与全剧TV 一致。
    final platformIds = [_favouritesId, _allId];
    final platformLabels = ['收藏', '全部频道'];
    var platformIndex = platformIds.indexOf(_platform);
    if (platformIndex < 0) platformIndex = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sources.length > 1) _sourceBar(sources),
        _platformBar(),
        const Divider(height: 1),
        Expanded(
          child: SwipeCategoryLayer(
            itemCount: platformIds.length,
            index: platformIndex,
            labels: platformLabels,
            onIndexChanged: (next) => _selectPlatform(platformIds[next]),
            child: _channelBody(context),
          ),
        ),
      ],
    );
  }

  Widget _sourceBar(List<LiveSource> sources) => SizedBox(
    height: 56,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: sources.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final source = sources[index];
        return _Chip(
          label: source.name,
          selected: source.id == _source?.id,
          onTap: () => _selectSource(source),
        );
      },
    ),
  );

  Widget _platformBar() => SizedBox(
    height: 52,
    child: Row(
      children: [
        const SizedBox(width: 16),
        _Chip(
          label: '收藏 ${widget.store.favourites.length}',
          selected: _platform == _favouritesId,
          onTap: () => _selectPlatform(_favouritesId),
        ),
        const SizedBox(width: 8),
        _Chip(
          label: _progressTotal > 0 && _loading && _platform == _allId
              ? '全部频道 $_progressDone/$_progressTotal'
              : '全部频道',
          badge: _platform != _allId && _channels.isNotEmpty
              ? '${_lastGood.length}'
              : null,
          selected: _platform == _allId,
          onTap: () => _selectPlatform(_allId),
        ),
        const Spacer(),
      ],
    ),
  );

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
    final grid = GridView.builder(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + widget.bottomInset),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisExtent: 64,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _channels.length,
      itemBuilder: (context, index) {
        final channel = _channels[index];
        return _ChannelTile(
          channel: channel,
          onTap: () => unawaited(_open(index)),
        );
      },
    );
    if (!_loading) return grid;
    // 还在补齐后面的分类：顶上留一条细进度，已有频道照常可点。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          minHeight: 2,
          value: _progressTotal > 0 ? _progressDone / _progressTotal : null,
        ),
        Expanded(child: grid),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });
  final String label;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GlassChip(
    label: label,
    badge: badge,
    selected: selected,
    onTap: onTap,
    height: 40,
  );
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel, required this.onTap});
  final LiveChannel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FocusRing(
      radius: 16,
      child: Material(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (channel.number.isNotEmpty)
                        Text(
                          channel.number,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  Icons.play_circle_outline_rounded,
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
