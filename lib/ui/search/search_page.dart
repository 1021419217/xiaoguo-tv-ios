import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_device.dart';
import '../../core_bridge.dart';
import '../../drama_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_catalog.dart';
import '../../verify_repair.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../widgets/glass_app_bar.dart';
import '../widgets/drama_grid.dart';
import '../widgets/follow_button.dart';
import '../widgets/focus_ring.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/search_field.dart';
import '../widgets/status_view.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.store,
    required this.source,
    this.query = '',
  });
  final LocalStore store;
  final SourceSite source;
  final String query;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final _controller = TextEditingController(text: widget.query);
  final _focus = FocusNode();
  late AppRepository _repository;
  late SourceCatalog _catalog;
  DramaFeed? _results;
  String _submitted = '';
  List<String> _suggestions = const [];
  Timer? _debounce;
  int _suggestion = 0;
  final _shownSuggestions = <Object>{};
  bool _ready = false;
  bool _verifying = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _repository = AppScope.of(context).repository;
    _catalog = SourceCatalog(_repository, widget.source);
    if (widget.query.trim().isNotEmpty) _submit(widget.query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestion++;
    unawaited(_repository.cancelSuggestions());
    _results?.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _forget(String query) {
    unawaited(HapticFeedback.selectionClick());
    unawaited(widget.store.forgetSearch(query).catchError((Object _) {}));
  }

  void _submit(String text) {
    final query = text.trim();
    if (query.isEmpty) return;
    _controller.text = query;
    _focus.unfocus();
    _debounce?.cancel();
    _suggestion++;
    unawaited(widget.store.rememberSearch(query).catchError((Object _) {}));
    _results?.dispose();
    final results = _results = DramaFeed(
      load: (page, _) => _catalog.search(query, page: page),
    )..addListener(() => setState(() {}));
    unawaited(results.reload());
    setState(() {
      _submitted = query;
      _suggestions = const [];
    });
  }

  /// 搜索同样可能是站点在挑战：搜索这次请求的 URL 从没被验证过的 WebView 抓过，
  /// Go 的 TLS 指纹过不去就是 403。和发现页一套流程：过验证 → 补抓 → 重试。
  Future<void> _verify() async {
    final results = _results;
    if (results == null || _verifying) return;
    final baseUrl = verifyBaseUrl(widget.source, results.error);
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (baseUrl.isEmpty || host.isEmpty) return;
    setState(() => _verifying = true);
    try {
      final solved = await AppDevice.solveChallenge(baseUrl, host);
      if (!mounted) return;
      if (solved == null) {
        _tell('没有拿到通行 cookie，可以再点一次「去验证」');
        return;
      }
      final pending = await _repository.pendingWebPages();
      final blocked = await _repository.blockedUrl(host);
      final urls = [
        ...pending,
        if (blocked.isNotEmpty && !pending.contains(blocked)) blocked,
      ];
      await _repository.saveChallenge(
        host,
        solved.cookie,
        userAgent: solved.userAgent,
      );
      if (!mounted) return;
      await primeVerifyPages(_repository, urls, host);
      if (!mounted) return;
      await results.reload(force: true);
      for (var round = 0; round < 2 && results.error.isNotEmpty; round++) {
        if (!mounted) return;
        if (!await primePendingAfterFailure(_repository, host)) break;
        if (!mounted) return;
        await results.reload(force: true);
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  void _tell(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        duration: const Duration(milliseconds: 1800),
        content: Text(text),
      ),
    );
  }

  void _changed(String text) {
    _debounce?.cancel();
    final query = text.trim();
    final generation = ++_suggestion;
    if (!widget.source.searchSuggestions || query.isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final items = await _repository.suggestions(widget.source.id, query);
        if (mounted && generation == _suggestion) {
          setState(() => _suggestions = items);
        }
      } catch (_) {}
    });
  }

  void _open(Drama drama) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama),
  );

  @override
  Widget build(BuildContext context) {
    final field = SearchField(
      hint: '在 ${widget.source.name} 中搜索',
      controller: _controller,
      focusNode: _focus,
      autofocus: widget.query.isEmpty,
      onChanged: _changed,
      onSubmitted: _submit,
      letterKeyboard: widget.store.televisionKeyboard,
      matches: widget.source.searchSuggestions
          ? (query) => _repository.suggestions(widget.source.id, query)
          : null,
    );
    if (AppScope.of(context).television) {
      return Scaffold(
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                televisionInset,
                27,
                televisionInset,
                0,
              ),
              child: field,
            ),
            Expanded(child: FadeSwitcher(child: _body(context))),
          ],
        ),
      );
    }
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        titleSpacing: 0,
        titleWidget: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: field,
        ),
      ),
      // SafeArea 已经让出顶栏高度，再叠 kToolbarHeight 会多出空白。
      body: SafeArea(
        top: true,
        bottom: false,
        child: FadeSwitcher(child: _body(context)),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final television = AppScope.of(context).television;
    if (_suggestions.isNotEmpty && _controller.text.trim() != _submitted) {
      return ListView(
        key: const ValueKey('suggest'),
        padding: television
            ? const EdgeInsets.fromLTRB(televisionInset, 8, televisionInset, 27)
            : const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final (index, item) in _suggestions.indexed)
            EnterOnce(
              key: ValueKey(index),
              id: item,
              played: _shownSuggestions,
              index: index,
              child: TileFocus(
                builder: (focusNode) => ListTile(
                  focusNode: focusNode,
                  leading: const Icon(Icons.search_rounded),
                  title: Text(item),
                  onTap: () => _submit(item),
                ),
              ),
            ),
        ],
      );
    }
    final results = _results;
    if (results == null) {
      return KeyedSubtree(
        key: const ValueKey('recent'),
        child: _recent(context),
      );
    }
    if (results.items.isEmpty) {
      if (results.loading) {
        return const StatusView.loading(
          key: ValueKey('loading'),
          title: '正在搜索',
        );
      }
      if (results.error.isNotEmpty) {
        final needsVerify =
            verifyBaseUrl(widget.source, results.error).isNotEmpty &&
            needsBrowserVerify(results.error);
        final message = needsVerify
            ? '${results.error}\n点「去验证」在应用内完成一次验证，通过后会自动重试。'
            : results.error;
        return StatusView(
          key: const ValueKey('error'),
          title: '搜索失败',
          message: message,
          // 与发现页 / 详情页一致：把「N 秒后重试」做成真的倒计时，到 0 自动重试。
          messageChild: RetryCountdown(
            text: message,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            onExpired: () => results.reload(force: true),
          ),
          icon: Icons.cloud_off_rounded,
          action: needsVerify ? (_verifying ? '验证中…' : '去验证') : '重试',
          onAction: needsVerify
              ? (_verifying ? null : () => unawaited(_verify()))
              : () => results.reload(force: true),
        );
      }
      return StatusView(
        key: const ValueKey('empty'),
        title: '没有找到「$_submitted」',
        message: '换个关键词试试',
        icon: Icons.search_off_rounded,
      );
    }
    final inset = television
        ? televisionInset
        : AppScope.formFactorOf(context) == FormFactor.phone
        ? 16.0
        : 24.0;
    return LayoutBuilder(
      key: ValueKey(('results', _submitted)),
      builder: (context, constraints) => AutoLoadMore(
        feed: results,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                television ? 16 : 8,
                inset,
                0,
              ),
              sliver: DramaSliverGrid(
                width: constraints.maxWidth - inset * 2,
                items: results.items,
                autofocus: television,
                heroScope: 'drama',
                onOpen: _open,
                onMore: (drama) => quickFollow(context, widget.store, drama),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                8,
                inset,
                television ? 27 : 16,
              ),
              sliver: SliverToBoxAdapter(child: FeedFooter(feed: results)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recent(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final recent = widget.store.recentSearches;
      return FadeSwitcher(child: _recentContent(context, recent));
    },
  );

  Widget _recentContent(BuildContext context, List<String> recent) {
    if (recent.isEmpty) {
      return StatusView(
        key: const ValueKey('empty'),
        title: '在 ${widget.source.name} 中搜索',
        message: '输入剧名或关键词',
        icon: Icons.search_rounded,
      );
    }
    final theme = Theme.of(context);
    return ListView(
      key: const ValueKey('recent'),
      padding: AppScope.of(context).television
          ? const EdgeInsets.fromLTRB(televisionInset, 8, televisionInset, 27)
          : const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '最近搜索',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            FocusRing(
              radius: 999,
              child: TextButton(
                onPressed: () => widget.store.clearRecentSearches().catchError(
                  (Object _) {},
                ),
                child: const Text('清空'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AnimatedSize(
          duration: Motion.of(context, Motion.medium),
          curve: Motion.enter,
          alignment: Alignment.topLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final query in recent)
                FocusRing(
                  radius: 8,
                  child: GestureDetector(
                    onLongPress: () => _forget(query),
                    onSecondaryTap: () => _forget(query),
                    child: ActionChip(
                      avatar: const Icon(Icons.history_rounded, size: 16),
                      label: Text(query),
                      onPressed: () => _submit(query),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
