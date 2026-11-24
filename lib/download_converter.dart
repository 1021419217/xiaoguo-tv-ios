import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;

import 'core_bridge.dart';
import 'diary_service.dart';
import 'download_export.dart';
import 'download_overview.dart';
import 'media_pipeline.dart';
import 'models.dart';

class DownloadConverter extends ChangeNotifier {
  DownloadConverter(this.repository, this.downloads, {MediaExecutor? executor})
    : executor = executor ?? FFmpegExecutor() {
    downloads.addListener(_sync);
    if (Platform.isIOS) {
      // iOS 上不再因切后台(onPause)取消转换。下载阶段靠静音音频保活维持
      // 进程存活，converting 状态也在保活判定内，ffmpeg 可以在后台把已下好
      // 的分集合并完；旧逻辑一切后台就 _suspend+_cancel，导致下载完停在
      // converting、必须等用户点回 App 才一集一集合并。仅在回到前台(onResume)
      // 时补一次同步作为兜底（进程若真被系统冻结，恢复后能继续驱动）。
      _lifecycle = AppLifecycleListener(onResume: _resume);
    }
    _sync();
  }

  final AppRepository repository;
  final DownloadOverview downloads;
  final MediaExecutor executor;
  AppLifecycleListener? _lifecycle;
  final _skipped = <String>{};
  String? _current;
  double? _progress;
  bool _cancelled = false, _disposed = false;

  double? progressOf(String id) => id == _current ? _progress : null;

  static List<String> arguments(
    DownloadConversion work, {
    bool transcode = false,
  }) => [
    if (work.key.isNotEmpty) ...['-decryption_key', work.key],
    if (path.extension(work.input).toLowerCase() == '.m3u8') ...[
      '-allowed_extensions',
      'ALL',
      '-extension_picky',
      '0',
    ],
    '-i',
    work.input,
    '-map',
    '0:v:0?',
    '-map',
    '0:a:0?',
    // 先试直接复制（快）；源流不兼容时退回转码，保证能出片。
    if (transcode) ...[
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '23',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
    ] else ...[
      '-c',
      'copy',
    ],
    '-movflags',
    '+faststart',
    work.output,
  ];

  void _sync() {
    _skipped.removeWhere(
      (id) => !downloads.jobs.any((job) => job.id == id && job.converting),
    );
    final current = _current;
    if (current != null) {
      if (!downloads.jobs.any((job) => job.id == current && job.converting)) {
        _cancel();
      }
      return;
    }
    if (_disposed) return;
    DownloadJob? next;
    for (final job in downloads.jobs) {
      if (!job.converting || _skipped.contains(job.id)) continue;
      if (next == null ||
          job.created < next.created ||
          job.created == next.created &&
              job.episode.number < next.episode.number) {
        next = job;
      }
    }
    if (next != null) unawaited(_convert(next));
  }

  Future<void> _convert(DownloadJob job) async {
    _current = job.id;
    _progress = 0;
    _cancelled = false;
    notifyListeners();
    var result = 'cancel';
    try {
      final DownloadConversion work;
      try {
        work = await repository.beginConversion(job.id);
      } catch (_) {
        _skipped.add(job.id);
        rethrow;
      }
      if (_cancelled) return;
      final duration = await _duration(work.input);
      if (_cancelled) return;
      result = 'failed';
      // 封装占 0→70%，退回转码占 70%→100%：两段合成一条连续进度。
      // 原来转码从 0 重新开始报，界面上就是「处理到 100% 又重来一遍」。
      const copyShare = 0.7;
      // 直接复制失败（源流不兼容、分片不规则等）时退回转码，避免整集报废。
      try {
        await executor.run(
          arguments(work),
          duration: duration,
          progress: (value) {
            _progress = value * copyShare;
            if (!_disposed) notifyListeners();
          },
        );
      } catch (copyError) {
        if (_cancelled) rethrow;
        DiaryService.add(
          '[下载] ${job.drama.title} 第 ${job.episode.number} 集直接复制失败，改用转码：$copyError',
        );
        await executor.run(
          arguments(work, transcode: true),
          duration: duration,
          progress: (value) {
            _progress = copyShare + value * (1 - copyShare);
            if (!_disposed) notifyListeners();
          },
        );
      }
      verifyMediaDuration(await executor.probe(work.output), duration);
      result = 'done';
    } catch (error) {
      if (_cancelled) {
        result = 'cancel';
      } else if (result == 'failed') {
        DiaryService.add(
          '[下载] ${job.drama.title} 第 ${job.episode.number} 集转换失败：$error',
        );
      }
    } finally {
      try {
        await repository.finishConversion(job.id, result);
      } catch (_) {}
      _current = null;
      _progress = null;
      if (!_disposed) {
        notifyListeners();
        await downloads.refresh();
        _sync();
      }
    }
    if (result == 'done') await _export(job);
  }

  Future<void> _export(DownloadJob job) async {
    if (!Platform.isAndroid || !downloads.store.autoExport || _disposed) return;
    try {
      await exportDownload(
        repository,
        job,
        delete: downloads.store.deleteAfterAutoExport,
      );
    } catch (error) {
      DiaryService.add(
        '[下载] ${job.drama.title} 第 ${job.episode.number} 集导出失败：$error',
      );
    }
    if (!_disposed) await downloads.refresh();
  }

  Future<double> _duration(String input) async {
    try {
      return (await executor.probe(input)).duration;
    } catch (_) {
      return 0;
    }
  }

  void _cancel() {
    if (_current == null || _cancelled) return;
    _cancelled = true;
    unawaited(executor.cancel());
  }

  void _resume() {
    // 回到前台兜底：进程若曾被系统冻结、后台转换停在半路，回到前台时
    // 重新驱动一次 _sync，把仍处于 converting 的分集合并完。
    _sync();
  }

  @override
  void dispose() {
    _disposed = true;
    downloads.removeListener(_sync);
    _lifecycle?.dispose();
    _cancel();
    super.dispose();
  }
}
