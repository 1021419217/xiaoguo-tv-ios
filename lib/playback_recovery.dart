import 'models.dart';

enum PlaybackRecoveryAction { alternative, refresh, stop }

class PlaybackRecovery {
  static const maxAttempts = 3;
  int _attempts = 0;
  bool _refreshed = false;

  void reset() {
    _attempts = 0;
    _refreshed = false;
  }

  PlaybackRecoveryAction next(PlaybackPlan plan) {
    if (_attempts >= maxAttempts) {
      return PlaybackRecoveryAction.stop;
    }
    if (plan.hasAlternative) {
      _attempts++;
      return PlaybackRecoveryAction.alternative;
    }
    if (!_refreshed) {
      _attempts++;
      _refreshed = true;
      return PlaybackRecoveryAction.refresh;
    }
    return PlaybackRecoveryAction.stop;
  }
}

class PlaybackHealth {
  static const stallTimeout = Duration(seconds: 20);
  static const seekStallTimeout = Duration(seconds: 8);
  Duration? _position;
  DateTime? _lastProgress;

  void reset() {
    _position = null;
    _lastProgress = null;
  }

  bool stalled({
    required Duration position,
    required bool playing,
    required bool foreground,
    required DateTime now,
    // 开场用 Media.start 定位中间分片时，卡住往往意味着定位失败。
    // 这种场景用更短的超时快速降级，避免干等满 20 秒。
    Duration? timeout,
  }) {
    if (!playing || !foreground || position != _position) {
      _position = position;
      _lastProgress = now;
      return false;
    }
    _lastProgress ??= now;
    return now.difference(_lastProgress!) >= (timeout ?? stallTimeout);
  }
}
