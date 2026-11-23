import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../widgets/form_text_field.dart';
import '../widgets/glass_dialog.dart';

Future<bool> showPasswordDialog(
  BuildContext context, {
  required String title,
  String? helper,
  required Future<void> Function(String pin) onSubmit,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) =>
          _PasswordDialog(title: title, helper: helper, onSubmit: onSubmit),
    ) ??
    false;

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.title,
    required this.helper,
    required this.onSubmit,
  });
  final String title;
  final String? helper;
  final Future<void> Function(String pin) onSubmit;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog>
    with SingleTickerProviderStateMixin {
  late final _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  final _pin = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _shake.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_pin.text);
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = failure is StateError ? failure.message : '$failure';
        });
        if (!Motion.reduced(context)) _shake.forward(from: 0);
      }
    }
  }

  @override
  Widget build(BuildContext context) => GlassDialogCard(
    title: widget.title,
    content: AnimatedBuilder(
      animation: _shake,
      builder: (context, child) => Transform.translate(
        offset: Offset(
          math.sin(_shake.value * math.pi * 4) * 8 * (1 - _shake.value),
          0,
        ),
        child: child,
      ),
      child: FormTextField(
        controller: _pin,
        autofocus: true,
        obscure: true,
        enabled: !_busy,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: '密码',
          helperText: widget.helper,
          errorText: _error,
        ),
      ),
    ),
    actions: [
      GlassAction(
        label: '取消',
        onPressed: _busy ? null : () => Navigator.pop<bool>(context, false),
      ),
      GlassAction(
        label: _busy ? '正在验证…' : '登录',
        primary: true,
        onPressed: _busy ? null : _submit,
      ),
    ],
  );
}
