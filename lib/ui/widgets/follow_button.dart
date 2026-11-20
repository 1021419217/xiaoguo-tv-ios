import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../theme/motion.dart';
import 'frosted_glass.dart';
import 'focus_ring.dart';
import 'motion/motion_widgets.dart';

Future<void> _toggle(BuildContext context, LocalStore store, Drama drama) =>
    store.toggleFavorite(drama).catchError((Object failure) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: Duration(milliseconds: 1400),
            content: Text('$failure'),
          ),
        );
      }
    });

Future<void> quickFollow(
  BuildContext context,
  LocalStore store,
  Drama drama,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final followed = store.isFavorite(drama.id);
  try {
    await store.toggleFavorite(drama);
  } catch (failure) {
    messenger.showSnackBar(
      SnackBar(
        duration: Duration(milliseconds: 1400),
        content: Text('$failure'),
      ),
    );
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: Duration(milliseconds: 1400),
        persist: false,
        content: Text(
          followed ? '已取消追剧「${drama.title}」' : '已追剧「${drama.title}」',
        ),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => store
              .toggleFavorite(drama)
              .catchError(
                (Object failure) => messenger.showSnackBar(
                  SnackBar(
                    duration: Duration(milliseconds: 1400),
                    content: Text('$failure'),
                  ),
                ),
              ),
        ),
      ),
    );
}

class FollowPill extends StatelessWidget {
  const FollowPill({
    super.key,
    required this.store,
    required this.drama,
    this.height = 40,
    this.radius,
    this.onToggled,
    this.focusNode,
  });
  final LocalStore store;
  final Drama drama;
  final double height;
  final double? radius;
  final VoidCallback? onToggled;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final followed = store.isFavorite(drama.id);
      final corner = radius ?? height / 2;
      // 固定中性冷灰：已追剧用更实的填充区分状态，未追剧是淡玻璃。
      final ink = Theme.of(context).colorScheme.onSurface;
      return FocusRing(
        radius: corner,
        child: FilledButton.tonalIcon(
          key: const ValueKey('follow-toggle'),
          focusNode: focusNode,
          onPressed: () {
            _toggle(context, store, drama);
            onToggled?.call();
          },
          style: FilledButton.styleFrom(
            minimumSize: Size(0, height),
            padding: EdgeInsets.fromLTRB(height / 4, 0, height * 0.35, 0),
            shape: StadiumBorder(
              side: BorderSide(
                color: GlassTones.hairline.withValues(alpha: 0.50),
              ),
            ),
            iconSize: height * 0.45,
            textStyle: TextStyle(
              fontSize: height >= 44 ? 15 : 14,
              fontWeight: FontWeight.w600,
            ),
            backgroundColor: ink.withValues(alpha: followed ? 0.18 : 0.08),
            foregroundColor: ink,
          ),
          icon: ToggleIconSwitcher(
            child: Icon(
              followed ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              key: ValueKey(followed),
            ),
          ),
          label: Stack(
            alignment: Alignment.center,
            children: [
              const Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Text('已追剧'),
              ),
              FadeSwitcher(
                duration: Motion.short,
                child: Text(followed ? '已追剧' : '追剧', key: ValueKey(followed)),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class FollowIcon extends StatelessWidget {
  const FollowIcon({
    super.key,
    required this.store,
    required this.drama,
    required this.color,
    required this.activeColor,
    this.size = 24,
    this.extent = 48,
  });
  final LocalStore store;
  final Drama drama;
  final Color color;
  final Color activeColor;
  final double size;
  final double extent;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final followed = store.isFavorite(drama.id);
      return Semantics(
        label: followed ? '已追剧，轻点取消' : '追剧',
        button: true,
        excludeSemantics: true,
        child: FrostedGlass(
          circle: true,
          width: extent,
          height: extent,
          blur: 10,
          elevated: false,
          onTap: () => _toggle(context, store, drama),
          child: Center(
            child: ToggleIconSwitcher(
              child: Icon(
                followed ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
                key: ValueKey(followed),
                size: size,
                color: followed ? activeColor : color,
              ),
            ),
          ),
        ),
      );
    },
  );
}
