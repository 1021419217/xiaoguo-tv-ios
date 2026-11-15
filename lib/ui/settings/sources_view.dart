import 'dart:async';

import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../widgets/focus_ring.dart';
import '../widgets/group_card.dart';
import 'settings_rows.dart';
import 'sorani_account_view.dart';

/// 站源管理：开关、拖动排序、删除、测速。
///
/// 排序与删除都是本机偏好（存在 settings 里），不影响内置清单；
/// 安装模块后新出现的源会自动补在末尾，删掉的源也能通过重装模块恢复。
class SourcesView extends StatefulWidget {
  const SourcesView({super.key, required this.store});
  final LocalStore store;

  @override
  State<SourcesView> createState() => _SourcesViewState();
}

class _SourcesViewState extends State<SourcesView> {
  bool _testing = false;
  Map<String, int?> _latency = const {};

  LocalStore get _store => widget.store;

  Future<void> _toggle(String id, bool value) {
    final repository = AppScope.of(context).repository;
    return saveSetting(context, () async {
      await _store.setSourceEnabled(id, value);
      if (!value && repository.supportsDownloads) {
        await repository.controlDownloads('pauseSource', id: id);
      }
    });
  }

  Future<void> _remove(SourceSite site) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${site.name}」'),
        content: const Text('删除后这个源不再出现在发现、搜索、下载与观看记录里，记录本身保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await saveSetting(
      context,
      () => _store.setSourceDeleted(site.id, deleted: true),
    );
  }

  void _reorder(int oldIndex, int newIndex) {
    final sites = [..._store.permittedSources];
    if (oldIndex < 0 || oldIndex >= sites.length) return;
    newIndex = newIndex.clamp(0, sites.length - 1);
    final moved = sites.removeAt(oldIndex);
    sites.insert(newIndex, moved);
    unawaited(
      saveSetting(
        context,
        () => _store.setSourceOrder([for (final site in sites) site.id]),
      ),
    );
  }

  /// 逐个源请求一次分类列表来测连通性与响应耗时；8 路并发，单项最多 8 秒。
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (context, _) {
      final admin = _store.profile.admin;
      final sites = _store.permittedSources;
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (!admin) ...[
            const _Note('需要管理员才能调整站源'),
            const SizedBox(height: 12),
          ],
          _speedCard(sites),
          const SizedBox(height: 12),
          if (sites.isEmpty)
            const _Note('还没有可用的站源，先在「模块」里安装站源模块。')
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: sites.length,
              onReorderItem: admin ? _reorder : (_, _) {},
              itemBuilder: (context, index) {
                final site = sites[index];
                return Padding(
                  key: ValueKey(site.id),
                  padding: EdgeInsets.only(bottom: index == sites.length - 1 ? 0 : 8),
                  child: _SourceRow(
                    site: site,
                    index: index,
                    enabled: _store.sourceEnabled(site.id),
                    latency: _latency[site.id],
                    tested: _latency.containsKey(site.id),
                    dragEnabled: admin && sites.length > 1,
                    onChanged: admin ? (value) => _toggle(site.id, value) : null,
                    onDelete: admin ? () => _remove(site) : null,
                  ),
                );
              },
            ),
          const SizedBox(height: 12),
          const _Note(
            '关闭的站源不在发现、搜索、追剧、观看记录和下载中显示，记录保留，重新开启后恢复。'
            '删除只在本机隐藏这个源，不影响其它用户。长期按住的拖动按钮可以调整顺序。',
          ),
        ],
      );
    },
  );

  Widget _speedCard(List<SourceSite> sites) => SettingsCard(
    children: [
      SettingsTile(
        icon: Icons.speed_rounded,
        title: _testing ? '正在测源…' : '站源测速',
        subtitle: _testing
            ? '正在请求各站源的分类接口'
            : _latency.isEmpty
            ? '检测每个站源能否连通以及响应速度'
            : '绿色快 / 橙色一般 / 红色慢 / 灰色不可用',
        enabled: !_testing && sites.isNotEmpty,
        onTap: _testing || sites.isEmpty ? null : _runSpeedTest,
        trailing: _testing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
    ],
  );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.site,
    required this.index,
    required this.enabled,
    required this.latency,
    required this.tested,
    required this.dragEnabled,
    required this.onChanged,
    required this.onDelete,
  });

  final SourceSite site;
  final int index;
  final bool enabled;
  final int? latency;
  final bool tested;
  final bool dragEnabled;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: TileFocus(
        builder: (focusNode) => ListTile(
          focusNode: focusNode,
          minTileHeight: 72,
          contentPadding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          leading: dragEnabled
              ? ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                )
              : const SizedBox(width: 12),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  site.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (tested) ...[
                const SizedBox(width: 8),
                _LatencyBadge(latency: latency),
              ],
              if (!site.available) ...[
                const SizedBox(width: 8),
                Text(
                  '未安装',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            site.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: onChanged == null ? null : () => onChanged!(!enabled),
          trailing: ExcludeFocus(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onDelete != null)
                  IconButton(
                    tooltip: '删除',
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                Switch(value: enabled, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LatencyBadge extends StatelessWidget {
  const _LatencyBadge({required this.latency});
  final int? latency;

  @override
  Widget build(BuildContext context) {
    final int? value = latency;
    final Color color;
    final String label;
    if (value == null) {
      color = Colors.grey;
      label = '不可用';
    } else if (value < 400) {
      color = const Color(0xFF34C759);
      label = '$value ms';
    } else if (value < 1200) {
      color = const Color(0xFFFF9F0A);
      label = '$value ms';
    } else {
      color = const Color(0xFFFF453A);
      label = '$value ms';
    }
    return Text(
      label,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    );
  }
}

class SourceAccountsView extends StatelessWidget {
  const SourceAccountsView({super.key, required this.store});
  final LocalStore store;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final admin = store.profile.admin;
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (!admin) ...[
            const _Note('需要管理员才能登录或退出站源账号'),
            const SizedBox(height: 12),
          ],
          if (soraniAccountAvailable())
            SettingsCard(children: [SoraniAccountTile(admin: admin)])
          else
            const _Note('没有已安装且需要登录的站源'),
        ],
      );
    },
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
