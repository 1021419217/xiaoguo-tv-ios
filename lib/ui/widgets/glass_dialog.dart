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
  builder: (dialogContext) => GlassDialogCard(
    title: title,
    message: message,
    content: content,
    cancelLabel: cancelLabel,
    confirmLabel: confirmLabel,
    danger: danger,
    defaultActions: true,
  ),
);

/// 通用版磨砂弹窗：按钮由调用方用 [GlassAction] 自己拼，可选「处理中」态，
/// 返回值类型自定（[showGlassDialog] 只服务「确认 / 取消」这一种）。
///
/// - 输入框、表单：把原布局塞进 [content]，按钮塞进 [actions]。
/// - 进度类：`loading: true`，底部换成一个 24 的细进度圈、按钮全部隐藏；
///   结束时调用方自己 `Navigator.pop` 关掉。
Future<T?> showGlassCard<T>({
  required BuildContext context,
  required String title,
  String? message,
  Widget? content,
  List<Widget> actions = const [],
  bool loading = false,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  barrierColor: Colors.black.withValues(alpha: 0.42),
  builder: (dialogContext) => GlassDialogCard(
    title: title,
    message: message,
    content: content,
    cancelLabel: '取消',
    confirmLabel: '确定',
    danger: false,
    actions: actions,
    loading: loading,
    defaultActions: false,
  ),
);

/// 磨砂弹窗里统一的动作按钮：胶囊形状，[primary] 为高对比实心，
/// [danger] 用错误色，其余是低对比文字按钮。原来每个弹窗各写一套样式，
/// 换成磨砂后颜色对不上，改这里一处即可全局生效。
class GlassAction extends StatelessWidget {
  const GlassAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : colors.onSurface;
    if (!primary && !danger) {
      return TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: ink.withValues(alpha: 0.62),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      );
    }
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: danger
            ? colors.errorContainer
            : (dark ? const Color(0xFFF2F2F5) : colors.primary),
        foregroundColor: danger
            ? colors.onErrorContainer
            : (dark ? const Color(0xFF111114) : colors.onPrimary),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        elevation: 0,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    );
  }
}

/// 磨砂弹窗卡片本体：可直接塞进 `showDialog` 的 builder，
/// 适合内容需要自己持有 State（输入框、动态列表）的场景。
class GlassDialogCard extends StatelessWidget {
  const GlassDialogCard({
    required this.title,
    this.message,
    this.content,
    this.cancelLabel = '取消',
    this.confirmLabel = '确定',
    this.danger = false,
    this.actions,
    this.loading = false,
    this.defaultActions = false,
    this.scrollable = true,
  });

  final String title;
  final String? message;
  final Widget? content;
  final String cancelLabel;
  final String confirmLabel;
  final bool danger;

  /// 自定义按钮组；给了就不再用默认的「取消 / 确定」。
  final List<Widget>? actions;
  final bool loading;

  /// 是否渲染默认双按钮（只有 [showGlassDialog] 走这条路，返回值是 bool）。
  final bool defaultActions;

  /// content 是否由卡片自动套一层滚动区。内容自己带 ScrollController
  /// （需要键盘 / 摇杆滚动）时传 false，避免两层滚动打架。
  final bool scrollable;

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
                  // 长内容（安装详情、屏蔽词列表、剧集选择）不会把弹窗顶爆，
                  // 只有内容本身超出可用高度时才在弹窗内部滚动。
                  Flexible(
                    child: scrollable
                        ? SingleChildScrollView(child: content!)
                        : content!,
                  ),
                ],
                ..._footer(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _footer(BuildContext context) {
    if (loading) {
      return const [
        SizedBox(height: 18),
        Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      ];
    }
    final actions = this.actions;
    if (actions != null && actions.isNotEmpty) {
      return [
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerRight,
          // 选项多的时候自动换行，不会把弹窗横向撑破。
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            runSpacing: 6,
            children: actions,
          ),
        ),
      ];
    }
    if (!defaultActions) return const [SizedBox(height: 6)];
    return [
      const SizedBox(height: 18),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GlassAction(
            label: cancelLabel,
            onPressed: () => Navigator.pop<bool>(context, false),
          ),
          const SizedBox(width: 6),
          GlassAction(
            label: confirmLabel,
            primary: true,
            danger: danger,
            onPressed: () => Navigator.pop<bool>(context, true),
          ),
        ],
      ),
    ];
  }
}
