import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/modules/modules_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 模块页标签栏换成自绘胶囊后，顶栏在手机宽度下不能溢出，
/// 四个标签也都要在、都要能点到。
void main() {
  testWidgets('模块页顶栏与标签栏不溢出', (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = await openStore();
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: ModulesPage(store: store),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    for (final label in ['已安装', '在线仓库', '内置', '手动']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('手动'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('选择本地文件'), findsOneWidget);
  });
}
