import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../download_converter.dart';
import '../../download_overview.dart';
import '../../local_store.dart';
import '../../merge_queue.dart';
import '../downloads/downloads_page.dart';
import '../follow/follow_page.dart';
import '../history/history_page.dart';

/// 「追剧」标签页：把追剧、最近观看、下载三块合成一页，用顶部分段胶囊切换。
///
/// 三个子页面各自保留原来的搜索、站源筛选与编辑操作，只把标题位置让给
/// [LibrarySwitcher]，因此视觉上始终是同一套顶栏，切换时只有内容在变。
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.store,
    required this.downloads,
    required this.converter,
    required this.merges,
    required this.entryFocus,
    required this.onExitUp,
  });
  final LocalStore store;
  final DownloadOverview downloads;
  final DownloadConverter converter;
  final MergeQueue merges;
  final FocusNode entryFocus;
  final VoidCallback onExitUp;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  var _index = 0;

  Widget get _switcher => LibrarySwitcher(
    index: _index,
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
        merges: widget.merges,
        headerChild: _switcher,
      ),
    ],
  );
}

/// 追剧 / 最近观看 / 下载 三段胶囊，样式与模块页的标签栏一致。
class LibrarySwitcher extends StatelessWidget {
  const LibrarySwitcher({
    super.key,
    required this.index,
    required this.onChanged,
  });
  final int index;
  final ValueChanged<int> onChanged;

  static const _labels = ['追剧', '最近观看', '下载'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? Colors.white : theme.colorScheme.onSurface;
    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ink.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _labels.length; i++)
            _Segment(
              label: _labels[i],
              selected: index == i,
              ink: ink,
              dim: theme.colorScheme.onSurfaceVariant,
              onTap: () => onChanged(i),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.ink,
    required this.dim,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final Color ink;
  final Color dim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? ink.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? ink.withValues(alpha: 0.14) : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            height: 1.1,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? ink : dim,
          ),
        ),
      ),
    ),
  );
}
