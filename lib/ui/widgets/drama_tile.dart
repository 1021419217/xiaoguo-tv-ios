import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models.dart';
import '../app_scope.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'cover_image.dart';
import 'focus_ring.dart';
import 'motion/motion_widgets.dart';

const _coverRadius = AppRadius.content;

class _PosterButton extends StatefulWidget {
  const _PosterButton({
    required this.cover,
    required this.caption,
    required this.label,
    required this.onTap,
    this.onMore,
    this.focusNode,
    this.autofocus = false,
    this.checked,
    this.aspect = 2 / 3,
  });
  final Widget cover;
  final List<Widget> caption;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onMore;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool? checked;
  final double aspect;

  @override
  State<_PosterButton> createState() => _PosterButtonState();
}

class _PosterButtonState extends State<_PosterButton> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final visible = focusVisible(_focused);
    final layer = _pressed ? 0.12 : (_hovered ? 0.08 : 0.0);
    final button = InkWell(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onTap: widget.onTap,
      onLongPress: widget.onMore,
      onSecondaryTap: widget.onMore,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onHover: (hovered) => setState(() => _hovered = hovered),
      onHighlightChanged: (pressed) => setState(() => _pressed = pressed),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: widget.aspect,
            child: FocusOutline(
              visible: visible,
              radius: _coverRadius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.cover,
                  IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(_coverRadius),
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: layer),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ...widget.caption,
        ],
      ),
    );
    return Semantics(
      label: widget.label,
      checked: widget.checked,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.contextMenu): ?widget.onMore,
        },
        child: AnimatedScale(
          scale: visible && AppScope.of(context).television ? 1.06 : 1,
          duration: const Duration(milliseconds: 120),
          child: button,
        ),
      ),
    );
  }
}

class DramaTile extends StatelessWidget {
  const DramaTile({
    super.key,
    required this.drama,
    required this.onTap,
    this.subtitle,
    this.rank,
    this.onMore,
    this.focusNode,
    this.autofocus = false,
    this.heroScope,
    this.showScore = false,
    this.exploreBlur = false,
    this.wide = false,
    this.aspect,
  });
  final Drama drama;
  final VoidCallback onTap;
  final String? heroScope;
  final bool showScore;
  final bool exploreBlur;
  final bool wide;
  final double? aspect;
  final String? subtitle;
  final int? rank;
  final VoidCallback? onMore;
  final FocusNode? focusNode;
  final bool autofocus;

  static TextStyle titleStyle(BuildContext context) => TextStyle(
    fontSize: AppScope.of(context).television ? 15 : 14,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  static TextStyle subtitleStyle(BuildContext context) => TextStyle(
    fontSize: AppScope.of(context).television ? 13 : 12,
    height: 1.3,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  static double extentFor(
    BuildContext context,
    double width, {
    bool wide = false,
  }) => (wide ? width * 9 / 16 : width * 1.5).ceilToDouble();

  @override
  Widget build(BuildContext context) => _PosterButton(
    cover: Stack(
      fit: StackFit.expand,
      children: [
        DramaCover(
          drama: drama,
          radius: _coverRadius,
          rank: rank,
          showScore: showScore,
          exploreBlur: exploreBlur,
          heroScope: AppScope.of(context).television || !Visibility.of(context)
              ? null
              : heroScope,
        ),
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_coverRadius),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.42, 1],
                colors: [Colors.transparent, Color(0xF2000000)],
              ),
            ),
          ),
        ),
        Positioned(
          left: 9,
          right: 9,
          bottom: 9,
          child: IgnorePointer(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  drama.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle ?? drama.category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.2,
                    color: Colors.white.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
    aspect: aspect ?? (wide ? 16 / 9 : 2 / 3),
    label:
        '${rank == null ? '' : '第$rank名，'}'
        '${drama.title}，${drama.episodes}集${drama.vip ? '，VIP' : ''}'
        '${showScore && drama.score.isNotEmpty ? '，评分${drama.score}' : ''}',
    onTap: onTap,
    onMore: onMore,
    focusNode: focusNode,
    autofocus: autofocus,
    caption: const [],
  );
}

