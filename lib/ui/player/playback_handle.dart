import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_session.dart';

Player _player() => Player(
  configuration: const PlayerConfiguration(
    bufferSize: 32 * 1024 * 1024,
    // 诊断用：error 级会把 libmpv 的具体原因吞掉，日志里只剩 Failed to open。
    // 提到 warn 后 playback_session 会把原生报错抄进「播放调试日记」。
    logLevel: MPVLogLevel.warn,
  ),
);

class PlaybackHandle {
  PlaybackHandle({
    required AppRepository repository,
    required LocalStore store,
    required DramaDetail detail,
    required int index,
    double position = 0,
    bool autoplay = true,
    bool preopen = true,
  }) {
    final main = _player();
    final standby = preopen ? _player() : null;
    _videos[main] = VideoController(main);
    if (standby != null) _videos[standby] = VideoController(standby);
    session = PlaybackSession(
      repository: repository,
      store: store,
      detail: detail,
      player: main,
      standby: standby,
      index: index,
      position: position,
      autoplay: autoplay,
    );
    // 风格已固定：不再周期性截取视频帧取色。那套 sampler 每 2 秒一次
    // notifyListeners，是播放中界面反复重绘闪烁的来源之一。
  }

  late final PlaybackSession session;
  final _videos = <Player, VideoController>{};

  VideoController video(Player player) => _videos[player]!;

  void dispose() {
    session.dispose();
  }
}
