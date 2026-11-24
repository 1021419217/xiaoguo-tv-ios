import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../core_bridge.dart';

/// 把已安装模块重新打包成 zip，再交给系统「存储到文件」面板。
///
/// 单个模块的包结构与安装包一致，导出后能直接用「手动安装」装回来；
/// 多个模块时外层包里每个模块是独立的一个 zip（<标识>-<版本>.zip），
/// 解压后拿到的就是一个个现成的模块包。用户取消时返回 null。
Future<String?> saveModuleArchive(
  AppRepository repository,
  List<String> ids,
) async {
  if (ids.isEmpty) throw AppFailure('没有可导出的模块');
  final archive = await repository.exportModules(ids);
  if (archive.path.isEmpty) throw AppFailure('导出文件生成失败，请重试');
  final file = File(archive.path);
  final bytes = await file.readAsBytes();
  try {
    final uri = await FilePicker.saveFile(
      fileName: archive.name,
      bytes: bytes,
      mimeType: 'application/zip',
      dialogTitle: ids.length > 1 ? '导出 ${ids.length} 个模块' : '导出模块',
    );
    if (uri == null) return null;
  } finally {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 临时文件删不掉不影响已经保存到别处的副本。
    }
  }
  return archive.name;
}
