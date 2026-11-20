import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_session.dart';
import '../theme/poster_palette.dart';
import 'frame_color_sampler.dart';

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
    // 播放时周期性从当前视频帧取主色，驱动播放器控件跟随视频色调变化；
    // 每次从 session.player 即时读取，切集换了 player 也能跟上。
    _sampler = FrameColorSampler(() => session.player)..start();
  }

  late final PlaybackSession session;
  late final FrameColorSampler _sampler;
  final _videos = <Player, VideoController>{};

  VideoController video(Player player) => _videos[player]!;

  void dispose() {
    _sampler.stop();
    PosterPalette.instance.resetVideoTint();
    session.dispose();
  }
}
