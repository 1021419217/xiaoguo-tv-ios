import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_modules.dart';
import '../app_scope.dart';
import '../settings/settings_rows.dart';
import 'module_export.dart';
import 'module_install.dart';
import '../settings/sorani_account_view.dart';
import '../widgets/action_pill.dart';
import '../widgets/bar_button.dart';
import '../widgets/capsule_tabs.dart';
import '../widgets/focus_ring.dart';
import '../widgets/form_text_field.dart';
import '../widgets/group_card.dart';
import '../widgets/glass_dialog.dart';

class ModulesPage extends StatefulWidget {
  const ModulesPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<ModulesPage> createState() => _ModulesPageState();
}

ModuleIndexEntry? _updateFor(SourceModule module, ModuleIndexEntry? entry) =>
    entry != null &&
        module.error.isEmpty &&
        // 手动装的版本由用户自己负责更新，不再拿内置/仓库的高版本来提示。
        !module.pinned &&
        isNewerModuleVersion(entry.version, module.version)
    ? entry
    : null;

List<SourceModule> _arranged(List<SourceModule> modules, List<String> order) {
  final byId = {for (final module in modules) module.id: module};
  final result = <SourceModule>[];
  for (final id in order) {
    final module = byId.remove(id);
    if (module != null) result.add(module);
  }
  result.addAll(byId.values);
  return result;
}

Map<String, String> _missingSources(
  LocalStore store,
  AppRepository repository,
) {
  final records = store.missingSourceRecords();
  final downloads = repository.missingSourceDownloads();
  final sources = {
    ...records.follows.keys,
    ...records.history.keys,
    ...downloads.keys,
  }.toList()..sort();
  String describe(String source) => [
    if (records.follows[source] case final count?) '追剧 $count 部',
    if (records.history[source] case final count?) '观看记录 $count 条',
    if (downloads[source] case final count?) '下载 $count 集',
  ].join('，');
  return {for (final source in sources) source: describe(source)};
}

