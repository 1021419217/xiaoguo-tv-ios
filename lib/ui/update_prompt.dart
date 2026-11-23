import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_update.dart';
import '../core_bridge.dart';
import '../local_store.dart';
import 'app_scope.dart';
import 'widgets/glass_dialog.dart';

var _checked = false;
const _manualCooldown = Duration(seconds: 30);
DateTime? _lastManualCheck;
AppUpdate? _lastManualUpdate;

enum _UpdateChoice { mute, skip, dismiss, download }

Future<void> runStartupChecks(BuildContext context, LocalStore store) async {
  if (_checked) return;
  _checked = true;
  final repository = AppScope.of(context).repository;
  final String current;
  final AppUpdate update;
  try {
    current = await currentAppVersion();
    if (store.shareUsage) {
      unawaited(repository.reportUsage(current).catchError((_) {}));
    }
    if (!store.checkUpdates) return;
    final latest = await repository.checkUpdate(current);
    if (latest == null) return;
    update = latest;
  } catch (_) {
    return;
  }
  if (update.version == store.ignoredUpdate || !context.mounted) return;
  final choice = await _askUpdate(context, current, update, manual: false);
  switch (choice) {
    case _UpdateChoice.mute:
      await store.setCheckUpdates(false);
    case _UpdateChoice.skip:
      await store.setIgnoredUpdate(update.version);
    case _UpdateChoice.download:
      if (context.mounted) await _openRelease(context, update.url);
    case _UpdateChoice.dismiss || null:
      return;
  }
}

Future<void> checkUpdateManually(BuildContext context) async {
  final repository = AppScope.of(context).repository;
  final messenger = ScaffoldMessenger.of(context);
  final String current;
  final AppUpdate? update;
  try {
    current = await currentAppVersion();
    final last = _lastManualCheck;
    if (last != null && DateTime.now().difference(last) < _manualCooldown) {
      update = _lastManualUpdate;
    } else {
      update = await repository.checkUpdate(current);
      _lastManualCheck = DateTime.now();
      _lastManualUpdate = update;
    }
  } catch (failure) {
    messenger.showSnackBar(
      SnackBar(
        duration: Duration(milliseconds: 1400),
        content: Text(
          failure is AppFailure ? '检查更新失败：$failure' : '检查更新失败，请稍后再试',
        ),
      ),
    );
    return;
  }
  if (update == null) {
    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(milliseconds: 1400),
        content: Text('已是最新版本'),
      ),
    );
    return;
  }
  if (!context.mounted) return;
  final choice = await _askUpdate(context, current, update, manual: true);
  if (choice == _UpdateChoice.download && context.mounted) {
    await _openRelease(context, update.url);
  }
}

Future<_UpdateChoice?> _askUpdate(
  BuildContext context,
  String current,
  AppUpdate update, {
  required bool manual,
}) {
  return showGlassCard<_UpdateChoice>(
    context: context,
    title: '发现新版本 ${update.version}',
    message: manual
        ? '当前版本 $current。'
        : '当前版本 $current。选「不再提醒」后可在设置 › 关于中重新打开检查更新。',
    actions: [
      for (final (choice, label) in [
        if (!manual) (_UpdateChoice.mute, '不再提醒'),
        if (!manual) (_UpdateChoice.skip, '忽略此版本'),
        (_UpdateChoice.dismiss, '忽略'),
      ])
        GlassAction(
          label: label,
          onPressed: () => Navigator.pop<_UpdateChoice>(context, choice),
        ),
      GlassAction(
        label: '更新',
        primary: true,
        onPressed: () =>
            Navigator.pop<_UpdateChoice>(context, _UpdateChoice.download),
      ),
    ],
  );
}

Future<void> _openRelease(BuildContext context, String url) async {
  final opened = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  ).catchError((_) => false);
  if (opened) return;
  await Clipboard.setData(ClipboardData(text: url));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(milliseconds: 1400),
        content: Text('无法打开浏览器，链接已复制'),
      ),
    );
  }
}
