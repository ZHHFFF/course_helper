import 'dart:io';

import 'package:course_helper/cache/course_cache.dart';
import 'package:course_helper/cache/ppt_cache.dart';
import 'package:course_helper/main.dart';
import 'package:course_helper/pages/courseware/list.dart';
import 'package:course_helper/pages/courseware/viewer.dart';
import 'package:course_helper/platform.dart';
import 'package:course_helper/setting/theme_setting.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/classroom_test_env.dart';

const _cachedPpt = {
  'title': '导航课件',
  'width': 800,
  'height': 600,
  'slides': [
    {'index': 0},
    {'index': 1},
    {'index': 2},
  ],
};

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  // File and directory streams need real event-loop turns as well as frames.
  // A loading spinner alone cannot be resolved by pumpAndSettle's fake clock.
  for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
    await flushClassroomTasks(tester);
  }
  expect(finder, findsAtLeastNWidgets(1));
  await tester.pumpAndSettle();
}

Future<Object?> _backEvent(
  WidgetTester tester,
  String method, {
  double progress = 0,
}) async {
  const codec = StandardMethodCodec();
  Object? response;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    codec.encodeMethodCall(
      MethodCall(method, {
        'touchOffset': [5.0, 300.0],
        'progress': progress,
        'swipeEdge': 0,
      }),
    ),
    (data) => response = data == null ? null : codec.decodeEnvelope(data),
  );
  return response;
}

Future<void> _mountCourseware(WidgetTester tester) async {
  await tester.pumpWidget(const MyApp());
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('课件').last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await _waitFor(tester, find.text('导航课程'));
  expect(find.text('导航课程'), findsOneWidget);
}

Future<void> _openPpt(WidgetTester tester) async {
  await tester.tap(find.text('导航课程').last);
  await _waitFor(tester, find.text('已缓存课件 (1)'));
  await tester.tap(find.text('导航课件').last);
  await _waitFor(tester, find.text('第 1 页没有图片'));
  expect(find.byType(CoursewareViewer), findsOneWidget);
}

void main() {
  late ClassroomTestEnv env;
  setUp(() async {
    env = await ClassroomTestEnv.create();
    await PlatformManager().setPlatform(PlatformType.rainClassroom);
    ThemeSetting.predictiveBack.value = true;
    ThemeSetting.blurEnabled.value = false;
    ThemeSetting.floatingNavBar.value = false;
    await PptCache.save(
      'navigation-lesson',
      'navigation-ppt',
      _cachedPpt,
      courseName: '导航课程',
    );
  });
  tearDown(() async {
    ThemeSetting.mode.value = ThemeMode.system;
    ThemeSetting.blurEnabled.value = true;
    await env.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets(
      'courseware stage back, theme and real tab retention, dark=$dark',
      (tester) async {
        ThemeSetting.mode.value = dark ? ThemeMode.dark : ThemeMode.light;
        await _mountCourseware(tester);
        final courseState = tester.state(find.byType(CoursewarePage));
        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(
          app.theme!.pageTransitionsTheme,
          same(app.darkTheme!.pageTransitionsTheme),
        );

        // Internal stages do not create routes or support a route-pop preview.
        await tester.tap(find.text('导航课程').last);
        await _waitFor(tester, find.text('已缓存课件 (1)'));
        expect(navigatorKey.currentState!.canPop(), isFalse);
        expect(await _backEvent(tester, 'startBackGesture'), isFalse);
        await _backEvent(tester, 'cancelBackGesture');
        await tester.pumpAndSettle();
        expect(find.text('已缓存课件 (1)'), findsOneWidget);
        expect(await _backEvent(tester, 'startBackGesture'), isFalse);
        await _backEvent(tester, 'commitBackGesture');
        await tester.pumpAndSettle();
        expect(find.text('已缓存课件 (1)'), findsNothing);
        expect(find.text('导航课程'), findsOneWidget);

        await _openPpt(tester);
        final viewerState = tester.state(find.byType(CoursewareViewer));
        await tester.tap(find.text('第 1 页没有图片'));
        await tester.pumpAndSettle();
        final viewerPages = find.descendant(
          of: find.byType(CoursewareViewer),
          matching: find.byType(PageView),
        );
        expect(viewerPages, findsOneWidget);
        await tester.drag(viewerPages, const Offset(-600, 0));
        await tester.pumpAndSettle();
        expect(find.text('2 / 3'), findsOneWidget);

        ThemeSetting.mode.value = dark ? ThemeMode.light : ThemeMode.dark;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(CoursewareViewer)), same(viewerState));
        await tester.tap(find.text('设置').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text('课件').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.state(find.byType(CoursewarePage)), same(courseState));
        expect(tester.state(find.byType(CoursewareViewer)), same(viewerState));
        expect(find.text('2 / 3'), findsOneWidget);

        // One return exits single-page mode; the next returns to the PPT list.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(viewerPages, findsNothing);
        expect(tester.state(find.byType(CoursewareViewer)), same(viewerState));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(CoursewareViewer), findsNothing);
        expect(find.text('已缓存课件 (1)'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
        await tester.pumpAndSettle();
        expect(find.text('已缓存课件 (1)'), findsNothing);
        expect(tester.state(find.byType(CoursewarePage)), same(courseState));
        expect(navigatorKey.currentState!.canPop(), isFalse);
        final saved = await tester.runAsync(() async {
          final dir = await CourseCache.pptDir('navigation-lesson');
          return CourseCache.readJson(File('${dir.path}/navigation-ppt.json'));
        });
        expect(saved!['data'], _cachedPpt);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await flushClassroomTasks(tester);
      },
    );
  }

  testWidgets(
    'fullscreen route predictive cancel/commit preserves the internal viewer',
    (tester) async {
      ThemeSetting.mode.value = ThemeMode.dark;
      await _mountCourseware(tester);
      await _openPpt(tester);
      final viewerState = tester.state<CoursewareViewerState>(
        find.byType(CoursewareViewer),
      );
      viewerState.openFullscreen();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final fullscreenScaffold = find.descendant(
        of: find.byType(CoursewareFullscreenViewer),
        matching: find.byType(Scaffold),
      );
      expect(tester.getRect(fullscreenScaffold).left, greaterThan(0));
      await tester.pumpAndSettle();
      final fullscreenState = tester.state(
        find.byType(CoursewareFullscreenViewer),
      );
      expect(await _backEvent(tester, 'startBackGesture'), isTrue);
      await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
      await tester.pump();
      await _backEvent(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(CoursewareFullscreenViewer)),
        same(fullscreenState),
      );
      expect(await _backEvent(tester, 'startBackGesture'), isTrue);
      await _backEvent(tester, 'updateBackGestureProgress', progress: 0.5);
      await tester.pump();
      await _backEvent(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.byType(CoursewareFullscreenViewer), findsNothing);
      expect(tester.state(find.byType(CoursewareViewer)), same(viewerState));
      expect(navigatorKey.currentState!.canPop(), isFalse);
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await flushClassroomTasks(tester);
    },
  );
}
