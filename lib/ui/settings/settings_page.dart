import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../local_store.dart';
import '../../resource_settings_editor.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../theme/type_scale.dart';
import '../modules/modules_page.dart';
import '../users/users_view.dart';
import '../widgets/bar_button.dart';
import '../widgets/focus_ring.dart';
import '../widgets/frosted_header.dart';
import '../widgets/group_card.dart';
import 'appearance_settings.dart';
import 'settings_rows.dart';
import 'settings_sections.dart';

typedef _Subpage = ({String title, WidgetBuilder body});

// 设置项圆形图标的低饱和彩色，仅作视觉区分，不参与主题强调色。（全剧TV 同款）
const _tileColors = <Color>[
  Color(0xFFB06AF7),
  Color(0xFFFF9F0A),
  Color(0xFF63636B),
  Color(0xFF32ADE6),
  Color(0xFFB06AF7),
  Color(0xFFFF9F0A),
  Color(0xFF63636B),
  Color(0xFF32ADE6),
];

void openUsers(BuildContext context, LocalStore store) => openPage<void>(
  context,
  (context) => settingsSplit(context)
      ? SettingsPage(store: store, initialGroup: SettingsGroup.users)
      : Scaffold(
          appBar: AppBar(title: Text(SettingsGroup.users.label)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              UsersView(
                store: store,
                open: (title, body) => _openFullPage(context, title, body),
              ),
            ],
          ),
        ),
);

Future<void> openProxySettings(BuildContext context, LocalStore store) =>
    openPage<void>(context, (_) => _ProxySettingsPage(store: store));

class _ProxySettingsPage extends StatefulWidget {
  const _ProxySettingsPage({required this.store});
  final LocalStore store;

  @override
  State<_ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends State<_ProxySettingsPage> {
  ResourceSettingsEditor? _editor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _editor ??= ResourceSettingsEditor(
      AppScope.of(context).repository,
      widget.store,
    )..load();
  }

  @override
  void dispose() {
    _editor?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    // 与设置主页同款：磨砂顶栏 + 玻璃胶囊标题。
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      surfaceTintColor: Colors.transparent,
      flexibleSpace: const FrostedHeader(fill: true),
      leading: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: BarButton(
          icon: Icons.arrow_back_rounded,
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
        ),
      ),
      title: GlassTitle(title: SettingsGroup.proxy.label),
    ),
    body: SafeArea(
      top: true,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.only(top: kToolbarHeight),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            SettingsSection(
              group: SettingsGroup.proxy,
              store: widget.store,
              editor: _editor!,
              open: (title, body) => _openFullPage(context, title, body),
            ),
          ],
        ),
      ),
    ),
  );
}

