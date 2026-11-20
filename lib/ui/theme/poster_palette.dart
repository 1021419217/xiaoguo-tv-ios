import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models.dart';

/// 动态取色（历史实现，现已停用）。
///
/// 早期按「每张海报 / 每帧视频都重建全局主题」实现，结果任何一次
/// notifyListeners 都会让 app.dart 重建整棵 MaterialApp，界面每换一张
/// 海报就闪一下；而短剧之家实际是首页底栏固定色、只在进入具体页面时
/// 定一次色、顶部按钮只微微透出底色。
///
/// 现在整套风格锁死为固定中性冷灰玻璃。保留这个类与全库 27 处调用点，
/// 但这些入口全部是 no-op：不解码、不通知、不改主题，从根上消除闪烁，
/// 也避免大范围删调用点引入编译风险。
final class PosterPalette extends ChangeNotifier {
  PosterPalette._();
  static final instance = PosterPalette._();

  /// 动态取色总闸，恒 false。只有改这里才会重新启用取色链路。
  static const bool dynamicTintEnabled = false;

  /// AppShell 会写入、HeroCarousel 会读取；固定模式下不产生任何视觉效果。
  bool carouselActive = true;

  Color? get color => null;
  String? get dramaId => null;
  Color? get videoTint => null;
  Color? get effectiveTint => null;
  bool get followEnabled => false;
  set followEnabled(bool _) {}
  Color? get buttonTint => null;

  static void syncDrama(BuildContext context, Drama? drama) {}

  Future<void> sync(String dramaId, String? path) async {}

  void applyVideoTint(Color color) {}

  void resetVideoTint() {}

  void reset() {}
}

/// 从封面文件提取一个可用于染表面层的种子色。（保留供后续按需启用）
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
  ui.Codec? codec;
  try {
    if (bytes.isEmpty) return null;
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 64,
      targetHeight: 64,
    );
    final frame = await codec!.getNextFrame();
    image = frame.image;
    final data = await image!.toByteData(format: ui.ImageByteFormat.rawRgba);
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
