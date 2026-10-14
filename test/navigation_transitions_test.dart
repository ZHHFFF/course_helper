import 'dart:async';
import 'dart:ui' as ui;

import 'package:course_helper/navigation/page_transitions.dart';
import 'package:course_helper/navigation/miuix_page_route.dart';
import 'package:course_helper/navigation/miuix_page_transition.dart';
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
  int builds = 0;
  final scroll = ScrollController();

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    builds++;
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
          Expanded(
            child: ListView(
              controller: scroll,
              children: [
                for (var i = 0; i < 30; i++)
                  SizedBox(height: 40, child: Center(child: Text('row $i'))),
              ],
            ),
          ),
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
    this.direction = TextDirection.ltr,
    this.reduceMotion = false,
  }) : predictive = ValueNotifier(predictiveBack),
       mode = ValueNotifier(themeMode);

  final nav = GlobalKey<NavigatorState>();
  final observer = _PopObserver();
  final dispatcher = MiuixBackGestureDispatcher();
  final ValueNotifier<bool> predictive;
  final ValueNotifier<ThemeMode> mode;
  final TargetPlatform platform;
  final ValueNotifier<bool>? canPop;
  final TextDirection direction;
  final bool reduceMotion;
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
          navigatorObservers: [observer, dispatcher],
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          themeMode: mode,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: Directionality(
              textDirection: direction,
              child: RepaintBoundary(
                key: _captureKey,
                child: ColoredBox(color: _gapColor, child: child!),
              ),
            ),
          ),
          onGenerateRoute: (settings) => MiuixPageRoute<void>(
            settings: settings,
            builder: (_) => switch (settings.name) {
              '/next' => _ProbePage(
                'next',
                canPop: canPop,
                onPop: popCallbacks.add,
              ),
              '/third' => const _ProbePage('third'),
              _ => const _ProbePage('home'),
            },
          ),
        );
      },
    ),
  );

  void dispose() {
    dispatcher.dispose();
    predictive.dispose();
    mode.dispose();
  }
}

Finder _page(String name) => find.byKey(ValueKey('page-$name'));

MiuixPageTransition _layer(WidgetTester tester, String name) =>
    tester.widget<MiuixPageTransition>(
      find.ancestor(
        of: _page(name),
        matching: find.byType(MiuixPageTransition),
      ),
    );

