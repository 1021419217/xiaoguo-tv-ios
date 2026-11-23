import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app_scope.dart';

/// 全应用统一的确认/提示弹窗：磨砂玻璃 + 大圆角 + 胶囊按钮。
///
/// 原来各处直接用 Material 的 `AlertDialog`，出来的是一块不透明深灰板，
/// 标题还特别大，和顶栏/底栏那套玻璃语言完全不搭。`DialogTheme` 只能改
/// 背景色和圆角，加不了 `BackdropFilter`，所以这里单独实现。
///
/// 返回值：确认 true / 取消或点遮罩 false（和 `showDialog<bool>` 一致）。
Future<bool?> showGlassDialog({
  required BuildContext context,
  required String title,
  String? message,
  Widget? content,
  String cancelLabel = '取消',
  String confirmLabel = '确定',
  bool danger = false,
  bool barrierDismissible = true,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: barrierDismissible,
  barrierColor: Colors.black.withValues(alpha: 0.42),
  builder: (dialogContext) => _GlassDialogBody(
    title: title,
    message: message,
    content: content,
    cancelLabel: cancelLabel,
    confirmLabel: confirmLabel,
    danger: danger,
  ),
);

class _GlassDialogBody extends StatelessWidget {
  const _GlassDialogBody({
    required this.title,
    this.message,
    this.content,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.danger,
  });

  final String title;
  final String? message;
  final Widget? content;
  final String cancelLabel;
  final String confirmLabel;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : colors.onSurface;
    // 顶栏那层玻璃用的是黑底高透明度，这里沿用同一套：深色模式压到近黑，
    // 浅色模式用白，两者都靠 alpha 让背后内容透出一点。
    final glass = dark ? const Color(0xFF161618) : colors.surface;
    final form = AppScope.formFactorOf(context);
    final width = switch (form) {
      FormFactor.phone => 320.0,
      FormFactor.pad || FormFactor.window => 380.0,
      FormFactor.television => 460.0,
    };
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            width: width,
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
            decoration: BoxDecoration(
              color: glass.withValues(alpha: dark ? 0.80 : 0.92),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: ink.withValues(alpha: 0.10)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                    color: ink,
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    message!,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.55,
                      color: ink.withValues(alpha: 0.72),
                    ),
                  ),
                ],
                if (content != null) ...[
                  const SizedBox(height: 14),
                  content!,
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop<bool>(context, false),
                      style: TextButton.styleFrom(
                        foregroundColor: ink.withValues(alpha: 0.62),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: Text(cancelLabel),
                    ),
                    const SizedBox(width: 6),
                    FilledButton(
                      onPressed: () => Navigator.pop<bool>(context, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: danger
                            ? colors.errorContainer
                            : (dark ? const Color(0xFFF2F2F5) : colors.primary),
                        foregroundColor: danger
                            ? colors.onErrorContainer
                            : (dark
                                  ? const Color(0xFF111114)
                                  : colors.onPrimary),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 12,
                        ),
                        elevation: 0,
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: Text(confirmLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
