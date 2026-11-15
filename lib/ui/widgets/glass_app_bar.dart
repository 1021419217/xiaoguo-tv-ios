import 'package:flutter/material.dart';

import 'frosted_header.dart';

/// 统一的磨砂顶栏：内容从背后透出、与底栏同一套玻璃语言。
///
/// 配合 `Scaffold(extendBodyBehindAppBar: true)` 使用；正文自己留出
/// `kToolbarHeight`（+ SafeArea）的空白即可，滚动时内容会从这层模糊背后经过。
AppBar glassAppBar({
  String? title,
  Widget? titleWidget,
  Widget? leading,
  List<Widget>? actions,
  PreferredSizeWidget? bottom,
  double? toolbarHeight,
  double? titleSpacing,
  bool automaticallyImplyLeading = true,
}) => AppBar(
  backgroundColor: Colors.transparent,
  surfaceTintColor: Colors.transparent,
  elevation: 0,
  scrolledUnderElevation: 0,
  flexibleSpace: const FrostedHeader(fill: true),
  automaticallyImplyLeading: automaticallyImplyLeading,
  titleSpacing: titleSpacing,
  leading: leading,
  bottom: bottom,
  toolbarHeight: toolbarHeight,
  title: titleWidget ?? (title == null ? null : GlassTitle(title: title)),
  actions: actions,
);