double _corner(WidgetTester tester, String name) => tester
    .renderObject<RenderMiuixPageTransition>(
      find.ancestor(
        of: _page(name),
        matching: find.byType(MiuixPageTransition),
      ),
    )
    .effectiveCorners
    .resolve(TextDirection.ltr)
    .topLeft
    .x;

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
      // The previous page remains visible under the animated scrim.
      final shadedHome = rgb(4);
      expect(shadedHome & 0xFF, inInclusiveRange(53, 68));
      expect((shadedHome >> 8) & 0xFF, inInclusiveRange(105, 135));
      expect(shadedHome >> 16, 0);
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
            expect(
              home.left,
              closeTo(-0.25 * 800 * _layer(tester, "next").progress, 1e-6),
            );
            expect(next.top, 0);
            expect(next.width, 800);
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
              expect(tester.getRect(_page('next')).width, 800);
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
  for (final commit in [false, true]) {
    for (final progress in [0.0, 0.03, 0.25, 0.75, 0.98, 1.0]) {
      testWidgets('continuous release at $progress, commit=$commit', (
        tester,
      ) async {
        final harness = _Harness();
        await _mount(tester, harness);
        _push(harness, '/next');
        await tester.pumpAndSettle();
        expect(await _backEvent(tester, 'startBackGesture'), isTrue);
        await _backEvent(
          tester,
          'updateBackGestureProgress',
          progress: progress,
        );
        await tester.pump();
        final before = tester.getRect(_page('next'));
        final corner = _corner(tester, 'next');
        expect(_layer(tester, 'next').progress, closeTo(1 - progress, 1e-8));
        await _backEvent(
          tester,
          commit ? 'commitBackGesture' : 'cancelBackGesture',
        );
        await tester.pump();
        if (!(commit && progress == 1)) {
          expect(
            tester.getRect(_page('next')),
            before,
            reason: 'the first released frame must stay at the finger position',
          );
          expect(_corner(tester, 'next'), corner);
          await tester.pump(const Duration(milliseconds: 30));
          final after = tester.getRect(_page('next'));
          expect(
            after.left,
            commit
                ? greaterThanOrEqualTo(before.left)
                : lessThanOrEqualTo(before.left),
          );
          _expectOpaque(tester, 'next');
        }
        await tester.pumpAndSettle();
        expect(harness.nav.currentState!.userGestureInProgress, isFalse);
        if (commit) {
          expect(harness.observer.popped, ['/next']);
        } else {
          expect(
            tester.getRect(_page('next')),
            const Rect.fromLTWH(0, 0, 800, 600),
          );
          expect(_corner(tester, 'next'), 0);
          expect(harness.observer.popped, isEmpty);
          // Cancellation must not leave its progress mapping on the next pop.
          await tester.binding.handlePopRoute();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.getRect(_page('next')).left, greaterThan(0));
          await tester.pumpAndSettle();
          expect(harness.observer.popped, ['/next']);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Push and button Pop both continuously change corners and size', (
    tester,
  ) async {
    final harness = _Harness();
    await _mount(tester, harness);
    _push(harness, '/next');
    await tester.pump();
    var previous = double.infinity;
    for (final milliseconds in [50, 50, 50, 50, 70, 100, 50]) {
      await tester.pump(Duration(milliseconds: milliseconds));
      final rect = tester.getRect(_page('next'));
      expect(rect.left, lessThanOrEqualTo(previous));
      previous = rect.left;
      if (rect.left > 0) {
        expect(
          tester.getRect(_page('home')).left,
          closeTo(-0.25 * 800 * _layer(tester, 'next').progress, 1e-6),
        );
      }
      _expectOpaque(tester, 'next');
      if (rect.left > 0) {
        expect(_corner(tester, 'next'), greaterThan(0));
        expect(rect.width, 800);
      }
    }
    await tester.pumpAndSettle();
    expect(_corner(tester, 'next'), 0);
    expect(tester.getRect(_page('next')), const Rect.fromLTWH(0, 0, 800, 600));
    await tester.tap(find.byKey(const ValueKey('back-next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_corner(tester, 'next'), greaterThan(0));
    expect(tester.getRect(_page('next')).width, 800);
    _expectOpaque(tester, 'next');
    await tester.pumpAndSettle();
    expect(harness.observer.popped, ['/next']);
  });

  testWidgets(
    'repeated cancellations preserve input, scrolling and underlying page state',
    (tester) async {
      final harness = _Harness();
      await _mount(tester, harness);
      await tester.tap(find.byKey(const ValueKey('count-home')));
      _push(harness, '/next');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('input-next')),
        'saved draft',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final state = tester.state<_ProbePageState>(find.byType(_ProbePage).last);
      state.scroll.jumpTo(280);
      await tester.pump();
      for (final progress in [0.02, 0.4, 0.9, 0.1, 0.65]) {
        expect(await _backEvent(tester, 'startBackGesture'), isTrue);
        await _backEvent(
          tester,
          'updateBackGestureProgress',
          progress: progress,
        );
        await tester.pump();
        await _backEvent(tester, 'cancelBackGesture');
        await tester.pumpAndSettle();
        expect(
          tester.state<_ProbePageState>(find.byType(_ProbePage).last),
          same(state),
        );
        expect(state.scroll.offset, 280);
        expect(find.text('saved draft'), findsOneWidget);
        expect(harness.observer.popped, isEmpty);
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('count: 1'), findsOneWidget);
    },
  );

  testWidgets(
    'a PopScope veto changed during drag cancels instead of exiting',
    (tester) async {
      final allowed = ValueNotifier(true);
      addTearDown(allowed.dispose);
      final harness = _Harness(canPop: allowed);
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pumpAndSettle();
      expect(await _backEvent(tester, 'startBackGesture'), isTrue);
      await _backEvent(tester, 'updateBackGestureProgress', progress: 0.7);
      await tester.pump();
      allowed.value = false;
      await tester.pump();
      final before = tester.getRect(_page('next'));
      await _backEvent(tester, 'commitBackGesture');
      await tester.pump();
      expect(tester.getRect(_page('next')), before);
      await tester.pumpAndSettle();
      expect(harness.observer.popped, isEmpty);
      expect(harness.popCallbacks, [false]);
      expect(harness.nav.currentState!.userGestureInProgress, isFalse);
      expect(
        tester.getRect(_page('next')),
        const Rect.fromLTWH(0, 0, 800, 600),
      );
    },
  );

  testWidgets('RTL mirrors ordinary motion and both system gesture edges', (
    tester,
  ) async {
    final harness = _Harness(direction: TextDirection.rtl);
    await _mount(tester, harness);
    _push(harness, '/next');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(_page('next')).left, lessThan(0));
    await tester.pumpAndSettle();
    for (final edge in [0, 1]) {
      expect(await _backEvent(tester, 'startBackGesture', edge: edge), isTrue);
      await _backEvent(
        tester,
        'updateBackGestureProgress',
        progress: 0.45,
        edge: edge,
      );
      await tester.pump();
      expect(tester.getRect(_page('next')).left, lessThan(0));
      await _backEvent(tester, 'cancelBackGesture', edge: edge);
      await tester.pumpAndSettle();
    }
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(_page('next')).left, lessThan(0));
    await tester.pumpAndSettle();
    expect(harness.observer.popped, ['/next']);
  });

  testWidgets(
    'reduce motion keeps pages fullscreen and normal system back working',
    (tester) async {
      final harness = _Harness(reduceMotion: true);
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        tester.getRect(_page('next')),
        const Rect.fromLTWH(0, 0, 800, 600),
      );
      expect(_corner(tester, 'next'), 0);
      _expectOpaque(tester, 'next');
      await tester.pumpAndSettle();
      expect(await _backEvent(tester, 'startBackGesture'), isFalse);
      await _backEvent(tester, 'cancelBackGesture');
      expect(harness.observer.popped, isEmpty);
      await _backEvent(tester, 'startBackGesture');
      await _backEvent(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(harness.observer.popped, ['/next']);
    },
  );

  testWidgets(
    'Apple SDK edge gesture uses the card and cancellation retains state',
    (tester) async {
      final harness = _Harness(platform: TargetPlatform.iOS);
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pumpAndSettle();
      final state = tester.state<_ProbePageState>(find.byType(_ProbePage).last);
      final gesture = await tester.startGesture(const Offset(1, 300));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(150, 0));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.getRect(_page('next')).left, greaterThan(0));
      expect(_corner(tester, 'next'), greaterThan(0));
      _expectOpaque(tester, 'next');
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(harness.observer.popped, isEmpty);
      expect(
        tester.state<_ProbePageState>(find.byType(_ProbePage).last),
        same(state),
      );
    },
  );
  testWidgets(
    'pop during unfinished push retains its position without restarting',
    (tester) async {
      final harness = _Harness();
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      final before = tester.getRect(_page('next'));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(tester.getRect(_page('next')), before);
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.getRect(_page('next')).left, greaterThan(before.left));
      await tester.pumpAndSettle();
      expect(harness.observer.popped, ['/next']);
    },
  );

  testWidgets('rapid repeated back taps only remove the top route', (
    tester,
  ) async {
    final harness = _Harness();
    await _mount(tester, harness);
    _push(harness, '/next');
    await tester.pumpAndSettle();
    _push(harness, '/third');
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('back-third'));
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(harness.observer.popped, ['/third']);
    expect(_page('next'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate native start retains the original gesture owner', (
    tester,
  ) async {
    final harness = _Harness();
    await _mount(tester, harness);
    _push(harness, '/next');
    await tester.pumpAndSettle();
    expect(await _backEvent(tester, 'startBackGesture'), isTrue);
    await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
    await tester.pump();
    final before = tester.getRect(_page('next'));
    expect(await _backEvent(tester, 'startBackGesture'), isTrue);
    await tester.pump();
    expect(tester.getRect(_page('next')), before);
    await _backEvent(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(harness.observer.popped, isEmpty);
    expect(harness.nav.currentState!.userGestureInProgress, isFalse);
    expect(tester.getRect(_page('next')), const Rect.fromLTWH(0, 0, 800, 600));
  });

  testWidgets('duplicate terminal events during settlement do not pop twice', (
    tester,
  ) async {
    final harness = _Harness();
    await _mount(tester, harness);
    _push(harness, '/next');
    await tester.pumpAndSettle();
    _push(harness, '/third');
    await tester.pumpAndSettle();
    expect(await _backEvent(tester, 'startBackGesture'), isTrue);
    await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
    await tester.pump();
    await _backEvent(tester, 'commitBackGesture');
    await _backEvent(tester, 'commitBackGesture');
    await _backEvent(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(harness.observer.popped, ['/third']);
    expect(_page('next'), findsOneWidget);
    expect(harness.nav.currentState!.userGestureInProgress, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'paint ticks retain page and transition widgets, one Leading clip and no opacity/scale layers',
    (tester) async {
      final harness = _Harness();
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final transition = _layer(tester, 'next');
      final nextState = tester.state<_ProbePageState>(
        find.byType(_ProbePage).last,
      );
      final homeState = tester.state<_ProbePageState>(
        find.byType(_ProbePage).first,
      );
      final nextBuilds = nextState.builds;
      final homeBuilds = homeState.builds;
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_layer(tester, 'next'), same(transition));
        expect(nextState.builds, nextBuilds);
        expect(homeState.builds, homeBuilds);
        final render = tester.renderObject<RenderMiuixPageTransition>(
          find.ancestor(
            of: _page('next'),
            matching: find.byType(MiuixPageTransition),
          ),
        );
        expect(render.effectiveCorners.topLeft.x, greaterThan(0));
        expect(render.effectiveCorners.topRight, Radius.zero);
        expect(render.effectiveCorners.bottomRight, Radius.zero);
        expect(tester.getRect(_page('next')).size, const Size(800, 600));
        final clips = tester.layers
            .whereType<ClipRSuperellipseLayer>()
            .toList();
        expect(clips, hasLength(1));
        expect(clips.single.clipBehavior, Clip.antiAlias);
        _expectOpaque(tester, 'next');
      }
      await tester.pumpAndSettle();
      expect(tester.layers.whereType<ClipRSuperellipseLayer>(), isEmpty);
    },
  );

  for (final edge in [0, 1]) {
    testWidgets(
      'foreground/background share gesture and spring progress, edge=$edge',
      (tester) async {
        final harness = _Harness();
        await _mount(tester, harness);
        _push(harness, '/next');
        await tester.pumpAndSettle();
        expect(
          await _backEvent(tester, 'startBackGesture', edge: edge),
          isTrue,
        );
        void check() {
          final value = _layer(tester, 'next').progress;
          expect(
            tester.getRect(_page('next')).left,
            closeTo((1 - value) * 800, 0.51),
          );
          expect(
            tester.getRect(_page('home')).left,
            closeTo(-value * 200, 1e-6),
          );
          expect(
            _corner(tester, 'next'),
            lessThanOrEqualTo(tester.getRect(_page('next')).left),
          );
        }

        for (final progress in [0.005, 0.02, 0.1, 0.55, 0.85]) {
          await tester.pump(const Duration(milliseconds: 16));
          await _backEvent(
            tester,
            'updateBackGestureProgress',
            progress: progress,
            edge: edge,
          );
          await tester.pump();
          check();
        }
        final before = tester.getRect(_page('next'));
        final background = tester.getRect(_page('home'));
        await _backEvent(tester, 'cancelBackGesture', edge: edge);
        await tester.pump();
        expect(tester.getRect(_page('next')), before);
        expect(tester.getRect(_page('home')), background);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          check();
        }
        await tester.pumpAndSettle();
        expect(harness.nav.currentState!.userGestureInProgress, isFalse);
      },
    );
  }

  testWidgets(
    'route removed during native session consumes late commit without popping previous route',
    (tester) async {
      final harness = _Harness();
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pumpAndSettle();
      _push(harness, '/third');
      await tester.pumpAndSettle();
      expect(await _backEvent(tester, 'startBackGesture'), isTrue);
      await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
      await tester.pump();
      final removed = ModalRoute.of(tester.element(_page('third')))!;
      harness.nav.currentState!.removeRoute(removed);
      await tester.pumpAndSettle();
      expect(harness.nav.currentState!.userGestureInProgress, isFalse);
      await _backEvent(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(_page('next'), findsOneWidget);
      expect(harness.observer.popped, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'push during native session restores held page smoothly and consumes stale end',
    (tester) async {
      final harness = _Harness();
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pumpAndSettle();
      final state = tester.state<_ProbePageState>(find.byType(_ProbePage).last);
      state.count = 5;
      expect(await _backEvent(tester, 'startBackGesture'), isTrue);
      await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
      await tester.pump();
      _push(harness, '/third');
      await tester.pumpAndSettle();
      await _backEvent(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(_page('third'), findsOneWidget);
      expect(harness.observer.popped, isEmpty);
      expect(harness.nav.currentState!.userGestureInProgress, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.state<_ProbePageState>(find.byType(_ProbePage).last),
        same(state),
      );
      expect(
        tester.getRect(_page('next')),
        const Rect.fromLTWH(0, 0, 800, 600),
      );
      expect(state.count, 5);
    },
  );

  testWidgets(
    'rapid repeated back while a route exits cannot pop a second page',
    (tester) async {
      final harness = _Harness();
      await _mount(tester, harness);
      _push(harness, '/next');
      await tester.pumpAndSettle();
      _push(harness, '/third');
      await tester.pumpAndSettle();
      expect(await _backEvent(tester, 'startBackGesture'), isTrue);
      await _backEvent(tester, 'updateBackGestureProgress', progress: 0.6);
      await tester.pump();
      await _backEvent(tester, 'commitBackGesture');
      await tester.pump();
      await _backEvent(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      await _backEvent(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(harness.observer.popped, ['/third']);
      expect(_page('next'), findsOneWidget);
    },
  );
}
