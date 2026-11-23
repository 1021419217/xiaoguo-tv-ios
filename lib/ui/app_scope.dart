import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core_bridge.dart';

enum FormFactor { phone, pad, window, television }

const televisionInset = 58.0;

/// 全局根导航器。
///
/// 吐司（SnackBar）挂在全局，页面关了它还在；这时用户点吐司上的按钮，
/// 原来那个页面的 context 已经销毁，不能再拿它去 Navigator.of。
/// 这类「浮层上的导航」统一走这个 key。
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

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
