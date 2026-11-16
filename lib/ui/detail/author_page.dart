import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import '../widgets/drama_grid.dart';
import '../widgets/glass_app_bar.dart';
import '../widgets/page_header.dart';
import 'detail_page.dart';

/// 作者主页：同一个站源里某位作者（上传者）的其它作品。
///
/// 数据走原生 `authorCatalog`，站源支持作者主页就直接取，否则内核用
/// 作者名搜索兜底，因此任何源只要能拿到作者都能点进来。
class AuthorPage extends StatefulWidget {
  const AuthorPage({
    super.key,
    required this.store,
    required this.source,
    required this.author,
    this.authorId = '',
    this.authorUrl = '',
  });

  final LocalStore store;
  final String source;
  final String author;
  final String authorId;
  final String authorUrl;

  @override
  State<AuthorPage> createState() => _AuthorPageState();
}

class _AuthorPageState extends State<AuthorPage> {
  final _items = <Drama>[];
  final _scroll = ScrollController();
  var _page = 0;
  var _hasMore = true;
  var _loading = false;
  var _started = false;
  String _error = '';

  String get _title =>
      widget.author.trim().isEmpty ? '作者主页' : widget.author.trim();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 320) {
      return;
    }
    _load();
  }

  Future<void> _load() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final result = await AppScope.of(context).repository.authorCatalog(
        widget.source,
        author: widget.author,
        authorId: widget.authorId,
        authorUrl: widget.authorUrl,
        page: _page + 1,
      );
      if (!mounted) return;
      final known = {for (final item in _items) item.id};
      setState(() {
        _page += 1;
        _items.addAll(result.items.where((item) => known.add(item.id)));
        _hasMore = result.hasMore && result.items.isNotEmpty;
        _loading = false;
        if (_items.isEmpty && result.warning.isNotEmpty) {
          _error = result.warning;
        }
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _error = failure is StateError ? failure.message : '$failure';
        _loading = false;
      });
    }
  }

  void _open(Drama drama) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inset = MediaQuery.sizeOf(context).width >= 720 ? 24.0 : 16.0;
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        title: _title,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading
                ? null
                : () {
                    setState(() {
                      _items.clear();
                      _page = 0;
                      _hasMore = true;
                      _error = '';
                    });
                    _load();
                  },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, top + 8, inset, 0),
            sliver: SliverToBoxAdapter(
              child: PageHeader(
                title: _title,
                count: _items.isEmpty ? null : '${_items.length}',
              ),
            ),
          ),
          if (_items.isEmpty && _loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(inset),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error.isEmpty ? '这个源里暂时没有该作者的其它作品' : _error,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (_error.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        FilledButton.tonal(
                          onPressed: () {
                            setState(() {
                              _hasMore = true;
                              _error = '';
                            });
                            _load();
                          },
                          child: const Text('重试'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
              sliver: DramaSliverGrid(
                width: MediaQuery.sizeOf(context).width - inset * 2,
                items: _items,
                onOpen: _open,
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 16, inset, 32),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: _loading && _items.isNotEmpty
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _hasMore ? '继续上滑加载更多' : '没有更多了',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