class _ModulesPageState extends State<ModulesPage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 5, vsync: this)
    ..addListener(_tabChanged);
  List<SourceModule>? _modules;
  List<String>? _moving;
  String? _error;
  bool _testing = false;
  Map<String, int?> _latency = const {};
  ModuleStore? _index;
  String? _indexError;
  ModuleStore? _personalIndex;
  String? _personalIndexError;
  /// 个人仓库索引的拉取时间：用来在页面上显示「索引更新于 X 分钟前」，
  /// 让用户能判断是「索引本身旧了」还是「真的没有新版本」。
  DateTime? _personalIndexAt;
  bool _busy = false;

  LocalStore get _store => widget.store;

  AppRepository get _repository => AppScope.of(context).repository;

  bool get _canInstall => _store.profile.admin && !_store.locked && !_busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _loadIndex();
      _loadPersonalIndex();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _tabChanged() {
    if (!_tabs.indexIsChanging) setState(() {});
  }

  Future<void> _refresh() async {
    try {
      final modules = await _repository.modules();
      if (mounted) {
        setState(() {
          _modules = [
            for (final module in modules)
              if (module.id != 'supjav') module,
          ];
          _error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    }
  }

  Future<void> _loadIndex({bool notify = false}) async {
    setState(() {
      _index = null;
      _indexError = null;
    });
    try {
      final index = await _repository.moduleIndex();
      if (mounted) {
        setState(
          () => _index = ModuleStore(
            [
              for (final entry in index.entries)
                if (entry.id != 'supjav') entry,
            ],
            warning: index.warning,
          ),
        );
        if (notify) _toastRefresh(_index?.entries.length ?? 0, null);
      }
    } catch (failure) {
      if (mounted) setState(() => _indexError = '$failure');
      if (mounted && notify) _toastRefresh(0, '$failure');
    }
  }

  /// 刷新完给个明确反馈：以前点完界面毫无变化，用户以为按钮坏了。
  void _toastRefresh(int total, String? failure, {int? updatable}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Text(
          failure == null
              ? (updatable == null
                  ? '已刷新：仓库 $total 个模块'
                  : '已刷新：$total 个模块，$updatable 个可更新')
              : '刷新失败：$failure',
        ),
      ),
    );
  }

  Future<void> _loadPersonalIndex({bool notify = false}) async {
    setState(() {
      _personalIndex = null;
      _personalIndexError = null;
    });
    try {
      final index = await _repository.personalModuleIndex();
      if (mounted) {
        setState(
          () => _personalIndex = ModuleStore(
            [
              for (final entry in index.entries)
                if (entry.id != 'supjav') entry,
            ],
            warning: index.warning,
          ),
        );
        _personalIndexAt = DateTime.now();
        if (notify) {
          final entries = _personalIndex?.entries ?? const [];
          final updatable = entries.where((entry) {
            final installed = installedVersionOf(entry.id);
            return installed != null && installed != entry.version;
          }).length;
          _toastRefresh(entries.length, null, updatable: updatable);
        }
      }
    } catch (failure) {
      if (mounted) setState(() => _personalIndexError = '$failure');
      if (mounted && notify) _toastRefresh(0, '$failure');
    }
  }

  /// 「刚刚 / X 分钟前 / X 小时前」
  static String _agoText(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }

  /// 比较两个 `x.y.z` 版本号：a 比 b 新返回 1，旧返回 -1，相同返回 0。
  static int _compareVersion(String a, String b) {
    final left = a.split('.');
    final right = b.split('.');
    for (var i = 0; i < 3; i++) {
      final x = int.tryParse(i < left.length ? left[i] : '0') ?? 0;
      final y = int.tryParse(i < right.length ? right[i] : '0') ?? 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }

  /// 「在线」标签只显示还能装的：排除内置条目和已安装的模块。
  /// 装完一个就少一个，和页面里实际列出的卡片数一致，不会像总数那样误导。
  int _onlineCount() {
    final installed = {for (final module in _modules ?? const []) module.id};
    return (_index?.entries ?? const <ModuleIndexEntry>[])
        .where((entry) => !entry.bundled && !installed.contains(entry.id))
        .length;
  }

  void _show(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 800),
        ),
      );
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } catch (failure) {
      _show('$failure');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _installIndexed(
    ModuleIndexEntry entry, {
    bool personal = false,
  }) => _run(
    () async => _install(
      personal
          ? await _repository.preparePersonalModule(indexed: entry.id)
          : await _repository.prepareModule(
              indexed: entry.id,
              bundled: entry.bundled,
            ),
    ),
  );

  Future<void> _install(SourceModule module) async {
    if (!mounted) return;
    final accepted = await showGlassCard<bool>(
      context: context,
      title: _moduleDialogTitle(module, true),
      content: _moduleDetails(context, module, install: true),
      actions: [
        GlassAction(
          label: '取消',
          onPressed: () => Navigator.pop<bool>(context, false),
        ),
        GlassAction(
          label: module.installed ? '更新' : '安装',
          primary: true,
          onPressed: () => Navigator.pop<bool>(context, true),
        ),
      ],
    );
    if (accepted != true) return;
    _show(await _applyInstall(module) ?? '${module.name} 已安装');
  }

  Future<String?> _applyInstall(SourceModule module) =>
      applyModuleInstall(_repository, _store, module);

  Future<void> _installFile() => _run(() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (file == null) return;
    var location = file.path;
    if (location == null) {
      final size = await file.length();
      if (size == null || size > 8 * 1024 * 1024) {
        throw AppFailure('安装包过大或无法读取');
      }
      location = path.join(
        (await getApplicationCacheDirectory()).path,
        'module-picked.zip',
      );
      await File(location).writeAsBytes(await file.readAsBytes());
    }
    await _install(await _repository.prepareModule(file: location));
  });

  Future<void> _installAddress() async {
    final address = await showDialog<String>(
      context: context,
      builder: (_) => const _AddressDialog(),
    );
    if (address == null || address.isEmpty) return;
    await _run(
      () async => _install(await _repository.prepareModule(url: address)),
    );
  }

  Future<void> _uninstall(SourceModule module) async {
    final accepted = await showGlassDialog(
      context: context,
      title: '卸载 ${module.name}？',
      message: '该站源的追剧、观看记录和已下载视频会保留，但在重新安装前不再显示，正在下载的集会暂停。',
      confirmLabel: '卸载',
      danger: true,
    );
    if (accepted != true) return;
    await _run(() async {
      if (_repository.supportsDownloads && SourceSite.isAvailable(module.id)) {
        await _repository.controlDownloads('pauseSource', id: module.id);
      }
      await _repository.uninstallModule(module.id);
      _show('${module.name} 已卸载');
    });
  }

  Future<void> _export(List<SourceModule> modules) => _run(() async {
    final name = await saveModuleArchive(_repository, [
      for (final module in modules) module.id,
    ]);
    if (name == null) return;
    _show(modules.length > 1 ? '已导出 ${modules.length} 个模块：$name' : '已导出：$name');
  });

  Future<void> _toggle(SourceModule module, bool value) {
    final repository = _repository;
    return saveSetting(context, () async {
      await _store.setSourceEnabled(module.id, value);
      if (!value && repository.supportsDownloads) {
        await repository.controlDownloads('pauseSource', id: module.id);
      }
    });
  }

  Future<void> _details(SourceModule module) => showGlassCard<void>(
    context: context,
    title: module.name,
    content: _moduleDetails(context, module, install: false),
    actions: [
      GlassAction(label: '关闭', onPressed: () => Navigator.pop<void>(context)),
    ],
  );

  Widget _list(List<Widget> children) => ListView.separated(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
    itemCount: children.length,
    itemBuilder: (_, index) => children[index],
    separatorBuilder: (_, _) => const SizedBox(height: 6),
  );

  Widget _installedTab() {
    final loaded = _modules;
    final modules = loaded == null
        ? null
        : _arranged(loaded, _moving ?? _store.sourceOrder);
    final enabled = _canInstall;
    final latest = <String, ModuleIndexEntry>{};
    // 「已安装」页的可更新判断必须同时看官方索引和个人仓库：
    // 以前只遍历 _index，个人仓库里的新版本完全不参与比较，
    // 表现就是「同步了模块但已安装页永远显示已是最新」。
    for (final entry in [
      ...?_index?.entries,
      ...?_personalIndex?.entries,
    ]) {
      final current = latest[entry.id];
      if (current == null ||
          isNewerModuleVersion(entry.version, current.version)) {
        latest[entry.id] = entry;
      }
    }
    Widget card(SourceModule module) => _InstalledCard(
      module: module,
      latency: _latency[module.id],
      tested: _latency.containsKey(module.id),
      update: _updateFor(module, latest[module.id]),
      enabled: _store.sourceEnabled(module.id),
      onToggle:
          _store.profile.admin &&
              module.error.isEmpty &&
              SourceSite.isAvailable(module.id)
          ? (value) => _toggle(module, value)
          : null,
      admin: _store.profile.admin,
      onDetails: () => _details(module),
      onUpdate: enabled ? () => _installIndexed(latest[module.id]!) : null,
      onUninstall: enabled ? () => _uninstall(module) : null,
      onExport: _busy ? null : () => _export([module]),
    );
    final header = <Widget>[
      if (_error case final error?) _Note(error),
    ];
    if (modules == null || modules.isEmpty) {
      return _list([
        ...header,
        if (modules == null && _error == null)
          const _Loading()
        else
          const _Note('还没有安装模块。站源以模块的形式提供，可以从在线仓库、内置或手动安装。'),
      ]);
    }
    if (!_store.profile.admin || _store.locked) {
      return _list([...header, for (final module in modules) card(module)]);
    }
    // 顶部这些卡片要跟着列表一起滚（以前放在 Column 里固定住，
    // 往下滑时它们占着上半屏不动，可滚区域被挤得很小）。
    final topCards = <Widget>[
      if (header.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(spacing: 10, children: header),
        ),
      // 原先这里是两张整块 SettingsCard（各占一行图标+标题+副标题+箭头），
      // 加起来一百多像素高。改成一行两个按钮，节省了大部分纵向空间。
      if (!_store.locked)
        Padding(
          // 上下留白对称：Tab 栏自带 10px 底距，这里补 2px 凑成 12；
          // 下方给 12px，与 header 归零后的间距一致，不再「上空下紧」。
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _runSpeedTest,
                  icon: _testing
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed_rounded, size: 18),
                  label: Text(
                    _testing
                        ? '测源中…'
                        : (_latency.isEmpty
                              ? '站源测速'
                              : '重测 ${_latency.length} 个'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _export(modules),
                  icon: const Icon(Icons.archive_outlined, size: 18),
                  label: const Text(
                    '导出模块',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
    // 顶部卡片作为列表 header，跟着一起滚
    return ReorderableListView.builder(
            header: Padding(
              padding: EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: topCards,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            buildDefaultDragHandles: false,
            itemCount: modules.length,
            onReorder: _reorder,
            proxyDecorator: (child, _, animation) => ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.03).animate(animation),
              child: Material(type: MaterialType.transparency, child: child),
            ),
            itemBuilder: (context, index) {
              final module = modules[index];
              return ReorderableDelayedDragStartListener(
                key: ValueKey(module.id),
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: card(module),
                ),
              );
            },
    );
  }

  Future<void> _runSpeedTest() async {
    if (_testing) return;
    final repository = AppScope.of(context).repository;
    final sites = _store.permittedSources;
    setState(() {
      _testing = true;
      _latency = const {};
    });
    final results = <String, int?>{};
    final queue = [...sites];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final site = queue.removeAt(0);
        final watch = Stopwatch()..start();
        try {
          await repository
              .categories(site.id, force: true)
              .timeout(const Duration(seconds: 8));
          results[site.id] = watch.elapsedMilliseconds;
        } catch (_) {
          results[site.id] = null;
        }
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _latency = results;
    });
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final loaded = _modules;
    if (loaded == null) return;
    final modules = _arranged(loaded, _moving ?? _store.sourceOrder);
    if (oldIndex < 0 || oldIndex >= modules.length) return;
    if (newIndex > oldIndex) newIndex--;
    final ids = [for (final module in modules) module.id];
    ids.insert(newIndex.clamp(0, ids.length), ids.removeAt(oldIndex));
    setState(() => _moving = ids);
    await saveSetting(context, () => _store.setSourceOrder(ids));
    if (mounted) setState(() => _moving = null);
  }

  /// 本地已安装的版本；没装过返回 null。
  String? installedVersionOf(String id) {
    for (final module in _modules ?? const <SourceModule>[]) {
      if (module.id == id) return module.version;
    }
    return null;
  }

  Widget _catalogTab({required bool bundled, bool personal = false}) {
    final enabled = _canInstall;
    final source = personal ? _personalIndex : _index;
    final sourceError = personal ? _personalIndexError : _indexError;
    final installed = {for (final module in _modules ?? const []) module.id};
    // 被用户手动锁定版本的模块，在「内置」分类里仍然列出，方便装回内置版本。
    final pinned = {
      for (final module in _modules ?? const [])
        if (module.pinned) module.id,
    };
    final missing = _missingSources(_store, _repository);
    final warning = bundled ? '' : source?.warning ?? '';
    final listed = [
      for (final entry in source?.entries ?? const <ModuleIndexEntry>[])
        if (entry.bundled == bundled) entry,
    ];
    final entries =
        [
          for (final entry in listed)
            // 个人在线是「自己的备份仓库」，已装过的也要列出来：
            // 既能看到手上有哪些，也能随时重装/更新，不能像在线仓库那样滤掉。
            if (personal ||
                !installed.contains(entry.id) ||
                bundled && pinned.contains(entry.id))
            entry,
        ]..sort((a, b) {
          int rank(ModuleIndexEntry entry) {
            // 0 = 仓库版本比已装的新（最该处理，排最前）
            final have = personal ? installedVersionOf(entry.id) : null;
            if (have != null && _compareVersion(entry.version, have) > 0) {
              return 0;
            }
            if (missing.containsKey(entry.id)) return 1;
            return 2;
          }

          final byRank = rank(a).compareTo(rank(b));
          if (byRank != 0) return byRank;
          return a.name.compareTo(b.name);
        });
    return _list([
      if (personal && _personalIndexAt != null)
        _Note(
          '索引更新于 ${_agoText(_personalIndexAt!)}'
          '${sourceError == null ? ' · 共 ${source?.entries.length ?? 0} 个模块' : ''}'
          '（raw GitHub 有 5 分钟缓存，刚同步完的模块请等几分钟再刷新）',
        ),
      if (warning.isNotEmpty) _Note(warning),
      if (sourceError ?? _error case final error?)
        _Note(error)
      else if (source == null || _modules == null)
        const _Loading()
      else if (listed.isEmpty && warning.isEmpty)
        _Note(
          bundled
              ? '这个安装包没有内置模块。'
              : personal
              ? '个人仓库里还没有模块。'
              : '仓库里还没有模块。',
        )
      else if (entries.isEmpty && listed.isNotEmpty)
        _Note(
          bundled
              ? '内置模块都已安装。'
              : personal
              ? '个人仓库的模块都已安装。'
              : '仓库里的模块都已安装。',
        )
      else
        for (final entry in entries)
          _IndexCard(
            entry: entry,
            records: missing[entry.id],
            restoreBuiltin: bundled && pinned.contains(entry.id),
            installedVersion: personal ? installedVersionOf(entry.id) : null,
            onInstall: enabled
                ? () => _installIndexed(entry, personal: personal)
                : null,
          ),
    ]);
  }

  Widget _manualTab() {
    final enabled = _canInstall;
    return _list([
      GroupCard(
        children: [
          SettingsTile(
            title: '选择本地文件',
            enabled: enabled,
            onTap: enabled ? _installFile : null,
          ),
        ],
      ),
      GroupCard(
        children: [
          SettingsTile(
            title: '输入下载地址',
            enabled: enabled,
            onTap: enabled ? _installAddress : null,
          ),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('模块'),
        actions: [
          if (_tabs.index == 2 || _tabs.index == 3)
            BarButton(
              icon: Icons.refresh_rounded,
              tooltip: '刷新',
              onPressed: _tabs.index == 3
                  ? (_personalIndex == null && _personalIndexError == null
                      ? null
                      : () => _loadPersonalIndex(notify: true))
                  : (_index == null && _indexError == null
                      ? null
                      : () => _loadIndex(notify: true)),
            ),
          const SizedBox(width: 12),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            // 左右 16 与下方按钮/卡片对齐；五个分类等分铺满整行，不靠轨道留白。
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: SizedBox(
              width: double.infinity,
              child: CapsuleTabs(
                // 五个分类固定、数量有限：等分铺满整行，字号也可以放大，
                // 比上一版「拉伸轨道但内容靠左、右边空一截」更整齐。
                expand: true,
                fontSize: 13.5,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                labels: [
                  '已安装 ${_modules?.length ?? 0}',
                  '导入',
                  '在线 ${_onlineCount()}',
                  '个人仓库 ${_personalIndex?.entries.length ?? 0}',
                  '内置',
                ],
                index: _tabs.index,
                animation: _tabs.animation,
                onChanged: (index) {
                  if (index == _tabs.index) return;
                  _tabs.animateTo(index);
                  setState(() {});
                },
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _installedTab(),
                _manualTab(),
                _catalogTab(bundled: false),
                _catalogTab(bundled: false, personal: true),
                _catalogTab(bundled: true),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.name,
    required this.adult,
    required this.version,
    required this.id,
    required this.body,
    this.trailing,
    this.leading = const [],
    this.actions = const [],
    this.onTap,
  });
  final String name;
  final bool adult;
  final String version;
  final String id;
  final List<Widget> body;
  final Widget? trailing;
  final List<Widget> leading;
  final List<Widget> actions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final meta = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
      fontSize: 12,
      height: 1.3,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
    );
    final footer = leading.isNotEmpty || actions.isNotEmpty;
    final trimmed = name.trim();
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surfaceContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(14, 9, 10, footer ? 6 : 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Monogram(
                      text: trimmed.isEmpty
                          ? '?'
                          : trimmed.substring(0, 1).toUpperCase(),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ModuleTitle(name, adult: adult),
                          const SizedBox(height: 1),
                          Text(
                            'v${version.isEmpty ? '—' : version}  ·  $id',
                            style: meta,
                          ),
                          if (body.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            DefaultTextStyle.merge(
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 12,
                                height: 1.3,
                                fontWeight: FontWeight.w500,
                                color: colors.onSurfaceVariant,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: 1,
                                children: body,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
              if (footer) ...[
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: colors.outlineVariant,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 5, 14, 6),
                  child: Row(
                    spacing: 8,
                    children: [...leading, const Spacer(), ...actions],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 模块首字母方块：36 见方、12 圆角、极淡玻璃底 + 一圈细描边。
/// 比彩色图标块安静，也不会和「限制级」这类状态标记抢注意力。
class _Monogram extends StatelessWidget {
  const _Monogram({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ink.withValues(alpha: 0.10)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
          color: ink.withValues(alpha: 0.86),
        ),
      ),
    );
  }
}

/// 状态标记：只有描边和弱化的字，不用红底，避免整页被一行红块切碎。
class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ink.withValues(alpha: 0.18)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          height: 1.35,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: ink.withValues(alpha: 0.62),
        ),
      ),
    );
  }
}

ButtonStyle _cardButton(ColorScheme colors, {bool primary = false}) =>
    FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 13),
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: primary
          ? colors.primaryContainer
          : colors.surfaceContainerHighest.withValues(alpha: 0.5),
      foregroundColor: primary ? colors.onPrimaryContainer : colors.onSurface,
    );

class _InstalledCard extends StatelessWidget {
  const _InstalledCard({
    required this.module,
    required this.update,
    required this.enabled,
    required this.onToggle,
    required this.admin,
    required this.onDetails,
    required this.onUpdate,
    required this.onUninstall,
    required this.onExport,
    this.latency,
    this.tested = false,
  });
  final SourceModule module;
  final ModuleIndexEntry? update;
  final int? latency;
  final bool tested;
  final bool enabled;
  final ValueChanged<bool>? onToggle;
  final bool admin;
  final VoidCallback onDetails;
  final VoidCallback? onUpdate;
  final VoidCallback? onUninstall;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ModuleCard(
      name: module.name,
      adult: module.adult,
      version: module.version,
      id: module.id,
      body: [
        if (module.error.isNotEmpty)
          Text(module.error, style: TextStyle(color: colors.error))
        else ...[
          if (module.description.isNotEmpty)
            Text(
              module.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if (module.pinned)
            Row(
              spacing: 4,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 13,
                  color: colors.onSurface.withValues(alpha: .7),
                ),
                Text(
                  '手动安装 · 已锁定版本',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface.withValues(alpha: .75),
                  ),
                ),
              ],
            ),
          if (update case final update?)
            Row(
              spacing: 4,
              children: [
                Icon(
                  Icons.arrow_upward_rounded,
                  size: 13,
                  color: colors.onSurface.withValues(alpha: 0.9),
                ),
                Text(
                  '可更新到 ${update.version}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          if (tested)
            Row(
              spacing: 4,
              children: [
                Icon(
                  Icons.speed_rounded,
                  size: 13,
                  color: latency == null
                      ? colors.error
                      : colors.onSurfaceVariant,
                ),
                Text(
                  latency == null ? '连接失败' : '${latency}ms',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: latency == null
                        ? colors.error
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
        ],
      ],
      trailing: FocusRing(
        radius: 20,
        child: Switch(value: enabled, onChanged: onToggle),
      ),
      onTap: onDetails,
      // 次要操作靠左（导出、账号），主操作与破坏性操作靠右（更新、卸载）：
      // 三枚胶囊等宽等高、留白一致，卡片底部不再出现「一枚按钮贴边、
      // 另一枚悬在中间」的松散感。
      leading: [
        ActionPill(
          icon: Icons.ios_share_rounded,
          label: '导出',
          onPressed: onExport,
        ),
        if (module.id == 'sorani' && soraniAccountAvailable())
          SoraniAccountButton(admin: admin, style: _cardButton(colors)),
      ],
      actions: [
        if (update != null)
          ActionPill(
            icon: Icons.arrow_circle_up_outlined,
            label: '更新',
            tone: ActionTone.accent,
            onPressed: onUpdate,
          ),
        ActionPill(
          icon: Icons.delete_outline_rounded,
          label: '卸载',
          tone: ActionTone.danger,
          onPressed: onUninstall,
        ),
      ],
    );
  }
}

class _IndexCard extends StatelessWidget {
  const _IndexCard({
    required this.entry,
    required this.records,
    required this.onInstall,
    this.restoreBuiltin = false,
    this.installedVersion,
  });
  final ModuleIndexEntry entry;
  final String? records;
  final VoidCallback? onInstall;
  final bool restoreBuiltin;

  /// 本地已装的版本；不为空时按钮显示「重装 / 更新」，个人在线页用它
  /// 区分哪些模块手里已经有了。
  final String? installedVersion;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ModuleCard(
      name: entry.name,
      adult: entry.adult,
      version: entry.version,
      id: entry.id,
      body: [
        if (installedVersion case final version?)
          Text(
            version == entry.version
                ? '已安装 v$version'
                : '已安装 v$version，仓库是 v${entry.version}',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        if (restoreBuiltin)
          Text(
            '当前使用手动安装的版本，装回内置版会解除版本锁定',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        if (entry.description.isNotEmpty)
          Text(entry.description, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (records != null)
          Text(
            '待恢复：$records',
            style: TextStyle(color: colors.onSurface.withValues(alpha: .85)),
          ),
      ],
      trailing: Padding(
        padding: const EdgeInsets.only(top: 2, left: 8),
        child: ActionPill(
          icon: restoreBuiltin
              ? Icons.restore_rounded
              : installedVersion == null
              ? Icons.download_rounded
              : Icons.refresh_rounded,
          label: restoreBuiltin
              ? '恢复内置版'
              : installedVersion == null
              ? '安装'
              : installedVersion == entry.version
              ? '重装'
              : '更新',
          tone: ActionTone.accent,
          onPressed: onInstall,
        ),
      ),
    );
  }
}

class _ModuleTitle extends StatelessWidget {
  const _ModuleTitle(this.text, {required this.adult});
  final String text;
  final bool adult;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontSize: 16.5,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      height: 1.25,
    );
    if (!adult) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return Row(
      spacing: 7,
      children: [
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        const _Tag('限制级'),
      ],
    );
  }
}

String _moduleDialogTitle(SourceModule module, bool install) => !install
    ? module.name
    : module.installed
    ? '更新 ${module.name}？'
    : '安装 ${module.name}？';

/// 模块详情正文：安装确认与「查看详情」共用同一份，原来各写了一遍。
Widget _moduleDetails(
  BuildContext context,
  SourceModule module, {
  required bool install,
}) {
  final text = Theme.of(context).textTheme;
  final version = module.version.isEmpty ? '未标注' : module.version;
  final capabilities = [
    for (final name in module.capabilities)
      moduleCapabilityNames[name] ?? name,
  ];
  Widget section(String title, String body) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text(title, style: text.labelLarge),
        Text(body),
      ],
    ),
  );
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (module.description.isNotEmpty) Text(module.description),
      section(
        '版本',
        install && module.installed
            ? '${module.previous.isEmpty ? '未标注' : module.previous} → $version'
            : version,
      ),
      section('标识', module.id),
      section('内容分级', module.adult ? '限制级' : '非限制级'),
      section('可访问的域名', module.hosts.isEmpty ? '无' : module.hosts.join('\n')),
      section('提供的功能', ['目录、详情和播放', ...capabilities].join('、')),
    ],
  );
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) => GlassDialogCard(
    title: '从地址安装',
    content: FormTextField(
      controller: _controller,
      autofocus: true,
      url: true,
      decoration: const InputDecoration(hintText: 'https://…/module.zip'),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      GlassAction(
        label: '取消',
        onPressed: () => Navigator.pop<String>(context),
      ),
      GlassAction(label: '下一步', primary: true, onPressed: _submit),
    ],
  );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(24),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        height: 1.6,
      ),
    ),
  );
}
