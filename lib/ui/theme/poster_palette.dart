import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../cover_loader.dart';
import '../../models.dart';
import '../app_scope.dart';

/// 首页轮播海报的动态取色。当前海报变化 → 提取主色相 → 通知全局主题重建。
///
/// 与短剧之家的机制一致：界面底色跟随当前海报的色系，海报一切整套界面
/// 跟着变。取色源是首页轮播当前海报的本地封面文件（已经由 CoverLoader
/// 缓存好），用 dart:ui 解码后做色相直方图统计，取最有代表性的色相作为
/// 表面层的染色种子。强调色（按钮、开关、进度）不参与，保持功能色不变。
///
/// 这是一个 [ChangeNotifier]，DuanjuApp 直接监听它；同一部剧只取一次色，
/// 避免自动轮播反复解码同一张图。
final class PosterPalette extends ChangeNotifier {
  PosterPalette._();
  static final instance = PosterPalette._();

  Color? _color;
  Color? _videoTint;
  String? _dramaId;
  int _generation = 0;
  bool _followEnabled = true;

  Color? get color => _color;
  String? get dramaId => _dramaId;

  /// 播放器当前视频帧的主色。独立于海报色，只用于播放器控件局部染色，
  /// 避免每几秒就重建整个 App 主题。关闭「跟随海报色」时同步骤退。
  Color? get videoTint => _followEnabled ? _videoTint : null;

  /// 是否启用「跟随海报色」。由 DuanjuApp 在每次重建时同步，关闭后按钮
  /// 与表面层一起退回中性白玻璃，不再残留上一次取到的海报色。
  bool get followEnabled => _followEnabled;
  set followEnabled(bool value) {
    _followEnabled = value;
  }

  /// 按钮玻璃层专用的色相源。
  ///
  /// 海报色本身只负责「定色调」：这里把饱和与明度重算成偏亮的中间调，
  /// 让按钮底与描边带上当前海报的色系，同时仍能透出背后的封面。
  /// 图标/文字颜色不取这个值，继续用 onSurface 反色，保证在花哨海报上可读。
  Color? get buttonTint {
    if (!_followEnabled || _color == null) return null;
    final hsl = HSLColor.fromColor(_color!);
    return HSLColor.fromAHSL(1, hsl.hue, 0.52, 0.66).toColor();
  }

  /// 页面用「当前主角封面」驱动全局取色——短剧之家的核心机制：进入哪个页面、
  /// 页面里最显眼的那张封面是什么色系，整套界面底色与按钮就跟着变。
  ///
  /// 列表页首项、详情页当前剧都调这个；封面尚未落地时 cachedPath 为空，
  /// 借 CoverShapes.revision 触发的重建再补一次即可。sync 幂等，不会重复解码。
  static void syncDrama(BuildContext context, Drama? drama) {
    if (drama == null || drama.id.isEmpty || drama.cover.isEmpty) return;
    final path = CoverLoader.cachedPath(
      AppScope.of(context).repository,
      drama,
    );
    if (path == null || path.isEmpty) return;
    unawaited(instance.sync(drama.id, path));
  }

  /// 用当前海报的本地封面路径取色。
  ///
  /// [dramaId] 相同且已经成功取色时直接跳过；[generation] 用来丢弃翻页
  /// 过程中过期的异步结果，保证落地的一定是用户当前看到的那张海报。
  Future<void> sync(String dramaId, String? path) async {
    if (path == null || path.isEmpty) return;
    if (_dramaId == dramaId && _color != null) return;
    final generation = ++_generation;
    final color = await extractCoverColor(path);
    if (generation != _generation || color == null) return;
    _dramaId = dramaId;
    if (_color == color) return;
    _color = color;
    notifyListeners();
  }

  /// 应用一帧视频的主色。只有色相变化超过阈值才通知，避免视频颜色微抖
  /// 导致控件每两秒重建闪烁；同一场景内的渐变由调用方平滑过渡。
  void applyVideoTint(Color color) {
    if (!_followEnabled) return;
    final previous = _videoTint;
    if (previous != null) {
      var delta = (HSLColor.fromColor(color).hue - HSLColor.fromColor(previous).hue).abs();
      if (delta > 180) delta = 360 - delta;
      if (delta < 12) return;
    }
    _videoTint = color;
    notifyListeners();
  }

  /// 退出播放器时清空视频色，避免残留到下一个页面。
  void resetVideoTint() {
    if (_videoTint == null) return;
    _videoTint = null;
    notifyListeners();
  }

  /// 主动清空（关闭「跟随海报色」时调用），避免下次打开残留旧色。
  void reset() {
    _generation++;
    if (_color == null) return;
    _color = null;
    _dramaId = null;
    notifyListeners();
  }
}

/// 从封面文件提取一个可用于染表面层的种子色。
///
/// 返回的是「中等饱和、中等明度」的纯色，只保留色相信息；具体明暗与
/// 饱和度由 AppTheme 按表面层级重新计算，这样不同海报只会改变色系，
/// 不会把海报本身的深浅直接带到界面上。
Future<Color?> extractCoverColor(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) return null;
    return await extractColorFromImageBytes(bytes);
  } catch (_) {
    return null;
  }
}

/// 从已经拿到的图片字节提取主色。播放器视频截图复用这一条解码/取色路径，
/// 保证「视频色」和「海报色」用完全同一套算法，观感一致。
Future<Color?> extractColorFromImageBytes(Uint8List bytes) async {
  ui.Image? image;
  ui.ImageCodec? codec;
  try {
    if (bytes.isEmpty) return null;
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 64,
      targetHeight: 64,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final pixels = data.buffer.asUint8List();
    return _dominantHue(pixels);
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// 色相直方图：把每个像素按色相分到 24 个桶，饱和度越高权重越大，
/// 过滤掉近黑、近白、近灰的像素（海报的文字、暗角、留白），取得分
/// 最高的桶中心作为代表色相。
Color? _dominantHue(Uint8List pixels) {
  const buckets = 24;
  final scores = List<double>.filled(buckets, 0);
  for (var i = 0; i + 3 < pixels.length; i += 4) {
    final r = pixels[i] / 255;
    final g = pixels[i + 1] / 255;
    final b = pixels[i + 2] / 255;
    final max = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final min = r < g ? (r < b ? r : b) : (g < b ? g : b);
    final lightness = (max + min) / 2;
    final delta = max - min;
    // 太暗/太亮/太灰的像素不代表海报色系。阈值放低一档：
    // 有些海报（如古装暖调）整体饱和不高，卡太严会一个桶都取不到。
    if (delta < 0.07 || lightness < 0.08 || lightness > 0.95) continue;
    double hue;
    if (max == r) {
      hue = ((g - b) / delta) % 6;
    } else if (max == g) {
      hue = (b - r) / delta + 2;
    } else {
      hue = (r - g) / delta + 4;
    }
    hue = (hue * 60 + 360) % 360;
    final index = (hue / (360 / buckets)).floor().clamp(0, buckets - 1);
    scores[index] += delta;
  }
  var best = -1;
  var bestScore = 0.0;
  for (var i = 0; i < buckets; i++) {
    if (scores[i] > bestScore) {
      bestScore = scores[i];
      best = i;
    }
  }
  if (best < 0 || bestScore <= 0) return null;
  final hue = best * (360 / buckets) + (360 / buckets) / 2;
  return HSLColor.fromAHSL(1.0, hue, 0.5, 0.5).toColor();
}
