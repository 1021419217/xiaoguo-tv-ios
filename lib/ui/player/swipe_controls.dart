import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_device.dart';
import '../../playback_session.dart';
import 'fade_presence.dart';
import 'player_surface.dart';

const _episodeSwipeDistance = 60.0;

enum _Level { brightness, volume }

class SwipeControls extends StatefulWidget {
  const SwipeControls({
    super.key,
    required this.session,
    this.enabled = true,
    this.levels = false,
    this.episodes = false,
    required this.child,
  });
  final PlaybackSession session;
  final bool enabled;
  final bool levels;
  final bool episodes;
  final Widget child;

  @override
  State<SwipeControls> createState() => _SwipeControlsState();
}

class _SwipeControlsState extends State<SwipeControls> {
  int? _seekFrom;
  double _seekOffset = 0;
  int? _lastHapticStep;
  // 连续触觉（iOS Core Haptics）的速度状态
  DateTime? _lastSeekMoveAt;
  double _seekVelocity = 0;
  DateTime? _lastHapticAt;
  double _lastSentIntensity = 0;
  bool _hapticRunning = false;
  _Level? _level;
  double? _value;
  double _pending = 0;
  double? _episodeOffset;

  PlaybackSession get _session => widget.session;

  @override
  void didUpdateWidget(SwipeControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled) return;
    _seekCancel();
    _levelEnd();
    _episodeCancel();
  }

  int get _duration => _session.player.state.duration.inMilliseconds;

  int get _seekTarget => (_seekFrom! + _seekOffset).round().clamp(0, _duration);

  void _seekStart(DragStartDetails _) {
    if (!_session.ready || _duration <= 0) return;
    setState(() {
      _seekFrom = _session.player.state.position.inMilliseconds;
      _seekOffset = 0;
      _lastHapticStep = null;
    });
    // 兜底：若上一次手势异常退出没停掉触觉，这里先停，避免残留震动。
    _stopHaptic();
  }

  void _seekUpdate(DragUpdateDetails details) {
    final from = _seekFrom;
    if (from == null) return;
    final preferences = _session.store.playbackPreferences;
    final span = math.min(_duration, preferences.swipeSeekSpan);
    final offset = _seekOffset + details.delta.dx / context.size!.width * span;
    final clamped = offset.clamp(-from, _duration - from).toDouble();
    setState(() => _seekOffset = clamped);

    if (preferences.swipeSeekHaptic) {
      _updateHaptic(from, clamped, span, details.delta.dx);
    }
  }

  void _seekEnd(DragEndDetails _) {
    if (_seekFrom == null) return;
    final target = _seekTarget;
    setState(() {
      _seekFrom = null;
      _lastHapticStep = null;
    });
    _stopHaptic();
    unawaited(_session.seekTo(Duration(milliseconds: target)));
  }

  void _seekCancel() {
    if (_seekFrom != null) {
      setState(() {
        _seekFrom = null;
        _lastHapticStep = null;
      });
      _stopHaptic();
    }
  }

  void _resetHaptic() {
    _lastSeekMoveAt = null;
    _seekVelocity = 0;
    _lastHapticAt = null;
    _lastSentIntensity = 0;
  }

  void _setHapticRunning(bool running) {
    if (_hapticRunning == running) return;
    _hapticRunning = running;
    if (running) {
      unawaited(AppDevice.hapticStart());
    } else {
      unawaited(AppDevice.hapticStop());
    }
  }

  /// 速度驱动的震动：慢滑静默，手一加速就渐次绵密起来。
  ///
  /// iOS 用 Core Haptics 连续事件（真实酥麻感）；其他平台没有该引擎，
  /// 退回原来的离散刻度 click，避免功能倒退。
  void _updateHaptic(int from, double clamped, int span, double deltaX) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      // 端点触发的离散震动（兼容平台）
      final target = (from + clamped).round().clamp(0, _duration);
      final step = (span / 12).round().clamp(1, 1 << 30);
      final hapticStep = (target / step).round();
      if (_lastHapticStep == null || hapticStep != _lastHapticStep) {
        _lastHapticStep = hapticStep;
        unawaited(HapticFeedback.selectionClick());
      }
      return;
    }

    final now = DateTime.now();
    // 用「每秒在屏上滑过的像素」衡量速度；两次 update 间隔作分母。
    final previous = _lastSeekMoveAt;
    _lastSeekMoveAt = now;
    if (previous == null) return;
    final dt = now.difference(previous).inMicroseconds / 1e6;
    if (dt <= 0 || dt > 0.2) {
      // 间隔过长（停住或卡顿）视为速度归零，让震动平滑淡出而非突然中断。
      _seekVelocity *= 0.5;
    } else {
      final instant = deltaX.abs() / dt; // px/s
      // 指数平滑，抹掉单帧抖动，同时起步跟手、停手很快衰减。
      _seekVelocity = _seekVelocity * 0.6 + instant * 0.4;
    }

    // 速度→强度：低于起步阈值完全静默，之后线性爬升到 1。
    const startPxPerSec = 180.0;
    const fullPxPerSec = 1800.0;
    final intensity =
        ((_seekVelocity - startPxPerSec) / (fullPxPerSec - startPxPerSec))
            .clamp(0.0, 1.0);
    // 锐度随速度提高：低强度偏圆润，高强度更细密酥麻。
    final sharpness = 0.35 + intensity * 0.55;

    // 慢滑（速度低于起步阈值）直接静默，不启动引擎。
    if (intensity <= 0.001) {
      _setHapticRunning(false);
      return;
    }

    // 节流：60ms 内且强度变化不大就不重复跨 isolate，减少通道压力。
    final lastAt = _lastHapticAt;
    final since = lastAt == null ? 1 << 30 : now.difference(lastAt).inMilliseconds;
    if (_hapticRunning && since < 60 && (intensity - _lastSentIntensity).abs() < 0.08) {
      return;
    }
    _lastHapticAt = now;
    _lastSentIntensity = intensity;

    // 先确保引擎在跑（内部有去重，只有首次真正 start）。
    _setHapticRunning(true);
    unawaited(
      AppDevice.hapticUpdate(intensity: intensity, sharpness: sharpness),
    );
  }

  void _stopHaptic() {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _setHapticRunning(false);
    }
    _resetHaptic();
  }

  Future<void> _levelStart(DragStartDetails details) async {
    final level = details.localPosition.dx < context.size!.width / 2
        ? _Level.brightness
        : _Level.volume;
    setState(() {
      _level = level;
      _value = null;
      _pending = 0;
    });
    final value = await (level == _Level.brightness
        ? AppDevice.brightness()
        : AppDevice.volume());
    if (!mounted || _level != level || _value != null) return;
    if (value == null) return setState(() => _level = null);
    _apply(value + _pending);
  }

  void _levelUpdate(DragUpdateDetails details) {
    if (_level == null) return;
    final delta = -details.delta.dy / context.size!.height;
    if (_value case final value?) {
      _apply(value + delta);
    } else {
      _pending += delta;
    }
  }

  void _apply(double value) {
    final next = value.clamp(0.0, 1.0);
    setState(() => _value = next);
    unawaited(
      _level == _Level.brightness
          ? AppDevice.setBrightness(next)
          : AppDevice.setVolume(next),
    );
  }

  void _levelEnd() {
    if (_level != null) setState(() => _level = null);
  }

  int get _episodeStep {
    final offset = _episodeOffset ?? 0;
    if (offset.abs() < _episodeSwipeDistance) return 0;
    return offset < 0 ? 1 : -1;
  }

  void _episodeStart(DragStartDetails _) => setState(() => _episodeOffset = 0);

  void _episodeUpdate(DragUpdateDetails details) {
    final offset = _episodeOffset;
    if (offset == null) return;
    setState(() => _episodeOffset = offset + details.delta.dy);
  }

  void _episodeEnd(DragEndDetails _) {
    final step = _episodeStep;
    _episodeCancel();
    if (step != 0) unawaited(_session.play(_session.index + step));
  }

  void _episodeCancel() {
    if (_episodeOffset != null) setState(() => _episodeOffset = null);
  }

  String? _episodeLabel() => switch (_episodeStep) {
    1 => _session.hasNext ? '松手播放下一集' : '已经是最后一集',
    -1 => _session.hasPrevious ? '松手播放上一集' : '已经是第一集',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final seek =
        widget.enabled &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final levels = seek && widget.levels;
    final episodes = seek && !levels && widget.episodes;
    final episodeLabel = _episodeLabel();
    final level = _level;
    final value = _value;
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onHorizontalDragStart: seek ? _seekStart : null,
          onHorizontalDragUpdate: seek ? _seekUpdate : null,
          onHorizontalDragEnd: seek ? _seekEnd : null,
          onHorizontalDragCancel: seek ? _seekCancel : null,
          onVerticalDragStart: levels
              ? (details) => unawaited(_levelStart(details))
              : episodes
              ? _episodeStart
              : null,
          onVerticalDragUpdate: levels
              ? _levelUpdate
              : episodes
              ? _episodeUpdate
              : null,
          onVerticalDragEnd: levels
              ? (_) => _levelEnd()
              : episodes
              ? _episodeEnd
              : null,
          onVerticalDragCancel: levels
              ? _levelEnd
              : episodes
              ? _episodeCancel
              : null,
          child: widget.child,
        ),
        FadePresence(
          child: _seekFrom != null
              ? _badge(_seekLabel())
              : level != null && value != null
              ? _badge(_levelBar(level, value))
              : episodeLabel != null
              ? _badge(
                  Text(
                    episodeLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : null,
        ),
      ],
    );
  }

  Widget _badge(Widget child) => IgnorePointer(
    child: Align(
      alignment: const Alignment(0, -.4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      ),
    ),
  );

  Widget _seekLabel() => Text.rich(
    TextSpan(
      text: formatClock(Duration(milliseconds: _seekTarget)),
      children: [
        TextSpan(
          text: ' / ${formatClock(_session.player.state.duration)}',
          style: TextStyle(color: Colors.white.withValues(alpha: .6)),
        ),
      ],
    ),
    style: const TextStyle(
      color: Colors.white,
      fontSize: 22,
      fontWeight: FontWeight.w700,
      fontFeatures: [FontFeature.tabularFigures()],
    ),
  );

  Widget _levelBar(_Level level, double value) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 10,
    children: [
      Icon(
        level == _Level.brightness
            ? Icons.brightness_6_rounded
            : value == 0
            ? Icons.volume_off_rounded
            : Icons.volume_up_rounded,
        size: 22,
        color: Colors.white,
      ),
      SizedBox(
        width: 120,
        child: LinearProgressIndicator(
          value: value,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
          color: Colors.white,
          backgroundColor: Colors.white.withValues(alpha: .25),
        ),
      ),
    ],
  );
}
