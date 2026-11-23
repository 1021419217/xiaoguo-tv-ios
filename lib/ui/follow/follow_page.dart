import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cover_shape.dart';
import '../../follow_list.dart';
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
import '../widgets/drama_grid.dart';
import '../widgets/drama_tile.dart';
import '../widgets/focus_ring.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/page_header.dart';
import '../widgets/search_field.dart';
import '../widgets/status_view.dart';

typedef _View = ({
  List<Drama> follows,
  List<SourceSite> sources,
  String source,
  List<Drama> shown,
  Set<String>? selection,
});

class FollowPage extends StatefulWidget {
  const FollowPage({
    super.key,
    required this.store,
    required this.entryFocus,
    required this.onExitUp,
    this.headerChild,
    this.standalone = false,
  });
  final LocalStore store;
  final FocusNode entryFocus;
  final VoidCallback onExitUp;
  final bool standalone;

  /// 由外层的「追剧 / 最近观看 / 下载」容器传入的分段胶囊，占用标题位置。
  final Widget? headerChild;

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage> {
  final _query = TextEditingController();
  final _editButton = FocusNode();
  final _entered = <Object>{};
  var _source = '';
  Set<String>? _selection;

  @override
  void dispose() {
    _query.dispose();
    _editButton.dispose();
    super.dispose();
  }

  void _keepFocus(FocusNode target) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !AppScope.of(context).television) return;
        final focused = FocusManager.instance.primaryFocus;
        if (focused != null && focused is! FocusScopeNode) return;
        if (target.context?.mounted ?? false) {
          revealFocus(target);
        } else {
          widget.onExitUp();
        }
      });

  void _startEditing() {
    setState(() => _selection = {});
    _keepFocus(widget.entryFocus);
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

  void _open(Drama drama) {
    if (widget.store.following(drama.id)?.hasUpdates ?? false) {
      saveSetting(context, () => widget.store.markUpdatesRead(drama.id));
    }
    openPage<void>(
      context,
      (_) => DetailPage(store: widget.store, drama: drama),
    );
  }

  Future<void> _unfollow(Set<String> ids) async {
    if (ids.isEmpty) return;
    final confirmed = await showGlassDialog(
      context: context,
      title: '取消追剧 ${ids.length} 部？',
      message: '观看记录会保留。',
      confirmLabel: '取消追剧',
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    await saveSetting(context, () => widget.store.removeFavorites(ids));
    if (!mounted) return;
    setState(() => _selection = null);
    _keepFocus(widget.entryFocus);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.store, _query]),
    builder: (context, _) {
      final follows = widget.store.favorites;
      final sources = followedSources(follows);
      final source = sources.any((site) => site.id == _source) ? _source : '';
      final shown = _shownFor(follows, source);
      final view = (
        follows: follows,
        sources: sources,
        source: source,
        shown: shown,
        selection: _selection?.intersection({
          for (final drama in shown) drama.id,
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

  Set<String> _ids(_View view) => {for (final drama in view.shown) drama.id};

  Widget _search({FocusNode? focusNode}) => SearchField(
    hint: '搜索追剧',
    controller: _query,
    focusNode: focusNode,
    onSubmitted: (_) {},
    letterKeyboard: widget.store.televisionKeyboard,
    matches: (query) async => {
      for (final drama in widget.store.favorites)
        if (matchesFollowTitle(drama, query)) drama.title,
    }.toList(),
  );

  /// 顶栏操作统一成 [ActionPill]，和下载页、模块页同一套胶囊。
  Widget _editButtonFor(_View view) => BarButton(
    icon: Icons.check_box_outlined,
    tooltip: '编辑',
    onPressed: view.shown.isEmpty ? null : _startEditing,
  );

  Widget _selectAll(_View view) {
    final all = _ids(view);
    final everything = view.selection!.length == all.length;
    return ActionPill(
      icon: Icons.select_all_rounded,
      label: everything ? '取消全选' : '全选',
      onPressed: () => setState(() => _selection = everything ? {} : all),
    );
  }

  Widget _unfollowButton(_View view) {
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
        onPressed: selection.isEmpty ? null : () => _unfollow(selection),
        icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
        label: const Text('取消追剧'),
      ),
    );
  }

  List<Widget> _editActions(_View view) => [
    _selectAll(view),
    _unfollowButton(view),
    ActionPill(
      icon: Icons.done_rounded,
      label: '完成',
      onPressed: _finishEditing,
    ),
  ];

  Widget _title(String text, double size) => Semantics(
    header: true,
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: size, fontWeight: FontWeight.w800),
    ),
  );

  Widget _sourceChip(String id, String label, _View view) => FocusRing(
    radius: 8,
    child: ChoiceChip(
      key: ValueKey('follow-source-$id'),
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
  Widget _sourceTabs(_View view) => CategoryTabs<String>(
    options: [
      const ChoiceOption('', '全部'),
      for (final site in view.sources) ChoiceOption(site.id, site.name),
    ],
    selected: view.source,
    onSelected: (id) => setState(() => _source = id),
  );

  /// 左右滑动切换下方「站源」分类（全部 → 各站源）。
  /// 注意只包住**列表本身**：顶栏、搜索框、站源胶囊留在滑动层外面，
  /// 否则一滑整个追剧画面（标题、搜索框、卡片）一起位移，看着就是在抖。
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
            follows: view.follows,
            sources: view.sources,
            source: id,
            shown: _shownFor(view.follows, id),
            selection: null,
          ),
          // 只有当前选中页才接管 entryFocus，否则多页会抢同一个 FocusNode。
          focused: id == view.source,
        );
      },
    );
  }

  Widget _phone(BuildContext context, _View view) {
    final selection = view.selection;
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: _content(
              context,
              view,
              inset: 16,
              swipe: true,
              header: [
                FadeSwitcher(
                  child: selection == null
                      ? PageHeader(
                          key: const ValueKey(false),
                          title: '追剧',
                          titleChild: widget.headerChild,
                          leading: widget.standalone
                              ? IconButton(
                                  tooltip: '返回',
                                  onPressed: () => Navigator.maybePop(context),
                                  icon: const Icon(Icons.arrow_back_rounded),
                                )
                              : null,
                          actions: [_editButtonFor(view)],
                        )
                      : PageHeader(
                          key: const ValueKey(true),
                          title: '已选择 ${selection.length} 部',
                          actions: [
                            _selectAll(view),
                            ActionPill(
                              icon: Icons.done_rounded,
                              label: '完成',
                              onPressed: _finishEditing,
                            ),
                          ],
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
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
              child: Center(child: _unfollowButton(view)),
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
                child: FadeSwitcher(
                  child: view.selection == null
                      ? Padding(
                          key: const ValueKey(false),
                          padding: const EdgeInsets.only(left: 12),
                          child: Row(
                            spacing: 8,
                            children: [
                              Expanded(
                                child: widget.headerChild ?? _title('追剧', 28),
                              ),
                              SizedBox(
                                width: (constraints.maxWidth - 400).clamp(
                                  160.0,
                                  280.0,
                                ),
                                child: _search(),
                              ),
                              _editButtonFor(view),
                            ],
                          ),
                        )
                      : Row(
                          key: const ValueKey(true),
                          spacing: 8,
                          children: [
                            IconButton(
                              tooltip: '退出编辑',
                              onPressed: _finishEditing,
                              icon: const Icon(Icons.close_rounded),
                            ),
                            Expanded(
                              child: _title(
                                '已选择 ${view.selection!.length} 部',
                                28,
                              ),
                            ),
                            ..._editActions(view),
                          ],
                        ),
                ),
              ),
            ),
          ),
          ?_sources(view, inset: 24),
        ],
      ),
    ),
  );

  Widget _television(BuildContext context, _View view) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, event) {
      if (event is KeyUpEvent ||
          event.logicalKey != LogicalKeyboardKey.arrowUp) {
        return KeyEventResult.ignored;
      }
      final moved = FocusManager.instance.primaryFocus?.focusInDirection(
        TraversalDirection.up,
      );
      if (moved != true) widget.onExitUp();
      return KeyEventResult.handled;
    },
    child: Scaffold(
      body: SafeArea(
        top: false,
        child: _content(
          context,
          view,
          inset: televisionInset,
          top: 14,
          header: [
            if (widget.headerChild != null && view.selection == null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  televisionInset,
                  0,
                  televisionInset,
                  8,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: widget.headerChild,
                ),
              ),
            if (view.follows.isNotEmpty || view.selection != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  televisionInset,
                  0,
                  televisionInset,
                  8,
                ),
                child: SizedBox(
                  height: 48,
                  child: FadeSwitcher(
                    child: Row(
                      key: ValueKey(view.selection == null),
                      spacing: 12,
                      children: view.selection == null
                          ? [
                              SizedBox(
                                width: 260,
                                child: _search(
                                  focusNode: view.shown.isEmpty
                                      ? widget.entryFocus
                                      : null,
                                ),
                              ),
                              const Spacer(),
                              _editButtonFor(view),
                            ]
                          : [
                              Expanded(
                                child: _title(
                                  '已选择 ${view.selection!.length} 部',
                                  24,
                                ),
                              ),
                              ..._editActions(view),
                            ],
                    ),
                  ),
                ),
              ),
            ?_sources(view, inset: televisionInset),
          ],
        ),
      ),
    ),
  );

  /// 按站源 + 搜索词过滤追剧列表。
  /// 真 PageView 要求每一页独立算出自己的列表，不能再共用当前选中站源的结果。
  List<Drama> _shownFor(List<Drama> follows, String sourceId) => [
    for (final drama in follows)
      if ((sourceId.isEmpty || drama.source == sourceId) &&
          matchesFollowTitle(drama, _query.text))
        drama,
  ];

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

      // 一页 = 一个站源的全部内容。真 PageView 相邻两页同屏，所以整页
      // （分区标题、海报归属、空状态）都得按本页自己的列表重算。
      // focused 只给当前选中的那页，否则多页会同时挂同一个 entryFocus。
      Widget page(_View v, {bool focused = false}) {
      final masonry =
          AppScope.formFactorOf(context) == FormFactor.phone &&
          v.shown.any((drama) => CoverShapes.isMixed(drama.source));
      final updated = [
        for (final drama in v.shown)
          if (widget.store.following(drama.id)?.hasUpdates ?? false) drama,
      ];
      final rest = [
        for (final drama in v.shown)
          if (!updated.contains(drama)) drama,
      ];
      final sections = <(String?, List<Drama>)>[
        if (updated.isNotEmpty) ('有更新', updated),
        if (rest.isNotEmpty) (updated.isEmpty ? null : '其他追剧', rest),
      ];
      final heroOwner = {
        for (final MapEntry(key: id, value: index) in firstIndexById(
          v.shown,
          (drama) => drama.id,
        ).entries)
          id: v.shown[index],
      };
      final first = v.shown.isEmpty
          ? null
          : (updated.firstOrNull ?? rest.first);
      return ValueListenableBuilder<int>(
        valueListenable: CoverShapes.revision,
        builder: (context, _, _) => CustomScrollView(
          // 每页独立保存滚动位置，来回翻不会跳回顶部。
          key: PageStorageKey('follow-page-${v.source}'),
          slivers: [
          if (v.shown.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: FadeSwitcher(
                scale: true,
                child: StatusView(
                  key: ValueKey(v.follows.isEmpty),
                  title: v.follows.isEmpty ? '还没有追剧' : '没有匹配的追剧',
                  message: v.follows.isEmpty
                      ? missingSourceHint(
                          widget.store.missingSourceRecords().follows,
                          '部追剧',
                        )
                      : null,
                  icon: v.follows.isEmpty
                      ? Icons.bookmark_border_rounded
                      : Icons.search_off_rounded,
                ),
              ),
            )
          else
            for (final (label, dramas) in sections) ...[
              if (label != null)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset + 4, 12, inset, 10),
                  sliver: SliverToBoxAdapter(
                    child: Semantics(
                      header: true,
                      child: Text.rich(
                        TextSpan(
                          text: label,
                          children: [
                            TextSpan(
                              text: '  ${dramas.length}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  label == null ? 12 : 0,
                  inset,
                  0,
                ),
                sliver: masonry
                    ? PosterMasonry(
                        key: ValueKey(
                          Object.hashAll([
                            for (final drama in dramas) drama.id,
                          ]),
                        ),
                        width: width,
                        count: dramas.length,
                        heightAt: (index, cellWidth) {
                          final drama = dramas[index];
                          return ProgressPoster.extentFor(
                            context,
                            cellWidth,
                            aspect: posterAspect(drama.source, drama.id),
                            date: widget.store.watched(drama.id) != null,
                          );
                        },
                        itemBuilder: (context, index, cellWidth) {
                          final drama = dramas[index];
                          return Focus(
                            key: ValueKey(drama.id),
                            canRequestFocus: false,
                            skipTraversal: true,
                            onKeyEvent: (_, event) => wrapGridRow(
                              index,
                              2,
                              dramas.length,
                              event,
                            ),
                            child: EnterOnce(
                              id: drama.id,
                              played: _entered,
                              index: index,
                              child: _poster(
                                context,
                                drama,
                                cellWidth,
                                v.selection,
                                focusNode: focused && drama == first
                                    ? widget.entryFocus
                                    : null,
                                hero: focused &&
                                    identical(heroOwner[drama.id], drama),
                                aspect: posterAspect(drama.source, drama.id),
                                date: widget.store.watched(drama.id)?.updatedAt,
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
                        itemCount: dramas.length,
                        itemBuilder: (context, index) {
                          final drama = dramas[index];
                          return Focus(
                            key: ValueKey(drama.id),
                            canRequestFocus: false,
                            skipTraversal: true,
                            onKeyEvent: (_, event) => wrapGridRow(
                              index,
                              columns,
                              dramas.length,
                              event,
                            ),
                            child: EnterOnce(
                              id: drama.id,
                              played: _entered,
                              index: index,
                              child: _poster(
                                context,
                                drama,
                                tile,
                                v.selection,
                                focusNode: focused && drama == first
                                    ? widget.entryFocus
                                    : null,
                                hero: focused &&
                                    identical(heroOwner[drama.id], drama),
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
      // 顶栏固定在上方，滑动层只包列表：横滑切站源时标题与搜索框纹丝不动。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(top: top),
            child: Column(children: header),
          ),
          Expanded(child: swipe ? _swipe(view, page) : page(view, focused: true)),
        ],
      );
    },
  );

  Widget _poster(
    BuildContext context,
    Drama drama,
    double width,
    Set<String>? selection, {
    FocusNode? focusNode,
    bool hero = false,
    double aspect = 2 / 3,
    DateTime? date,
  }) {
    final watch = widget.store.watched(drama.id);
    final state = widget.store.following(drama.id);
    final total = drama.episodes;
    final String caption;
    if (watch == null) {
      caption = total > 0 ? '未观看 · 共 $total 集' : '未观看';
    } else if (total > 0 && watch.episode >= total && watch.finished) {
      caption = '已看完';
    } else {
      final long = '看到第 ${watch.episode} 集 / 共 $total 集';
      caption = total > 0 && _fits(context, long, width)
          ? long
          : '看到第 ${watch.episode} 集';
    }
    return ProgressPoster(
      drama: drama,
      width: width,
      aspect: aspect,
      date: date == null ? null : '观看 ${watchDateLabel(date)}',
      focusNode: focusNode,
      progress: watch != null && total > 0 ? watch.episode / total : 0,
      caption: caption,
      tag: SourceSite.byId(drama.source).name,
      heroScope: hero ? 'drama' : null,
      badge: state != null && state.hasUpdates
          ? '${state.newEpisodes} 集更新'
          : null,
      selected: selection?.contains(drama.id),
      onTap: selection == null ? () => _open(drama) : () => _toggle(drama.id),
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
