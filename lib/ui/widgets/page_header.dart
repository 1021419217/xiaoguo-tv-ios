import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../theme/tokens.dart';

/// 页面主标题：超粗白色大标题，可带灰色数量后缀（如「追剧 · 62」）。
/// 手机端与电视端同一套纯文字标题，不再把标题做成胶囊。
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.count,
    this.titleChild,
  });
  final String title;
  final List<Widget> actions;

  /// 显示在标题右侧的灰色数量，例如 `62`。
  final String? count;

  /// 自定义标题组件（如可点击的站源切换胶囊）。传入时替代纯文字标题，
  /// 靠左对齐且不撑满，方便与右侧操作组形成左右呼应的平衡构图。
  final Widget? titleChild;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 16, 0),
      child: SizedBox(
        height: 62,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: switch (titleChild) {
                  Widget child => Align(
                    alignment: Alignment.centerLeft,
                    child: child,
                  ),
                  _ =>
                    AppScope.formFactorOf(context) == FormFactor.television
                        ? _titleRow(context, 22)
                        : _titleRow(context, AppType.display),
                },
              ),
            ),
            if (actions.isNotEmpty)
              Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: actions),
          ],
        ),
      ),
    );
  }

  Widget _titleRow(BuildContext context, double fontSize) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              height: 1.1,
              color: colors.onSurface,
            ),
          ),
        ),
        if (count case final value?) ...[
          const SizedBox(width: 7),
          Text(
            '· $value',
            style: TextStyle(
              fontSize: fontSize > 24 ? 13 : 15,
              fontWeight: FontWeight.w500,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
