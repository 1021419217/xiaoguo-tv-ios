import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import 'focus_ring.dart';

/// 固定「中性冷灰玻璃」视觉常量，按短剧之家截图逐点取色实测。
/// 全 App 的圆形 / 胶囊 / 卡片控件共用这一套，不含任何动态取色，
/// 界面不会随海报或视频帧变化。
abstract final class GlassTones {
  static const Color background = Color(0xFF1B1D23);
  static const Color card = Color(0xFF2E3138);
  static const Color cell = Color(0xFF1A1A1C);
  static const Color orbCenter = Color(0xFF2A2B2F);
  static const Color orbEdge = Color(0xFF161618);
  static const Color orbSelected = Color(0xFF4B4B4D);
  static const Color hairline = Color(0xFF4A4A4C);

  /// 噪点纹理（早期误把「磨砂」理解成雾面颗粒，已停用；保留仅为兼容旧调用）。
  /// 现在的质感是高斯模糊 + 通透玻璃，不需要任何颗粒层。
  static const String frostDark = 'assets/textures/frost_dark.png';
  static const String frostLight = 'assets/textures/frost_light.png';

  /// 短剧之家那种「隐约能看到一圈白边」：1px、低不透明度的亮灰描边。
  static BorderSide edge([double opacity = 0.72]) =>
      BorderSide(color: hairline.withValues(alpha: opacity), width: 1);
}

/// 玻璃档位：[surface] 用于圆钮/底栏/卡片，[cell] 用于集数格子/分段这类
/// 一次渲染几十个的密集控件（更暗、更薄、不投影）。
enum GlassVariant { surface, cell }

/// 高斯模糊玻璃表面。
///
/// 参考短剧之家的实际效果：主体是「透过玻璃看到被高斯模糊的背景」，
/// 不是一层雾面颗粒。质感靠四层叠加：
///   1. `BackdropFilter` 真高斯模糊 —— 背后的环境光/内容被化开后透出来，
///      这是玻璃感的来源，玻璃底色必须足够透，否则会被盖成一块灰板；
///   2. 极淡的斜向受光渐变 —— 左上略亮、右下略暗，只做倾向不做实底；
///   3. 顶部弧形反光 + 很轻的底部内阴影 —— 玻璃厚度与球面鼓起；
///   4. 1px 渐变亮边（上/左亮、下/右暗）+ 柔和外阴影 —— 把玻璃从背景浮出来。
///
/// [frosted] 关掉时跳过昂贵的 BackdropFilter，只保留其余层，
/// 供集数格子 / 分段胶囊这类一次渲染几十个的密集控件复用，视觉仍一致。
/// [noise] 默认关闭：早期误加的雾面颗粒会把玻璃糊成水泥板。
class FrostedGlass extends StatelessWidget {
  const FrostedGlass({
    super.key,
    required this.child,
    this.circle = false,
    this.radius = 22,
    this.width,
    this.height,
    this.padding,
    this.blur = 26,
    this.frosted = true,
    this.noise = false,
    this.selected = false,
    this.accent = false,
    this.variant = GlassVariant.surface,
    this.elevated = true,
    this.expand = false,
    this.focusNode,
    this.autofocus = false,
    this.onTap,
    this.tooltip,
    this.semanticLabel,
  });

  final Widget child;
  final bool circle;
  final double radius;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final double blur;

  /// 是否做真实背景模糊。密集小格子建议 false 以省 GPU。
  final bool frosted;
  final bool noise;
  final bool selected;
  final bool accent;
  final GlassVariant variant;

  /// 是否投柔和外阴影。密集格子关掉，避免几十个阴影叠成脏边。
  final bool elevated;

  /// 撑满父约束：给 GridView / 分段列表这类由外部定尺寸的格子用。
  final bool expand;

  /// 透传给内部 InkWell，保留电视端遥控器焦点与选中项自动聚焦。
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onTap;
  final String? tooltip;
  final String? semanticLabel;

  BoxShape get _shape => circle ? BoxShape.circle : BoxShape.rectangle;
  BorderRadius? get _radius =>
      circle ? null : BorderRadius.circular(radius);

