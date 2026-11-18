import 'catalog_sort.dart';
import 'models.dart';

/// 观看记录的分组标题：今天 / 昨天 / 11月5日。
String watchPeriodLabel(DateTime watched, DateTime now) {
  final local = watched.toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return '今天';
  if (diff == 1) return '昨天';
  return '${local.month}月${local.day}日';
}

List<SourceSite> watchedSources(List<WatchEntry> history) => [
  for (final site in SourceSite.values)
    if (history.any((entry) => entry.drama.source == site.id)) site,
];

bool matchesWatchTitle(WatchEntry entry, String query) =>
    matchesTitle(entry.drama.title, query);
