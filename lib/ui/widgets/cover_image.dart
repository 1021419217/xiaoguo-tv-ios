import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../../cover_loader.dart';
import '../../cover_shape.dart';
import '../../models.dart';
import '../app_scope.dart';
import '../cover_blur.dart';
import 'motion/motion_widgets.dart';

const vipGold = Color(0xFFF6C86B);
const onVipGold = Color(0xFF40300D);

class VipBadge extends StatelessWidget {
  const VipBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: vipGold,
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Text(
      'VIP',
      style: TextStyle(
        color: onVipGold,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        height: 1.2,
      ),
    ),
  );
}

class DramaCover extends StatelessWidget {
  const DramaCover({
    super.key,
    required this.drama,
    this.radius = 12,
    this.details = true,
    this.rank,
    this.heroScope,
    this.showScore = false,
    this.exploreBlur = false,
    this.alignment = Alignment.center,
    this.decodeWidth = 440,
    this.onAspect,
  });
  final Drama drama;
  final double radius;
  final bool details;
  final bool exploreBlur;
  final bool showScore;
  final Alignment alignment;

  /// 解码宽度（物理像素）。列表里的小封面用默认值即可，详情页的大封面
  /// 传更大的值，否则放大后会糊。
  final int decodeWidth;

  /// 封面真实宽高比（宽 / 高）读出来后回调一次，按图片本身排版，
  /// 不依赖站源声明或历史学习结果。
  final ValueChanged<double>? onAspect;
  final int? rank;
  final String? heroScope;
  static const imagesDisabled = bool.fromEnvironment('DISABLE_REMOTE_IMAGES');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.movie_creation_outlined,
          size: 36,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
    Widget image = Stack(
      fit: StackFit.expand,
      children: [
        placeholder,
        if (!imagesDisabled && drama.id.isNotEmpty)
          CoverImage(
            key: ValueKey('${drama.id}\u0000${drama.cover}'),
            drama: drama,
            repository: AppScope.of(context).repository,
            placeholder: const SizedBox.shrink(),
            alignment: alignment,
            decodeWidth: decodeWidth,
            onAspect: onAspect,
            fit: BoxFit.cover,
          ),
      ],
    );
    // Always build the same wrapper so the CoverImage state is kept when the
    // hero condition flips; HeroMode just turns the flight on or off.
    final heroEnabled = heroScope != null && drama.id.isNotEmpty;
    final blurred =
        CoverBlurScope.of(context)?.blurs(drama, explore: exploreBlur) ?? false;
    image = HeroMode(
      enabled: heroEnabled,
      child: Hero(
        tag: coverHeroTag(drama.id, heroScope ?? ''),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: ImageFiltered(
            enabled: blurred,
            imageFilter: ImageFilter.blur(
              sigmaX: 16,
              sigmaY: 16,
              tileMode: TileMode.clamp,
            ),
            child: image,
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (details)
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xC7000000)],
                  ),
                ),
              ),
            ),
          if (details && (drama.badge.isNotEmpty || drama.episodes > 0))
            Positioned(
              left: 9,
              bottom: 9,
              child: Text(
                drama.badge.isNotEmpty ? drama.badge : '共 ${drama.episodes} 集',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          if (details && showScore && drama.score.isNotEmpty)
            Positioned(
              right: 9,
              bottom: 9,
              child: Text(
                drama.score,
                style: const TextStyle(
                  color: Color(0xFFFFC542),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (details && drama.vip)
            Positioned(
              left: rank == null ? 8 : null,
              right: rank == null ? null : 8,
              top: 8,
              child: const VipBadge(),
            ),
          if (rank case final rank?)
            Positioned(left: 0, top: 0, child: RankBadge(rank: rank)),
        ],
      ),
    );
  }
}

