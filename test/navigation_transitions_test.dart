import 'dart:async';
import 'dart:ui' as ui;

import 'package:course_helper/navigation/page_transitions.dart';
import 'package:course_helper/setting/theme_setting.dart';
import 'package:course_helper/utils/storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _homeColor = Color(0xFF008744);
const _nextColor = Color(0xFF0057E7);
const _gapColor = Color(0xFFFF00FF);
const _captureKey = ValueKey('navigation-capture');

class _PopObserver extends NavigatorObserver {
  final List<String?> popped = [];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route.settings.name);
  }
}

class _ProbePage extends StatefulWidget {
  const _ProbePage(this.name, {this.canPop, this.onPop});

  final String name;
  final ValueNotifier<bool>? canPop;
  final void Function(bool)? onPop;

  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      key: ValueKey('page-${widget.name}'),
      backgroundColor: widget.name == 'home' ? _homeColor : _nextColor,
      body: Column(
        children: [
          Text(widget.name),
          TextButton(
            key: ValueKey('back-${widget.name}'),
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('back'),
          ),
          TextButton(
            key: ValueKey('count-${widget.name}'),
            onPressed: () => setState(() => count++),
            child: Text('count: $count'),
          ),
          TextField(key: ValueKey('input-${widget.name}')),
        ],
      ),
    );
    if (widget.canPop == null) return page;
    return ValueListenableBuilder<bool>(
      valueListenable: widget.canPop!,
      builder: (_, canPop, child) => PopScope<void>(
        canPop: canPop,
        onPopInvokedWithResult: (didPop, _) => widget.onPop?.call(didPop),
        child: child!,
      ),
      child: page,
    );
  }
}

class _Harness {
  _Harness({
    bool predictiveBack = true,
    ThemeMode themeMode = ThemeMode.light,
    this.platform = TargetPlatform.android,
    this.canPop,
  }) : predictive = ValueNotifier(predictiveBack),
       mode = ValueNotifier(themeMode);

  final nav = GlobalKey<NavigatorState>();
  final observer = _PopObserver();
  final ValueNotifier<bool> predictive;
  final ValueNotifier<ThemeMode> mode;
  final TargetPlatform platform;
  final ValueNotifier<bool>? canPop;
  final List<bool> popCallbacks = [];

  Widget get app => ValueListenableBuilder<ThemeMode>(
    valueListenable: mode,
    builder: (_, mode, _) => ValueListenableBuilder<bool>(
      valueListenable: predictive,
      builder: (_, predictive, _) {
        final transitions = appPageTransitionsTheme(predictiveBack: predictive);
        ThemeData theme(Brightness brightness) => ThemeData(
          platform: platform,
          brightness: brightness,
          pageTransitionsTheme: transitions,
        );
        return MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [observer],
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          themeMode: mode,
          builder: (_, child) => RepaintBoundary(
            key: _captureKey,
            child: ColoredBox(color: _gapColor, child: child!),
          ),
          home: const _ProbePage('home'),
          routes: {
            '/next': (_) =>
                _ProbePage('next', canPop: canPop, onPop: popCallbacks.add),
            '/third': (_) => const _ProbePage('third'),
          },
        );
      },
    ),
  );

  void dispose() {
    predictive.dispose();
    mode.dispose();
  }
}

Finder _page(String name) => find.byKey(ValueKey('page-$name'));

void _expectOpaque(WidgetTester tester, String name) {
  final page = _page(name);
  for (final fade in tester.widgetList<FadeTransition>(
    find.ancestor(of: page, matching: find.byType(FadeTransition)),
  )) {
    expect(fade.opacity.value, 1.0, reason: '$name must not fade');
  }
  for (final opacity in tester.widgetList<Opacity>(
    find.ancestor(of: page, matching: find.byType(Opacity)),
  )) {
    expect(opacity.opacity, 1.0, reason: '$name must not fade');
  }
}

// Android 14+ events use this channel, including buttons with no touchOffset.
Future<Object?> _backEvent(
  WidgetTester tester,
  String method, {
  double progress = 0,
  int edge = 0,
  bool button = false,
}) async {
  const codec = StandardMethodCodec();
  Object? response;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    codec.encodeMethodCall(
      MethodCall(method, {
        'touchOffset': button ? null : [edge == 0 ? 5.0 : 795.0, 300.0],
        'progress': progress,
        'swipeEdge': edge,
      }),
    ),
    (data) => response = data == null ? null : codec.decodeEnvelope(data),
  );
  return response;
}

Future<void> _mount(WidgetTester tester, _Harness harness) async {
  addTearDown(harness.dispose);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(harness.app);
  await tester.pumpAndSettle();
}

void _push(_Harness harness, String name) {
  unawaited(harness.nav.currentState!.pushNamed<void>(name));
}

