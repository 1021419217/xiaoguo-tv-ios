import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'core_bridge.dart';
import 'danmaku_controller.dart';
import 'danmaku_style.dart';
import 'diary_service.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_loader.dart';
import 'player_guards.dart';
import 'playback_preferences.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';

Size? videoDisplaySize(VideoParams parameters) {
  final width = (parameters.dw ?? 0) > 0 ? parameters.dw! : parameters.w ?? 0;
  final height = (parameters.dh ?? 0) > 0 ? parameters.dh! : parameters.h ?? 0;
  if (width <= 0 || height <= 0) return null;
  final rotation = (parameters.rotate ?? 0) % 180;
  return rotation == 90
      ? Size(height.toDouble(), width.toDouble())
      : Size(width.toDouble(), height.toDouble());
}

String _diagnostic(Object error) {
  final text = error.toString().replaceAll(
    RegExp(r'[a-z]+://\S+', caseSensitive: false),
    '[地址]',
  );
  return text.length > 300 ? text.substring(0, 300) : text;
}

class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.repository,
    required this.store,
    required this.detail,
    required this._player,
    this._standby,
    required int index,
    double position = 0,
    bool autoplay = true,
  }) : _engaged = autoplay,
       _index = index,
       _epoch = store.profileEpoch {
    final preferences = store.playbackPreferences;
    _speed = preferences.speed;
    _quality = preferences.quality;
    _danmakuEnabled = preferences.danmaku;
    _videoFit = preferences.videoFit;
    _unmutedVolume = store.playerVolume.clamp(1.0, 100.0);
    unawaited(_player.setVolume(_unmutedVolume));
    _loader = PlaybackLoader(repository);
    _preloader = PlaybackPreloader(repository)..addListener(_prime);
    danmaku = DanmakuController(repository)
      ..setEnabled(_danmakuEnabled)
      ..setMerge(preferences.danmakuMerge)
      ..setBlockedWords(preferences.danmakuWords);
    store.addListener(_accessChanged);
    store.addListener(_syncBlockedWords);
    _bind();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => saveProgress(quiet: true),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_closed || !_acceptErrors || _loading || _error != null) return;
      final position = player.state.position;
      // 开场定位到记忆点后若迟迟没有进度，多半是中间分片定位失败。
      // 这种场景用 8 秒短超时快速降级（C），正常播放仍用 20 秒避免误判。
      final nearStart =
          _openedAt > 0 && position.inMilliseconds / 1000 < _openedAt + 3;
      if (_health.stalled(
        position: position,
        playing: player.state.playing && _playIntent,
        foreground: _foreground,
        now: DateTime.now(),
        timeout: nearStart ? PlaybackHealth.seekStallTimeout : null,
      )) {
        unawaited(_recover('position_stalled'));
      }
      // 另一种卡顿：position 正常前进（音频在走）但画面不更新。
      // position 维度的 stalled 抓不到，必须单独看渲染帧号。
      unawaited(_checkVideoFrozen());
    });
    // 「记忆播放」关闭时，所有入口一律从头播：忽略上层传入的续播位置。
    // 这样详情、本地下载、投屏恢复的行为一致，也彻底不走 mpv 中间分片定位。
    final startAt = preferences.rememberProgress ? position : 0.0;
    unawaited(play(index, position: startAt, playWhenReady: autoplay));
  }

  void _bind() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final size = videoDisplaySize(player.state.videoParams);
    if (size != null) _videoSize = size;
    _buffering(player.state.buffering);
    final stream = player.stream;
    _subscriptions.addAll([
      stream.error.listen(_playerError),
      stream.completed.listen(_completed),
      stream.position.listen((position) {
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
          // 进度真正往前走了（超过开场定位点 1 秒）才算定位成功，
          // 之后卡住就按「播放中途卡顿」处理，保留位置恢复。
          if (position.inMilliseconds / 1000 > _openedAt + 1) {
            _positionAdvanced = true;
          }
        }
        _sync();
      }),
      stream.playing.listen((playing) {
        if (!playing) endBoost();
        _sync();
      }),
      stream.buffering.listen((buffering) {
        _buffering(buffering);
        _sync();
      }),
      for (final changes in [stream.duration, stream.buffer, stream.rate])
        changes.listen((_) => _sync()),
      stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size == null || _closed) return;
        _videoSize = size;
        _notify();
        unawaited(_logVideoOutput(parameters));
      }),
    ]);
  }

  String _videoOutput = '';

  Future<void> _logVideoOutput(VideoParams parameters) async {
    final platform = player.platform;
    if (parameters.pixelformat == null || platform is! NativePlayer) return;
    try {
      final values = [
        for (final name in [
          'hwdec-current',
          'current-vo',
          'video-codec',
          'container-fps',
        ])
          await platform.getProperty(name),
      ];
      final line =
          '[Video] decoder=${store.playbackPreferences.televisionDecoder.name} hwdec=${values[0]} vo=${values[1]} codec=${values[2]} fps=${values[3]} format=${parameters.pixelformat} hw_format=${parameters.hwPixelformat} size=${parameters.w}x${parameters.h}';
      if (_closed || line == _videoOutput) return;
      _videoOutput = line;
      DiaryService.add(line);
    } catch (_) {}
  }

  final AppRepository repository;
  final LocalStore store;
  DramaDetail detail;
  Player _player;
  Player? _standby;
  late final DanmakuController danmaku;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  final _recovery = PlaybackRecovery();
  final _health = PlaybackHealth();
  final int _epoch;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Timer? _boostTimer;
  Timer? _stallTimer;
  Timer? _volumeTimer;
  Timer? _sleepTimer;
  DateTime? _sleepAt;
  int _sleepMinutes = 0;
  bool _sleepAtEpisodeEnd = false;
  bool _advancingSeason = false;
  Future<void> _operations = Future<void>.value();
  Future<void> _rates = Future<void>.value();
  int _index;
  int _openedIndex = -1;
  int _generation = 0;
  int _seekSequence = 0;
  bool _loading = true;
  bool _online = false;
  bool _localFailure = false;
  bool _loginRequired = false;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _pendingError = false;
  bool _boosting = false;
  bool _boostLocked = false;
  bool _engaged;
  bool _staleAudio = false;
  bool _stalled = false;
  String _loadingMessage = '正在准备播放';
  String? _error;
  String? _saveWarning;
  String? _savedProgressKey;
  bool _savedQuietly = false;
  PlaybackPlan? _plan;
  PlaybackPlan? _standbyPlan;
  int _standbyIndex = -1;
  bool _standbyOpen = false;
  DateTime _standbyAt = DateTime(2000);
  double _openedAt = 0;
  double _speed = 1;
  int _quality = 0;
  bool _danmakuEnabled = true;
  Size? _videoSize;
  VideoFit _videoFit = VideoFit.auto;
  double _resumePosition = 0;
  // 本集是否真正吐出过播放进度。false 表示开场定位阶段就卡住，
  // 自动恢复时应从 0 播，避免反复用同一个记忆卡点定位（死循环）。
  bool _positionAdvanced = false;
  double _unmutedVolume = 100;
  // 视频冻结看门狗：位置/音频前进但画面不更新时，用帧号停滞判定并唤醒。
  int _lastFrameNumber = -1;
  Duration _framePosition = Duration.zero;
  DateTime? _frozenSince;
  DateTime? _lastWakeAt;
  int _wakeAttempts = 0;
  bool _frameCheckBusy = false;
  // 唤醒多次仍不涨帧（多半是「画面本来就静止」的视频，不是故障），
  // 就临时停用看门狗，宁可不管也不能反复 seek 破坏正常播放。
  DateTime? _frameWatchOffUntil;

  Player get player => _player;

  Player? get standby => _standbyOpen ? _standby : null;
  int get standbyIndex => _standbyOpen ? _standbyIndex : -1;
  int get index => _index;
  Episode get episode => detail.episodes[_index];
  bool get loading => _loading;
  String get loadingMessage => _loadingMessage;
  String? get error => _error;
  bool get localFailure => _localFailure;
  bool get loginRequired => _loginRequired;
  String? get saveWarning => _saveWarning;
  bool get ready => !_loading && _error == null;

  bool get stalled => _stalled;

  bool get paused => !_playIntent;
  bool get boosting => _boosting;
  bool get boostLocked => _boostLocked;
  Size? get videoSize => _videoSize;
  double get aspectRatio => switch (_videoSize) {
    final size? => size.width / size.height,
    null => 9 / 16,
  };
  bool get aspectKnown => _videoSize != null;
  VideoFit get videoFit => _videoFit;
  double get speed => _speed;
  DateTime? get sleepAt => _sleepAt;
  int get sleepMinutes => _sleepMinutes;
  bool get sleepAtEpisodeEnd => _sleepAtEpisodeEnd;
  int get quality => _quality;
  bool get local => _plan?.local == true;
  List<int> get qualities => _plan?.qualities ?? const [];
  bool get danmakuSupported => SourceSite.byId(detail.drama.source).danmaku;
  bool get danmakuEnabled => _danmakuEnabled;
  PlaybackPreferences get preferences => _preferences;
  DanmakuStyle get danmakuStyle => DanmakuStyle.of(store.playbackPreferences);
  bool get hasPrevious => _index > 0;
  bool get hasNext => _index + 1 < detail.episodes.length;
  String get qualityLabel {
    final plan = _plan;
    if (plan != null && plan.local) {
      return plan.quality > 0 ? '本地 ${plan.quality}P' : '本地';
    }
    if (_quality > 0) return '${_quality}P';
    return plan != null && plan.quality > 0 ? '自动（${plan.quality}P）' : '自动';
  }

  double get currentPosition =>
      _openedIndex == _index && player.state.position > Duration.zero
      ? player.state.position.inMilliseconds / 1000
      : _resumePosition;

  bool get _usable => !_closed && store.profileEpoch == _epoch;
  bool _current(int ticket) => _usable && ticket == _generation;

  PlaybackPreferences get _preferences => store.playbackPreferences.copyWith(
    speed: _speed,
    quality: _quality,
    danmaku: _danmakuEnabled,
    videoFit: _videoFit,
    autoAdvance: true,
    preload: true,
  );

  double get _rate => _boosting ? store.playbackPreferences.boostSpeed : _speed;

  void _buffering(bool buffering) {
    _stallTimer?.cancel();
    if (buffering) {
      _stallTimer = Timer(const Duration(milliseconds: 500), () {
        if (_closed || !player.state.buffering) return;
        _stalled = true;
        _notify();
      });
    } else if (_stalled) {
      _stalled = false;
      _notify();
    }
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _accessChanged() {
    if (_closed) return;
    if (store.profileEpoch != _epoch || store.locked) {
      _preloader.clear();
      _dropStandby();
      _playIntent = false;
      endBoost();
      unawaited(player.pause());
    }
    if (store.profileEpoch != _epoch ||
        store.locked ||
        !store.allowsSource(detail.drama.source)) {
      danmaku.setPlan(null);
    }
  }

  void _syncBlockedWords() {
    if (_closed) return;
    danmaku.setBlockedWords(store.playbackPreferences.danmakuWords);
  }

  void _sync() {
    _syncDanmaku();
    _syncPreload();
  }

  void _syncDanmaku() {
    if (_closed) return;
    final state = player.state;
    danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available:
          ready &&
          _openedIndex == _index &&
          _usable &&
          !store.locked &&
          store.allowsSource(detail.drama.source),
    );
  }

  void _syncPreload() {
    if (_closed) return;
    if (!_foreground ||
        _plan?.local == true ||
        !ready ||
        _openedIndex != _index ||
        !_usable ||
        !_engaged ||
        store.locked ||
        !hasNext) {
      _preloader.clear();
      return;
    }
    final state = player.state;
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    final ahead = state.buffer.inMilliseconds - position;
    if (_standby != null) {
      if (_standbyOpen &&
          DateTime.now().difference(_standbyAt) > const Duration(minutes: 8)) {
        _dropStandby();
      }
      if (_standbyIndex >= 0 || duration <= 0 || ahead < 3000) return;
    } else {
      if (!state.playing || state.buffering || !_playIntent) {
        _preloader.pause();
        return;
      }
      // 预加载时机刻意保守：只在下半段 / 尾巴临近时准备，避免一开播就
      // 和当前集抢带宽（解析下一集地址虽然不下载视频，但仍是并发请求）。
      // ahead < 5000 再兜一道：当前缓冲不足 5 秒时绝不掺和。
      if (duration <= 0 ||
          position < 2000 ||
          (position < duration ~/ 2 && duration - position > 45000) ||
          ahead < 5000) {
        return;
      }
    }
    _preloader.prepare(
      detail.drama,
      detail.episodes[_index + 1],
      quality: _quality,
      online: _online,
    );
  }

  void _playerError(String error) {
    if (_closed || !_acceptErrors || error.trim().isEmpty) return;
    DiaryService.add('[Play] 播放器报错：${_diagnostic(error)}');
    _queueRecovery('player_error');
  }

  void _completed(bool completed) {
    if (!completed || _loading || _closed || !_acceptErrors || _error != null) {
      return;
    }
    final duration = player.state.duration;
    final position = player.state.position;
    if (duration <= Duration.zero
        ? position <= Duration.zero
        : position < duration - const Duration(seconds: 2)) {
      _queueRecovery('early_completion');
    } else if (_foreground && hasNext && !_sleepAtEpisodeEnd) {
      unawaited(play(_index + 1));
    } else if (_foreground &&
        !_sleepAtEpisodeEnd &&
        detail.nextSeason != null) {
      unawaited(_playNextSeason());
    } else {
      final sleeping = _sleepAtEpisodeEnd;
      if (sleeping) _clearSleep();
      _stop();
      if (sleeping) _notify();
    }
  }

  void _stop() {
    _playIntent = false;
    endBoost();
    unawaited(player.pause());
    unawaited(saveProgress());
  }

  void syncSeasons(List<DramaSeason> seasons) {
    if (_closed ||
        seasons.isEmpty ||
        identical(seasons, detail.seasons) ||
        !seasons.any((season) => season.drama.id == detail.drama.id)) {
      return;
    }
    detail = DramaDetail(
      detail.drama,
      detail.episodes,
      warning: detail.warning,
      seasons: seasons,
    );
  }

  Future<bool> playSeason(DramaSeason season) async {
    if (season.drama.id == detail.drama.id) return true;
    if (_advancingSeason || !_usable) return false;
    _advancingSeason = true;
    final ticket = _generation;
    _dropStandby();
    _preloader.clear();
    _notify();
    try {
      await saveProgress();
      final next = await repository.detail(season.drama);
      if (!_current(ticket) || !_foreground) return false;
      if (next.episodes.isEmpty) {
        throw AppFailure('${season.label}暂时没有可播放的分集');
      }
      final watch = store.watched(season.drama.id);
      var index = 0;
      if (watch != null) {
        final at = next.episodes.indexWhere(
          (episode) => episode.number == watch.episode,
        );
        if (at >= 0) index = at;
      }
      final position =
          watch != null &&
              !watch.finished &&
              watch.episode == next.episodes[index].number
          ? watch.position
          : 0.0;
      detail = DramaDetail(
        repository.catalogUpdates.current(season.drama).merge(next.drama),
        next.episodes,
        warning: next.warning,
        seasons: detail.seasons,
      );
      _openedIndex = -1;
      _index = index;
      _online = false;
      _notify();
      await play(index, position: position);
      return true;
    } catch (error) {
      DiaryService.add('[Play] 手动切换到${season.label}失败：${_diagnostic(error)}');
      if (_current(ticket)) _stop();
      _notify();
      return false;
    } finally {
      _advancingSeason = false;
    }
  }

  Future<void> _playNextSeason() async {
    final season = detail.nextSeason;
    if (_advancingSeason || season == null || !_usable) return;
    _advancingSeason = true;
    final ticket = _generation;
    DiaryService.add('[Play] 本季播完，切换到${season.label}');
    _dropStandby();
    _preloader.clear();
    try {
      await saveProgress();
      final next = await repository.detail(season.drama);
      if (!_current(ticket) || !_foreground) return;
      if (next.episodes.isEmpty) throw AppFailure('下一季暂时没有可播放的分集');
      detail = DramaDetail(
        repository.catalogUpdates.current(season.drama).merge(next.drama),
        next.episodes,
        warning: next.warning,
        seasons: detail.seasons,
      );
      _openedIndex = -1;
      _index = 0;
      _online = false;
      _notify();
      await play(0);
    } catch (error) {
      DiaryService.add('[Play] 切换下一季失败：${_diagnostic(error)}');
      if (_current(ticket)) _stop();
      _notify();
    } finally {
      _advancingSeason = false;
    }
  }

  void _clearSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepAt = null;
    _sleepMinutes = 0;
    _sleepAtEpisodeEnd = false;
  }

  void setSleepTimer({int minutes = 0, bool episodeEnd = false}) {
    if (_closed) return;
    _clearSleep();
    if (episodeEnd) {
      _sleepAtEpisodeEnd = true;
    } else if (minutes > 0) {
      final after = Duration(minutes: minutes);
      _sleepMinutes = minutes;
      _sleepAt = DateTime.now().add(after);
      _sleepTimer = Timer(after, () {
        _clearSleep();
        if (!_closed) _stop();
        _notify();
      });
    }
    _notify();
  }

  void _queueRecovery(String reason) {
    if (_closed || !_acceptErrors || _error != null) return;
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) return;
    final ticket = _generation;
    final position = player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (!_current(ticket) || !_foreground || !_acceptErrors) return;
      _pendingError = false;
      final state = player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover(reason));
    });
  }

  Future<void> _recover(String reason) async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    // A 治本：开场定位从未真正推进过（_positionAdvanced=false），说明卡在
    // Media.start 的中间分片定位上。此时 currentPosition 会回退到记忆卡点，
    // 再用它恢复必然重复卡死。改为从 0 播，彻底打破死循环。
    final position = _positionAdvanced ? currentPosition : 0.0;
    if (!_positionAdvanced && position == 0.0) {
      DiaryService.add('[Play] 开场定位未成功，恢复改为从头播放');
    }
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    DiaryService.add(
      '[Play] 自动恢复 原因=$reason 处理=${action.name} 线路=${current.routeIndex + 1}/${current.routeCount}',
    );
    if (action != PlaybackRecoveryAction.stop) {
      await play(_index, position: position, recovery: action);
      return;
    }
    _resumePosition = position;
    final ticket = _generation;
    try {
      await _serialize(() async {
        if (!_current(ticket)) return;
        try {
          await saveProgress();
          _openedIndex = -1;
          await player.stop();
        } finally {
          await _release(current.session);
        }
      });
    } catch (_) {}
    if (!_current(ticket)) return;
    _loading = false;
    _localFailure = current.local;
    _loginRequired = false;
    final symptom = switch (reason) {
      'position_stalled' => '画面长时间没有进度',
      'video_frozen' => '画面卡住不动（有声音）',
      'early_completion' => '视频提前结束',
      'open_exception' => '视频打开失败',
      _ => '播放器报错',
    };
    _error = current.local
        ? '$symptom，本地视频没能播放。可重试或重新下载，也可以改为在线播放。'
        : '$symptom，自动恢复未成功。可重试、换一集或选择其他清晰度。';
    _notify();
  }

  Future<void> _release(String session) async {
    if (session.isEmpty) return;
    await repository.release(session).catchError((Object _) {});
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  Future<void> _configure(Player target, PlaybackPlan plan) async {
    final platform = target.platform;
    if (platform is! NativePlayer) return;
    final hwdec = switch (store.playbackPreferences.televisionDecoder) {
      TelevisionDecoder.software => 'no',
      TelevisionDecoder.hardware when Platform.isAndroid => 'mediacodec-copy',
      TelevisionDecoder.hardware when Platform.isIOS || Platform.isMacOS =>
        'videotoolbox-copy',
      _ when Platform.isWindows => 'd3d11va-copy',
      _ when Platform.isAndroid => 'auto-safe',
      _ when Platform.isMacOS => 'auto-safe',
      _ => null,
    };
    if (hwdec != null) await platform.setProperty('hwdec', hwdec);
    if (Platform.isAndroid) {
      await platform.setProperty('hwdec-codecs', 'all');
      await platform.setProperty('vd-lavc-skiploopfilter', 'nonkey');
      await platform.setProperty('vd-lavc-threads', '4');
      await platform.setProperty('vd-lavc-fast', 'yes');
      await platform.setProperty('video-sync', 'audio');
      await platform.setProperty('framedrop', 'vo');
    }
    await platform.setProperty(
      'demuxer-lavf-o',
      [
        'seg_max_retry=3',
        'strict=experimental',
        'allowed_extensions=ALL',
        'advanced_editlist=0',
        plan.local
            ? 'protocol_whitelist=[file,crypto,data]'
            : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
        if (plan.decryptionKey.isNotEmpty)
          'decryption_key=${plan.decryptionKey}',
      ].join(','),
    );
    await platform.setProperty('network-timeout', '20');
    // 切集跳秒的根因：mpv 的 resume-playback 默认 yes，open 同一 URL 时会
    // 读 watch-later 把画面自动 seek 到上次记录的位置（十几/几十秒不等，
    // 取决于该集上次看到哪）。这个 seek 发生在 open 之后，所以 Dart 层在
    // open 刚返回时读到的 position 还是 0 —— 正是日志里「打开位置 0.0s」
    // 却跳秒的矛盾来源。历史上单设 start='0' 修不好，也是被它覆盖。
    // 续播一律由 App 自己的 _resumeSeek 精确控制，mpv 层不要自动恢复。
    // 3.0.4 实测日志：只设 resume-playback=no 仍会跳到 8.0/28.0/29.7s，
    // 说明还有别的恢复通道；3.0.5 起统一走公共防护（含显式 start=0）。
    // 这里覆盖「主播放器」和「切集预加载 standby」（_open 也调用本函数）。
    await applyNoResumeGuard(target, startAt: 0);
    // 自检：把这些属性读回来写进日记。3.0.6 的教训是「设了却不知道有没有
    // 生效」——日志里有真实值，下次定位不用再猜。
    try {
      final resume = await platform.getProperty('resume-playback');
      final startProp = await platform.getProperty('start');
      final saveQuit = await platform.getProperty('save-position-on-quit');
      DiaryService.add(
        '[Play] 防续播自检 resume-playback=$resume start=$startProp '
        'save-position-on-quit=$saveQuit',
      );
    } catch (_) {}
    // 深层兜底：清掉 mpv 的 watch-later 旧记录。这些文件按 URL 记录每集
    // 「上次看到哪」——实测切集起播 17.5/17.4/18.7 秒正是这么来的。
    // App 的记忆播放走自己的 WatchEntry，不依赖 mpv 这份记录，清空安全。
    // 属性返回 `~~/watch_later` 这种未展开路径时 Directory 解析会失败，
    // 这里静默跳过，不影响播放。
    try {
      final raw = await platform.getProperty('watch-later-directory');
      final path = '${raw ?? ''}'.trim();
      var cleared = 0;
      if (path.isNotEmpty && path != 'no' && !path.startsWith('~~')) {
        final dir = Directory(path);
        if (await dir.exists()) {
          await for (final entry in dir.list()) {
            if (entry is File) {
              try {
                await entry.delete();
                cleared += 1;
              } catch (_) {}
            }
          }
        }
      }
      DiaryService.add('[Play] 清续播记录 path=$path 删除$cleared个');
    } catch (_) {}
    if (!plan.local &&
        (Uri.tryParse(plan.url)?.path.toLowerCase().endsWith('.m3u8') ?? false)) {
      await platform.setProperty('demuxer-readahead-secs', '30');
    }
  }

  Future<void> play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recovery,
    bool playWhenReady = true,
  }) async {
    if (!_usable || index < 0 || index >= detail.episodes.length) return;
    endBoost();
    _staleAudio = false;
    if (index != _index) _online = false;
    if (recovery == null &&
        position == 0 &&
        _standbyOpen &&
        _standbyIndex == index &&
        !_online) {
      return _swap(index, playWhenReady);
    }
    _dropStandby();
    final warmed = recovery == null
        ? _preloader.take(
            detail.drama,
            detail.episodes[index],
            quality: _quality,
            online: _online,
          )
        : null;
    _preloader.clear();
    final ticket = ++_generation;
    _seekSequence++;
    danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recovery == null) {
      _recovery.reset();
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    _openedAt = position;
    _positionAdvanced = false;
    // 换集/重开：重置画面看门狗（新的视频源要重新判断，不能沿用停用状态）。
    _lastFrameNumber = -1;
    _framePosition = Duration.zero;
    _frozenSince = null;
    _wakeAttempts = 0;
    _frameWatchOffUntil = null;
    _index = index;
    _loading = true;
    _error = null;
    _localFailure = false;
    _loginRequired = false;
    _loadingMessage = switch (recovery) {
      PlaybackRecoveryAction.alternative => '正在切换备用线路',
      PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
      _ => '正在准备播放',
    };
    _notify();
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    var installed = false;
    try {
      await _serialize(() async {
        if (!_current(ticket)) return;
        await saveProgress();
        if (!_current(ticket)) return;
        _openedIndex = -1;
        await player.stop();
        final previous = _plan;
        _plan = null;
        if (recovery == PlaybackRecoveryAction.alternative) {
          retained = previous;
        } else if (previous != null) {
          await _release(previous.session);
        }
      });
      if (!_current(ticket)) return;
      prepared = retained != null
          ? await _loader.fallback(retained!)
          : warmed != null
          ? await _loader.use(warmed)
          : await _loader.load(
              detail.drama,
              detail.episodes[index],
              quality: _quality,
              online: _online,
            );
      if (prepared == null) return;
      final plan = prepared;
      await _serialize(() async {
        if (!_current(ticket)) {
          await _release(plan.session);
          return;
        }
        if (plan.url.isEmpty) throw AppFailure('站源未返回播放地址，请重试');
        await _configure(player, plan);
        await _limitCache(player, !_engaged);
        await _selectAudio(player, true);
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        // 关键：open 前显式声明起播点，从源头掐掉 mpv 读 watch-later 跳位置。
        //   position == 0（切集/普通打开）→ start=0，强制从头；
        //   position > 0（记忆续播）→ start=no，清掉上一集残留的 0，
        //     由 _resumeSeek 在拿到时长后精确定位（避免中间分片长缓冲）。
        // mpv 里 start 一旦被显式设置就不再做 watch-later 恢复，这是比
        // resume-playback=no 更硬的开关（3.0.4 证明后者单独用没挡住）。
        // 起播点写进 loadfile 的媒体参数：这是 mpv 里优先级最高的一层，
        // 高于 setProperty('start') 和 watch-later 记录。
        // 依据（实测日志）：3.0.6 已经设了 setProperty('start','0')，切集仍
        // 从 17.5s/17.4s/18.7s 起播（每集自己上次看到的位置），随即被
        // _observeStart 拉回 0.1s —— 能拉回说明 0 位置存在（排除分片时间戳），
        // 真正原因就是 setProperty('start') 没挡住 watch-later。
        // 这里只对「从头播」用 1 毫秒；记忆续播不传 start（仍按老路：先 0
        // 打开再 _resumeSeek 精确定位），避免在打开阶段定位中间分片。
        final fromStart = const Duration(milliseconds: 1);
        await player.open(
          Media(
            plan.url,
            httpHeaders: plan.headers,
            start: position > 0 ? Duration.zero : fromStart,
          ),
          play: _foreground && _playIntent,
        );
        if (!_current(ticket)) return;
        _openedIndex = index;
        _health.reset();
        await _setRate(_rate);
        if (!_current(ticket)) return;
        _loading = false;
        _notify();
        danmaku.setPlan(plan);
        _syncDanmaku();
        // 记忆续播：带超时的二次 seek；失败/超时就留在本集开头继续播。
        if (position > 0 && !plan.local) {
          unawaited(_resumeSeek(position, ticket));
        } else if (position == 0) {
          // 切集/普通打开：mpv 自动续播已在 _configure 里关掉，这里只记录
          // 起播位置用于诊断，不再强制 seek（热 seek 会让切集后花屏）。
          unawaited(_observeStart(ticket));
        }
      });
    } catch (error) {
      if (_current(ticket)) {
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          _queueRecovery('open_exception');
        } else {
          if (prepared != null) await _release(prepared.session);
          if (_current(ticket)) {
            DiaryService.add('[Play] 无法播放：${_diagnostic(error)}');
            _loading = false;
            _localFailure = error is AppFailure && error.code == 'local_media';
            _loginRequired =
                error is AppFailure && error.code == 'source_login';
            _error = error is AppFailure ? error.message : '无法播放这一集，请重试或换一集。';
            _notify();
          }
        }
      } else if (prepared != null && !installed) {
        await _release(prepared.session);
      }
    } finally {
      if (warmed != null && !installed) await _release(warmed.session);
      if (retained != null) await _release(retained!.session);
    }
  }

  /// 切集起播诊断 + 兜底归零。
  ///
  /// 主防线是 applyNoResumeGuard（resume-playback=no + save-position-on-quit=no
  /// + 显式 start=0），从源头不让 mpv 恢复上次位置，因此正常情况下不会触发
  /// 这里的 seek，也就没有「两次 seek 导致花屏」的问题。
  /// 只有起播仍明显偏离（>2s，例如某些 HLS 首分片时间戳不从 0 起）才归零一次，
  /// 并把 seek 后的真实位置写进日记，便于区分是续播残留还是分片时间戳。
  Future<void> _observeStart(int ticket) async {
    if (!_current(ticket) || _closed) return;
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (_current(ticket) && !_closed) {
      final state = player.state;
      if (state.duration > Duration.zero || state.buffer > Duration.zero) {
        break;
      }
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (!_current(ticket) || _closed) return;
    // mpv 的 watch-later 续播恢复是**异步**的：常在 open 后几百毫秒、甚至
    // 播了一会儿才把位置跳到旧值。只在某一个时间点读一次会漏掉（这正是
    // 「快进过再切集才跳秒、直接切反而正常」的原因——快进留下了可被恢复的
    // 位置）。这里盯住起播后的 2.5 秒，任何时刻位置明显偏离就拉回开头。
    final watchUntil = DateTime.now().add(const Duration(milliseconds: 2500));
    final startSeq = _seekSequence;
    var corrected = false;
    while (_current(ticket) && !_closed && DateTime.now().isBefore(watchUntil)) {
      final pos = player.state.position;
      if (pos.inMilliseconds > 2000) {
        // 用户在这 2.5 秒内自己拖了进度（切集后立刻快进/后退也很常见），
        // seekTo 会递增 _seekSequence —— 这是用户的意图，绝不能拉回开头。
        if (_seekSequence != startSeq) break;
        DiaryService.add(
          '[Play] 切集诊断：起播偏移 ${(pos.inMilliseconds / 1000).toStringAsFixed(1)}s，回开头',
        );
        corrected = true;
        try {
          await player.seek(Duration.zero).timeout(const Duration(seconds: 4));
          await Future<void>.delayed(const Duration(milliseconds: 400));
          final after = player.state.position;
          final tail = (after.inMilliseconds / 1000).toStringAsFixed(1);
          DiaryService.add(
            '[Play] 回开头后位置 ${tail}s'
            '${after.inMilliseconds > 2000 ? '（仍偏移，疑似分片时间戳）' : ''}',
          );
        } catch (e) {
          DiaryService.add('[Play] 回开头失败: $e');
        }
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!corrected) {
      final pos = player.state.position;
      DiaryService.add(
        '[Play] 切集诊断：起播位置 ${(pos.inMilliseconds / 1000).toStringAsFixed(1)}s',
      );
    }
  }

  /// 视频冻结看门狗：进度/音频正常前进但画面定格时自动唤醒。
  ///
  /// 症状（用户实际遇到）：①切集后有的集画面不动、进度条却在走，手动快进
  /// 一下才恢复；②切到别的 App 再回来，声音继续但画面不动，滑动几秒恢复。
  /// 两者本质相同——音频/解复用通路正常，**视频解码或输出层停摆**。
  ///
  /// 判定依据是 mpv 的 `estimated-frame-number`（已渲染帧号）：位置前进了
  /// 但帧号不涨，就是画面冻结。唤醒方式与用户手动滑动一致——在当前位置
  /// 向前 seek 0.3 秒，触发关键帧重解、重建视频输出。连续两次仍无效才走
  /// 常规恢复（切线路/重开），避免一直反复 seek。
  Future<void> _checkVideoFrozen() async {
    if (_frameCheckBusy || _closed || !_foreground || !_playIntent) return;
    if (_loading || _error != null) return;
    final offUntil = _frameWatchOffUntil;
    if (offUntil != null && DateTime.now().isBefore(offUntil)) return;
    if (!player.state.playing || player.state.buffering) {
      _frozenSince = null;
      return;
    }
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    _frameCheckBusy = true;
    try {
      final raw = await platform.getProperty('estimated-frame-number');
      final frames = int.tryParse('$raw'.trim()) ?? -1;
      if (frames < 0) return;
      final position = player.state.position;
      final advanced = position - _framePosition;
      final stuck =
          _lastFrameNumber >= 0 && frames <= _lastFrameNumber;
      _framePosition = position;
      _lastFrameNumber = frames;
      if (advanced > const Duration(milliseconds: 400) && stuck) {
        final now = DateTime.now();
        _frozenSince ??= now;
        final frozenFor = now.difference(_frozenSince!);
        final cooledDown = _lastWakeAt == null ||
            now.difference(_lastWakeAt!) >= const Duration(seconds: 5);
        if (frozenFor >= const Duration(seconds: 2) && cooledDown) {
          _lastWakeAt = now;
          _frozenSince = null;
          _wakeAttempts += 1;
          DiaryService.add(
            '[Play] 画面冻结（位置在走/帧号不涨），第 $_wakeAttempts 次唤醒',
          );
          if (_wakeAttempts > 2) {
            // 三次轻量唤醒都没让帧号动起来：更可能是「画面本来就静止」
            // （过场黑屏/静态镜头），继续 seek 只会破坏播放体验。
            // 临时停用 3 分钟，期间一律不干预；真有故障用户手动滑即可。
            _wakeAttempts = 0;
            _frameWatchOffUntil = DateTime.now().add(const Duration(minutes: 3));
            DiaryService.add('[Play] 画面长时间静止，暂停自动唤醒 3 分钟');
          } else {
            unawaited(_wakeVideo(position));
          }
        }
      } else if (!stuck) {
        if (_frozenSince != null) {
          DiaryService.add('[Play] 画面已恢复');
        }
        _frozenSince = null;
        _wakeAttempts = 0;
      }
    } catch (_) {
      // 该属性不可用就跳过检测，绝不影响正常播放。
    } finally {
      _frameCheckBusy = false;
    }
  }

  Future<void> _wakeVideo(Duration position) async {
    try {
      await player
          .seek(position + const Duration(milliseconds: 300))
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      DiaryService.add('[Play] 画面唤醒失败: $e');
    }
  }

  /// 记忆续播的二次定位：先从 0 播起来，等播放器拿到时长/缓冲后，
  /// 再 seek 到历史位置。这样避免 Media.start 在打开阶段定位中间分片的
  /// 长时间缓冲。任何一步失败或超时都放弃定位，留在本集开头继续播，
  /// 不再用同一个卡点反复重开（那是转圈 60 秒的根源）。
  Future<void> _resumeSeek(double position, int ticket) async {
    final target = Duration(milliseconds: (position * 1000).round());
    // 先把记忆位置夹到实际时长内，避免历史进度超过真实长度导致定位卡死。
    final duration = player.state.duration;
    if (duration > Duration.zero && target >= duration - const Duration(seconds: 2)) {
      return;
    }
    // 等 mpv 解析出时长 / 建立缓冲，最多等 6 秒。
    final waitUntil = DateTime.now().add(const Duration(seconds: 6));
    while (_current(ticket) && !_closed) {
      final state = player.state;
      if (state.duration > Duration.zero || state.buffer > Duration.zero) break;
      if (DateTime.now().isAfter(waitUntil)) {
        DiaryService.add('[Play] 续播等待缓冲超时，从头播放');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!_current(ticket) || _closed) return;
    try {
      await player.seek(target).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      DiaryService.add('[Play] 续播 seek 超时，从头播放');
      return;
    } catch (_) {
      return;
    }
    if (!_current(ticket) || _closed) return;
    _seekSequence++;
    _resumePosition = position;
    _syncDanmaku();
  }

  Future<void> _swap(int index, bool playWhenReady) async {
    final plan = _standbyPlan!;
    final next = _standby!;
    final previous = _player;
    final previousPlan = _plan;
    final volume = previous.state.volume;
    unawaited(saveProgress());
    _preloader.clear();
    final ticket = ++_generation;
    _seekSequence++;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    _recovery.reset();
    _playIntent = playWhenReady;
    _resumePosition = 0;
    _openedAt = 0;
    _positionAdvanced = false;
    _index = index;
    _error = null;
    _localFailure = false;
    _loginRequired = false;
    _loading = false;
    _standbyPlan = null;
    _standbyIndex = -1;
    _standbyOpen = false;
    _player = next;
    _standby = previous;
    _plan = plan;
    _bind();
    _openedIndex = index;
    _acceptErrors = true;
    final stopping = previous.stop().catchError((Object _) {});
    if (previousPlan != null) unawaited(_release(previousPlan.session));
    danmaku.setPlan(plan);
    _notify();
    _syncDanmaku();
    try {
      await _limitCache(next, false);
      await next.setVolume(volume);
      await _setRate(_rate);
      await stopping;
      await _selectAudio(next, true);
      if (_current(ticket) && _foreground && _playIntent) await next.play();
      // standby 是复用的 Player 实例，起播位置只记录到日记用于诊断；
      // 不再强制 seek 回开头（热 seek 会让切集后花屏）。
      if (_current(ticket)) unawaited(_observeStart(ticket));
    } catch (_) {
      if (_current(ticket)) _queueRecovery('open_exception');
    }
  }

  void _prime() {
    final standby = _standby;
    final next = _index + 1;
    if (_closed ||
        standby == null ||
        _standbyIndex >= 0 ||
        !_preloader.ready ||
        next >= detail.episodes.length) {
      return;
    }
    _standbyIndex = next;
    final plan = _preloader.take(
      detail.drama,
      detail.episodes[next],
      quality: _quality,
      online: _online,
    );
    if (plan == null) {
      _standbyIndex = -1;
      return;
    }
    _standbyPlan = plan;
    unawaited(_open(standby, plan));
  }

  Future<void> _open(Player standby, PlaybackPlan plan) async {
    try {
      await _configure(standby, plan);
      await _limitCache(standby, true);
      await _selectAudio(standby, false);
      // 预加载的永远是「下一集从头」，同样用 loadfile 级 start 参数挡续播。
      await standby.open(
        Media(
          plan.url,
          httpHeaders: plan.headers,
          start: const Duration(milliseconds: 1),
        ),
        play: false,
      );
    } catch (_) {
      if (identical(_standbyPlan, plan)) _dropStandby();
      return;
    }
    if (_closed || !identical(_standbyPlan, plan)) return;
    _standbyOpen = true;
    _standbyAt = DateTime.now();
    _notify();
  }

  void _dropStandby() {
    final plan = _standbyPlan;
    final opened = _standbyOpen || plan != null;
    _standbyPlan = null;
    _standbyIndex = -1;
    _standbyOpen = false;
    if (opened) unawaited(_standby?.stop().catchError((Object _) {}));
    if (plan != null) unawaited(_release(plan.session));
  }

  Future<void> _limitCache(Player target, bool limited) async {
    final platform = target.platform;
    if (platform is! NativePlayer) return;
    await platform.setProperty(
      'demuxer-max-bytes',
      '${(limited ? 4 : 32) * 1024 * 1024}',
    );
  }

  Future<int?> networkSpeed() async {
    final platform = player.platform;
    if (_closed || local || platform is! NativePlayer) return null;
    try {
      final value = await platform.getProperty('cache-speed');
      return double.tryParse(value)?.round();
    } catch (_) {
      return null;
    }
  }

  Future<void> _selectAudio(Player target, bool enabled) async {
    final platform = target.platform;
    if (platform is! NativePlayer || !Platform.isIOS) return;
    await platform.setProperty('aid', enabled ? 'auto' : 'no');
  }

  void start(int index, {double position = 0}) {
    if (!_usable) return;
    // 关闭「记忆播放」时忽略上层传入的续播位置，与构造函数保持一致。
    if (!store.playbackPreferences.rememberProgress) position = 0;
    final wasEngaged = _engaged;
    _engaged = true;
    if (index != _index ||
        (position - _openedAt).abs() > .5 ||
        _error != null) {
      unawaited(play(index, position: position));
      return;
    }
    _playIntent = true;
    if (!wasEngaged) unawaited(_limitCache(player, false));
    if (ready) unawaited(player.play());
  }

  Future<void> retry() =>
      play(_index, position: currentPosition, playWhenReady: true);

  Future<void> switchOnline() {
    _online = true;
    return retry();
  }

  Future<bool> next() async {
    if (!hasNext) return false;
    await play(_index + 1);
    return true;
  }

  Future<bool> previous() async {
    if (!hasPrevious) return false;
    await play(_index - 1);
    return true;
  }

  void togglePlayback() {
    if (!_usable || !ready) return;
    endBoost();
    _playIntent = !player.state.playing;
    _health.reset();
    if (_playIntent && player.state.completed) {
      unawaited(play(_index));
      return;
    }
    if (_playIntent && _staleAudio) {
      _staleAudio = false;
      unawaited(player.seek(player.state.position).then((_) => player.play()));
    } else {
      unawaited(player.playOrPause());
    }
    if (!_playIntent) unawaited(saveProgress());
    _syncDanmaku();
  }

  Future<bool> seekTo(Duration target) async {
    if (!_usable || !ready) return false;
    final ticket = ++_seekSequence;
    final generation = _generation;
    danmaku.beginSeek();
    var succeeded = false;
    try {
      await player.seek(target);
      succeeded = true;
    } catch (_) {
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        danmaku.endSeek(succeeded ? target : player.state.position);
      }
    }
    return succeeded;
  }

  Duration? seekBy(int seconds) {
    final duration = player.state.duration;
    if (!ready || duration <= Duration.zero) return null;
    final target = Duration(
      milliseconds: (player.state.position.inMilliseconds + seconds * 1000)
          .clamp(0, duration.inMilliseconds),
    );
    unawaited(seekTo(target));
    return target;
  }

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    return _rates.catchError((Object _) {});
  }

  void beginBoost() {
    if (!ready || _boostTimer != null || _boosting) return;
    _boostTimer = Timer(const Duration(milliseconds: 350), () {
      _boostTimer = null;
      if (_closed ||
          !ready ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _boosting = true;
      unawaited(_setRate(_rate));
      _notify();
    });
  }

  void holdBoost() {
    if (!_usable || _boosting) return;
    _boostTimer?.cancel();
    _boostTimer = null;
    _boosting = true;
    unawaited(_setRate(_rate));
    _notify();
  }

  void setBoostLocked(bool locked) {
    if (_boostLocked == locked) return;
    if (locked) {
      holdBoost();
      _boostLocked = true;
      _notify();
    } else {
      _boostLocked = false;
      endBoost();
      _notify();
    }
  }

  bool endBoost() {
    if (_boostLocked) return false;
    final boosted = _boosting;
    _boostTimer?.cancel();
    _boostTimer = null;
    _boosting = false;
    if (boosted) {
      unawaited(_setRate(_speed));
      _notify();
    }
    return boosted;
  }

  void setVolume(double value) {
    final volume = value.clamp(0.0, 100.0);
    if (volume > 0) {
      _unmutedVolume = volume;
      _volumeTimer?.cancel();
      _volumeTimer = Timer(const Duration(milliseconds: 500), _saveVolume);
    }
    _applyVolume(volume);
  }

  void _saveVolume() {
    _volumeTimer = null;
    unawaited(store.setPlayerVolume(_unmutedVolume).catchError((Object _) {}));
  }

  void _applyVolume(double volume) {
    if (!player.state.playing) _staleAudio = true;
    unawaited(player.setVolume(volume));
  }

  double changeVolume(double delta) {
    final volume = (player.state.volume + delta).clamp(0.0, 100.0);
    setVolume(volume);
    return volume;
  }

  double toggleMute() {
    final current = player.state.volume;
    if (current > 0) _unmutedVolume = current;
    final target = current > 0 ? 0.0 : _unmutedVolume;
    _applyVolume(target);
    return target;
  }

  Future<void> _savePreferences(PlaybackPreferences preferences) async {
    if (!_usable) throw StateError('当前用户已变更');
    await store.setPlaybackPreferences(preferences);
    if (!_usable) throw StateError('当前用户已变更');
  }

  Future<void> setSpeed(double value) async {
    if (value == _speed) return;
    await _savePreferences(_preferences.copyWith(speed: value));
    _speed = value;
    _notify();
    if (!_boosting) await _setRate(value);
  }

  Future<void> setVideoFit(VideoFit value) async {
    if (value == _videoFit) return;
    final previous = _videoFit;
    _videoFit = value;
    _notify();
    try {
      await _savePreferences(_preferences);
    } catch (_) {
      if (_videoFit == value) {
        _videoFit = previous;
        _notify();
      }
      rethrow;
    }
  }

  Future<void> setQuality(int value) async {
    if (value == _quality) return;
    await _savePreferences(_preferences.copyWith(quality: value));
    _quality = value;
    _preloader.clear();
    _notify();
    if (_plan?.local == true) return;
    await play(
      _index,
      position: currentPosition,
      playWhenReady: _error != null || player.state.playing,
    );
  }

  Future<void> setDanmakuMerge(bool merge) async {
    if (_preferences.danmakuMerge == merge) return;
    await _savePreferences(_preferences.copyWith(danmakuMerge: merge));
    danmaku.setMerge(merge);
  }

  Future<void> toggleDanmaku() async {
    if (!danmakuSupported) return;
    final enabled = !_danmakuEnabled;
    await _savePreferences(_preferences.copyWith(danmaku: enabled));
    _danmakuEnabled = enabled;
    danmaku.setEnabled(enabled);
    _syncDanmaku();
    _notify();
  }

  Future<void> setDanmakuScale(double value) async {
    final scale = value.clamp(danmakuScaleMin, danmakuScaleMax);
    await _savePreferences(_preferences.copyWith(danmakuScale: scale));
    _notify();
  }

  Future<void> setDanmakuColor(int value) async {
    await _savePreferences(_preferences.copyWith(danmakuColor: value));
    _notify();
  }

  Future<void> setDanmakuOpacity(double value) async {
    final opacity = value.clamp(.1, 1.0);
    await _savePreferences(_preferences.copyWith(danmakuOpacity: opacity));
    _notify();
  }

  Future<void> setDanmakuBold(bool value) async {
    await _savePreferences(_preferences.copyWith(danmakuBold: value));
    _notify();
  }

  Future<void> setDanmakuStroke(double value) async {
    final stroke = value.clamp(danmakuStrokeMin, danmakuStrokeMax);
    await _savePreferences(_preferences.copyWith(danmakuStroke: stroke));
    _notify();
  }

  Future<void> setDanmakuShadow(double value) async {
    final shadow = value.clamp(danmakuShadowMin, danmakuShadowMax);
    await _savePreferences(_preferences.copyWith(danmakuShadow: shadow));
    _notify();
  }

  Future<void> setDanmakuSpeed(double value) async {
    final speed = value.clamp(danmakuSpeedMin, danmakuSpeedMax);
    await _savePreferences(_preferences.copyWith(danmakuSpeed: speed));
    _notify();
  }

  Future<void> setDanmakuCoverage(DanmakuCoverage value) async {
    await _savePreferences(_preferences.copyWith(danmakuCoverage: value));
    _notify();
  }

  Future<void> setDanmakuWords(List<String> words) async {
    final normalized = normalizeDanmakuWords(words);
    await _savePreferences(_preferences.copyWith(danmakuWords: normalized));
    _notify();
  }

  void setForeground(bool visible) {
    if (_closed || _foreground == visible) return;
    DiaryService.add(visible ? '[Play] 应用回到前台' : '[Play] 应用不可见，暂停播放');
    _foreground = visible;
    _health.reset();
    // 前后台切换会跨过一段时间：position 可能跳变而帧号停在上次。
    // 清空帧检测基线，避免回来第一秒被判成「画面冻结」而误唤醒。
    // 真正的冻结（iOS 回收 VideoToolbox）会由看门狗在 2 秒后抓住。
    _lastFrameNumber = -1;
    _framePosition = Duration.zero;
    _frozenSince = null;
    _wakeAttempts = 0;
    _sync();
    if (!visible) {
      endBoost();
      _playIntent = false;
      unawaited(player.pause());
      unawaited(saveProgress());
    } else if (_pendingError) {
      _queueRecovery('foreground_pending_error');
    }
  }

  Future<void> saveProgress({bool quiet = false}) async {
    if (!_engaged || _openedIndex < 0 || store.profileEpoch != _epoch) return;
    final position = player.state.position.inMilliseconds / 1000;
    final duration = player.state.duration.inMilliseconds / 1000;
    if (position < .1) return;
    final key = '${detail.drama.id}:$_openedIndex:$position:$duration';
    if (_savedProgressKey == key &&
        _saveWarning == null &&
        (quiet || !_savedQuietly)) {
      return;
    }
    final entry = WatchEntry(
      drama: repository.catalogUpdates.current(detail.drama),
      episode: detail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await store.saveWatch(entry, quiet: quiet);
      _savedProgressKey = key;
      _savedQuietly = quiet;
      if (_saveWarning != null) {
        _saveWarning = null;
        _notify();
      }
    } catch (_) {
      if (_saveWarning == null) {
        _saveWarning = '观看进度尚未保存，请检查存储空间后重试。';
        _notify();
      }
    }
  }

  @override
  void dispose() {
    unawaited(saveProgress());
    _closed = true;
    _generation++;
    store.removeListener(_accessChanged);
    store.removeListener(_syncBlockedWords);
    _saveTimer?.cancel();
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _boostTimer?.cancel();
    _stallTimer?.cancel();
    _volumeTimer?.cancel();
    _sleepTimer?.cancel();
    if (_volumeTimer != null) _saveVolume();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    danmaku.dispose();
    _preloader.dispose();
    final session = _plan?.session ?? '';
    unawaited(_release(session));
    final standbyPlan = _standbyPlan;
    if (standbyPlan != null) unawaited(_release(standbyPlan.session));
    final standby = _standby;
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations.catchError((Object _) {}).then((_) async {
        await _rates.catchError((Object _) {});
        await player.dispose();
        await standby?.dispose();
      }),
    );
    super.dispose();
  }
}