class RankBadge extends StatelessWidget {
  const RankBadge({super.key, required this.rank});
  final int rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = rank <= 3;
    return Container(
      constraints: const BoxConstraints(minWidth: 28),
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: !top
            ? const Color(0x8C000000)
            : theme.brightness == Brightness.dark
            ? theme.colorScheme.inversePrimary
            : theme.colorScheme.primary,
        borderRadius: const BorderRadius.only(bottomRight: Radius.circular(10)),
      ),
      child: Text(
        '$rank',
        style: TextStyle(
          color: Colors.white,
          fontSize: top ? 15 : 13,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

class CoverImage extends StatefulWidget {
  const CoverImage({
    super.key,
    required this.drama,
    required this.repository,
    required this.placeholder,
    this.retryable = true,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.decodeWidth = 440,
    this.onAspect,
  });
  final Drama drama;
  final AppRepository repository;
  final Widget placeholder;
  final bool retryable;
  final BoxFit fit;
  final Alignment alignment;

  /// 解码宽度（物理像素）。同一张封面用同一宽度才会命中同一份解码缓存。
  final int decodeWidth;

  /// 封面真实宽高比（宽 / 高）读出来后回调一次。
  final ValueChanged<double>? onAspect;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  /// 列表里小封面的解码宽度；同时充当详情大图解码完成前的过渡图。
  static const _thumbWidth = 440;

  CoverRequest? _request;
  Future<String>? _file;

  /// 已经拿到本地文件时直接同步出图：不再先空一帧再淡入，进出详情不闪。
  String? _path;
  String? _measuredPath;
  int _revision = 0;
  bool _failed = false;
  bool _retryOnFailure = false;
  bool _retryQueued = false;
  String? _failedPath;

  @override
  void initState() {
    super.initState();
    _revision = widget.repository.catalogUpdates.coverRevision(widget.drama.id);
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.catalogUpdates.removeListener(_metadataChanged);
      widget.repository.catalogUpdates.addListener(_metadataChanged);
    }
    if (oldWidget.repository != widget.repository ||
        oldWidget.drama.id != widget.drama.id ||
        oldWidget.drama.source != widget.drama.source ||
        oldWidget.drama.cover != widget.drama.cover) {
      _failed = _retryOnFailure = false;
      _failedPath = null;
      _revision = widget.repository.catalogUpdates.coverRevision(
        widget.drama.id,
      );
      _load();
    }
  }

  @override
  void dispose() {
    _request?.cancel();
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    super.dispose();
  }

  void _load() {
    _request?.cancel();
    _request = null;
    _file = null;
    _path = null;
    _measuredPath = null;
    final cached = CoverLoader.cachedPath(widget.repository, widget.drama);
    if (cached != null && File(cached).existsSync()) {
      _path = cached;
      unawaited(_measure(cached));
      return;
    }
    _file = CoverLoader.cached(widget.repository, widget.drama);
    if (_file != null) {
      unawaited(_measureWhenReady(_file!));
      return;
    }
    final request = _request = CoverLoader.request(
      widget.repository,
      widget.drama,
    );
    _file = request.file;
    unawaited(_measureWhenReady(_file!));
  }

  Future<void> _measureWhenReady(Future<String> file) async {
    try {
      final path = await file;
      if (mounted) await _measure(path);
    } catch (_) {
      // 取封面失败会走展示层的错误态，这里不用再处理。
    }
  }

  /// 直接读文件头拿真实宽高比：瀑布流按它排版，不再依赖站源声明或
  /// 上一次学习的结果，图片是横的就排横的，竖的就排竖的。
  Future<void> _measure(String path) async {
    if (_measuredPath == path) return;
    _measuredPath = path;
    double ratio = 0;
    try {
      final bytes = await File(path).readAsBytes();
      final buffer = await ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ImageDescriptor.encoded(buffer);
      ratio = descriptor.width / descriptor.height;
      descriptor.dispose();
      buffer.dispose();
    } catch (_) {
      return;
    }
    if (ratio <= 0) return;
    unawaited(
      CoverShapes.learn(
        widget.drama.source,
        widget.drama.id,
        path,
        ratio: ratio,
      ),
    );
    if (mounted) widget.onAspect?.call(ratio);
  }

  void _metadataChanged() {
    final revision = widget.repository.catalogUpdates.coverRevision(
      widget.drama.id,
    );
    if (revision == _revision) return;
    _revision = revision;
    _retryOnFailure = true;
    if (_failed) _queueRetry();
  }

  void _queueRetry() {
    if (_retryQueued || !_retryOnFailure) return;
    _retryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retryQueued = false;
      if (!mounted || !_retryOnFailure) return;
      _retryOnFailure = false;
      _retry(_failedPath);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _retry(String? path) async {
    if (path != null) {
      for (final width in {_thumbWidth, widget.decodeWidth}) {
        await ResizeImage.resizeIfNeeded(
          width,
          null,
          FileImage(File(path)),
        ).evict();
      }
    }
    if (!mounted) return;
    _request?.cancel();
    setState(() {
      _request = null;
      _path = null;
      _measuredPath = null;
      _failed = _retryOnFailure = false;
      _failedPath = null;
      _file = widget.repository.cover(
        widget.repository.catalogUpdates.current(widget.drama),
        force: true,
      );
    });
    if (_file case final file?) unawaited(_measureWhenReady(file));
  }

  Widget _failure(String? path) {
    _failed = true;
    _failedPath = path;
    if (_retryOnFailure) _queueRetry();
    if (!widget.retryable) return widget.placeholder;
    return Center(
      child: IconButton(
        tooltip: '重试海报',
        onPressed: () => _retry(path),
        icon: Icon(
          Icons.refresh_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _image(
    String path,
    int width, {
    required Widget Function() onError,
  }) => Image.file(
    File(path),
    fit: widget.fit,
    alignment: widget.alignment,
    cacheWidth: width,
    excludeFromSemantics: true,
    frameBuilder: fadeInFrameBuilder,
    errorBuilder: (_, _, _) => onError(),
  );

  Widget _resolved(String path) {
    unawaited(_measure(path));
    final sharp = _image(path, widget.decodeWidth, onError: () => _failure(path));
    if (widget.decodeWidth <= _thumbWidth) return sharp;
    // 大图解码要几帧：先铺已经缓存的小图，大图在它上面淡入，
    // 进出详情时既不空一帧，也不会一直糊着。
    return Stack(
      fit: StackFit.expand,
      children: [
        _image(path, _thumbWidth, onError: () => const SizedBox.shrink()),
        sharp,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    if (path != null) return _resolved(path);
    return FutureBuilder<String>(
      future: _file,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.placeholder;
        }
        if (snapshot.hasError || !snapshot.hasData) return _failure(null);
        return _resolved(snapshot.data!);
      },
    );
  }
}
