import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../theme/poster_palette.dart';

/// 周期性从当前播放帧取主色，让播放器控件跟随视频色调实时变化。
///
/// 用 media_kit 的 screenshot 拿到 JPEG 字节，复用海报取色的同一套解码与
/// 色相直方图算法；每 2 秒一次、仅在播放中采样，色相变化超过阈值的帧
/// 才会通知重建，避免视频颜色微抖导致控件闪烁。
class FrameColorSampler {
  FrameColorSampler(this._playerOf);

  /// 每次采样都重新读取当前 player——切集时 PlaybackSession 会换 player。
  final Player Function() _playerOf;
  Timer? _timer;
  int _generation = 0;
  var _running = false;

  void start({Duration interval = const Duration(seconds: 2)}) {
    if (_running) return;
    _running = true;
    unawaited(_sample());
    _timer = Timer.periodic(interval, (_) => unawaited(_sample()));
  }

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  Future<void> _sample() async {
    if (!_running || !PosterPalette.instance.followEnabled) return;
    final generation = _generation;
    try {
      final player = _playerOf();
      if (!player.state.playing) return;
      final bytes = await player.screenshot(format: 'image/jpeg');
      if (generation != _generation || !_running) return;
      if (bytes == null || bytes.isEmpty) return;
      final color = await extractColorFromImageBytes(bytes);
      if (generation != _generation || !_running || color == null) return;
      PosterPalette.instance.applyVideoTint(color);
    } catch (_) {
      // 部分硬解/渲染组合下截图会失败，静默跳过，下一轮再试。
    }
  }
}
