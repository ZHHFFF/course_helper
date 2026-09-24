import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/pages/courseware/list.dart';
import 'package:course_helper/platform.dart';
import 'package:course_helper/utils/storage.dart';
import 'support/cache_test_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformManager 平台管理器与响应式通知器 (F5)', () {
    late CacheTestEnv env;

    setUp(() async {
      env = await CacheTestEnv.create();
      PlatformManager.debugReset();
    });

    tearDown(() async {
      PlatformManager.debugReset();
      await env.dispose();
    });

    test('初始状态与兼容性别名正确', () {
      final pm = PlatformManager();
      expect(pm.currentPlatform, equals(PlatformType.chaoxing));
      expect(pm.platform, equals(PlatformType.chaoxing));
      expect(pm.platformNotifier.value, equals(PlatformType.chaoxing));
      expect(pm.isChaoxing, isTrue);
      expect(pm.isRainClassroom, isFalse);
      expect(pm.isYuketang, isFalse);
      expect(pm.currentServer, equals(RainClassroomServerType.changjiang));
    });

    test('切换平台触发 platformNotifier 通知并更新状态与别名', () async {
      final pm = PlatformManager();
      int notifyCount = 0;
      PlatformType? notifiedPlatform;

      void listener() {
        notifyCount++;
        notifiedPlatform = pm.platformNotifier.value;
      }

      pm.platformNotifier.addListener(listener);

      // 切换至雨课堂
      await pm.setPlatform(PlatformType.rainClassroom);

      expect(notifyCount, equals(1));
      expect(notifiedPlatform, equals(PlatformType.rainClassroom));
      expect(pm.platformNotifier.value, equals(PlatformType.rainClassroom));
      expect(pm.currentPlatform, equals(PlatformType.rainClassroom));
      expect(pm.platform, equals(PlatformType.rainClassroom));
      expect(pm.isChaoxing, isFalse);
      expect(pm.isRainClassroom, isTrue);
      expect(pm.isYuketang, isTrue);

      pm.platformNotifier.removeListener(listener);
    });

    test('重复设置相同平台保持幂等，不触发多余通知', () async {
      final pm = PlatformManager();
      int notifyCount = 0;

      void listener() {
        notifyCount++;
      }

      pm.platformNotifier.addListener(listener);

      // 当前已经是 chaoxing，再次设置为 chaoxing
      await pm.setPlatform(PlatformType.chaoxing);
      expect(notifyCount, equals(0));

      // 切换到 rainClassroom（触发一次）
      await pm.setPlatform(PlatformType.rainClassroom);
      expect(notifyCount, equals(1));

      // 再次设置为 rainClassroom（幂等，不应触发）
      await pm.setPlatform(PlatformType.rainClassroom);
      expect(notifyCount, equals(1));

      pm.platformNotifier.removeListener(listener);
    });

    test('往复切换平台支持多次通知', () async {
      final pm = PlatformManager();
      final history = <PlatformType>[];

      void listener() {
        history.add(pm.platformNotifier.value);
      }

      pm.platformNotifier.addListener(listener);

      await pm.setPlatform(PlatformType.rainClassroom);
      await pm.setPlatform(PlatformType.chaoxing);
      await pm.setPlatform(PlatformType.rainClassroom);

      expect(history, equals([
        PlatformType.rainClassroom,
        PlatformType.chaoxing,
        PlatformType.rainClassroom,
      ]));

      pm.platformNotifier.removeListener(listener);
    });

    test('多监听器独立注册与解绑', () async {
      final pm = PlatformManager();
      int l1Count = 0;
      int l2Count = 0;

      void l1() => l1Count++;
      void l2() => l2Count++;

      pm.platformNotifier.addListener(l1);
      pm.platformNotifier.addListener(l2);

      await pm.setPlatform(PlatformType.rainClassroom);
      expect(l1Count, equals(1));
      expect(l2Count, equals(1));

      pm.platformNotifier.removeListener(l1);

      await pm.setPlatform(PlatformType.chaoxing);
      expect(l1Count, equals(1)); // l1 已移除，不再增加
      expect(l2Count, equals(2)); // l2 继续收到通知

      pm.platformNotifier.removeListener(l2);
    });

    test('setServer 切换雨课堂服务器不会误触发 platformNotifier', () async {
      final pm = PlatformManager();
      int notifyCount = 0;

      void listener() => notifyCount++;
      pm.platformNotifier.addListener(listener);

      await pm.setServer(RainClassroomServerType.huanghe);
      expect(notifyCount, equals(0));
      expect(pm.currentServer, equals(RainClassroomServerType.huanghe));

      pm.platformNotifier.removeListener(listener);
    });

    test('initialize() 从持久化存储还原平台并同步 platformNotifier', () async {
      final pm = PlatformManager();
      // 在存储中模拟已保存 rainClassroom
      StorageManager.prefs.setString('current_platform', 'rainclassroom');

      await pm.initialize();

      expect(pm.currentPlatform, equals(PlatformType.rainClassroom));
      expect(pm.platformNotifier.value, equals(PlatformType.rainClassroom));
      expect(pm.isYuketang, isTrue);
    });

    test('debugReset() 恢复管理器默认状态', () async {
      final pm = PlatformManager();
      await pm.setPlatform(PlatformType.rainClassroom);
      await pm.setServer(RainClassroomServerType.pro);

      expect(pm.currentPlatform, equals(PlatformType.rainClassroom));
      expect(pm.platformNotifier.value, equals(PlatformType.rainClassroom));

      PlatformManager.debugReset();

      expect(pm.currentPlatform, equals(PlatformType.chaoxing));
      expect(pm.platformNotifier.value, equals(PlatformType.chaoxing));
      expect(pm.currentServer, equals(RainClassroomServerType.changjiang));
    });
  });

  group('CoursewarePage 平台变更即时响应与生命周期 (F6)', () {
    late CacheTestEnv env;

    setUp(() async {
      env = await CacheTestEnv.create();
      PlatformManager.debugReset();
    });

    tearDown(() async {
      PlatformManager.debugReset();
      await env.dispose();
    });

    Future<void> pumpUntilSettled(WidgetTester tester) async {
      for (int i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('切换平台触发 CoursewarePage 自动重载并不抛出异常', (tester) async {
      await tester.pumpWidget(
        MiuixTheme(
          data: MiuixThemeData.light(),
          child: const MaterialApp(
            home: Scaffold(
              body: CoursewarePage(),
            ),
          ),
        ),
      );
      await pumpUntilSettled(tester);

      // 切换平台至雨课堂
      await PlatformManager().setPlatform(PlatformType.rainClassroom);
      await pumpUntilSettled(tester);

      // 再次切换回学习通
      await PlatformManager().setPlatform(PlatformType.chaoxing);
      await pumpUntilSettled(tester);

      // 验证未发生未捕获异常
      expect(find.byType(CoursewarePage), findsOneWidget);
    });

    testWidgets('快速连续切换平台（防竞态）不会崩溃或卡死', (tester) async {
      await tester.pumpWidget(
        MiuixTheme(
          data: MiuixThemeData.light(),
          child: const MaterialApp(
            home: Scaffold(
              body: CoursewarePage(),
            ),
          ),
        ),
      );
      await pumpUntilSettled(tester);

      // 快速交替连续切换
      final f1 = PlatformManager().setPlatform(PlatformType.rainClassroom);
      final f2 = PlatformManager().setPlatform(PlatformType.chaoxing);
      final f3 = PlatformManager().setPlatform(PlatformType.rainClassroom);

      await Future.wait([f1, f2, f3]);
      await pumpUntilSettled(tester);

      expect(PlatformManager().currentPlatform, equals(PlatformType.rainClassroom));
      expect(find.byType(CoursewarePage), findsOneWidget);
    });

    testWidgets('CoursewarePage dispose 时正确注销监听器', (tester) async {
      await tester.pumpWidget(
        MiuixTheme(
          data: MiuixThemeData.light(),
          child: const MaterialApp(
            home: Scaffold(
              body: CoursewarePage(),
            ),
          ),
        ),
      );
      await pumpUntilSettled(tester);

      // 替换为不同 widget 以触发 CoursewarePage 的 dispose
      await tester.pumpWidget(
        MiuixTheme(
          data: MiuixThemeData.light(),
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox.shrink(),
            ),
          ),
        ),
      );
      await pumpUntilSettled(tester);

      // dispose 后切换平台，确保无任何内存泄漏异常或使用已销毁 State 的异常
      await PlatformManager().setPlatform(PlatformType.rainClassroom);
      expect(PlatformManager().currentPlatform, equals(PlatformType.rainClassroom));
    });
  });
}
