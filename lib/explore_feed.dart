import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'drama_feed.dart';
import 'local_store.dart';
import 'models.dart';
import 'ranking_models.dart';
import 'source_catalog.dart';

const recommendTab = CatalogCategory('app:recommend', '推荐');

CatalogCategory rankingTab(RankingBoard board) =>
    CatalogCategory('app:rank:${board.id}', board.name);

class ExploreFeed extends ChangeNotifier {
  ExploreFeed(this.repository, this.store) {
    store.addListener(_storeChanged);
    repository.catalogUpdates.addListener(_metadataChanged);
    _open();
  }
  final AppRepository repository;
  final LocalStore store;
  SourceCatalog? _catalog;
  CatalogCategory _tab = CatalogCategory.all;
  DramaFeed? _feed;
  Map<String, int> _ranks = const {};
  final _feeds = <String, DramaFeed>{};
  final _rankings = <String, Map<String, int>>{};
  bool _disposed = false;

  SourceSite? get source => _catalog?.source;
  DramaFeed? get feed => _feed;
  CatalogCategory get tab => _tab;
  bool get recommending => _tab.id == recommendTab.id;

  List<CatalogCategory> get tabs {
    final catalog = _catalog;
    if (catalog == null) return const [];
    final [all, ...genres] = catalog.categories;
    return [
      if (catalog.recommends) recommendTab,
      all,
      for (final board in catalog.boards) rankingTab(board),
      ...genres,
    ];
  }

  int? rankOf(Drama drama) => _ranks[drama.id];

  /// 真 PageView 用：按 tab id 只读地取该分类自己的数据，不改动当前选中项。
  /// 每个分类页据此独立构建内容，相邻两页才能同时贴在屏内。
  DramaFeed? feedFor(String id) => _feeds[id];

  /// 该 tab 的榜单名次表（未加载过时为空）。
  Map<String, int> ranksFor(String id) => _rankings[id] ?? const {};

  /// 该 tab 是否走「推荐 + 顶部大海报」布局。
  bool recommendingFor(String id) => id == recommendTab.id;

  /// 指定 tab 是否处于「有续看、因而不出大海报」的状态。
  bool hasResumeFor(String id) {
    final source = this.source;
    if (source == null || id != tabs.firstOrNull?.id) return false;
    return store.history.any((entry) => entry.drama.source == source.id);
  }

  /// 指定 tab 的大海报主角（推荐且无续看时的第一条）。
  Drama? featuredFor(String id) {
    if (!recommendingFor(id) || hasResumeFor(id)) return null;
    return _feeds[id]?.items.firstOrNull;
  }

  /// 指定 tab 的网格条目（有大海报时跳过第一条）。
  List<Drama> itemsFor(String id) {
    final items = _feeds[id]?.items ?? const <Drama>[];
    return featuredFor(id) == null ? items : items.skip(1).toList();
  }

  /// 确保某 tab 的 feed 已建立并开始加载，但不切换当前选中项。
  /// PageView 会预构建相邻页，这些页可能从未被点开过，需要先触发加载。
  void ensureFeed(String id) {
    final catalog = _catalog;
    if (catalog == null || _feeds.containsKey(id)) return;
    final tab = tabs.where((tab) => tab.id == id).firstOrNull;
    if (tab == null) return;
    final ranks = _rankings[id] = <String, int>{};
    final feed = _feeds[id] = _createFeed(catalog, tab, ranks);
    unawaited(feed.reload());
  }

  DramaFeed _createFeed(
    SourceCatalog catalog,
    CatalogCategory tab,
    Map<String, int> ranks,
  ) {
    final board = catalog.boards
        .where((board) => rankingTab(board).id == tab.id)
        .firstOrNull;
    final feed = tab.id == recommendTab.id
        ? DramaFeed(
            cumulative: true,
            load: (page, force) =>
                _saved(catalog.recommendations(more: page > 1, force: force)),
          )
        : board != null
        ? DramaFeed(
            load: (page, force) =>
                _saved(_ranking(catalog, board, ranks, page, force)),
          )
        : DramaFeed(
            cached: () => catalog.cached(tab),
            load: (page, force) =>
                _saved(catalog.fetch(tab, page: page, force: force)),
          );
    feed.addListener(_notify);
    return feed;
  }

