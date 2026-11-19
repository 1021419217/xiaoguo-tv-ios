import 'dart:async';

import 'package:flutter/material.dart';

import 'focus_ring.dart';
import 'motion/motion_widgets.dart';

class StatusView extends StatelessWidget {
  const StatusView({
    super.key,
    required this.title,
    this.message,
    this.messageChild,
    this.icon = Icons.movie_filter_outlined,
    this.action,
    this.onAction,
    this.autofocus = false,
  }) : loading = false;

  const StatusView.loading({super.key, this.title = '正在加载'})
    : message = null,
      messageChild = null,
      icon = null,
      action = null,
      onAction = null,
      autofocus = false,
      loading = true;

  final String title;
  final String? message;
  final Widget? messageChild;
  final IconData? icon;
  final String? action;
  final VoidCallback? onAction;
  final bool autofocus;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeSwitcher(
              scale: true,
              child: loading
                  ? const CircularProgressIndicator(key: ValueKey(true))
                  : Icon(
                      icon,
                      key: const ValueKey(false),
                      size: 56,
                      color: theme.colorScheme.primary,
                    ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (messageChild case final child?) ...[
              const SizedBox(height: 8),
              child,
            ] else if (message case final message?) ...[
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action case final action?) ...[
              const SizedBox(height: 24),
              FocusRing(
                radius: 999,
                child: FilledButton.tonal(
                  autofocus: autofocus,
                  onPressed: onAction,
                  child: Text(action),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误文案里带「N 秒后重试」时，每秒自己走，到 0 自动回调重试；
/// 不再只有切换分类/刷新才重新取到新的秒数。
class RetryCountdown extends StatefulWidget {
  const RetryCountdown({
    super.key,
    required this.text,
    required this.style,
    required this.onExpired,
  });

  final String text;
  final TextStyle? style;
  final VoidCallback onExpired;

  @override
  State<RetryCountdown> createState() => _RetryCountdownState();
}

class _RetryCountdownState extends State<RetryCountdown> {
  static final _seconds = RegExp(r'(\d+)\s*秒后重试');
  Timer? _timer;
  var _remaining = 0;
  var _fired = false;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(covariant RetryCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _reset();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _fired = false;
    final match = _seconds.firstMatch(widget.text);
    _remaining = int.tryParse(match?.group(1) ?? '') ?? 0;
    if (_remaining > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    }
  }

  void _tick(Timer timer) {
    if (!mounted) return;
    if (_remaining <= 1) {
      timer.cancel();
      setState(() => _remaining = 0);
      if (!_fired) {
        _fired = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onExpired();
        });
      }
      return;
    }
    setState(() => _remaining -= 1);
  }

  @override
  Widget build(BuildContext context) {
    final match = _seconds.firstMatch(widget.text);
    final text = match == null
        ? widget.text
        : widget.text.replaceRange(
            match.start(1),
            match.end(1),
            '$_remaining',
          );
    return Text(text, textAlign: TextAlign.center, style: widget.style);
  }
}
