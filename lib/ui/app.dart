import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app_build.dart';
import '../app_device.dart';
import '../core_bridge.dart';
import '../local_store.dart';
import '../theme_color.dart';
import 'app_scope.dart';
import 'cover_blur.dart';
import 'device_registration.dart';
import 'shell/app_shell.dart';
import 'terms_page.dart';
import 'theme/app_theme.dart';
import 'theme/motion.dart';
import 'theme/system_color.dart';
import 'users/unlock_page.dart';
import 'widgets/focus_ring.dart';

class DuanjuApp extends StatefulWidget {
  const DuanjuApp({
    super.key,
    required this.repository,
    this.store,
    this.bootstrapError,
    this.onRetry,
    this.television = false,
    this.version = '',
  });
  final AppRepository repository;
  final LocalStore? store;
  final String? bootstrapError;
  final VoidCallback? onRetry;
  final bool television;
  final String version;

  @override
  State<DuanjuApp> createState() => _DuanjuAppState();
}

class _DuanjuAppState extends State<DuanjuApp> with WidgetsBindingObserver {
  final _navigator = rootNavigatorKey;
  Color? _systemColor;
  int? _profileEpoch;
  var _television = false;
  var _phone = false;
  (Color, bool, bool)? _themeKey;
  CoverBlur? _coverBlur;
  late (ThemeData, ThemeData) _themes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance
      ..addEarlyKeyEventHandler(_blockKeyboardFocus)
      ..addEarlyKeyEventHandler(_leaveTextField)
      ..addEarlyKeyEventHandler(_scrollPage);
    _loadSystemColor();
  }

  @override
  void dispose() {
    FocusManager.instance
      ..removeEarlyKeyEventHandler(_blockKeyboardFocus)
      ..removeEarlyKeyEventHandler(_leaveTextField)
      ..removeEarlyKeyEventHandler(_scrollPage);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadSystemColor();
  }

  Future<void> _loadSystemColor() async {
    final color = await readSystemColor();
    if (mounted && color != _systemColor) {
      setState(() => _systemColor = color);
    }
  }

  static final _focusKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  };

  KeyEventResult _blockKeyboardFocus(KeyEvent event) {
    if (_television) return KeyEventResult.ignored;
    final key = event.logicalKey;
    return key == LogicalKeyboardKey.tab ||
            focusedTextField() == null &&
                !keyboardControlsFocused() &&
                _focusKeys.contains(key)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  KeyEventResult _leaveTextField(KeyEvent event) {
    if (!_television || event is KeyUpEvent) return KeyEventResult.ignored;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null ||
        focusedTextField() == null ||
        textFieldKeepsKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    return direction != null && focus.focusInDirection(direction)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  KeyEventResult _scrollPage(KeyEvent event) {
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (_television ||
        event is KeyUpEvent ||
        (key != LogicalKeyboardKey.pageUp &&
            key != LogicalKeyboardKey.pageDown) ||
        keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboardControlsFocused() ||
        (focusedTextField()?.widget.maxLines ?? 1) != 1) {
      return KeyEventResult.ignored;
    }
    final position = _centerScrollPosition();
    if (position == null) return KeyEventResult.ignored;
    final forward =
        (key == LogicalKeyboardKey.pageDown) !=
        (position.axisDirection == AxisDirection.up);
    final step = 0.8 * position.viewportDimension * (forward ? 1 : -1);
    position.moveTo(
      (position.pixels + step).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
      duration: Motion.short,
      curve: Motion.standard,
    );
    return KeyEventResult.handled;
  }

  static ScrollPosition? _centerScrollPosition() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return null;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      view.physicalSize.center(Offset.zero) / view.devicePixelRatio,
      view.viewId,
    );
    for (final entry in result.path) {
      if (entry.target
          case RenderViewportBase(offset: final ScrollPosition position)
          when position.axis == Axis.vertical &&
              position.hasContentDimensions &&
              position.maxScrollExtent > position.minScrollExtent) {
        return position;
      }
    }
    return null;
  }

  KeyEventResult _escape(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    final context =
        focusedTextField()?.context ??
        FocusManager.instance.primaryFocus?.context;
    if (context == null) return KeyEventResult.ignored;
    const intent = DismissIntent();
    final action = Actions.maybeFind<DismissIntent>(context, intent: intent);
    if (action != null &&
        Actions.of(context).invokeActionIfEnabled(action, intent, context).$1) {
      return KeyEventResult.handled;
    }
    final navigator = Navigator.maybeOf(context);
    if (navigator == null || !navigator.canPop()) {
      return KeyEventResult.ignored;
    }
    navigator.maybePop();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return ListenableBuilder(
      listenable: Listenable.merge([?store]),
      builder: (_, _) => _application(store),
    );
  }

  void _resetRoutes(LocalStore? store) {
    final epoch = store?.profileEpoch;
    if (epoch == _profileEpoch) return;
    final previous = _profileEpoch;
    _profileEpoch = epoch;
    if (previous == null) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _navigator.currentState?.popUntil((route) => route.isFirst),
    );
  }

  Widget _application(LocalStore? store) {
    _resetRoutes(store);
    final formFactor = switch (store?.displayMode) {
      'television' => FormFactor.television,
      'phone' => FormFactor.phone,
      'pad' => FormFactor.pad,
      'window' => desktopPlatform ? FormFactor.window : FormFactor.pad,
      _ => widget.television ? FormFactor.television : null,
    };
    final television = formFactor == FormFactor.television;
    if (television != _television) {
      unawaited(AppDevice.setTelevisionMode(television));
    }
    _television = television;
    if (store != null) {
      _coverBlur ??= store.blurCoversButton
          ? CoverBlur.values.byName(store.blurCoversLaunch)
          : CoverBlur.off;
    }
    final coverBlur = _coverBlur ?? CoverBlur.off;
    final systemColor = (store?.followSystemColor ?? true)
        ? _systemColor
        : null;
    final seed =
        systemColor ?? Color((store?.themeColor ?? ThemeColor.orange).seed);
    final pureBlack = store?.pureBlack ?? false;
    if ((seed, television, pureBlack) != _themeKey) {
      _themeKey = (seed, television, pureBlack);
      _themes = (
        AppTheme.build(seed, Brightness.light, television: television),
        AppTheme.build(
          seed,
          Brightness.dark,
          television: television,
          pureBlack: pureBlack,
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => FocusManager.instance.highlightStrategy = television
          ? FocusHighlightStrategy.alwaysTraditional
          : FocusHighlightStrategy.alwaysTouch,
    );
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: appName,
      debugShowCheckedModeBanner: false,
      scrollBehavior: const FocusOutlineScrollBehavior(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _themes.$1,
      darkTheme: _themes.$2,
      themeMode: AppTheme.mode(store?.themeMode ?? 'system'),
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemBars(Theme.of(context).brightness),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) => _escape(event),
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
                  ActivateIntent(),
              SingleActivator(
                LogicalKeyboardKey.gameButtonA,
                includeRepeats: false,
              ): ActivateIntent(),
            },
            child: AppScope(
              repository: widget.repository,
              formFactor: formFactor,
              systemColorAvailable: _systemColor != null,
              version: widget.version,
              child: CoverBlurScope(
                mode: coverBlur,
                enabled: !television && (store?.blurCoversButton ?? false),
                everywhere: store?.blurAllCovers ?? false,
                onToggle: () => setState(
                  () => _coverBlur = coverBlur == CoverBlur.off
                      ? CoverBlur.all
                      : CoverBlur.off,
                ),
                child: Builder(
                  builder: (context) {
                    final phone =
                        AppScope.formFactorOf(context) == FormFactor.phone;
                    if (phone != _phone) {
                      _phone = phone;
                      unawaited(AppDevice.setPhoneMode(phone));
                    }
                    return FocusOutlineMotion(
                      child: FocusOutlineLayer(
                        child: FocusTraversalGroup(
                          policy: ReadingOrderTraversalPolicy(
                            requestFocusCallback: revealFocus,
                          ),
                          child: child!,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
      themeAnimationDuration: Motion.long,
      themeAnimationCurve: Motion.standard,
      home: switch (store) {
        null => _BootScreen(
          error: widget.bootstrapError,
          onRetry: widget.onRetry,
        ),
        LocalStore(acceptedTerms: < termsVersion) => TermsPage(store: store),
        LocalStore(locked: true) => UnlockPage(store: store),
        _ => DeviceRegistrationGate(
          store: store,
          child: AppShell(key: ValueKey(store.profileEpoch), store: store),
        ),
      },
    );
  }
}

class _BootScreen extends StatefulWidget {
  const _BootScreen({this.error, this.onRetry});
  final String? error;
  final VoidCallback? onRetry;

  @override
  State<_BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<_BootScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..forward();

  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.15, 0.75, curve: Curves.easeOut),
  );

  late final Animation<double> _scale =
      Tween<double>(begin: 0.92, end: 1).animate(
        CurvedAnimation(
          parent: _controller,
          curve: const Interval(0.15, 0.85, curve: Curves.easeOut),
        ),
      );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0C0C0E),
    body: Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _BootLines(_controller)),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FadeTransition(
                opacity: _fade,
                child: ScaleTransition(
                  scale: _scale,
                  child: Text(
                    appName,
                    style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 4,
                      color: Color(0xFFECE7DE),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              FadeTransition(
                opacity: _fade,
                child: const Text(
                  'XIAO GUO',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 6,
                    color: Color(0xFF8C867C),
                  ),
                ),
              ),
              if (widget.error != null) ...[
                const SizedBox(height: 28),
                Text(
                  widget.error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF8A857D),
                  ),
                ),
                if (widget.onRetry != null) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: widget.onRetry,
                    child: const Text('重新打开'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

/// 斜向光带：随启动进度从一侧扫过，营造速度感。
class _BootLines extends CustomPainter {
  _BootLines(this.animation) : super(repaint: animation);
  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = animation.value;
    final center = Offset(size.width / 2, size.height * 0.46);
    final paint = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 7; i++) {
      final offset = (i - 3) * 22.0;
      final weight = 70 - (i - 3).abs() * 14;
      if (weight <= 0) continue;
      paint.color = const Color(0xFF96969E).withValues(
        alpha: (weight / 255) * progress,
      );
      final start = Offset(center.dx - 150, center.dy + offset + 90);
      final end = Offset(center.dx + 150, center.dy + offset - 90);
      final drawn = Offset(
        start.dx + (end.dx - start.dx) * progress,
        start.dy + (end.dy - start.dy) * progress,
      );
      canvas.drawLine(start, drawn, paint);
    }
  }

  @override
  bool shouldRepaint(_BootLines oldDelegate) =>
      oldDelegate.animation != animation;
}