  WatchEntry? get resume {
    final source = this.source;
    if (source == null || _tab.id != tabs.first.id) return null;
    return store.history
        .where((entry) => entry.drama.source == source.id)
        .firstOrNull;
  }

  Drama? get featured =>
      recommending && resume == null ? _feed?.items.firstOrNull : null;

  List<Drama> get items {
    final items = _feed?.items ?? const <Drama>[];
    return featured == null ? items : items.skip(1).toList();
  }

  void select(String id) {
    if (id == _tab.id) return;
    final tab = tabs.where((tab) => tab.id == id).firstOrNull;
    if (tab != null) _select(tab);
  }

  Future<void> refresh() async {
    final catalog = _catalog;
    if (catalog == null) return;
    if (catalog.categories.length == 1) {
      unawaited(_loadCategories(catalog, force: true));
    }
    await _feed?.reload(force: true);
  }

  void _open() {
    final id = store.source;
    if (id == _catalog?.source.id) return;
    unawaited(repository.cancelCatalog());
    unawaited(repository.cancelRecommendations());
    _dropFeeds();
    if (id.isEmpty) {
      _catalog = null;
      return;
    }
    final catalog = _catalog = SourceCatalog(repository, SourceSite.byId(id));
    _select(catalog.recommends ? recommendTab : CatalogCategory.all);
    unawaited(_loadCategories(catalog));
  }

  Future<void> _loadCategories(
    SourceCatalog catalog, {
    bool force = false,
  }) async {
    try {
      await catalog.loadCategories(force: force);
    } catch (_) {}
    if (_disposed || catalog != _catalog) return;
    _notify();
  }

  void _select(CatalogCategory tab) {
    final catalog = _catalog!;
    if (recommending) unawaited(repository.cancelRecommendations());
    _tab = tab;
    if (_feeds[tab.id] case final kept?) {
      _feed = kept;
      _ranks = _rankings[tab.id] ?? const {};
      if (kept.items.isEmpty && !kept.loading) unawaited(kept.reload());
      _notify();
      return;
    }
    final ranks = _ranks = _rankings[tab.id] = <String, int>{};
    final feed = _feed = _feeds[tab.id] = _createFeed(catalog, tab, ranks);
    unawaited(feed.reload());
    _notify();
  }

  Future<CatalogPage> _ranking(
    SourceCatalog catalog,
    RankingBoard board,
    Map<String, int> ranks,
    int page,
    bool force,
  ) async {
    final result = await catalog.ranking(board, page: page, force: force);
    for (final item in result.items) {
      ranks[item.drama.id] = item.rank;
    }
    return CatalogPage(
      [for (final item in result.items) item.drama],
      hasMore: result.hasMore,
      warning: result.warning,
      page: result.page,
    );
  }

  Future<CatalogPage> _saved(Future<CatalogPage> request) async {
    final page = await request;
    unawaited(store.refreshDramas(page.items).catchError((Object _) {}));
    return page;
  }

  void _storeChanged() {
    _open();
    _notify();
  }

  void _metadataChanged() {
    final drama = repository.catalogUpdates.latest;
    if (drama == null || drama.source != source?.id) return;
    _catalog?.remember([drama]);
    for (final feed in _feeds.values) {
      feed.update(drama);
    }
    unawaited(store.refreshDrama(drama).catchError((Object _) {}));
  }

  void _dropFeeds() {
    for (final feed in _feeds.values) {
      feed.dispose();
    }
    _feeds.clear();
    _rankings.clear();
    _feed = null;
    _ranks = const {};
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_storeChanged);
    repository.catalogUpdates.removeListener(_metadataChanged);
    _dropFeeds();
    unawaited(repository.cancelCatalog());
    unawaited(repository.cancelRecommendations());
    super.dispose();
  }
}
