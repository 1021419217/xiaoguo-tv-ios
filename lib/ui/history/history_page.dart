import 'package:flutter/material.dart';

import '../../cover_shape.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_modules.dart';
import '../../watch_history.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../settings/settings_rows.dart';
import '../widgets/action_pill.dart';
import '../widgets/bar_button.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/swipe_category_layer.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../widgets/frosted_header.dart';
import '../widgets/glass_app_bar.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/drama_grid.dart';
import '../widgets/drama_tile.dart';
import '../widgets/focus_ring.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/search_field.dart';
import '../widgets/status_view.dart';

typedef _View = ({
  List<WatchEntry> history,
  List<SourceSite> sources,
  String source,
  List<WatchEntry> shown,
  Set<String>? selection,
});

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    required this.store,
    this.root = false,
    this.headerChild,
  });
  final LocalStore store;
  final bool root;

  /// 由外层的「追剧 / 最近观看 / 下载」容器传入的分段胶囊，占用标题位置。
  final Widget? headerChild;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _query = TextEditingController();
  final _firstPoster = FocusNode();
  final _editButton = FocusNode();
  final _searchField = FocusNode();
  final _entered = <Object>{};
  var _source = '';
  Set<String>? _selection;

  @override
  void initState() {
    super.initState();
    if (!widget.root) _keepFocus(_firstPoster);
  }

  @override
  void dispose() {
    _query.dispose();
    _firstPoster.dispose();
    _editButton.dispose();
    _searchField.dispose();
    super.dispose();
  }

  void _keepFocus(FocusNode target, [FocusNode? fallback]) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !AppScope.of(context).television) return;
        final focused = FocusManager.instance.primaryFocus;
        if (focused != null && focused is! FocusScopeNode) return;
        for (final node in [target, ?fallback]) {
          if (node.context?.mounted ?? false) {
            revealFocus(node);
            return;
          }
        }
      });

  void _startEditing() {
    setState(() => _selection = {});
    _keepFocus(_firstPoster);
  }

  void _finishEditing() {
    setState(() => _selection = null);
    _keepFocus(_editButton);
  }

  void _toggle(String id) => setState(() {
    final selection = {...?_selection};
    if (!selection.remove(id)) selection.add(id);
    _selection = selection;
  });

  Future<void> _remove(Set<String> ids, {required bool clear}) async {
    if (ids.isEmpty) return;
    final confirmed = await showGlassDialog(
      context: context,
      title: clear ? '清空观看记录？' : '删除 ${ids.length} 条观看记录？',
      message: clear
          ? '将删除当前列出的 ${ids.length} 条观看记录，追剧不受影响。'
          : '追剧不受影响。',
      confirmLabel: clear ? '清空' : '删除',
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    await saveSetting(context, () => widget.store.removeHistory(ids));
    if (!mounted) return;
    setState(() => _selection = null);
    _keepFocus(_firstPoster, _searchField);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.store, _query]),
    builder: (context, _) {
      final history = widget.store.history;
      final sources = watchedSources(history);
      final source = sources.any((site) => site.id == _source) ? _source : '';
      final shown = _shownFor(history, source);
      final view = (
        history: history,
        sources: sources,
        source: source,
        shown: shown,
        selection: _selection?.intersection({
          for (final entry in shown) entry.drama.id,
        }),
      );
      return PopScope(
        canPop: _selection == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _finishEditing();
        },
        child: switch (AppScope.formFactorOf(context)) {
          FormFactor.phone => _phone(context, view),
          FormFactor.pad || FormFactor.window => _wide(context, view),
          FormFactor.television => _television(context, view),
        },
      );
    },
  );

  Set<String> _ids(_View view) => {
    for (final entry in view.shown) entry.drama.id,
  };

  /// 按站源 + 搜索词过滤观看记录。
  /// 真 PageView 要求每页独立算自己的列表，不能共用当前选中站源那一份。
  List<WatchEntry> _shownFor(List<WatchEntry> history, String sourceId) => [
    for (final entry in history)
      if ((sourceId.isEmpty || entry.drama.source == sourceId) &&
          matchesWatchTitle(entry, _query.text))
        entry,
  ];

  Widget _search({double height = 40, FocusNode? focusNode}) => SearchField(
    hint: '搜索观看记录',
    controller: _query,
    focusNode: focusNode,
    height: height,
    onSubmitted: (_) {},
    letterKeyboard: widget.store.televisionKeyboard,
    matches: (query) async => {
      for (final entry in widget.store.history)
        if (matchesWatchTitle(entry, query)) entry.drama.title,
    }.toList(),
  );

  /// 顶栏操作统一成 [ActionPill]：和追剧、下载、模块页同一套胶囊语言。
  /// 顶部操作收成图标按钮：原来两个带文字的胶囊挤在一行，占位太多。
  List<Widget> _browseActions(_View view) => [
    BarButton(
      icon: Icons.check_box_outlined,
      tooltip: '编辑',
      onPressed: view.shown.isEmpty ? null : _startEditing,
    ),
    BarButton(
      icon: Icons.delete_sweep_outlined,
      tooltip: '清空',
      onPressed: view.shown.isEmpty
          ? null
          : () => _remove(_ids(view), clear: true),
    ),
  ];

  Widget _selectAll(_View view) {
    final all = _ids(view);
    final everything = view.selection!.length == all.length;
    return ActionPill(
      icon: Icons.select_all_rounded,
      label: everything ? '取消全选' : '全选',
      onPressed: () => setState(() => _selection = everything ? {} : all),
    );
  }

  Widget _deleteButton(_View view) {
    final colors = Theme.of(context).colorScheme;
    final selection = view.selection!;
    return FocusRing(
      radius: 21,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: colors.onPrimary,
          minimumSize: const Size(0, 42),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        onPressed: selection.isEmpty
            ? null
            : () => _remove(selection, clear: false),
        icon: const Icon(Icons.delete_outline_rounded, size: 18),
        label: const Text('删除'),
      ),
    );
  }

  List<Widget> _editActions(_View view) => [
    _selectAll(view),
    _deleteButton(view),
    ActionPill(
      icon: Icons.done_rounded,
      label: '完成',
      onPressed: _finishEditing,
    ),
  ];

  Widget _title(_View view, double size) => Semantics(
    header: true,
    child: FadeSwitcher(
      duration: Motion.short,
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        key: ValueKey(view.selection == null),
        view.selection == null ? '观看记录' : '已选择 ${view.selection!.length} 部',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: size, fontWeight: FontWeight.w800),
      ),
    ),
  );

  Widget _trailing(_View view, Widget search, {double spacing = 8}) =>
      FadeSwitcher(
        duration: Motion.short,
        alignment: AlignmentDirectional.centerEnd,
        child: Row(
          key: ValueKey(view.selection == null),
          mainAxisSize: MainAxisSize.min,
          spacing: spacing,
          children: view.selection == null
              ? [search, ..._browseActions(view)]
              : _editActions(view),
        ),
      );

  Widget _sourceChip(String id, String label, _View view) => FocusRing(
    radius: 8,
    child: ChoiceChip(
      key: ValueKey('history-source-$id'),
      label: Text(label),
      showCheckmark: false,
      selected: view.source == id,
      onSelected: (_) => setState(() => _source = id),
    ),
  );

  Widget? _sources(_View view, {required double inset, bool scroll = false}) {
    if (view.sources.length < 2) return null;
    final chips = [
      _sourceChip('', '全部', view),
      for (final site in view.sources) _sourceChip(site.id, site.name, view),
    ];
    if (scroll) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(inset, 4, inset, 8),
        child: Row(spacing: 8, children: chips),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 4, inset, 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    );
  }

  /// 首页同款下划线分类条，替代原来的紫色 ChoiceChip。
  /// 站源筛选本质就是分类切换，没理由和首页长两套样子。
  Widget _sourceTabs(_View view) => CategoryTabs<String>(
    options: [
      const ChoiceOption('', '全部'),
      for (final site in view.sources) ChoiceOption(site.id, site.name),
    ],
    selected: view.source,
    onSelected: (id) => setState(() => _source = id),
  );

  /// 左右滑动切换下方「站源」分类，与追剧页、下载页的手势保持一致。
  /// 与追剧、首页同一套横滑层：相邻两页同屏、1:1 跟手。
  ///
  /// [buildPage] 每页各算一次自己的列表——真 PageView 相邻两页同屏，
  /// 必须各自持有本页数据，不能共用「当前选中站源」那一份。
  Widget _swipe(
    _View view,
    Widget Function(_View page, {bool focused}) buildPage,
  ) {
    if (view.selection != null) return buildPage(view, focused: true);
    final ids = ['', for (final site in view.sources) site.id];
    var index = ids.indexOf(view.source);
    if (index < 0) index = 0;
    return SwipeCategoryLayer(
      itemCount: ids.length,
      index: index,
      labels: ['全部', for (final site in view.sources) site.name],
      onIndexChanged: (next) => setState(() => _source = ids[next]),
      hintTop: 8,
      itemBuilder: (context, i) {
        final id = ids[i];
        return buildPage(
          (
            history: view.history,
            sources: view.sources,
            source: id,
            shown: _shownFor(view.history, id),
            selection: null,
          ),
          focused: id == view.source,
        );
      },
    );
  }

  Widget _phone(BuildContext context, _View view) {
    final selection = view.selection;
    final root = widget.root;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        titleSpacing: 16,
        leading: !root
            ? null
            : selection == null
            ? null
            : IconButton(
                tooltip: '退出编辑',
                onPressed: _finishEditing,
                icon: const Icon(Icons.close_rounded),
              ),
        titleWidget: FadeSwitcher(
          duration: Motion.short,
          alignment: AlignmentDirectional.centerStart,
          child: selection == null && widget.headerChild != null
              ? widget.headerChild!
              : GlassTitle(
                  key: ValueKey(selection == null),
                  title: selection == null
                      ? '观看记录'
                      : '已选择 ${selection.length} 部',
                ),
        ),
        actions: [
          FadeSwitcher(
            duration: Motion.short,
            alignment: AlignmentDirectional.centerEnd,
            child: Row(
              key: ValueKey(selection == null),
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: selection == null
                  ? _browseActions(view)
                  : [_selectAll(view)],
            ),
          ),
          const SizedBox(width: 20),
        ],
      ),
      // SafeArea 已让出「状态栏 + 磨砂顶栏」，不再叠 kToolbarHeight。
      body: Stack(
        children: [
          SafeArea(
            top: true,
            bottom: false,
            child: _content(
              context,
              view,
              inset: 16,
              // 不要再加 top: kToolbarHeight——extendBodyBehindAppBar 下
              // Scaffold 已把它算进 MediaQuery.padding.top，SafeArea 让出的
              // 那一截里就含顶栏高度，再补一次会空出一大块。
              swipe: true,
              header: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: _search(),
                ),
                _sourceTabs(view),
              ],
            ),
          ),
          if (selection != null && selection.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 80 + 8,
              child: Center(child: _deleteButton(view)),
            ),
        ],
      ),
    );
  }

  Widget _wide(BuildContext context, _View view) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: _content(
        context,
        view,
        inset: 24,
        header: [
          LayoutBuilder(
            builder: (context, constraints) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 24, 8),
              child: SizedBox(
                height: 48,
                child: Row(
                  spacing: 8,
                  children: [
                    ToggleIconSwitcher(
                      child: view.selection == null
                          ? widget.root
                                ? const SizedBox(key: ValueKey(false), width: 8)
                                : const BackButton(key: ValueKey(false))
                          : IconButton(
                              key: const ValueKey(true),
                              tooltip: '退出编辑',
                              onPressed: _finishEditing,
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                    Expanded(child: widget.headerChild ?? _title(view, 28)),
                    _trailing(
                      view,
                      SizedBox(
                        width: (constraints.maxWidth - 400).clamp(160.0, 280.0),
                        child: _search(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ?_sources(view, inset: 24),
        ],
      ),
    ),
  );

  Widget _television(BuildContext context, _View view) => Scaffold(
    body: SafeArea(
      child: _content(
        context,
        view,
        inset: televisionInset,
        top: 27,
        header: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              televisionInset,
              0,
              televisionInset,
              8,
            ),
            child: SizedBox(
              height: 48,
              child: Row(
                spacing: 12,
                children: [
                  Expanded(child: widget.headerChild ?? _title(view, 24)),
                  _trailing(
                    view,
                    SizedBox(
                      width: 260,
                      child: _search(focusNode: _searchField),
                    ),
                    spacing: 12,
                  ),
                ],
              ),
            ),
          ),
          ?_sources(view, inset: televisionInset),
        ],
      ),
    ),
  );

  (int, double, double) _grid(BuildContext context, double width) {
    switch (AppScope.formFactorOf(context)) {
      case FormFactor.phone:
        return (3, 10, 20);
      case FormFactor.television:
        return (6, 20, 24);
      case FormFactor.pad || FormFactor.window:
        final desktop = AppScope.formFactorOf(context) == FormFactor.window;
        final minimum = desktop ? 140.0 : 120.0;
        final gap = desktop ? 18.0 : 16.0;
        final columns = ((width + gap) / (minimum + gap)).floor().clamp(1, 99);
        return (columns, gap, desktop ? 22 : 20);
    }
  }

  Widget _content(
    BuildContext context,
    _View view, {
    required double inset,
    double top = 0,
    required List<Widget> header,
    bool swipe = false,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth - inset * 2;
      final (columns, gap, runGap) = _grid(context, width);
      final tile = (width - gap * (columns - 1)) / columns;

      // 一页 = 一个站源的全部记录。真 PageView 相邻两页同屏，所以整页
      // （分时段标题、海报归属、空状态）都得按本页自己的列表重算。
      // focused 只给当前选中的那页，否则多页会同时挂同一个 firstPoster。
      Widget page(_View v, {bool focused = false}) {
      final masonry =
          AppScope.formFactorOf(context) == FormFactor.phone &&
          v.shown.any((entry) => CoverShapes.isMixed(entry.drama.source));
      final now = DateTime.now();
      final periods = <WatchPeriod, List<WatchEntry>>{};
      for (final entry in v.shown) {
        periods
            .putIfAbsent(WatchPeriod.of(entry.updatedAt, now), () => [])
            .add(entry);
      }
      final heroOwner = {
        for (final MapEntry(key: id, value: index) in firstIndexById(
          v.shown,
          (entry) => entry.drama.id,
        ).entries)
          id: v.shown[index],
      };
      final first = v.shown.firstOrNull;
      return ValueListenableBuilder<int>(
        valueListenable: CoverShapes.revision,
        builder: (context, _, _) => CustomScrollView(
          // 每页独立保存滚动位置，来回翻不会跳回顶部。
          key: PageStorageKey('history-page-${v.source}'),
          slivers: [
          if (v.shown.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: FadeSwitcher(
                scale: true,
                child: StatusView(
                  key: ValueKey(v.history.isEmpty),
                  title: v.history.isEmpty ? '还没有观看记录' : '没有匹配的记录',
                  message: v.history.isEmpty
                      ? missingSourceHint(
                          widget.store.missingSourceRecords().history,
                          '条观看记录',
                        )
                      : null,
                  icon: v.history.isEmpty
                      ? Icons.history_rounded
                      : Icons.search_off_rounded,
                ),
              ),
            )
          else
            for (final MapEntry(key: period, value: entries)
                in periods.entries) ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset + 4, 12, inset, 10),
                sliver: SliverToBoxAdapter(
                  child: Semantics(
                    header: true,
                    child: Text(
                      period.label,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: masonry
                    ? PosterMasonry(
                        key: ValueKey(
                          Object.hashAll([
                            for (final entry in entries) entry.drama.id,
                          ]),
                        ),
                        width: width,
                        count: entries.length,
                        heightAt: (index, cellWidth) => ProgressPoster.extentFor(
                          context,
                          cellWidth,
                          aspect: posterAspect(
                            entries[index].drama.source,
                            entries[index].drama.id,
                          ),
                          date: true,
                        ),
                        itemBuilder: (context, index, cellWidth) {
                          final entry = entries[index];
                          return Focus(
                            key: ValueKey(entry.drama.id),
                            canRequestFocus: false,
                            skipTraversal: true,
                            onKeyEvent: (_, event) => wrapGridRow(
                              index,
                              2,
                              entries.length,
                              event,
                            ),
                            child: EnterOnce(
                              id: entry.drama.id,
                              played: _entered,
                              index: index,
                              child: _poster(
                                context,
                                entry,
                                cellWidth,
                                v.selection,
                                focusNode: focused && entry == first ? _firstPoster : null,
                                hero: focused &&
                                    identical(heroOwner[entry.drama.id], entry),
                                aspect: posterAspect(
                                  entry.drama.source,
                                  entry.drama.id,
                                ),
                                date: entry.updatedAt,
                              ),
                            ),
                          );
                        },
                      )
                    : SliverGrid.builder(
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                              crossAxisSpacing: gap,
                              mainAxisSpacing: runGap,
                              mainAxisExtent: ProgressPoster.extentFor(
                                context,
                                tile,
                              ),
                            ),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return Focus(
                            key: ValueKey(entry.drama.id),
                            canRequestFocus: false,
                            skipTraversal: true,
                            onKeyEvent: (_, event) => wrapGridRow(
                              index,
                              columns,
                              entries.length,
                              event,
                            ),
                            child: EnterOnce(
                              id: entry.drama.id,
                              played: _entered,
                              index: index,
                              child: _poster(
                                context,
                                entry,
                                tile,
                                v.selection,
                                focusNode: focused && entry == first ? _firstPoster : null,
                                hero: focused &&
                                    identical(heroOwner[entry.drama.id], entry),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: AppScope.of(context).television ? 27 : 32,
            ),
          ),
          ],
        ),
      );
      }
      // 顶栏留在滑动层外面，横滑切站源时标题、搜索框不跟着动。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(top: top),
            child: Column(children: header),
          ),
          Expanded(
            child: swipe ? _swipe(view, page) : page(view, focused: true),
          ),
        ],
      );
    },
  );

  Widget _poster(
    BuildContext context,
    WatchEntry entry,
    double width,
    Set<String>? selection, {
    FocusNode? focusNode,
    bool hero = false,
    double aspect = 2 / 3,
    DateTime? date,
  }) {
    final drama = entry.drama;
    final total = drama.episodes;
    final long = '看到第 ${entry.episode} 集 / 共 $total 集';
    return ProgressPoster(
      drama: drama,
      width: width,
      aspect: aspect,
      date: date == null ? null : '观看 ${watchDateLabel(date)}',
      focusNode: focusNode,
      progress: total > 0 ? entry.episode / total : 0,
      caption: total > 0 && entry.episode >= total && entry.finished
          ? '已看完'
          : total > 0 && _fits(context, long, width)
          ? long
          : '看到第 ${entry.episode} 集',
      tag: SourceSite.byId(drama.source).name,
      heroScope: hero ? 'drama' : null,
      selected: selection?.contains(drama.id),
      onTap: selection == null
          ? () => openPage<void>(
              context,
              (_) => DetailPage(store: widget.store, drama: drama),
            )
          : () => _toggle(drama.id),
      onMore: selection == null
          ? () => setState(() => _selection = {drama.id})
          : null,
    );
  }

  bool _fits(BuildContext context, String text, double width) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.copyWith(
          fontSize: AppScope.of(context).television ? 13 : 12,
          height: 1.3,
        ),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final fits = painter.width <= width - 4;
    painter.dispose();
    return fits;
  }
}
