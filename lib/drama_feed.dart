import 'package:flutter/foundation.dart';

import 'models.dart';

typedef PageLoader = Future<CatalogPage> Function(int page, bool force);

class DramaFeed extends ChangeNotifier {
  DramaFeed({required this.load, this.cached, this.cumulative = false});
  final PageLoader load;
  final Future<CatalogPage> Function()? cached;
  final bool cumulative;

  List<Drama> _items = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  String _error = '';
  int _next = 1;
  int _generation = 0;
  bool _disposed = false;

  List<Drama> get items => _items;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String get error => _error;
  bool get canLoadMore =>
      _hasMore && !_loading && !_loadingMore && _error.isEmpty;

  Future<void> reload({bool force = false}) async {
    final generation = ++_generation;
    _loading = true;
    _loadingMore = false;
    _error = '';
    _notify();
    if (!force && cached != null) {
      try {
        final page = await cached!();
        if (generation != _generation) return;
        if (page.items.isNotEmpty) {
          _accept(page, more: false, requested: page.page);
          if (page.fresh && page.warning.isEmpty) {
            _loading = false;
            _notify();
            return;
          }
          _notify();
        }
      } catch (_) {}
    }
    await _fetch(generation, page: 1, force: force, more: false);
  }

  Future<void> loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final generation = ++_generation;
    _loadingMore = true;
    _error = '';
    _notify();
    await _fetch(generation, page: _next, force: false, more: true);
  }

  void update(Drama drama) {
    if (!_items.any((item) => item.id == drama.id)) return;
    _items = [
      for (final item in _items) item.id == drama.id ? item.merge(drama) : item,
    ];
    _notify();
  }

  Future<void> _fetch(
    int generation, {
    required int page,
    required bool force,
    required bool more,
  }) async {
    try {
      final result = await load(page, force);
      if (generation != _generation) return;
      _accept(result, more: more, requested: page);
    } catch (error) {
      if (generation != _generation) return;
      final text = error.toString();
      // 换源/预加载时，后发的同类请求会主动 cancel 掉先发的那条。
      // 这是内部协调、不是站点失败，不该弹「暂时无法加载 context canceled」。
      // 仅吞掉错误文案，loading/notify 照常收尾，避免卡在加载中。
      if (!text.contains('canceled') && !text.contains('Canceled')) {
        _error = text;
      }
    }
    _loading = _loadingMore = false;
    _notify();
  }

  void _accept(CatalogPage page, {required bool more, required int requested}) {
    if (cumulative || !more) {
      _items = page.items;
    } else {
      final known = {for (final item in _items) item.id};
      _items = [
        ..._items,
        for (final item in page.items)
          if (known.add(item.id)) item,
      ];
    }
    final failed = page.warning.isNotEmpty;
    _next = failed ? requested : page.page + 1;
    _hasMore = page.hasMore || failed;
    _error = page.warning;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
