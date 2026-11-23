import 'dart:async';

import 'package:flutter/services.dart';

import 'diary_service.dart';

/// 下载期间的后台保活。
///
/// iOS 把 App 切到后台几秒后就会挂起整个进程，Go 那边的下载线程也跟着停。
/// 唯一能长期维持的办法是持有一条正在播放的音频通道（Info.plist 里开了
/// audio 后台模式），原生侧循环播放一段静音音频。
///
/// 只在下「有任务在跑」的时候开，全部结束立刻关，省电也省得占着音频通道。
/// 原生失败时会把原因回传（以前静默吞掉、还因为去重不再重试，等于永远没开）。
class BackgroundKeepAlive {
  BackgroundKeepAlive._();

  static const _channel = MethodChannel('duanju/device');
  static bool? _enabled;
  static String _lastError = '';
  static DateTime? _lastErrorAt;

  /// 有任务在跑就开、没有就关；状态没变时不重复调用原生。
  static void sync(bool needed) {
    if (_enabled == needed) return;
    _enabled = needed;
    unawaited(_apply(needed));
  }

  static Future<void> _apply(bool needed) async {
    try {
      final result = await _channel
          .invokeMapMethod<String, dynamic>('backgroundKeepAlive', needed);
      final ok = result?['ok'] == true;
      if (ok) {
        if (needed) DiaryService.add('[Download] 后台保活已开启');
        return;
      }
      _enabled = null; // 下次轮询还能再试
      _report(needed, '${result?['error'] ?? '未知原因'}');
    } catch (error) {
      _enabled = null;
      _report(needed, '$error');
    }
  }

  /// 失败日志按「同一条原因 30 秒内只记一次」来写，别把日记刷爆。
  static void _report(bool needed, String reason) {
    final now = DateTime.now();
    final repeated = reason == _lastError &&
        _lastErrorAt != null &&
        now.difference(_lastErrorAt!) < const Duration(seconds: 30);
    _lastError = reason;
    _lastErrorAt = now;
    if (repeated) return;
    DiaryService.add('[Download] 后台保活${needed ? '开启' : '关闭'}失败：$reason');
  }
}
