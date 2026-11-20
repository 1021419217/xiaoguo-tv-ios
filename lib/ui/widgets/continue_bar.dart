import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/poster_palette.dart';
import 'focus_ring.dart';

/// 短剧之家式「继续观看」横条玻璃卡：白色圆形播放钮 + 剧名 + 进度，
/// 下方可带两条统计（已看完 / 已预约）。底色跟随当前海报色相。
class ContinueWatchingBar extends StatelessWidget {
  const ContinueWatchingBar({
    super.key,
    required this.title,
    required this.progress,
    this.onTap,
    this.stats = const [],
  });

  final String title;
  final String progress;
  final VoidCallback? onTap;

  /// 每条统计是 (标题, 数值)，例如 ('已看完', '41')。
  final List<(String, String)> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    final tint = PosterPalette.instance.buttonTint ??
        (dark ? Colors.white : theme.colorScheme.onSurface);
    return FocusRing(
      radius: 22,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Material(
            color: tint.withValues(alpha: dark ? 0.12 : 0.06),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(
                color: tint.withValues(alpha: dark ? 0.20 : 0.12),
              ),
            ),
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow_rounded,
                            color: Color(0xFF111114),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 2,
                            children: [
                              Text(
                                '继续观看',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: ink.withValues(alpha: 0.55),
                                ),
                              ),
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: ink,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          progress,
                          style: TextStyle(
                            fontSize: 12,
                            color: ink.withValues(alpha: 0.62),
                          ),
                        ),
                      ],
                    ),
                    if (stats.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Divider(
                          height: 1,
                          color: tint.withValues(alpha: 0.14),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          for (final (i, stat) in stats.indexed) ...[
                            if (i > 0) const SizedBox(width: 18),
                            Expanded(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 5,
                                children: [
                                  Icon(
                                    i == 0
                                        ? Icons.check_circle_outline_rounded
                                        : Icons.calendar_month_outlined,
                                    size: 14,
                                    color: ink.withValues(alpha: 0.6),
                                  ),
                                  Flexible(
                                    child: Text(
                                      '${stat.$1} ${stat.$2}  ›',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        color: ink.withValues(alpha: 0.72),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
