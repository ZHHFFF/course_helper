import 'package:course_helper/pages/widget/log_viewer.dart';
import 'package:course_helper/pages/widget/cache_manager.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:course_helper/main.dart';
import 'package:course_helper/pages/accounts.dart';
import 'package:course_helper/pages/login.dart';
import 'package:course_helper/navigation/miuix_page_transition.dart';
import 'package:course_helper/pages/settings/appearance.dart';
import 'package:course_helper/pages/settings/settings.dart';
import 'package:course_helper/setting/theme_setting.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/classroom_test_env.dart';

const _output = String.fromEnvironment('NAVIGATION_FRAME_DIR');
const _font = String.fromEnvironment('NAVIGATION_PREVIEW_FONT');
const _iconFont = String.fromEnvironment('NAVIGATION_PREVIEW_ICON_FONT');
const _capture = ValueKey('card-navigation-frame');

Future<void> _snapshot(WidgetTester tester, String name) async {
  if (_output.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final file = File('$_output/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Future<Object?> _back(
  WidgetTester tester,
  String method, [
  double progress = 0,
]) async {
  const codec = StandardMethodCodec();
  Object? response;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    codec.encodeMethodCall(
      MethodCall(method, {
        'touchOffset': [5.0, 350.0],
        'progress': progress,
        'swipeEdge': 0,
      }),
    ),
    (bytes) => response = bytes == null ? null : codec.decodeEnvelope(bytes),
  );
  return response;
}

void main() {
  late ClassroomTestEnv env;
  setUp(() async {
    env = await ClassroomTestEnv.create();
    ThemeSetting.predictiveBack.value = true;
    ThemeSetting.blurEnabled.value = true;
    ThemeSetting.floatingNavBar.value = true;
    ThemeSetting.liquidGlass.value = true;
  });
  tearDown(() async {
    ThemeSetting.mode.value = ThemeMode.system;
    ThemeSetting.floatingNavBar.value = false;
    await env.dispose();
  });

  testWidgets('named account and login routes retain arguments and results', (tester) async {
    await tester.pumpWidget(const MyApp());
    await flushClassroomTasks(tester);
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    for (final entry in <String, Type>{'/accounts': AccountsPage, '/login': LoginPage}.entries) {
      final argument = Object();
      final result = navigator.pushNamed(entry.key, arguments: argument);
      await flushClassroomTasks(tester);
      await tester.pumpAndSettle();
      final route = ModalRoute.of(tester.element(find.byType(entry.value).last))!;
      expect(route.settings.name, entry.key);
      expect(route.settings.arguments, same(argument));
      navigator.pop(true);
      expect(await result, isTrue);
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'real Miuix Push, predictive Pop and Cancel frames, dark=$dark',
      (tester) async {
        final oldBanner = WidgetsApp.debugAllowBannerOverride;
        WidgetsApp.debugAllowBannerOverride = false;
        addTearDown(() {
          WidgetsApp.debugAllowBannerOverride = oldBanner;
        });
        if (_font.isNotEmpty) {
          await tester.runAsync(() async {
            final loader = FontLoader('Roboto');
            final bytes = await File(_font).readAsBytes();
            loader.addFont(Future.value(ByteData.sublistView(bytes)));
            await loader.load();
          });
        }
        if (_iconFont.isNotEmpty) {
          await tester.runAsync(() async {
            final loader = FontLoader('MaterialIcons');
            final bytes = await File(_iconFont).readAsBytes();
            loader.addFont(Future.value(ByteData.sublistView(bytes)));
            await loader.load();
          });
        }
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        ThemeSetting.mode.value = dark ? ThemeMode.dark : ThemeMode.light;
        await tester.pumpWidget(
          const RepaintBoundary(key: _capture, child: MyApp()),
        );
        await flushClassroomTasks(tester);
        // Select the existing tab directly; this test measures route motion,
        // while the glass bar's pointer interactions have their own tests.
        tester
            .widget<PageView>(find.byType(PageView).first)
            .controller!
            .jumpToPage(3);
        await tester.pump(const Duration(milliseconds: 500));
        await flushClassroomTasks(tester);
        await tester.pumpAndSettle();
        final settingsState = tester.state(find.byType(SettingsPage));
        final color = dark ? 'dark' : 'light';
        await _snapshot(tester, '$color-push-1');
        await tester.tap(find.text('主題設定'));
        await tester.pump();
        for (final step in [(2, 45), (3, 55), (4, 95)]) {
          await tester.pump(Duration(milliseconds: step.$2));
          final page = find.byType(AppearanceSettingsPage);
          final layer = tester.widget<MiuixPageTransition>(
            find.ancestor(of: page, matching: find.byType(MiuixPageTransition)),
          );
          expect(layer.progress, inExclusiveRange(0, 1));
          expect(tester.getRect(page).left, greaterThan(0));
          await _snapshot(tester, '$color-push-${step.$1}');
        }
        await tester.pumpAndSettle();
        final appearanceState = tester.state(
          find.byType(AppearanceSettingsPage),
        );
        await _snapshot(tester, '$color-push-5');
        await _snapshot(tester, '$color-back-1');
        expect(await _back(tester, 'startBackGesture'), isTrue);
        await _back(tester, 'updateBackGestureProgress', 0.12);
        await tester.pump();
        await _snapshot(tester, '$color-back-2');
        await _back(tester, 'updateBackGestureProgress', 0.55);
        await tester.pump();
        await _snapshot(tester, '$color-back-3');
        final before = tester.getRect(find.byType(AppearanceSettingsPage));
        await _back(tester, 'commitBackGesture');
        await tester.pump();
        expect(tester.getRect(find.byType(AppearanceSettingsPage)), before);
        await tester.pump(const Duration(milliseconds: 90));
        await _snapshot(tester, '$color-back-4');
        await tester.pumpAndSettle();
        expect(find.byType(AppearanceSettingsPage), findsNothing);
        expect(tester.state(find.byType(SettingsPage)), same(settingsState));
        await _snapshot(tester, '$color-back-5');

        await tester.tap(find.text('主題設定'));
        await tester.pumpAndSettle();
        final cancelState = tester.state(find.byType(AppearanceSettingsPage));
        expect(cancelState, isNot(same(appearanceState)));
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(AppearanceSettingsPage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        scroll.position.jumpTo(scroll.position.maxScrollExtent.clamp(0, 70));
        await tester.pumpAndSettle();
        final scrollOffset = scroll.position.pixels;
        expect(await _back(tester, 'startBackGesture'), isTrue);
        for (final step in [(1, 0.3), (2, 0.55)]) {
          await _back(tester, 'updateBackGestureProgress', step.$2);
          await tester.pump();
          await _snapshot(tester, '$color-cancel-${step.$1}');
        }
        final cancelledAt = tester.getRect(find.byType(AppearanceSettingsPage));
        await _back(tester, 'cancelBackGesture');
        await tester.pump();
        expect(
          tester.getRect(find.byType(AppearanceSettingsPage)),
          cancelledAt,
        );
        await tester.pump(const Duration(milliseconds: 35));
        await _snapshot(tester, '$color-cancel-3');
        await tester.pump(const Duration(milliseconds: 55));
        await _snapshot(tester, '$color-cancel-4');
        await tester.pumpAndSettle();
        await _snapshot(tester, '$color-cancel-5');
        expect(
          tester.state(find.byType(AppearanceSettingsPage)),
          same(cancelState),
        );
        expect(scroll.position.pixels, scrollOffset);
        expect(
          tester.getRect(find.byType(AppearanceSettingsPage)),
          const Rect.fromLTWH(0, 0, 390, 844),
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'real settings routes preserve Miuix layout and State, dark=$dark',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        ThemeSetting.mode.value = dark ? ThemeMode.dark : ThemeMode.light;
        await tester.pumpWidget(const MyApp());
        await flushClassroomTasks(tester);
        tester
            .widget<PageView>(find.byType(PageView).first)
            .controller!
            .jumpToPage(3);
        await tester.pump(const Duration(milliseconds: 500));
        await flushClassroomTasks(tester);
        await tester.pumpAndSettle();
        final settings = tester.state(find.byType(SettingsPage));
        for (final entry in <String, Type>{
          '主題設定': AppearanceSettingsPage,
          '运行日志': LogViewerPage,
          '课件缓存': CacheManagerPage,
        }.entries) {
          await Scrollable.ensureVisible(tester.element(find.text(entry.key)));
          await tester.pumpAndSettle();
          await tester.tap(find.text(entry.key));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 60));
          final page = find.byType(entry.value);
          expect(page, findsOneWidget);
          final rect = tester.getRect(page);
          expect(rect.left, inExclusiveRange(0, 390));
          expect(rect.top, 0);
          expect(rect.size, const Size(390, 844));
          final render = tester.renderObject<RenderMiuixPageTransition>(
            find.ancestor(of: page, matching: find.byType(MiuixPageTransition)),
          );
          expect(render.effectiveCorners.topLeft.x, greaterThan(0));
          expect(render.effectiveCorners.topRight, Radius.zero);
          await flushClassroomTasks(tester);
          await tester.pumpAndSettle();
          final state = tester.state(page);
          expect(await _back(tester, 'startBackGesture'), isTrue);
          await _back(tester, 'updateBackGestureProgress', 0.5);
          await tester.pump();
          expect(tester.getRect(page).left, 195);
          await _back(tester, 'cancelBackGesture');
          await tester.pumpAndSettle();
          expect(tester.state(page), same(state));
          expect(tester.getRect(page), const Rect.fromLTWH(0, 0, 390, 844));
          final back = find.descendant(
            of: page,
            matching: find.byIcon(Icons.arrow_back_ios_new),
          );
          await tester.tap(back.first);
          await tester.pumpAndSettle();
          expect(page, findsNothing);
          expect(tester.state(find.byType(SettingsPage)), same(settings));
        }
      },
    );
  }
}
