import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cover_shape.dart';
import '../../download_collections.dart';
import '../../download_converter.dart';
import '../../download_overview.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_modules.dart';
import '../../watch_history.dart';
import '../app_scope.dart';
import '../player/playback_handle.dart';
import '../player/playback_page.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../widgets/action_pill.dart';
import '../widgets/bar_button.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/cover_image.dart';
import '../widgets/glass_app_bar.dart';
import '../widgets/drama_grid.dart';
import '../widgets/drama_tile.dart';
import '../widgets/focus_ring.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/status_view.dart';
import 'download_actions.dart';

typedef _View = ({
  List<DownloadJob> pending,
  List<DownloadedDrama> downloaded,
  List<SourceSite> sources,
  String source,
  Set<String>? selection,
});

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    required this.store,
    required this.downloads,
    this.converter,
    this.headerChild,
  });
  final LocalStore store;
  final DownloadOverview downloads;
  /// 转换器由 AppShell 统一持有；万一没取到（刚重建等）就只显示下载进度。
  final DownloadConverter? converter;

  /// 由外层的「追剧 / 最近观看 / 下载」容器传入的分段胶囊，占用标题位置。
  /// 传入时同时把本页当作 tab 根页面处理（不显示返回箭头）。
  final Widget? headerChild;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage>
    with WidgetsBindingObserver {
  /// 一条 PageController 贯穿全部页：页 0 = 下载中，页 1..N = 已下载按站源分页。
  /// 这样从「下载中」滑到「已下载」再继续滑就是下一个站源，双向连续无断点。
  late final _tabs = PageController(initialPage: 0);
  int _page = 0;
  /// 上次已震动反馈的页（TabController→PageController 后按页去重）。
  int _vibratedPage = 0;
  /// 正在程序化翻页的目标页：期间经过的中间页不回传、不震动。
  int? _animatingTo;
  final _sources = ['', ''];
  Set<String>? _selection;
  bool _busy = false;
  final _enteredJobs = <Object>{};

  bool get _pendingTab => _page == 0;
  bool get _downloadedTab => _page >= 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.downloads.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // iOS 在后台把进程挂起后，进度不会继续推进；切回前台必须主动同步一次，
      // 否则界面停在切走那一刻的数字，看起来像「卡住不动」。
      widget.downloads.refresh();
    }
  }

  /// 扁平页停稳后同步当前页：0 = 下载中，>=1 = 已下载（索引即站源序号）。
  void _tabChanged(int index) {
    if (!mounted) return;
    // 程序化跨多页点击会经过中间页（0→5 依次报 1、2、3、4），这些不是
    // 用户意图：忽略它们，只有到达目标页才收尾，避免"点一下震四下 / 目标拉回"。
    if (_animatingTo != null) {
      if (index == _animatingTo) _animatingTo = null;
      return;
    }
    if (index == _page) return;
    // 与首页滑分类同款：每越过一个分类轻震一次。
    if (index != _vibratedPage) {
      _vibratedPage = index;
      unawaited(HapticFeedback.selectionClick());
    }
    setState(() {
      _page = index;
      _selection = null;
    });
  }

  /// 程序化翻页：跨多页时先瞬移到目标相邻页，再只动画最后一页，
  /// 途中不触发中间页回调。用户手指按下时由手势接管解除屏蔽。
  void _animateTo(int target) {
    if (!_tabs.hasClients) {
      // 宽屏/电视布局没有 PageView attach（touch=false 走 body 分支），
      // 翻页只能靠直接改 _page，不能等 client 否则会无限递归。
      if (!mounted || target == _page) return;
      if (target != _vibratedPage) {
        _vibratedPage = target;
        unawaited(HapticFeedback.selectionClick());
      }
      setState(() => _page = target);
      return;
    }
    _animatingTo = target;
    final from = _tabs.page?.round() ?? _page;
    if ((target - from).abs() > 1) {
      _tabs.jumpToPage(target > from ? target - 1 : target + 1);
    }
    unawaited(
      _tabs
          .animateToPage(
            target,
            duration: Motion.of(context, Motion.medium),
            curve: Motion.standard,
          )
          .whenComplete(() {
            if (mounted && _animatingTo == target) _animatingTo = null;
          }),
    );
  }

  /// 已下载区扁平页的站源 id 列表（含开头 ''=全部），页 k>=1 对应 [_doneOptionIds[k-1]]。
  List<String> _doneOptionIds(List<DownloadJob> jobs) => [
    '',
    for (final site in downloadSources([
      for (final job in jobs) if (job.completed) job,
    ]))
      site.id,
  ];

  /// 按扁平页独立构造数据，供 PageView 每页各自渲染、互不串数据。
  /// 页 0 = 下载中（沿用 _sources[0] 的点击筛选）；页 k>=1 = 已下载按站源分页。
  _View _viewFor(int page, List<DownloadJob> jobs) {
    final done = page >= 1;
    final sources = downloadSources(
      done
          ? [for (final job in jobs) if (job.completed) job]
          : pendingDownloads(jobs),
    );
    final options = ['', for (final site in sources) site.id];
    final wanted = done
        ? (page - 1 >= 0 && page - 1 < options.length
              ? options[page - 1]
              : '')
        : _sources[0];
    final source = sources.any((site) => site.id == wanted) ? wanted : '';
    bool shown(Drama drama) => source.isEmpty || drama.source == source;
    final pending = [
      for (final job in pendingDownloads(jobs))
        if (shown(job.drama)) job,
    ];
    final downloaded = [
      for (final drama in downloadedDramas(jobs))
        if (shown(drama.drama)) drama,
    ];
    return (
      pending: pending,
      downloaded: downloaded,
      sources: sources,
      source: source,
      selection: _selection?.intersection(
        done
            ? {for (final item in downloaded) item.drama.id}
            : {for (final job in pending) job.id},
      ),
    );
  }

  /// 由扁平页号直接构造内容：页 0 渲染下载中，其余渲染已下载网格。
  Widget _pageOf(BuildContext context, int page, List<DownloadJob> jobs) {
    final view = _viewFor(page, jobs);
    return page == 0
        ? _pendingList(context, view)
        : _downloadedGrid(context, view);
  }

  void _toggle(String id) => setState(() {
    final selection = {...?_selection};
    if (!selection.remove(id)) selection.add(id);
    _selection = selection;
  });

  /// 已下载点封面直接播：续上次看到的那一集，没记录就看第一集。
  /// 想选别的集在播放页里切，不再先跳一层列表让用户点第二次。
  Future<void> _playDownloaded(DownloadedDrama item) async {
    if (item.episodes.isEmpty) return;
    final watch = widget.store.watched(item.drama.id);
    var index = 0;
    if (watch != null) {
      final found = item.episodes.indexWhere(
        (job) => job.episode.number == watch.episode,
      );
      if (found >= 0) index = found;
    }
    final episode = item.episodes[index].episode;
    final position = watch?.episode == episode.number && !watch!.finished
        ? watch.position
        : 0.0;
    final handle = PlaybackHandle(
      repository: AppScope.of(context).repository,
      store: widget.store,
      detail: DramaDetail(item.drama, [
        for (final job in item.episodes) job.episode,
      ]),
      index: index,
      position: position,
      preopen: widget.store.playbackPreferences.preopens(
        television: AppScope.of(context).television,
      ),
    );
    handle.session.start(index, position: position);
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaybackPage(store: widget.store, handle: handle),
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      await widget.downloads.refresh();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _control(DownloadJob job) => _run(
    () => AppScope.of(
      context,
    ).repository.controlDownloads(job.active ? 'pause' : 'resume', id: job.id),
  );

  void _controlAll(String command, List<DownloadJob> jobs) => _run(() async {
    final repository = AppScope.of(context).repository;
    final result = await controlDownloadJobs(repository, command, [
      for (final job in jobs) job.id,
    ]);
    if (result.failures.isNotEmpty && mounted) {
      showMessage(
        context,
        '${result.failures.length} 集未能处理：${result.failures.values.first}',
      );
    }
  });

  Future<void> _cancel(Set<String> ids) async {
    if (ids.isEmpty ||
        !await confirmRemoval(
          context,
          title: '取消下载 ${ids.length} 集？',
          message: '已下载的部分会一起删除。',
          action: '取消下载',
        ) ||
        !mounted) {
      return;
    }
    await _run(() => removeDownloads(context, ids.toList(), done: '已取消下载'));
    if (mounted) setState(() => _selection = null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.store,
      widget.downloads,
      if (widget.converter case final converter?) converter,
      _tabs,
    ]),
    builder: (context, _) {
      final jobs = widget.downloads.jobs;
      // 下载中 + 已下载各站源处在同一条 PageView：页 0 = 下载中，
      // 页 1..N = 已下载按站源分页。从「下载中」滑到「已下载」再继续滑
      // 就是下一个站源，反向同理，分类之间没有断点。
      final doneOptions = _doneOptionIds(jobs);
      final count = 1 + doneOptions.length;
      // 站源数量会随下载完成/删除变化，夹紧当前页并纠正控制器位置。
      if (_page > count - 1) {
        final corrected = count - 1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _page = corrected);
        });
      }
      final index = _page.clamp(0, count - 1);
      final view = _viewFor(index, jobs);
      final body = !widget.downloads.available
          ? const StatusView(
              title: '当前用户没有下载权限',
              icon: Icons.lock_outline_rounded,
            )
          : _pageOf(context, index, jobs);
      final touch = switch (AppScope.formFactorOf(context)) {
        FormFactor.phone || FormFactor.pad => true,
        _ => false,
      };
      // 多选编辑态禁用滑动，避免误触切页。
      final swiped = touch && widget.downloads.available
          ? NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null) {
                  _animatingTo = null; // 手指接管，作废排队中的程序化吸附
                }
                return false;
              },
              child: PageView(
                controller: _tabs,
                onPageChanged: _tabChanged,
                physics: _selection == null
                    ? const PageScrollPhysics(parent: BouncingScrollPhysics())
                    : const NeverScrollableScrollPhysics(),
                children: [
                  for (var page = 0; page < count; page++)
                    _pageOf(context, page, jobs),
                ],
              ),
            )
          : body;
      return PopScope(
        canPop: _selection == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _selection = null);
        },
        child: AppScope.formFactorOf(context) == FormFactor.phone
            ? _phone(context, view, swiped)
            : _wide(context, view, swiped),
      );
    },
  );

  /// 顶栏操作统一走 [ActionPill]：和模块页、追剧页同一套胶囊语言，
  /// 不再混用 Material 默认字按钮（主色文字、无底、高度不一致）。
  Widget _editButton(_View view) => ActionPill(
    icon: Icons.check_box_outlined,
    label: '编辑',
    onPressed: _editable(view) ? () => setState(() => _selection = {}) : null,
  );

  Widget _pauseAll(_View view) {
    final active = [
      for (final job in view.pending)
        if (job.active) job,
    ];
    return BarButton(
      icon: Icons.pause_rounded,
      tooltip: '全部暂停',
      onPressed: active.isEmpty || _busy
          ? null
          : () => _controlAll('pause', active),
    );
  }

  Widget _resumeAll(_View view) {
    final paused = [
      for (final job in view.pending)
        if (job.resumable) job,
    ];
    return BarButton(
      icon: Icons.play_arrow_rounded,
      tooltip: '全部继续',
      onPressed: paused.isEmpty || _busy
          ? null
          : () => _controlAll('resume', paused),
    );
  }

  bool _editable(_View view) => _pendingTab
      ? view.pending.isNotEmpty
      : _downloadedTab && view.downloaded.isNotEmpty;

  String _selectedTitle(Set<String> selection) =>
      '已选择 ${selection.length} ${_downloadedTab ? '部' : '集'}';

  Future<void> _removeSelected(_View view) async {
    final items = [
      for (final item in view.downloaded)
        if (view.selection!.contains(item.drama.id)) item,
    ];
    final ids = [
      for (final item in items)
        for (final job in item.episodes) job.id,
    ];
    if (ids.isEmpty ||
        !await confirmRemoval(
          context,
          title: '删除 ${items.length} 部剧？',
          message: '共 ${ids.length} 集，视频文件会一起删除。',
          action: '删除',
        ) ||
        !mounted) {
      return;
    }
    await _run(() => removeDownloads(context, ids, done: '已删除'));
    if (mounted) setState(() => _selection = null);
  }

  List<Widget> _selectionActions(_View view) => _downloadedTab
      ? [_removeSelectedButton(view)]
      : [_cancelButton(view)];

  Widget _removeSelectedButton(_View view) {
    final colors = Theme.of(context).colorScheme;
    final selection = view.selection!;
    return FocusRing(
      radius: 21,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          // 走全局 filledButtonTheme（深色=白底黑字），不跟种子色变紫。
          minimumSize: const Size(0, 42),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        onPressed: selection.isEmpty || _busy
            ? null
            : () => _removeSelected(view),
        icon: const Icon(Icons.delete_outline_rounded, size: 18),
        label: const Text('删除'),
      ),
    );
  }

  Widget _selectAll(_View view) {
    final all = _downloadedTab
        ? {for (final item in view.downloaded) item.drama.id}
        : {for (final job in view.pending) job.id};
    final everything = view.selection!.length == all.length;
    return ActionPill(
      icon: Icons.select_all_rounded,
      label: everything ? '取消全选' : '全选',
      onPressed: () => setState(() => _selection = everything ? {} : all),
    );
  }

  Widget _cancelButton(_View view) {
    final colors = Theme.of(context).colorScheme;
    final selection = view.selection!;
    return FocusRing(
      radius: 21,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          // 走全局 filledButtonTheme（深色=白底黑字），不跟种子色变紫。
          minimumSize: const Size(0, 42),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        onPressed: selection.isEmpty || _busy ? null : () => _cancel(selection),
        icon: const Icon(Icons.close_rounded, size: 18),
        label: const Text('取消下载'),
      ),
    );
  }

  /// 主标签与首页 / 追剧 / 历史同一套下划线 [CategoryTabs]。
  /// 用扁平 PageView 的连续位置驱动下划线：页 0 = 下载中、页 >=1 = 已下载，
  /// 投影到 0..1 两条主标签之间，手指拖到一半线就跟到一半。
  Widget _tabBar(double inset) {
    final pending = pendingDownloads(widget.downloads.jobs).length;
    final downloaded = downloadedDramas(widget.downloads.jobs).length;
    final options = [
      ChoiceOption(0, pending == 0 ? '下载中' : '下载中 $pending'),
      ChoiceOption(1, downloaded == 0 ? '已下载' : '已下载 $downloaded'),
    ];
    void select(int index) {
      if (index == (_page >= 1 ? 1 : 0)) return;
      setState(() => _selection = null);
      // 震动统一由 _tabChanged（onPageChanged）负责，避免点按 + 程序化翻页震两次。
      // 目标页是主标签 0/1 → 扁平页 0 或 1（已下载第一页=全部）。
      _animateTo(index == 0 ? 0 : 1);
    }

    Widget tabs(double? progress) => CategoryTabs<int>(
      options: options,
      selected: _page >= 1 ? 1 : 0,
      progress: progress,
      onSelected: select,
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      // PageController 滚动时每帧回传位置，只重建这条分类栏。
      child: AnimatedBuilder(
        animation: _tabs,
        builder: (context, _) {
          final p = _tabs.hasClients ? _tabs.page : null;
          final projected = p == null
              ? null
              : (p >= 1 ? 1.0 : (p < 0 ? 0.0 : p));
          return tabs(projected);
        },
      ),
    );
  }

  Widget _phone(BuildContext context, _View view, Widget body) {
    final selection = view.selection;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: selection == null
          ? glassAppBar(
              titleSpacing: 16,
              leading: widget.headerChild == null
                  ? IconButton(
                      tooltip: '返回',
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    )
                  : null,
              title: widget.headerChild == null ? '下载管理' : null,
              titleWidget: widget.headerChild,
              actions: [
                // 只在真的有可暂停 / 可继续的任务时才出现对应圆钮，顶栏不会
                // 常驻两枚灰着的按钮，也就给中间的胶囊标签留出了位置。
                if (_pendingTab && view.pending.isNotEmpty) ...[
                  if (view.pending.any((job) => job.active)) ...[
                    _pauseAll(view),
                    const SizedBox(width: 6),
                  ],
                  if (view.pending.any((job) => job.resumable)) ...[
                    _resumeAll(view),
                    const SizedBox(width: 6),
                  ],
                  _editButton(view),
                ],
                if (_downloadedTab && view.downloaded.isNotEmpty)
                  _editButton(view),
                const SizedBox(width: 16),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: _tabBar(0),
              ),
            )
          : glassAppBar(
              title: _selectedTitle(selection),
              leading: IconButton(
                tooltip: '退出编辑',
                onPressed: () => setState(() => _selection = null),
                icon: const Icon(Icons.close_rounded),
              ),
              actions: [_selectAll(view), const SizedBox(width: 8)],
            ),
      // SafeArea 已经让出「状态栏 + 顶栏（含标签条）」的高度，
      // 再叠 kToolbarHeight 只会多出一条空白。
      body: Stack(
        children: [
          SafeArea(
            top: true,
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sourceTabs(view, inset: 16),
                Expanded(child: body),
              ],
            ),
          ),
          if (selection != null && selection.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 80 + 8,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 10,
                  children: _selectionActions(view),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _wide(BuildContext context, _View view, Widget body) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 24, 8),
            child: SizedBox(
              height: 48,
              child: Row(
                spacing: 8,
                children: [
                  ToggleIconSwitcher(
                    child: view.selection == null
                        ? widget.headerChild != null
                              ? const SizedBox(key: ValueKey('back'), width: 8)
                              : const BackButton(key: ValueKey('back'))
                        : IconButton(
                            key: const ValueKey('close'),
                            tooltip: '退出编辑',
                            onPressed: () => setState(() => _selection = null),
                            icon: const Icon(Icons.close_rounded),
                          ),
                  ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: FadeSwitcher(
                        duration: Motion.short,
                        alignment: AlignmentDirectional.centerStart,
                        child:
                            view.selection == null && widget.headerChild != null
                            ? widget.headerChild!
                            : Text(
                                view.selection == null
                                    ? '下载'
                                    : _selectedTitle(view.selection!),
                                key: ValueKey(view.selection == null),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                      ),
                    ),
                  ),
                  if (view.selection != null || _editable(view))
                    FadeSwitcher(
                      duration: Motion.short,
                      alignment: AlignmentDirectional.centerEnd,
                      child: view.selection != null
                          ? Row(
                              key: const ValueKey('editing'),
                              mainAxisSize: MainAxisSize.min,
                              spacing: 8,
                              children: [
                                _selectAll(view),
                                ..._selectionActions(view),
                                ActionPill(
                                  icon: Icons.done_rounded,
                                  label: '完成',
                                  onPressed: () =>
                                      setState(() => _selection = null),
                                ),
                              ],
                            )
                          : _pendingTab && view.pending.isNotEmpty
                          ? Row(
                              key: const ValueKey('normal'),
                              mainAxisSize: MainAxisSize.min,
                              spacing: 8,
                              children: [
                                _pauseAll(view),
                                _resumeAll(view),
                                _editButton(view),
                              ],
                            )
                          : _downloadedTab && view.downloaded.isNotEmpty
                          ? KeyedSubtree(
                              key: const ValueKey('downloaded'),
                              child: _editButton(view),
                            )
                          : const SizedBox.shrink(key: ValueKey('none')),
                    ),
                ],
              ),
            ),
          ),
          _tabBar(24),
          const SizedBox(height: 4),
          _sourceTabs(view, inset: 24),
          Expanded(child: body),
        ],
      ),
    ),
  );

  /// 站源筛选：和首页 / 追剧 / 历史同一套下划线 [CategoryTabs]，并且常驻。
  /// 原来是「有数据才长出来」的 ChoiceChip 胶囊（外面还套了 AnimatedSize），
  /// 进页面时先空一块再弹出来，样式也和全站其它页两套观感。
  Widget _sourceTabs(_View view, {required double inset}) {
    final options = [
      const ChoiceOption('', '全部'),
      for (final site in view.sources) ChoiceOption(site.id, site.name),
    ];
    // 下载中：站源是点击筛选（列表按站源过滤），不参与横向翻页。
    if (!_downloadedTab) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        child: CategoryTabs<String>(
          key: const ValueKey('download-source-tabs-pending'),
          options: options,
          selected: view.source,
          onSelected: (id) => setState(() => _sources[0] = id),
        ),
      );
    }
    // 已下载：每个站源就是一条扁平页（页 1..N），点击直接翻页，下划线跟手。
    final selectedIndex = options.indexWhere((o) => o.value == view.source);
    void jump(int i) {
      if (i == _page - 1) return;
      setState(() => _selection = null);
      // 震动统一由 _tabChanged 负责，避免重复。站源 i → 扁平页 i+1。
      _animateTo(i + 1);
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: AnimatedBuilder(
        animation: _tabs,
        builder: (context, _) {
          final p = _tabs.hasClients ? _tabs.page : null;
          // 页 p>=1 对应站源序号 p-1， clamp 防止越界。
          final progress = p == null
              ? null
              : (p - 1).clamp(0.0, (options.length - 1).toDouble());
          return CategoryTabs<String>(
            key: const ValueKey('download-source-tabs-done'),
            options: options,
            selected: view.source,
            progress: progress,
            onSelected: (id) {
              final i = options.indexWhere((o) => o.value == id);
              if (i >= 0) jump(i);
            },
          );
        },
      ),
    );
  }

  Widget _pendingList(BuildContext context, _View view) => FadeSwitcher(
    scale: true,
    child: KeyedSubtree(
      key: ValueKey(view.pending.isEmpty),
      child: _pendingBody(context, view),
    ),
  );

  Widget _pendingBody(BuildContext context, _View view) {
    if (view.pending.isEmpty) {
      return StatusView(
        title: '没有正在下载的剧集',
        message: _missingHint(context),
        icon: Icons.download_rounded,
      );
    }
    final phone = AppScope.formFactorOf(context) == FormFactor.phone;
    final inset = phone ? 16.0 : 24.0;
    final counts = <String, int>{};
    for (final job in view.pending) {
      counts[job.state] = (counts[job.state] ?? 0) + 1;
    }
    final summary = [
      for (final (state, label) in const [
        ('downloading', '下载中'),
        ('converting', '处理中'),
        ('queued', '等待'),
        ('paused', '已暂停'),
        ('failed', '失败'),
      ])
        if (counts[state] case final count?) '$label $count',
    ].join(' · ');
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(inset, 8, inset, 32),
      itemCount: view.pending.length + 1,
      separatorBuilder: (_, index) => SizedBox(height: index == 0 ? 4 : 8),
      itemBuilder: (context, index) => index == 0
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                summary,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          : EnterOnce(
              key: ValueKey(view.pending[index - 1].id),
              id: view.pending[index - 1].id,
              played: _enteredJobs,
              index: index - 1,
              child: _JobRow(
                key: ValueKey(view.pending[index - 1].id),
                job: view.pending[index - 1],
                conversion: widget.converter?.progressOf(
                  view.pending[index - 1].id,
                ),
                selected: view.selection?.contains(view.pending[index - 1].id),
                busy: _busy,
                onToggle: () => _toggle(view.pending[index - 1].id),
                onSelect: () =>
                    setState(() => _selection = {view.pending[index - 1].id}),
                onControl: () => _control(view.pending[index - 1]),
              ),
            ),
    );
  }

  String? _missingHint(BuildContext context) => missingSourceHint(
    AppScope.of(context).repository.missingSourceDownloads(),
    '集下载',
  );

  (int, double, double) _grid(BuildContext context, double width) {
    if (AppScope.formFactorOf(context) == FormFactor.phone) return (3, 10, 20);
    final desktop = AppScope.formFactorOf(context) == FormFactor.window;
    final minimum = desktop ? 140.0 : 120.0;
    final gap = desktop ? 18.0 : 16.0;
    final columns = ((width + gap) / (minimum + gap)).floor().clamp(1, 99);
    return (columns, gap, desktop ? 22 : 20);
  }

  Widget _downloadedGrid(BuildContext context, _View view) => FadeSwitcher(
    scale: true,
    child: KeyedSubtree(
      key: ValueKey(view.downloaded.isEmpty),
      child: _downloadedBody(context, view),
    ),
  );

  Widget _downloadedBody(BuildContext context, _View view) {
    if (view.downloaded.isEmpty) {
      return StatusView(
        title: '没有下载完成的剧集',
        message: _missingHint(context),
        icon: Icons.download_done_rounded,
      );
    }
    final inset = AppScope.formFactorOf(context) == FormFactor.phone
        ? 16.0
        : 24.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - inset * 2;
        final masonry =
            AppScope.formFactorOf(context) == FormFactor.phone &&
            view.downloaded.any(
              (item) => CoverShapes.isMixed(item.drama.source),
            );
        final (columns, gap, runGap) = _grid(context, width);
        final tile = (width - gap * (columns - 1)) / columns;
        DateTime? dateOf(DownloadedDrama item) {
          final watch = widget.store.watched(item.drama.id);
          if (watch != null) return watch.updatedAt;
          if (item.episodes.isEmpty) return null;
          final stamp = item.episodes
              .map((job) => job.created)
              .reduce((a, b) => a > b ? a : b);
          return stamp > 0
              ? DateTime.fromMillisecondsSinceEpoch(stamp)
              : null;
        }

        String? dateLabelOf(DownloadedDrama item) {
          final date = dateOf(item);
          if (date == null) return null;
          final watched = widget.store.watched(item.drama.id) != null;
          return '${watched ? '观看' : '下载'} ${watchDateLabel(date)}';
        }

        return ValueListenableBuilder<int>(
          valueListenable: CoverShapes.revision,
          builder: (context, _, _) {
            if (masonry) {
              return CustomScrollView(
                slivers: [
                  PosterMasonry(
                    key: ValueKey(
                      Object.hashAll([
                        for (final item in view.downloaded) item.drama.id,
                      ]),
                    ),
                    width: constraints.maxWidth,
                    count: view.downloaded.length,
                    padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
                    heightAt: (index, cellWidth) {
                      final item = view.downloaded[index];
                      return ProgressPoster.extentFor(
                        context,
                        cellWidth,
                        aspect: posterAspect(item.drama.source, item.drama.id),
                        date: dateOf(item) != null,
                      );
                    },
                    itemBuilder: (context, index, cellWidth) {
                      final item = view.downloaded[index];
                      return _downloadedPoster(
                        context,
                        item,
                        view,
                        index,
                        2,
                        cellWidth,
                        posterAspect(item.drama.source, item.drama.id),
                        dateLabelOf(item),
                      );
                    },
                  ),
                  SliverPadding(padding: const EdgeInsets.only(bottom: 32)),
                ],
              );
            }
            return GridView.builder(
              padding: EdgeInsets.fromLTRB(inset, 12, inset, 32),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: gap,
                mainAxisSpacing: runGap,
                mainAxisExtent: ProgressPoster.extentFor(context, tile),
              ),
              itemCount: view.downloaded.length,
              itemBuilder: (context, index) => _downloadedPoster(
                context,
                view.downloaded[index],
                view,
                index,
                columns,
                tile,
                2 / 3,
                null,
              ),
            );
          },
        );
      },
    );
  }

  Widget _downloadedPoster(
    BuildContext context,
    DownloadedDrama item,
    _View view,
    int index,
    int columns,
    double width,
    double aspect,
    String? date,
  ) => Focus(
    key: ValueKey(item.drama.id),
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, event) =>
        wrapGridRow(index, columns, view.downloaded.length, event),
    child: ProgressPoster(
      drama: item.drama,
      width: width,
      aspect: aspect,
      date: date,
      progress: null,
      caption: '${item.episodes.length} 集 · ${formatBytes(item.bytes)}',
      tag: SourceSite.byId(item.drama.source).name,
      badge: item.pending > 0 ? '${item.pending} 集下载中' : null,
      selected: view.selection?.contains(item.drama.id),
      onTap: view.selection != null
          ? () => _toggle(item.drama.id)
          : () => _playDownloaded(item),
      onMore: view.selection == null
          ? () => setState(() => _selection = {item.drama.id})
          : null,
    ),
  );
}

