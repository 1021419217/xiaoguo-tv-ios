import 'package:flutter/material.dart';

import '../../download_collections.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../widgets/focus_ring.dart';
import '../widgets/glass_dialog.dart';

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
      duration: const Duration(milliseconds: 1600),
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
