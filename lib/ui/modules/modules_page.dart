import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../app_scope.dart';
import '../settings/modules_view.dart';
import '../widgets/bar_button.dart';
import '../widgets/frosted_header.dart';
import '../widgets/page_header.dart';

/// 站源模块管理：从「我的 → 模块」进入，是独立二级页，需要返回键与磨砂顶栏。
class ModulesPage extends StatelessWidget {
  const ModulesPage({super.key, required this.store});
  final LocalStore store;

  @override
  Widget build(BuildContext context) {
    if (AppScope.of(context).television) {
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const PageHeader(title: '模块'),
              Expanded(child: ModulesView(store: store)),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        surfaceTintColor: Colors.transparent,
        flexibleSpace: const FrostedHeader(fill: true),
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: BarButton(
            icon: Icons.arrow_back_rounded,
            tooltip: '返回',
            onPressed: () => Navigator.pop(context),
          ),
        ),
        title: const GlassTitle(title: '模块'),
      ),
      body: SafeArea(
        top: true,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(top: kToolbarHeight),
          child: ModulesView(store: store),
        ),
      ),
    );
  }
}