void _openFullPage(BuildContext context, String title, WidgetBuilder body) =>
    openPage<void>(
      context,
      (context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: body(context),
      ),
    );

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    this.initialGroup = SettingsGroup.appearance,
    this.followPage,
    this.downloadsPage,
  });
  final LocalStore store;
  final SettingsGroup initialGroup;
  final WidgetBuilder? followPage;
  final WidgetBuilder? downloadsPage;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ResourceSettingsEditor? _editor;
  final _groupsScope = FocusScopeNode(
    debugLabel: 'settings-groups',
    traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
  );
  final _detailScope = FocusScopeNode(
    debugLabel: 'settings-detail',
    traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
  );
  final _groupFocus = [for (final _ in SettingsGroup.values) FocusNode()];
  late var _group = widget.initialGroup;
  _Subpage? _subpage;
  FocusNode? _opener;
  var _detailFocused = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _editor ??= ResourceSettingsEditor(
      AppScope.of(context).repository,
      widget.store,
    )..load();
  }

  @override
  void dispose() {
    _editor?.dispose();
    _groupsScope.dispose();
    _detailScope.dispose();
    for (final node in _groupFocus) {
      node.dispose();
    }
    super.dispose();
  }

  String _summary(SettingsGroup group) {
    final store = widget.store;
    final scope = AppScope.of(context);
    return switch (group) {
      SettingsGroup.appearance => [
        themeModes[store.themeMode],
        scope.systemColorAvailable && store.followSystemColor
            ? '系统取色'
            : store.themeColor.label,
        displayModes[platformDisplayMode(store.displayMode)],
      ].join(' · '),
      SettingsGroup.playback => '倍速、清晰度、解码与手势',
      SettingsGroup.danmaku => '字号、颜色、显示区域与屏蔽词',
      SettingsGroup.download =>
        Platform.isAndroid ? '默认画质、同时下载数量、自动导出' : '默认画质、VIP 集、同时下载数量',
      SettingsGroup.storage => '下载目录、清理缓存、删除全部数据',
      SettingsGroup.proxy => '连接方式、代理地址',
      SettingsGroup.users => '当前：${store.profile.name}',
      SettingsGroup.about =>
        scope.version.isEmpty ? '版本未知' : '版本 ${scope.version}',
      SettingsGroup.modules => '排序、测速、开关与恢复已删除的站源',
      SettingsGroup.diagnostics => '播放调试日记、备份与恢复',
    };
  }

  Widget _section(SettingsGroup group) => SettingsSection(
    group: group,
    store: widget.store,
    editor: _editor!,
    open: _open,
  );

  void _open(String title, WidgetBuilder body) {
    if (!settingsSplit(context)) {
      _openFullPage(context, title, body);
      return;
    }
    _opener = FocusManager.instance.primaryFocus;
    setState(() => _subpage = (title: title, body: body));
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusDetail());
  }

  void _closeSubpage() {
    final opener = _opener;
    _opener = null;
    setState(() => _subpage = null);
    if (!AppScope.of(context).television) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (opener != null && opener.context != null) revealFocus(opener);
    });
  }

  void _select(SettingsGroup group) {
    if (group == _group) return;
    setState(() {
      _group = group;
      _subpage = null;
      _opener = null;
    });
  }

  FocusNode? _detailTarget({required bool resume}) {
    final last = _detailScope.focusedChild;
    if (resume && last != null && last.canRequestFocus) return last;
    final first = FocusTraversalGroup.of(
      context,
    ).findFirstFocus(_detailScope, ignoreCurrentFocus: true);
    return first == _detailScope ? null : first;
  }

  void _focusDetail() {
    if (!mounted || !AppScope.of(context).television) return;
    if (_detailTarget(resume: false) case final target?) revealFocus(target);
  }

  KeyEventResult _onGroupsKey(KeyEvent event) {
    if (event is KeyUpEvent ||
        event.logicalKey != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final target = _detailTarget(resume: true);
    if (target == null) return KeyEventResult.ignored;
    revealFocus(target);
    return KeyEventResult.handled;
  }

  KeyEventResult _onDetailKey(KeyEvent event) {
    if (!AppScope.of(context).television ||
        event is KeyUpEvent ||
        event.logicalKey != LogicalKeyboardKey.arrowLeft ||
        textFieldKeepsKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus.focusInDirection(TraversalDirection.left)) {
      return KeyEventResult.handled;
    }
    revealFocus(_groupFocus[_group.index]);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    // 短剧之家字阶：标题粗、说明细，靠对比制造层次，不再「整体加粗」。
    // 分组标题小灰字 + 正字距，条目标题中粗，副标题细灰，子页面自动继承。
    final scoped = theme.copyWith(
      textTheme: text.copyWith(
        bodyLarge: text.bodyLarge?.copyWith(
          fontSize: 16,
          fontWeight: TypeScale.semibold,
          letterSpacing: TypeScale.trackingSnug,
          height: TypeScale.leadingTitle,
        ),
        bodyMedium: text.bodyMedium?.copyWith(
          fontSize: 14.5,
          fontWeight: TypeScale.regular,
          letterSpacing: TypeScale.trackingNormal,
          height: TypeScale.leadingBody,
        ),
        bodySmall: text.bodySmall?.copyWith(
          fontSize: 12.5,
          fontWeight: TypeScale.regular,
          height: TypeScale.leadingCaption,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontSize: 17,
          fontWeight: TypeScale.heavy,
          letterSpacing: TypeScale.trackingSnug,
          height: TypeScale.leadingTitle,
        ),
        titleSmall: text.titleSmall?.copyWith(
          fontSize: 15,
          fontWeight: TypeScale.semibold,
          height: TypeScale.leadingTitle,
        ),
        labelLarge: text.labelLarge?.copyWith(
          fontSize: 15,
          fontWeight: TypeScale.bold,
        ),
        labelMedium: text.labelMedium?.copyWith(
          fontSize: 13,
          fontWeight: TypeScale.medium,
          letterSpacing: TypeScale.trackingLoose,
        ),
      ),
    );
    return Theme(
      data: scoped,
      child: settingsSplit(context) ? _split(context) : _phone(context),
    );
  }

  Widget _phone(BuildContext context) => Scaffold(
    // 与首页同款：内容从磨砂顶栏背后透出，标题文字换成玻璃胶囊。
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      surfaceTintColor: Colors.transparent,
      flexibleSpace: const FrostedHeader(fill: true),
      title: const GlassTitle(title: '设置', plain: true),
    ),
    body: SafeArea(
      top: true,
      bottom: false,
      child: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          // 站源与诊断按用户要求收进「常用」，紧跟模块入口，不再单独成组。
          final groups = [
            for (final group in SettingsGroup.values)
              if (group != SettingsGroup.modules &&
                  group != SettingsGroup.diagnostics)
                group,
          ];
          // 每 3 个分组一段，段名按内容归组（新增分组时只需补段名）。
          const sections = ['界面与播放', '设备与数据', '账号与关于'];
          return ListView(
            // 底部留出悬浮胶囊导航的空间，避免最后一项被遮住。
            // 顶部不再额外加留白：SafeArea 已经把状态栏与磨砂顶栏让出来了。
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
            children: [
              if (widget.followPage != null || widget.downloadsPage != null) ...[
                const SectionHeader(
                  title: '内容',
                  padding: EdgeInsets.fromLTRB(4, 18, 8, 10),
                ),
                GroupCard(
                  children: [
                    if (widget.followPage != null)
                      SettingsTile(
                        icon: Icons.bookmark_border_rounded,
                        iconColor: _tileColors[0],
                        title: '追剧',
                        subtitle: '收藏的剧集与更新提醒',
                        onTap: () =>
                            openPage<void>(context, widget.followPage!),
                      ),
                    if (widget.downloadsPage != null)
                      SettingsTile(
                        icon: Icons.download_rounded,
                        iconColor: _tileColors[1],
                        title: '下载管理',
                        subtitle: '下载中、已下载与合并任务',
                        onTap: () =>
                            openPage<void>(context, widget.downloadsPage!),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              const SectionHeader(
                title: '常用',
                padding: EdgeInsets.fromLTRB(4, 18, 8, 10),
              ),
              GroupCard(
                children: [
                  SettingsTile(
                    icon: Icons.extension_outlined,
                    iconColor: _tileColors[0],
                    title: '模块',
                    subtitle: '安装、更新、导出模块，以及站源开关',
                    onTap: () => openPage<void>(
                      context,
                      (_) => ModulesPage(store: widget.store),
                    ),
                  ),
                  SettingsTile(
                    icon: SettingsGroup.diagnostics.icon,
                    iconColor: _tileColors[2],
                    title: SettingsGroup.diagnostics.label,
                    subtitle: _summary(SettingsGroup.diagnostics),
                    onTap: () => _openGroup(SettingsGroup.diagnostics),
                  ),
                ],
              ),
              for (
                var section = 0;
                section < sections.length && section * 3 < groups.length;
                section++
              ) ...[
                SectionHeader(
                  title: sections[section],
                  padding: const EdgeInsets.fromLTRB(4, 18, 8, 8),
                ),
                GroupCard(
                  children: [
                    for (
                      var i = section * 3;
                      i < groups.length && i < section * 3 + 3;
                      i++
                    )
                      SettingsTile(
                        icon: groups[i].icon,
                        iconColor: _tileColors[i % _tileColors.length],
                        title: groups[i].label,
                        subtitle: _summary(groups[i]),
                        onTap: () => _openGroup(groups[i]),
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    ),
  );

  void _openGroup(SettingsGroup group) => openPage<void>(
    context,
    (pageContext) => Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        surfaceTintColor: Colors.transparent,
        flexibleSpace: const FrostedHeader(fill: true),
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: BarButton(
            icon: Icons.arrow_back_rounded,
            tooltip: '返回',
            // 手机/电视形态下分组页被 push 到「根」Navigator，必须用本页
            // 自己的 context 出栈。若误用设置主页的 context，pop 的会是
            // 「设置」tab 自己的 Navigator，把它的初始页弹空，返回后底栏
            // 还在、内容区却全黑（IndexedStack 那一格变空白）。
            onPressed: () => Navigator.pop(pageContext),
          ),
        ),
        title: GlassTitle(title: group.label),
      ),
      body: SafeArea(
        top: true,
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [_section(group)],
        ),
      ),
    ),
  );

  Widget _split(BuildContext context) {
    final television = AppScope.of(context).television;
    return PopScope(
      canPop: _subpage == null && !(television && _detailFocused),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_subpage != null) {
          _closeSubpage();
        } else {
          revealFocus(_groupFocus[_group.index]);
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 280,
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: (_, event) => _onGroupsKey(event),
                  child: FocusScope(
                    node: _groupsScope,
                    child: _groupList(television),
                  ),
                ),
              ),
              Expanded(
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onFocusChange: (focused) =>
                      setState(() => _detailFocused = focused),
                  onKeyEvent: (_, event) => _onDetailKey(event),
                  child: FocusScope(
                    node: _detailScope,
                    child: _detail(television),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _groupList(bool television) {
    final left = television ? televisionInset : 16.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(left, television ? 27 : 20, 12, 0),
          child: SizedBox(
            height: 48,
            child: Row(
              spacing: 4,
              children: [
                if (!television)
                  BarButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: '返回',
                    onPressed: () => Navigator.pop(context),
                  ),
                Padding(
                  padding: EdgeInsets.only(left: television ? 8 : 0),
                  child: Text(
                    '设置',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: ListView(
              padding: television
                  ? const EdgeInsets.fromLTRB(televisionInset, 4, 16, 27)
                  : const EdgeInsets.fromLTRB(16, 4, 12, 24),
              children: _groupItems(television),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _groupItems(bool television) => [
    for (final group in SettingsGroup.values)
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: _GroupItem(
          key: ValueKey('settings-${group.name}'),
          label: group.label,
          selected: group == _group,
          focusNode: _groupFocus[group.index],
          autofocus: television && group == _group,
          onTap: () => _select(group),
          onFocus: television ? () => _select(group) : null,
        ),
      ),
  ];

  Widget _detail(bool television) {
    final subpage = _subpage;
    final top = television ? 27.0 : 20.0;
    final right = television ? televisionInset : 24.0;
    final content = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, 8, right, television ? 27 : 32),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _section(_group),
        ),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: subpage != null,
          child: ExcludeFocus(
            excluding: subpage != null,
            child: _PaneSwitcher(
              duration: television ? Duration.zero : Motion.medium,
              offset: const Offset(0, 0.02),
              child: Column(
                key: ValueKey(_group),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _DetailHeader(title: _group.label, top: top, right: right),
                  Expanded(child: content),
                ],
              ),
            ),
          ),
        ),
        if (subpage != null)
          Column(
            key: ValueKey(subpage.title),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DetailHeader(
                title: subpage.title,
                top: top,
                right: right,
                onBack: television ? null : _closeSubpage,
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: 8, right: right - 16),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 776),
                      child: subpage.body(context),
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// 分组详情切换动画（小果原有，保留）：淡入 + 轻微上滑。
class _PaneSwitcher extends StatelessWidget {
  const _PaneSwitcher({
    required this.duration,
    required this.offset,
    required this.child,
  });

  final Duration duration;
  final Offset offset;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.of(context, duration),
    reverseDuration: Motion.of(context, Motion.short),
    switchInCurve: Motion.enter,
    switchOutCurve: Motion.exit,
    layoutBuilder: (current, previous) => Stack(
      fit: StackFit.expand,
      children: [
        for (final child in previous) _inert(child, true),
        if (current != null) _inert(current, false),
      ],
    ),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(begin: offset, end: Offset.zero).animate(animation),
        child: child,
      ),
    ),
    child: child,
  );

  // 新旧内容保持同一层级和同一 key，切换时不会重建内部状态
  static Widget _inert(Widget child, bool inert) => ExcludeFocus(
    key: child.key,
    excluding: inert,
    child: IgnorePointer(
      ignoring: inert,
      child: ExcludeSemantics(excluding: inert, child: child),
    ),
  );
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.title,
    required this.top,
    required this.right,
    this.onBack,
  });
  final String title;
  final double top;
  final double right;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(onBack == null ? 24 : 16, top, right, 0),
    child: SizedBox(
      height: 48,
      child: Row(
        spacing: 4,
        children: [
          if (onBack != null)
            BarButton(
              icon: Icons.arrow_back_rounded,
              tooltip: '返回',
              onPressed: onBack,
            ),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _GroupItem extends StatelessWidget {
  const _GroupItem({
    super.key,
    required this.label,
    required this.selected,
    required this.focusNode,
    required this.autofocus,
    required this.onTap,
    required this.onFocus,
  });
  final String label;
  final bool selected;
  final FocusNode focusNode;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback? onFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final television = AppScope.of(context).television;
    final item = FocusPill(
      focusNode: focusNode,
      selected: selected,
      textStyle: theme.textTheme.titleSmall?.copyWith(
        fontSize: 16,
        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
        letterSpacing: -0.2,
        color: theme.colorScheme.onSurface,
      ),
      child: InkWell(
        focusNode: focusNode,
        autofocus: autofocus,
        focusColor: television ? Colors.transparent : null,
        onTap: onTap,
        onFocusChange: (focused) {
          if (focused) onFocus?.call();
        },
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          alignment: Alignment.centerLeft,
          child: Text(label),
        ),
      ),
    );
    return Semantics(
      selected: selected,
      child: television ? item : FocusRing(radius: 24, scale: 1, child: item),
    );
  }
}
