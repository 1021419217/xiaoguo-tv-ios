import 'package:media_kit/media_kit.dart';

/// 统一关闭 mpv 的「自动续播 / 位置记忆」，并在打开前指定起播点。
///
/// 为什么必须是通用层：mpv 默认 `resume-playback=yes`，打开文件时会读
/// watch-later 把画面 seek 到该文件上次记录的位置。App 里所有自建
/// `Player` 实例——主播放器、切集预加载 standby、直播播放器——共用同一个
/// libmpv 配置目录，**任何一处漏设置**，切集/换集就会跳到十几~几十秒。
/// 这正是短剧连播（夜社/黄桃等）、各影视站源都复现过的同一个问题，
/// 与具体站源无关。
///
/// 记忆续播由 App 自己的 `_resumeSeek` 精确控制，mpv 层一律不要自动恢复。
///
/// [startAt] 传 0 = 强制从头（显式写 mpv 的 `start=0`，优先级高于
/// watch-later 记录）；传 >0 = 由调用方自己定位，这里只把可能残留的
/// `start=0` 清成 `no`，避免影响后续的精确 seek。
Future<void> applyNoResumeGuard(Player player, {double startAt = 0}) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return;
  try {
    await platform.setProperty('resume-playback', 'no');
    await platform.setProperty('save-position-on-quit', 'no');
    // 不再把播放位置写进 watch-later 记录（默认会存 start）。
    // 已有旧记录仍可能被读取，所以还要靠 open 时的 Media.start 兜住。
    try {
      await platform.setProperty('watch-later-options', '');
    } catch (_) {}
    await platform.setProperty('start', startAt > 0 ? 'no' : '0');
  } catch (_) {
    // 个别 libmpv 版本不接受 'no'；忽略即可，调用方仍有起播兜底。
  }
}