class ProgressPoster extends StatelessWidget {
  const ProgressPoster({
    super.key,
    required this.drama,
    required this.progress,
    required this.caption,
    required this.onTap,
    this.tag,
    this.onMore,
    this.focusNode,
    this.width = 100,
    this.selected,
    this.badge,
    this.dotColor,
    this.heroScope,
  });
  final Drama drama;
  final String? heroScope;
  final double? progress;
  final String caption;
  final String? tag;
  final String? badge;
  final Color? dotColor;
  final VoidCallback onTap;
  final VoidCallback? onMore;
  final FocusNode? focusNode;
  final double width;
  final bool? selected;

  static const _titleLines = 2;

  static double extentFor(BuildContext context, double width) =>
      (width * 1.5).ceilToDouble();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final television = AppScope.of(context).television;
    return SizedBox(
      width: width,
      child: _PosterButton(
        cover: Stack(
          fit: StackFit.expand,
          children: [
            DramaCover(
              drama: drama,
              radius: _coverRadius,
              details: false,
              heroScope:
                  television || selected != null || !Visibility.of(context)
                  ? null
                  : heroScope,
            ),
            if (tag case final tag?)
              Positioned(
                left: AppSpace.sm,
                top: AppSpace.sm,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    dotColor == null ? AppSpace.sm : 6,
                    3,
                    AppSpace.sm,
                    3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: AppRadius.badgeAll,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (dotColor case final dotColor?) ...[
                        DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: dotColor,
                          ),
                          child: const SizedBox.square(dimension: 4),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        tag,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: AppType.caption,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (badge case final badge? when selected == null)
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(
                      color: colors.onPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            if (television)
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(
                      Radius.circular(_coverRadius),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [.55, 1],
                      colors: [Colors.transparent, Color(0xB3000000)],
                    ),
                  ),
                ),
              ),
            if (progress case final progress?)
              Positioned(
                left: television ? 8 : _coverRadius,
                right: television ? 8 : _coverRadius,
                bottom: television ? 8 : 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(television ? 2 : 1.5),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: television ? 4 : 3,
                    color: colors.primaryFixedDim,
                    backgroundColor: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.zero,
                    stopIndicatorColor: Colors.transparent,
                  ),
                ),
              ),
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_coverRadius),
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.42, 1],
                    colors: [Colors.transparent, Color(0xF2000000)],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 9,
              right: 9,
              bottom: 9,
              child: IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drama.title,
                      maxLines: _titleLines,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (selected case final selected?) ...[
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: selected ? 1 : 0,
                  duration: Motion.of(context, Motion.short),
                  curve: Motion.standard,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_coverRadius),
                      border: Border.all(color: colors.primary, width: 3),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 8,
                top: 8,
                child: AnimatedContainer(
                  duration: Motion.of(context, Motion.short),
                  curve: Motion.standard,
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? colors.primary
                        : Colors.black.withValues(alpha: 0.35),
                    border: selected
                        ? null
                        : Border.all(color: Colors.white, width: 2),
                  ),
                  child: ToggleIconSwitcher(
                    child: selected
                        ? Icon(
                            Icons.check_rounded,
                            key: const ValueKey(true),
                            size: 18,
                            color: colors.onPrimary,
                          )
                        : const SizedBox.shrink(key: ValueKey(false)),
                  ),
                ),
              ),
            ],
          ],
        ),
        label:
            '${drama.title}，${tag == null ? '' : '$tag，'}${badge == null ? '' : '$badge，'}$caption',
        checked: selected,
        onTap: onTap,
        onMore: onMore,
        focusNode: focusNode,
        caption: const [],
      ),
    );
  }
}
