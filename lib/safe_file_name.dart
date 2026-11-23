/// 把标题里的非法字符换成下划线，用作下载/导出的文件名。
///
/// 原来放在 download_merge.dart（那一整套合并功能已经删掉），
/// 导出和下载都要用，独立出来。
String safeFileName(String title) {
  final name = title
      .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_')
      .trim();
  return name.isEmpty ? '未命名' : name;
}
