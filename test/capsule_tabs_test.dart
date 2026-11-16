import 'package:duanju_app/ui/widgets/capsule_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 模块页 / 下载页的「胶囊没盖全文字」问题回归测试：
/// 选中段的背景必须完整包住文字，并且四周留白一致。
void main() {
  testWidgets('选中胶囊完整包住文字', (tester) async {
    var index = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Align(
              alignment: Alignment.topLeft,
              child: CapsuleTabs(
                labels: const ['已安装', '在线仓库', '内置', '手动'],
                index: index,
                onChanged: (next) => setState(() => index = next),
              ),
            ),
          ),
        ),
      ),
    );

    for (final label in ['已安装', '在线仓库', '内置', '手动']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      final capsule = tester.getRect(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final text = tester.getRect(find.text(label));
      expect(
        capsule.left,
        lessThanOrEqualTo(text.left - 12),
        reason: '$label 左侧留白不足',
      );
      expect(
        capsule.right,
        greaterThanOrEqualTo(text.right + 12),
        reason: '$label 右侧留白不足',
      );
      expect(
        capsule.top,
        lessThanOrEqualTo(text.top - 4),
        reason: '$label 顶部被裁',
      );
      expect(
        capsule.bottom,
        greaterThanOrEqualTo(text.bottom + 4),
        reason: '$label 底部被裁',
      );
    }
  });

  testWidgets('点击切换回调对应序号', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CapsuleTabs(
            labels: const ['追剧', '最近观看', '下载'],
            index: 0,
            onChanged: taps.add,
          ),
        ),
      ),
    );
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(taps, [2]);
  });
}
