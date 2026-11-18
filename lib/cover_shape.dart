import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

enum CoverShape { unknown, portrait, landscape, mixed }

/// 判定一个站源的封面朝向，并记住每张封面的宽高比。
///
/// 优先用模块清单里的 `coverAspect` 声明；没声明时按实际封面图的宽高比
/// 统计（每站源最多 [maxSamples] 个样本）：横竖都出现过的站源判为
/// [CoverShape.mixed]，由列表切到瀑布流布局。
class CoverShapes {
  CoverShapes._();

  static const maxSamples = 12;
  static const _margin = 2;
  static const _mixedHits = 2;
  static const _prefix = 'coverShape.';

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static final Map<String, int> _score = <String, int>{};
  static final Map<String, int> _wide = <String, int>{};
  static final Map<String, int> _tall = <String, int>{};
  static final Map<String, double> _ratios = <String, double>{};
  static final Set<String> _seen = <String>{};
  static SharedPreferences? _prefs;
  static bool _loaded = false;
  static bool _pending = false;

  static void _notify() {
    if (_pending) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      revision.value++;
    });
  }

  /// 单张封面的宽高比（宽 / 高），未知时返回 0。
  static double ratioOf(String dramaId) => _ratios[dramaId] ?? 0;

  static CoverShape of(String source) {
    final declared = SourceSite.byId(source).coverAspect;
    if (declared == 'landscape') return CoverShape.landscape;
    if (declared == 'portrait') return CoverShape.portrait;
    if ((_wide[source] ?? 0) >= _mixedHits && (_tall[source] ?? 0) >= _mixedHits) {
      return CoverShape.mixed;
    }
    final score = _score[source] ?? 0;
    if (score >= _margin) return CoverShape.landscape;
    if (score <= -_margin) return CoverShape.portrait;
    return CoverShape.unknown;
  }

  static bool isLandscape(String source) => of(source) == CoverShape.landscape;

  static bool isMixed(String source) => of(source) == CoverShape.mixed;

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(_prefix)) continue;
        final id = key.substring(_prefix.length);
        final score = prefs.getInt(key);
        if (score != null) _score[id] = score;
        final wide = prefs.getInt('${_prefix}w.$id');
        final tall = prefs.getInt('${_prefix}t.$id');
        if (wide != null) _wide[id] = wide;
        if (tall != null) _tall[id] = tall;
      }
    } catch (_) {
      // 读不到就按未学习处理，后续样本会重新建立判断。
    }
    _loaded = true;
    _notify();
  }

  static Future<void> learn(
    String source,
    String dramaId,
    String path,
  ) async {
    if (source.isEmpty || path.isEmpty) return;
    if (!_seen.add('$source\u0000$dramaId\u0000$path')) return;

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
    if (dramaId.isNotEmpty && !_ratios.containsKey(dramaId)) {
      _ratios[dramaId] = ratio;
      _notify();
    }

    if (SourceSite.byId(source).coverAspect.isNotEmpty) return;
    final used = _wide[source] ?? 0;
    final tall = _tall[source] ?? 0;
    if (used + tall >= maxSamples) return;

    final before = of(source);
    if (ratio >= 1.25) {
      _wide[source] = used + 1;
    } else if (ratio <= 0.85) {
      _tall[source] = tall + 1;
    } else {
      return;
    }
    final next = ((_score[source] ?? 0) + (ratio >= 1.25 ? 1 : -1)).clamp(-24, 24);
    _score[source] = next;
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setInt('$_prefix$source', next);
      await prefs.setInt('${_prefix}w.$source', _wide[source] ?? 0);
      await prefs.setInt('${_prefix}t.$source', _tall[source] ?? 0);
    } catch (_) {
      // 落盘失败不影响本次判断。
    }
    if (of(source) != before) _notify();
  }
}