Future<void> _expectCoveredEdges(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int rgb(int x) {
        final i = (500 * image.width + x) * 4;
        expect(pixels.getUint8(i + 3), 255);
        return (pixels.getUint8(i) << 16) |
            (pixels.getUint8(i + 1) << 8) |
            pixels.getUint8(i + 2);
      }

      // Distinct page colors reveal a gap or black/white theme flash.
      expect(rgb(4), _homeColor.toARGB32() & 0xFFFFFF);
      expect(rgb(image.width - 5), _nextColor.toARGB32() & 0xFFFFFF);
      for (var x = 0; x < image.width; x++) {
        expect(rgb(x), isNot(_gapColor.toARGB32() & 0xFFFFFF));
        expect(rgb(x), isNot(0x000000));
        expect(rgb(x), isNot(0xFFFFFF));
      }
    } finally {
      image.dispose();
    }
  });
}

void main() {
  test(
    'keeps the existing predictive-back storage key and saved value',
    () async {
      SharedPreferences.setMockInitialValues({'theme_predictive_back': false});
      await StorageManager.initialize();
      await ThemeSetting.ensureLoaded();
      expect(ThemeSetting.predictiveBack.value, isFalse);
      await ThemeSetting.setPredictiveBack(true);
      expect(StorageManager.prefs.getBool('theme_predictive_back'), isTrue);
      await ThemeSetting.setPredictiveBack(false);
      expect(StorageManager.prefs.getBool('theme_predictive_back'), isFalse);
    },
  );

  for (final dark in [false, true]) {
    for (final predictive in [false, true]) {
      for (final back in ['button', 'legacy system', 'Android 14 button']) {
        testWidgets(
          'horizontal push/$back pop, dark=$dark predictive=$predictive',
          (tester) async {
            final harness = _Harness(
              predictiveBack: predictive,
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            );
            await _mount(tester, harness);
            _push(harness, '/next');
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));
            final next = tester.getRect(_page('next'));
            final home = tester.getRect(_page('home'));
            expect(next.left, inExclusiveRange(0, 800));
            expect(home.left, lessThan(0));
            expect(next.top, 0);
            expect(next.size, const Size(800, 600));
            _expectOpaque(tester, 'next');
            _expectOpaque(tester, 'home');
            if (back == 'button') await _expectCoveredEdges(tester);
            for (var frame = 0; frame < 2; frame++) {
              await tester.pump(const Duration(milliseconds: 100));
              _expectOpaque(tester, 'next');
              _expectOpaque(tester, 'home');
            }
            await tester.pumpAndSettle();
            switch (back) {
              case 'button':
                await tester.tap(find.byKey(const ValueKey('back-next')));
              case 'legacy system':
                await tester.binding.handlePopRoute();
              case 'Android 14 button':
                expect(
                  await _backEvent(tester, 'startBackGesture', button: true),
                  isFalse,
                );
                await _backEvent(tester, 'commitBackGesture', button: true);
            }
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));
            expect(
              tester.getRect(_page('next')).left,
              inExclusiveRange(0, 800),
            );
            _expectOpaque(tester, 'next');
            _expectOpaque(tester, 'home');
            if (back == 'button') await _expectCoveredEdges(tester);
            for (var frame = 0; frame < 2; frame++) {
              await tester.pump(const Duration(milliseconds: 100));
              _expectOpaque(tester, 'next');
              _expectOpaque(tester, 'home');
            }
            await tester.pumpAndSettle();
            expect(_page('next'), findsNothing);
            expect(harness.observer.popped, ['/next']);
            expect(
              tester.getRect(_page('home')),
              const Rect.fromLTWH(0, 0, 800, 600),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final dark in [false, true]) {
    for (final edge in [0, 1]) {
      for (final commit in [false, true]) {
        testWidgets(
          'predictive progress/finish, dark=$dark edge=$edge commit=$commit',
          (tester) async {
            final harness = _Harness(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            );
            await _mount(tester, harness);
            _push(harness, '/next');
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('count-next')));
            await tester.enterText(
              find.byKey(const ValueKey('input-next')),
              'keep me',
            );
            FocusManager.instance.primaryFocus?.unfocus();
            await tester.pumpAndSettle();
            final state = tester.state<_ProbePageState>(
              find.byType(_ProbePage).last,
            );

            expect(
              await _backEvent(tester, 'startBackGesture', edge: edge),
              isTrue,
            );
            for (final progress in [0.2, 0.6]) {
              await _backEvent(
                tester,
                'updateBackGestureProgress',
                progress: progress,
                edge: edge,
              );
              await tester.pump();
              expect(tester.getRect(_page('next')).width, lessThan(800));
              expect(_page('home'), findsOneWidget);
              expect(harness.observer.popped, isEmpty);
            }
            await _backEvent(
              tester,
              commit ? 'commitBackGesture' : 'cancelBackGesture',
              edge: edge,
            );
            await tester.pumpAndSettle();
            expect(harness.nav.currentState!.userGestureInProgress, isFalse);
            if (commit) {
              expect(_page('next'), findsNothing);
              expect(harness.observer.popped, ['/next']);
            } else {
              expect(
                tester.getRect(_page('next')),
                const Rect.fromLTWH(0, 0, 800, 600),
              );
              expect(
                tester.state<_ProbePageState>(find.byType(_ProbePage).last),
                same(state),
              );
              expect(state.count, 1);
              expect(find.text('keep me'), findsOneWidget);
              expect(harness.observer.popped, isEmpty);
              _expectOpaque(tester, 'next');
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'disabled predictive animation cancels without pop, commits with slide',
    (tester) async {
      final harness = _Harness(predictiveBack: false);
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pumpAndSettle();
      expect(await _backEvent(tester, 'startBackGesture'), isFalse);
      await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
      await tester.pump();
      expect(
        tester.getRect(_page('next')),
        const Rect.fromLTWH(0, 0, 800, 600),
      );
      await _backEvent(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(harness.observer.popped, isEmpty);
      expect(await _backEvent(tester, 'startBackGesture'), isFalse);
      await _backEvent(tester, 'commitBackGesture');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(_page('next')).left, greaterThan(0));
      _expectOpaque(tester, 'next');
      await tester.pumpAndSettle();
      expect(harness.observer.popped, ['/next']);
    },
  );

  testWidgets(
    'three route levels pop only the top route and preserve underlying state',
    (tester) async {
      final harness = _Harness();
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('count-next')));
      await tester.pump();
      _push(harness, '/third');
      await tester.pumpAndSettle();
      expect(await _backEvent(tester, 'startBackGesture'), isTrue);
      await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
      await tester.pump();
      await _backEvent(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(harness.observer.popped, ['/third']);
      expect(find.text('count: 1'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(harness.observer.popped, ['/third', '/next']);
      expect(_page('home'), findsOneWidget);
    },
  );

  testWidgets('PopScope blocks button, legacy and predictive system return', (
    tester,
  ) async {
    final allowed = ValueNotifier(false);
    addTearDown(allowed.dispose);
    final harness = _Harness(canPop: allowed);
    await _mount(tester, harness);
    _push(harness, '/next');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('back-next')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(await _backEvent(tester, 'startBackGesture'), isFalse);
    await _backEvent(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(_page('next'), findsOneWidget);
    expect(harness.observer.popped, isEmpty);
    expect(harness.popCallbacks, [false, false, false]);
    allowed.value = true;
    await tester.pump();
    expect(await _backEvent(tester, 'startBackGesture'), isTrue);
    await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
    await tester.pump();
    await _backEvent(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(harness.observer.popped, ['/next']);
    expect(harness.popCallbacks, [false, false, false, true]);
  });

  testWidgets(
    'theme changes during a gesture preserve navigation and cancellation',
    (tester) async {
      final harness = _Harness();
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pumpAndSettle();
      final state = tester.state<_ProbePageState>(find.byType(_ProbePage).last);
      expect(await _backEvent(tester, 'startBackGesture'), isTrue);
      await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
      await tester.pump();
      harness.mode.value = ThemeMode.dark;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await _backEvent(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(_page('next'))).brightness,
        Brightness.dark,
      );
      expect(
        tester.state<_ProbePageState>(find.byType(_ProbePage).last),
        same(state),
      );
      expect(harness.observer.popped, isEmpty);
      harness.mode.value = ThemeMode.light;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(_page('next'))).brightness,
        Brightness.light,
      );
      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(
        materialApp.theme!.pageTransitionsTheme,
        same(materialApp.darkTheme!.pageTransitionsTheme),
      );
    },
  );

  for (final commit in [false, true]) {
    testWidgets(
      'setting changed mid-gesture still finishes safely, commit=$commit',
      (tester) async {
        final harness = _Harness();
        await _mount(tester, harness);
        _push(harness, '/next');
        await tester.pumpAndSettle();
        expect(await _backEvent(tester, 'startBackGesture'), isTrue);
        await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
        await tester.pump();
        harness.predictive.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await _backEvent(
          tester,
          commit ? 'commitBackGesture' : 'cancelBackGesture',
        );
        await tester.pumpAndSettle();
        expect(harness.nav.currentState!.userGestureInProgress, isFalse);
        expect(harness.observer.popped, commit ? ['/next'] : isEmpty);
        if (!commit) {
          expect(
            tester.getRect(_page('next')),
            const Rect.fromLTWH(0, 0, 800, 600),
          );
          expect(await _backEvent(tester, 'startBackGesture'), isFalse);
          await _backEvent(tester, 'cancelBackGesture');
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform also slides ordinary routes without fading', (
      tester,
    ) async {
      final harness = _Harness(platform: platform);
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(_page('next')).left, inExclusiveRange(0, 800));
      _expectOpaque(tester, 'next');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('back-next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(_page('next')).left, greaterThan(0));
      _expectOpaque(tester, 'next');
      await tester.pumpAndSettle();
      expect(harness.observer.popped, ['/next']);
    });
  }

  testWidgets('Android does not add a competing iOS pointer edge swipe', (
    tester,
  ) async {
    final harness = _Harness();
    await _mount(tester, harness);
    _push(harness, '/next');
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(1, 300), const Offset(700, 0));
    await tester.pumpAndSettle();
    expect(harness.observer.popped, isEmpty);
    expect(_page('next'), findsOneWidget);
  });
}
