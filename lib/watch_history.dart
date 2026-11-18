import 'catalog_sort.dart';
import 'models.dart';

enum WatchPeriod {
  today('今天'),
  yesterday('昨天'),
  earlier('更早');

  const WatchPeriod(this.label);
  final String label;

  static WatchPeriod of(DateTime watched, DateTime now) {
    final local = watched.toLocal();
    if (!local.isBefore(DateTime(now.year, now.month, now.day))) return today;
    if (!local.isBefore(DateTime(now.year, now.month, now.day - 1))) {
      return yesterday;
    }
    return earlier;
  }
}

String watchDateLabel(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final year = local.year == now.year ? '' : '${local.year}年';
  return '$year${local.month}月${local.day}日';
}

List<SourceSite> watchedSources(List<WatchEntry> history) => [
  for (final site in SourceSite.values)
    if (history.any((entry) => entry.drama.source == site.id)) site,
];

bool matchesWatchTitle(WatchEntry entry, String query) =>
    matchesTitle(entry.drama.title, query);
