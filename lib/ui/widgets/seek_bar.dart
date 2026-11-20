import 'package:flutter/material.dart';

import '../player/player_surface.dart' show formatClock;
import '../theme/poster_palette.dart';
import 'contained_slider.dart';

/// 播放器进度条：左侧「已播」、右侧「/ 总时长」，中间是胶囊形轨道。
///
/// 以前只有一根默认 M3 滑杆——轨道末端带一个停靠点，拖动时轨道突然变粗，
/// 和全局的玻璃胶囊语言格格不入，也看不到总时长。这里统一成：
/// 细胶囊轨道 + 主色进度 + 白色小圆点拇指，两端各给一个等宽数字的时间，
/// 拖到哪儿就显示哪儿的时间。
class SeekBar extends StatelessWidget {
  const SeekBar({
    super.key,
    required this.value,
    required this.duration,
    required this.buffered,
    this.onStart,
    this.onChanged,
    this.onEnd,
    this.enabled = true,
    this.showTimes = true,
    this.thumbRadius = 6,
    this.height = 4,
    this.followVideoColor = false,
  });

  /// 当前位置（毫秒），拖动时由调用方替换成手指位置。
  final double value;

  /// 总时长（毫秒），未知时传 0。
  final double duration;

  /// 已缓冲位置（毫秒）。
  final double buffered;

  final ValueChanged<double>? onStart;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onEnd;
  final bool enabled;

  /// 横屏底部已经单独放了时间，那边关掉，免得重复。
  final bool showTimes;
  final double thumbRadius;
  final double height;

  /// 播放器内开启：进度条已播段跟随当前视频帧主色。
  final bool followVideoColor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final videoTint = followVideoColor ? PosterPalette.instance.videoTint : null;
    final active = videoTint ?? colors.primary;
    final max = duration > 0 ? duration : 1.0;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: height,
        // 左右各留一个拇指半径，滑到两端时圆点不会被切掉。
        padding: EdgeInsets.symmetric(horizontal: thumbRadius + 1),
        activeTrackColor: active,
        inactiveTrackColor: Colors.white.withValues(alpha: .20),
        secondaryActiveTrackColor: Colors.white.withValues(alpha: .30),
        thumbColor: Colors.white,
        overlayShape: SliderComponentShape.noOverlay,
        // 默认 M3 拇指是「竖条 + 外圈」，这里换成干净的白点。
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: thumbRadius,
          elevation: 3,
          pressedElevation: 5,
        ),
        trackShape: const _CapsuleTrackShape(),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        showValueIndicator: ShowValueIndicator.never,
      ),
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            if (showTimes) ...[
              _Time(
                text: formatClock(Duration(milliseconds: value.round())),
                bold: true,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: ContainedSlider(
                slider: Slider(
                  value: value.clamp(0, max),
                  max: max,
                  secondaryTrackValue: buffered.clamp(0, max),
                  semanticFormatterCallback: (v) => formatClock(
                    Duration(milliseconds: v.round()),
                  ),
                  onChangeStart: enabled ? onStart : null,
                  onChanged: enabled ? onChanged : null,
                  onChangeEnd: onEnd,
                ),
              ),
            ),
            if (showTimes) ...[
              const SizedBox(width: 8),
              _Time(
                text: '/ ${formatClock(Duration(milliseconds: duration.round()))}',
                dim: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Time extends StatelessWidget {
  const _Time({required this.text, this.bold = false, this.dim = false});

  final String text;
  final bool bold;
  final bool dim;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    style: TextStyle(
      color: Colors.white.withValues(alpha: dim ? .52 : .92),
      fontSize: 12,
      height: 1,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
      letterSpacing: .2,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

/// 纯胶囊轨道：两端全圆角，不画 M3 的停靠点，也不随拖动变粗。
class _CapsuleTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _CapsuleTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.isEmpty) return;
    final canvas = context.canvas;
    final radius = Radius.circular(rect.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()..color = sliderTheme.inactiveTrackColor ?? const Color(0x33FFFFFF),
    );
    final buffered = secondaryOffset?.dx;
    if (buffered != null && buffered > rect.left) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(rect.left, rect.top, buffered, rect.bottom),
          radius,
        ),
        Paint()
          ..color =
              sliderTheme.secondaryActiveTrackColor ?? const Color(0x66FFFFFF),
      );
    }
    final activeRight = thumbCenter.dx.clamp(rect.left, rect.right);
    if (activeRight > rect.left) {
      final active = sliderTheme.activeTrackColor ?? Colors.white;
      final span = Rect.fromLTRB(rect.left, rect.top, activeRight, rect.bottom);
      canvas.drawRRect(
        RRect.fromRectAndRadius(span, radius),
        Paint()
          ..shader = LinearGradient(
            colors: [active.withValues(alpha: .72), active],
          ).createShader(span),
      );
    }
  }
}
