import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../download_converter.dart';
import '../../download_overview.dart';
import '../../local_store.dart';
import '../downloads/downloads_page.dart';
import '../follow/follow_page.dart';
import '../history/history_page.dart';
import '../widgets/capsule_tabs.dart';

/// 「追剧」标签页：把追剧、最近观看、下载三块合成一页。
///
/// 交互分工（用户明确要求）：
/// * 上方「追剧 / 最近观看 / 下载」只响应点击——它决定的是「看哪一块」，
///   左右滑动在这里容易和列表本身的横滑打架，所以不做手势切换；
/// * 每一块内部自己的分类（追剧/最近观看是站源筛选，下载是下载中/已下载/合并）
///   才用左右滑动切换，手势与「发现」页的分类横滑一致。
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.store,
    required this.downloads,
    required this.converter,
    required this.entryFocus,
    required this.onExitUp,
  });
  final LocalStore store;
  final DownloadOverview downloads;
  final DownloadConverter converter;
  final FocusNode entryFocus;
  final VoidCallback onExitUp;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  var _index = 0;

  /// 三段胶囊和首页选站源同一高度，不再按可用宽度缩放。
  Widget get _switcher => CapsuleTabs(
    labels: const ['追剧', '最近观看', '下载'],
    index: _index,
    fontSize: 14,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    onChanged: (index) {
      if (index == _index) return;
      unawaited(HapticFeedback.selectionClick());
      setState(() => _index = index);
    },
  );

  @override
  Widget build(BuildContext context) => IndexedStack(
    index: _index,
    children: [
      FollowPage(
        store: widget.store,
        entryFocus: widget.entryFocus,
        onExitUp: widget.onExitUp,
        headerChild: _switcher,
      ),
      HistoryPage(store: widget.store, root: true, headerChild: _switcher),
      DownloadsPage(
        store: widget.store,
        downloads: widget.downloads,
        converter: widget.converter,
        headerChild: _switcher,
      ),
    ],
  );
}
