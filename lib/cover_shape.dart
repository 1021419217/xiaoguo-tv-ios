import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

enum CoverShape { unknown, portrait, landscape }

/// 判定一个站源的封面是横向还是竖向。
///
/// 优先用模块清单里的 `coverAspect` 声明；没声明时按实际封面图的宽高比
/// 投票学习（每个站源最多 [maxSamples] 个样本），结果落盘，下次启动直接可用。
class CoverShapes {
  CoverShapes._();

  static const maxSamples = 12;
  static const _margin = 2;
  static const _prefix = 'coverShape.';

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static final Map<String, int> _score = <String, int>{};
  static final Map<String, int> _samples = <String, int>{};
  static final Set<String> _seen = <String>{};
  static SharedPreferences? _prefs;
  static bool _loaded = false;

  static CoverShape of(String source) {
    final declared = SourceSite.byId(source).coverAspect;
    if (declared == 'landscape') return CoverShape.landscape;
    if (declared == 'portrait') return CoverShape.portrait;
    final score = _score[source] ?? 0;
    if (score >= _margin) return CoverShape.landscape;
    if (score <= -_margin) return CoverShape.portrait;
    return CoverShape.unknown;
  }

  static bool isLandscape(String source) =>
      of(source) == CoverShape.landscape;

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(_prefix)) continue;
        final score = prefs.getInt(key);
        if (score != null) _score[key.substring(_prefix.length)] = score;
      }
    } catch (_) {
      // 读不到就按未学习处理，后续样本会重新建立判断。
    }
    _loaded = true;
    revision.value++;
  }

  static Future<void> learn(String source, String path) async {
    if (source.isEmpty || path.isEmpty) return;
    if (!_seen.add(path)) return;
    if (SourceSite.byId(source).coverAspect.isNotEmpty) return;
    final used = _samples[source] ?? 0;
    if (used >= maxSamples) return;
    _samples[source] = used + 1;

    int width;
    int height;
    try {
      final bytes = await File(path).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      width = descriptor.width;
      height = descriptor.height;
      descriptor.dispose();
      buffer.dispose();
    } catch (_) {
      return;
    }
    if (width <= 0 || height <= 0) return;

    final ratio = width / height;
    final delta = ratio >= 1.25
        ? 1
        : ratio <= 0.85
        ? -1
        : 0;
    if (delta == 0) return;

    final before = of(source);
    final next = ((_score[source] ?? 0) + delta).clamp(-24, 24);
    _score[source] = next;
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setInt('$_prefix$source', next);
    } catch (_) {
      // 落盘失败不影响本次判断。
    }
    if (of(source) != before) revision.value++;
  }
}
