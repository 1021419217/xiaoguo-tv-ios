import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core_bridge.dart';

enum FormFactor { phone, pad, window, television }

const televisionInset = 58.0;

/// 贴底底栏在手机端占的高度（62）加上系统手势区，再留 16 收尾。
/// 所有 tab 根页面都按这个值收底：最后一行不会被底栏压住，也不会空一截。
double pageBottomInset(BuildContext context) =>
    switch (AppScope.formFactorOf(context)) {
      FormFactor.phone => MediaQuery.paddingOf(context).bottom + 62 + 16,
      FormFactor.television => 27,
      FormFactor.pad || FormFactor.window => 24,
    };

bool get desktopPlatform => switch (defaultTargetPlatform) {
  TargetPlatform.windows ||
  TargetPlatform.macOS ||
  TargetPlatform.linux => true,
  _ => false,
};

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.repository,
    this.formFactor,
    this.systemColorAvailable = false,
    this.version = '',
    required super.child,
  });
  final AppRepository repository;
  final FormFactor? formFactor;
  final bool systemColorAvailable;
  final String version;

  bool get television => formFactor == FormFactor.television;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  static FormFactor formFactorOf(BuildContext context) {
    if (of(context).formFactor case final form?) return form;
    final size = MediaQuery.sizeOf(context);
    if (desktopPlatform) {
      return size.width >= 600 ? FormFactor.window : FormFactor.phone;
    }
    return size.shortestSide >= 600 ? FormFactor.pad : FormFactor.phone;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      repository != oldWidget.repository ||
      formFactor != oldWidget.formFactor ||
      systemColorAvailable != oldWidget.systemColorAvailable ||
      version != oldWidget.version;
}
