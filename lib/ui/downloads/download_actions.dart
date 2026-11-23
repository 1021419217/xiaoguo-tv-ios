import 'package:flutter/material.dart';

import '../../download_collections.dart';
import '../../download_overview.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../widgets/focus_ring.dart';
import '../widgets/glass_dialog.dart';
import 'downloads_page.dart';

/// 「去下载」：复用 AppShell 里那份下载概览与转换器，直接打开下载管理页。
/// 不自己再 new 一个转换器，免得两个转换器抢同一集去转码。
void openDownloadsPage(BuildContext context, LocalStore store) {
  final overview = DownloadServices.overview;
  final converter = DownloadServices.converter;
  final repository = DownloadServices.repository;
  // 服务还没登记上（AppShell 未就绪 / 正在重建）时也别让按钮点了没反应：
  // 现场建一份只读概览，转换器缺失只是暂时看不到处理进度。
  final downloads =
      overview ?? (repository == null ? null : DownloadOverview(repository, store));
  if (downloads == null) return;
  // 选集页下载完会 pop 掉自己，吐司挂在全局还留在屏幕上；这时原来的
  // context 已经失效，必须走全局根导航器，否则点了完全没反应。
  final navigator = context.mounted
      ? Navigator.of(context, rootNavigator: true)
      : rootNavigatorKey.currentState;
  if (navigator == null) return;
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) =>
          DownloadsPage(store: store, downloads: downloads, converter: converter),
    ),
  );
}

/// 提示条右侧的胶囊按钮：半透明底 + 细描边，和提示条本身的圆角一致。
class _SnackAction extends StatelessWidget {
  const _SnackAction({
    required this.label,
    required this.color,
    required this.onTap,
  });
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 8),
    child: Material(
      color: color.withValues(alpha: 0.16),
      shape: StadiumBorder(
        side: BorderSide(color: color.withValues(alpha: 0.34)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 9, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 3,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                  letterSpacing: .2,
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 15, color: color),
            ],
          ),
        ),
      ),
    ),
  );
}

String formatBytes(int bytes) => bytes >= 1 << 30
    ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB'
    : bytes >= 1 << 20
    ? '${(bytes / (1 << 20)).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).round()} KB';

/// 统一样式的操作提示：悬浮圆角条 + 图标，跟应用的深色金调保持一致。
void showMessage(BuildContext context, String text) {
  final accent = Theme.of(context).colorScheme.primary;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(milliseconds: 1600),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      backgroundColor: const Color(0xFF232320),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      content: Row(
        children: [
          Icon(Icons.check_circle_rounded, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, color: Color(0xFFE8E3DA)),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<bool> downloadEpisodes(
  BuildContext context,
  LocalStore store,
  DramaDetail detail,
  List<Episode> episodes,
) async {
  if (episodes.isEmpty) return false;
  final messenger = ScaffoldMessenger.of(context);
  final accent = Theme.of(context).colorScheme.primary;
  void notify(String text, {bool error = false}) => messenger.showSnackBar(
    SnackBar(
      // 带「去下载」时多留一点时间，够手指移过去点。
      duration: Duration(milliseconds: error ? 1600 : 3200),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      backgroundColor: const Color(0xFF232320),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      content: Row(
        children: [
          Icon(
            error ? Icons.error_outline_rounded : Icons.check_circle_rounded,
            size: 18,
            color: error ? const Color(0xFFD6644A) : accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, color: Color(0xFFE8E3DA)),
            ),
          ),
          if (!error)
            _SnackAction(
              label: '去下载',
              color: accent,
              onTap: () {
                messenger.hideCurrentSnackBar();
                openDownloadsPage(context, store);
              },
            ),
        ],
      ),
    ),
  );
  try {
    final added = await enqueueEpisodes(
      AppScope.of(context).repository,
      store,
      detail,
      episodes,
    );
    notify(added == 0 ? '已在下载列表中' : '已加入下载 $added 集');
    return true;
  } catch (error) {
    notify(error.toString(), error: true);
    return false;
  }
}

Future<bool> confirmRemoval(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final confirmed = await showGlassDialog(
    context: context,
    title: title,
    message: message,
    cancelLabel: '保留',
    confirmLabel: action,
    danger: true,
  );
  return confirmed == true;
}

Future<bool> removeDownloads(
  BuildContext context,
  List<String> ids, {
  required String done,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await controlDownloadJobs(
    AppScope.of(context).repository,
    'remove',
    ids,
  );
  messenger.showSnackBar(
    SnackBar(
      duration: Duration(milliseconds: 1400),
      content: Text(
        result.failures.isEmpty
            ? done
            : '${result.failures.length} 集未能删除：${result.failures.values.first}',
      ),
    ),
  );
  return result.failures.isEmpty;
}

class SourceTag extends StatelessWidget {
  const SourceTag(this.source, {super.key});
  final String source;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        SourceSite.byId(source).name,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1.3,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