  /// 第 5 层：玻璃厚度的受光边，左上亮白、右下压暗，末尾轻微回光。
  LinearGradient _edgeGradient(bool dark) {
    if (variant == GlassVariant.cell) {
      // 格子只需要「隐约一圈细亮边」，不能像圆钮那样有明显受光斜面。
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: dark
            ? const [Color(0x7AFFFFFF), Color(0x2EFFFFFF), Color(0x12FFFFFF)]
            : const [Color(0xE6FFFFFF), Color(0x80FFFFFF), Color(0x26000000)],
        stops: const [0.0, 0.45, 1.0],
      );
    }
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: dark
          ? const [
              Color(0x9EFFFFFF),
              Color(0x50FFFFFF),
              Color(0x30FFFFFF),
              Color(0x46FFFFFF),
            ]
          : const [
              Color(0xE6FFFFFF),
              Color(0x99FFFFFF),
              Color(0x26000000),
              Color(0x52000000),
            ],
      stops: const [0.0, 0.32, 0.72, 1.0],
    );
  }

  /// 第 2 层：极淡的斜向受光倾向，只给方向不铺实底。
  LinearGradient _slant(bool dark) {
    if (variant == GlassVariant.cell) {
      // 集数格子 / 分段：底色更暗更薄，选中态是白底（对齐截图里的选中格）。
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: dark
            ? (selected
                  ? const [
                      Color(0xE8F8F8FA),
                      Color(0xDEECECF0),
                      Color(0xD6DCDCE0),
                    ]
                  : const [
                      Color(0x8E3A3B42),
                      Color(0x90282A2F),
                      Color(0x9C18191D),
                    ])
            : const [
                Color(0xD9FFFFFF),
                Color(0xCFF3F4F7),
                Color(0xC4E3E5EA),
              ],
        stops: const [0.0, 0.48, 1.0],
      );
    }
    // 玻璃本体：alpha 压到 0x20~0x50 区间，让 BackdropFilter 的高斯模糊
    // 真正透出来。之前 0xA8~0xC4 的实心底把模糊全盖住，才变成灰水泥板。
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: dark
          ? (selected
                ? const [
                    Color(0x5AA0A5B2),
                    Color(0x4E727680),
                    Color(0x56474A54),
                  ]
                : accent
                ? const [
                    Color(0x468C919E),
                    Color(0x3A5F636E),
                    Color(0x42393C46),
                  ]
                : const [
                    Color(0x329AA0AE),
                    Color(0x266E737E),
                    Color(0x2E454A55),
                  ])
          : const [
              Color(0x8CFFFFFF),
              Color(0x78F2F3F7),
              Color(0x70E2E4EA),
            ],
      stops: const [0.0, 0.48, 1.0],
    );
  }

  /// 第 3 层上半：顶部弧形高光。圆形控件把光心压到上中部、收小半径，
  /// 出来的是「球面鼓起」而不是一条横贯的亮带；胶囊/卡片仍用顶缘弧光。
  RadialGradient _topGlow(bool circle) => RadialGradient(
    center: circle ? const Alignment(0, -0.5) : const Alignment(0, -1.05),
    radius: circle ? 1.1 : 1.45,
    colors: const [Color(0x3AFFFFFF), Color(0x00FFFFFF)],
    stops: [0.0, 1.0],
  );

  /// 第 3 层下半：底部内阴影，让底边压暗、整体鼓起。
  LinearGradient get _innerShade => const LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00000000), Color(0x00000000), Color(0x20000000)],
    stops: [0.0, 0.52, 1.0],
  );

  DecorationImage _frostImage(bool dark) => DecorationImage(
    image: AssetImage(dark ? GlassTones.frostDark : GlassTones.frostLight),
    repeat: ImageRepeat.repeat,
    fit: BoxFit.none,
    alignment: Alignment.topLeft,
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final television = AppScope.of(context).television;

    // 电视端省掉模糊与噪点：遥控器焦点靠对比度识别，GPU 也省下来。
    final useBlur = frosted && !television;
    final useNoise = noise && !television;

    Widget layers = Container(
      decoration: BoxDecoration(gradient: _slant(dark)),
      child: Container(
        decoration: BoxDecoration(gradient: _topGlow(circle)),
        child: Container(
          decoration: BoxDecoration(gradient: _innerShade),
          child: Container(
            decoration: BoxDecoration(
              image: useNoise ? _frostImage(dark) : null,
            ),
            child: Padding(
              padding: padding ?? EdgeInsets.zero,
              child: child,
            ),
          ),
        ),
      ),
    );

    if (useBlur) {
      layers = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: layers,
      );
    }

    Widget surface = Container(
      width: width ?? (expand ? double.infinity : null),
      height: height ?? (expand ? double.infinity : null),
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        shape: _shape,
        borderRadius: _radius,
        gradient: _edgeGradient(dark),
        boxShadow: elevated
            ? const [
                BoxShadow(
                  color: Color(0x59000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
                BoxShadow(
                  color: Color(0x26000000),
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: circle
          ? ClipOval(child: layers)
          : ClipRRect(
              borderRadius: BorderRadius.circular(radius - 1),
              child: layers,
            ),
    );

    if (onTap != null) {
      // 点击层必须压在玻璃之上：InkWell 的水波纹画在 Material 上，
      // 若把 Material 放在玻璃下面，水波纹会被半透明玻璃盖住看不见。
      final border = circle
          ? const CircleBorder()
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
            );
      surface = FocusRing(
        radius: circle ? 999 : radius,
        child: Stack(
          children: [
            surface,
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                shape: border,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  customBorder: border,
                  focusNode: focusNode,
                  autofocus: autofocus,
                  onTap: () {
                    unawaited(HapticFeedback.selectionClick());
                    onTap!();
                  },
                  splashColor: Colors.white.withValues(alpha: 0.10),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (semanticLabel != null) {
      surface = Semantics(button: onTap != null, label: semanticLabel, child: surface);
    }
    if (tooltip != null) {
      surface = Tooltip(message: tooltip!, child: surface);
    }
    return surface;
  }
}

/// 短剧之家式圆形玻璃钮：高斯模糊玻璃 + 白色粗实心图标。
class GlassOrb extends StatelessWidget {
  const GlassOrb({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 42,
    this.iconSize,
    this.tooltip,
    this.selected = false,
    this.accent = false,
    this.iconColor,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double? iconSize;
  final String? tooltip;
  final bool selected;
  final bool accent;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = iconColor ?? (dark ? Colors.white : const Color(0xFF14161A));
    return FrostedGlass(
      circle: true,
      width: size,
      height: size,
      blur: 16,
      selected: selected,
      accent: accent,
      onTap: onTap,
      tooltip: tooltip,
      semanticLabel: tooltip,
      child: Center(
        child: Icon(
          icon,
          size: iconSize ?? size * 0.46,
          weight: 700,
          color: ink.withValues(alpha: onTap == null ? 0.38 : 0.96),
          shadows: const [Shadow(color: Color(0x33FFFFFF), blurRadius: 2)],
        ),
      ),
    );
  }
}
