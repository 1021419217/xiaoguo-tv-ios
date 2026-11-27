import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../playback_session.dart';

Player _player() {
  final player = Player(
    configuration: const PlayerConfiguration(
      bufferSize: 32 * 1024 * 1024,
      // 诊断用：error 级会把 libmpv 的具体原因吞掉，日志里只剩 Failed to open。
      // 提到 warn 后 playback_session 会把原生报错抄进「播放调试日记」。
      logLevel: MPVLogLevel.warn,
    ),
  );
  // 切集跳秒的真正根源与修法（排查结论）：
  // mpv 的 watch-later 会在每次 loadfile 时记录当前位置，下次打开同一 URL
  // 时恢复（resume-playback 默认 yes）。而 media_kit 的 setProperty 走
  // mpv_set_property_async（异步队列），在 open 前一刻才设置 resume-playback=no
  // 根本来不及在 loadfile 恢复之前生效——这是之前几版修复全部无效的原因。
  // 正确做法：在 Player 创建时就设置。创建到 open 之间有用户操作间隔，
  // 异步队列早已执行完毕，loadfile 时 resume-playback 已是 no，不再恢复。
  final platform = player.platform;
  if (platform is NativePlayer) {
    unawaited(platform.setProperty('resume-playback', 'no'));
    // 同时不再往 watch-later 记录里写位置，物理上不再产生新记录。
    unawaited(platform.setProperty('watch-later-options', ''));
  }
  return player;
}

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
  }

  late final PlaybackSession session;
  final _videos = <Player, VideoController>{};

  VideoController video(Player player) => _videos[player]!;

  void dispose() => session.dispose();
}
