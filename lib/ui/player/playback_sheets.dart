import 'dart:async';

import 'package:flutter/material.dart';

import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../theme/app_theme.dart';
import '../theme/poster_palette.dart';
import '../widgets/frosted_glass.dart';
import 'cast_page.dart';
import 'danmaku_settings.dart';

// 缓存键带上当前取色值：海报/视频一换色，播放器弹层与投屏页的局部主题
// 必须跟着重建，否则会一直停留在第一次打开时的旧色（跟随失效）。
(Color, Color?, ThemeData)? _darkPlayerTheme;

ThemeData playerTheme(BuildContext context) {
  final theme = Theme.of(context);
  if (theme.brightness == Brightness.dark) return theme;
  final seed = theme.colorScheme.primary;
  final tint = PosterPalette.instance.effectiveTint;
  if (_darkPlayerTheme case (final cachedSeed, final cachedTint, final dark)
      when cachedSeed == seed && cachedTint == tint) {
    return dark;
  }
  final dark = AppTheme.build(
    seed,
    Brightness.dark,
    television: false,
    surfaceTint: tint,
  );
  _darkPlayerTheme = (seed, tint, dark);
  return dark;
}

Future<void> showPlayerSheet(
  BuildContext context,
  WidgetBuilder builder, {
  bool dark = true,
}) {
  final theme = dark ? playerTheme(context) : Theme.of(context);
  final height = MediaQuery.sizeOf(context).height * .6;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    // 弹层也用统一高斯玻璃：底色调透明，让 FrostedGlass 去糊后面的画面。
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints.tightFor(height: height),
    builder: (context) => Theme(
      data: theme,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: theme.colorScheme.onSurface),
        child: FrostedGlass(
          radius: 24,
          width: double.infinity,
          height: height,
          blur: 28,
          elevated: false,
          child: Builder(builder: builder),
        ),
      ),
    ),
  );
}

class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(spacing: 8, children: children),
    ),
  );
}

const sheetTitle = TextStyle(fontSize: 20, fontWeight: FontWeight.w700);

class PlaybackSettings extends StatelessWidget {
  const PlaybackSettings({
    super.key,
    required this.session,
    required this.onFailure,
    this.onMiniWindow,
  });
  final PlaybackSession session;
  final VoidCallback onFailure;
  final VoidCallback? onMiniWindow;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SheetHeader(
        children: [
          const Expanded(child: Text('播放设置', style: sheetTitle)),
          GlassOrb(
            icon: Icons.close_rounded,
            size: 38,
            iconSize: 20,
            onTap: () => Navigator.pop(context),
            tooltip: '关闭',
          ),
        ],
      ),
      Expanded(
        child: PlaybackSettingsList(
          session: session,
          onFailure: onFailure,
          onMiniWindow: onMiniWindow,
          onCast: () {
            final navigator = Navigator.of(context);
            navigator.pop();
            unawaited(startCast(navigator.context, session));
          },
        ),
      ),
    ],
  );
}

class PlaybackSettingsList extends StatelessWidget {
  const PlaybackSettingsList({
    super.key,
    required this.session,
    required this.onFailure,
    this.onMiniWindow,
    required this.onCast,
  });
  final PlaybackSession session;
  final VoidCallback onFailure;
  final VoidCallback? onMiniWindow;
  final VoidCallback onCast;

  Future<void> _change(Future<void> Function() change) async {
    try {
      await change();
    } catch (_) {
      onFailure();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final label = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text('倍速', style: label),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final speed in playbackSpeeds)
                _Choice(
                  label: '${speed}x',
                  selected: speed == session.speed,
                  onSelected: () => _change(() => session.setSpeed(speed)),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text('清晰度', style: label),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: session.local
                ? [
                    _Choice(
                      label: session.qualityLabel,
                      selected: true,
                      onSelected: null,
                    ),
                  ]
                : [
                    for (final quality in [...session.qualities, 0])
                      _Choice(
                        label: quality == 0
                            ? (session.quality == 0
                                  ? session.qualityLabel
                                  : '自动')
                            : '${quality}P',
                        selected: quality == session.quality,
                        onSelected: session.ready
                            ? () => _change(() => session.setQuality(quality))
                            : null,
                      ),
                  ],
          ),
          const SizedBox(height: 18),
          Text('画面比例', style: label),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final fit in VideoFit.values)
                _Choice(
                  label: fit.label,
                  selected: fit == session.videoFit,
                  onSelected: () => _change(() => session.setVideoFit(fit)),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text(sleepTimerLabel(session), style: label),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final choice in sleepChoices)
                _Choice(
                  label: choice.label,
                  selected: choice.selected(session),
                  onSelected: () => choice.apply(session),
                ),
            ],
          ),
          if (session.danmakuSupported) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('弹幕'),
              value: session.danmakuEnabled,
              onChanged: (_) => _change(session.toggleDanmaku),
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              shape: const Border(),
              collapsedShape: const Border(),
              leading: const Icon(Icons.text_fields_rounded),
              title: const Text('弹幕样式'),
              subtitle: Text(
                '字号、颜色、透明度与显示区域',
                style: TextStyle(fontSize: 12, color: label.color),
              ),
              children: [
                DanmakuSettings(
                  session: session,
                  onFailure: onFailure,
                  dense: true,
                ),
              ],
            ),
          ],
          if (onMiniWindow case final onMiniWindow?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.picture_in_picture_alt_rounded),
              title: const Text('小窗播放'),
              onTap: onMiniWindow,
            ),
          if (castSupported)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cast_rounded),
              title: const Text('投屏'),
              onTap: onCast,
            ),
        ],
      );
    },
  );
}

typedef SleepChoice = ({
  String label,
  bool Function(PlaybackSession) selected,
  void Function(PlaybackSession) apply,
});

final List<SleepChoice> sleepChoices = [
  (
    label: '关闭',
    selected: (session) =>
        session.sleepMinutes == 0 && !session.sleepAtEpisodeEnd,
    apply: (session) => session.setSleepTimer(),
  ),
  (
    label: '播完本集',
    selected: (session) => session.sleepAtEpisodeEnd,
    apply: (session) => session.setSleepTimer(episodeEnd: true),
  ),
  for (final minutes in const [15, 30, 60, 90])
    (
      label: '$minutes 分钟',
      selected: (session) => session.sleepMinutes == minutes,
      apply: (session) => session.setSleepTimer(minutes: minutes),
    ),
];

String sleepTimerLabel(PlaybackSession session) {
  if (session.sleepAtEpisodeEnd) return '定时停止 · 本集播完后暂停';
  final at = session.sleepAt;
  if (at == null) return '定时停止';
  final time =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  return '定时停止 · $time 暂停';
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final bool selected;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) => FrostedGlass(
    radius: 20,
    frosted: false,
    elevated: false,
    selected: selected,
    onTap: onSelected,
    semanticLabel: label,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
        color: Colors.white.withValues(alpha: selected ? 1.0 : 0.92),
      ),
    ),
  );
}
