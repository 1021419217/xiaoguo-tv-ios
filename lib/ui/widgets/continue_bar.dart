import 'package:flutter/material.dart';

import 'frosted_glass.dart';

/// 短剧之家式「继续观看」磨砂玻璃横条：白色圆形播放钮 + 剧名 + 进度，
/// 下方可带两条统计（已看完 / 已预约）。固定中性冷灰玻璃，不随海报变化。
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
    // 整条卡就是一块磨砂玻璃：背景模糊 + 斜向受光 + 顶部弧光 +
    // 雾面噪点 + 上亮下暗渐变细边，与底栏/顶栏胶囊同一套质感。
    return FrostedGlass(
      radius: 22,
      blur: 18,
      onTap: onTap,
      semanticLabel: onTap == null ? null : '继续观看 $title',
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
              child: Divider(height: 1, color: ink.withValues(alpha: 0.14)),
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
    );
  }
}
