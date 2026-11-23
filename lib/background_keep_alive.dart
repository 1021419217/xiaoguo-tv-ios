import 'dart:async';

import 'package:flutter/services.dart';

/// 下载期间的后台保活。
///
/// iOS 把 App 切到后台几秒后就会挂起整个进程，Go 那边的下载线程也跟着停。
/// 唯一能长期维持的办法是持有一条正在播放的音频通道（Info.plist 里开了
/// audio 后台模式），原生侧循环播放一段静音音频，音量 0，用 mixWithOthers
/// 不会打断用户正在听的东西。
///
/// 只在下「有任务在跑」的时候开，全部结束立刻关，省电也省得占着音频通道。
class BackgroundKeepAlive {
  BackgroundKeepAlive._();

  static const _channel = MethodChannel('duanju/device');
  static bool? _enabled;

  /// 有任务在跑就开、没有就关；状态没变时不重复调用原生。
  static void sync(bool needed) {
    if (_enabled == needed) return;
    _enabled = needed;
    unawaited(
      _channel.invokeMethod<bool>('backgroundKeepAlive', needed).catchError((
        Object _,
      ) {
        // 原生侧失败（模拟器、权限缺失等）时回退状态，下次还能再试。
        _enabled = null;
        return false;
      }),
    );
  }
}