class _JobRow extends StatelessWidget {
  const _JobRow({
    super.key,
    required this.job,
    required this.conversion,
    required this.selected,
    required this.busy,
    required this.onToggle,
    required this.onSelect,
    required this.onControl,
  });
  final DownloadJob job;
  final double? conversion;
  final bool? selected;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback onSelect;
  final VoidCallback onControl;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final downloading = job.state == 'downloading';
    final failed = job.state == 'failed';
    final converted = (conversion ?? 0) > 0 ? conversion : null;
    // 进度条只表示「下载」这一段的真实进度（0-100%），不再压到 80%：
    // 压缩之后条走到头也不代表下完了，和体积对不上，看着像虚高。
    // 下载完成后文件已落盘，条保持满格，处理进度用文案单独显示。
    final overall = switch (job.state) {
      'completed' => 1.0,
      'converting' => 1.0,
      _ => job.progress,
    };
    // 每一步都摊开写：左边阶段 + 该阶段的百分比，右边体积（已下 / 总体积）。
    final state = switch (job.state) {
      'downloading' => '下载中 ${(job.progress * 100).round()}%',
      'converting' => '处理中 ${((converted ?? 0) * 100).round()}%',
      _ => job.stateLabel,
    };
    final detail = switch (job.state) {
      'failed' => job.error,
      'queued' => '',
      // 处理阶段文件已经下完，体积不再变化，直接把总体积写出来。
      'converting' => job.total > 0 ? '总计 ${formatBytes(job.total)}' : '',
      _ when job.total > 0 =>
        '${formatBytes(job.bytes)} / ${formatBytes(job.total)}',
      _ when job.bytes > 0 => '${formatBytes(job.bytes)} · 计算体积中',
      _ => '',
    };
    final secondary = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    final title = '${job.drama.title} 第 ${job.episode.number} 集';
    return Semantics(
      label: '$title，$state${detail.isEmpty ? '' : '，$detail'}',
      checked: selected,
      child: FocusRing(
        radius: 16,
        child: Material(
          color: colors.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: selected == true
                ? BorderSide(
                    color: colors.onSurface.withValues(alpha: .55),
                    width: 2,
                  )
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: selected == null ? null : onToggle,
            onLongPress: selected == null ? onSelect : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                spacing: 16,
                children: [
                  if (selected case final selected?)
                    Checkbox(value: selected, onChanged: (_) => onToggle()),
                  SizedBox(
                    width: 48,
                    height: 72,
                    child: DramaCover(
                      drama: job.drama,
                      radius: 8,
                      details: false,
                    ),
                  ),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 6,
                        children: [
                          Row(
                            spacing: 8,
                            children: [
                              Flexible(
                                child: Text(
                                  job.drama.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                '第 ${job.episode.number} 集',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              SourceTag(job.drama.source),
                            ],
                          ),
                          LinearProgressIndicator(
                            value: overall,
                            minHeight: 4,
                            borderRadius: BorderRadius.circular(2),
                            color: downloading || job.converting
                                ? null
                                : colors.outline,
                          ),
                          Row(
                            spacing: 12,
                            children: [
                              Text(
                                state,
                                style: secondary.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: failed
                                      ? colors.error
                                      : downloading || job.converting
                                      ? colors.onSurface
                                      : null,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: secondary,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (selected == null && !job.converting)
                    FocusRing(
                      radius: 20,
                      child: IconButton.filledTonal(
                        tooltip: failed
                            ? '重试'
                            : job.active
                            ? '暂停'
                            : '继续',
                        onPressed: busy ? null : onControl,
                        icon: ToggleIconSwitcher(
                          child: Icon(
                            key: ValueKey((failed, job.active)),
                            failed
                                ? Icons.refresh_rounded
                                : job.active
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
