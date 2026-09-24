import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/cache/ppt_cache.dart';
import 'package:course_helper/pages/courseware/list.dart';
import 'package:course_helper/pages/courseware/viewer.dart';
import 'package:course_helper/platform.dart';
import 'support/cache_test_env.dart';

Map<String, dynamic> _pptData(String title, List<String> imageUrls) => {
      'title': title,
      'width': 720,
      'height': 540,
      'version': '1.0',
      'slides': [
        for (var i = 0; i < imageUrls.length; i++)
          {
            'id': 'slide-$i',
            'index': i,
            'cover': imageUrls[i],
            'coverAlt': imageUrls[i],
            'thumbnail': imageUrls[i],
            'shapes': <dynamic>[],
            'note': '',
          },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CoursewarePage 深度层级 (_Stage.pptList / _Stage.viewer) 平台切换状态机压力测试', () {
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

    testWidgets('在 _Stage.pptList 深度层级切换平台，干净复位至 _Stage.courseList 且清除导航条返回键与课件数据', (tester) async {
      // 1. 初始化平台为雨课堂并写入课程与课件缓存（courseId 为空以走纯离线路径，避免发起远程网络请求）
      await PlatformManager().setPlatform(PlatformType.rainClassroom);
      await PptCache.save(
        'lesson-101',
        'ppt-201',
        _pptData('计算机网络第1讲', []),
        courseId: '',
        courseName: '计算机网络',
      );

      // 2. 渲染课件页
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

      // 3. 验证第一层正常展示
      expect(find.text('计算机网络'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);

      // 4. 点击进入第二层 _Stage.pptList
      await tester.tap(find.text('计算机网络'));
      await pumpUntilSettled(tester);

      // 5. 验证进入了第二层 _Stage.pptList
      expect(find.text('计算机网络第1讲'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);

      // 6. 在第二层活跃状态下，平台发生切换至学习通
      await PlatformManager().setPlatform(PlatformType.chaoxing);
      await pumpUntilSettled(tester);

      // 7. 严格断言：
      // - 必须干净返回 _Stage.courseList，顶栏返回键被移除
      expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
      // - 第二层的 PPT 标题不再存在
      expect(find.text('计算机网络第1讲'), findsNothing);
      // - 页面主体处于 courseList 层级
      expect(find.byType(CoursewarePage), findsOneWidget);
    });

    testWidgets('在 _Stage.viewer 离线浏览深度层级切换平台，即时卸载 Viewer 且无悬挂指针与渲染异常', (tester) async {
      // 1. 初始化平台为雨课堂并写入带幻灯片的课件（空图片 URL 走纯占位离线模式，不触发 Dio 网络拉取）
      await PlatformManager().setPlatform(PlatformType.rainClassroom);
      await PptCache.save(
        'lesson-102',
        'ppt-202',
        _pptData('操作系统导论', ['', '']),
        courseId: '',
        courseName: '操作系统',
      );

      // 2. 渲染课件页
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

      // 3. 点击课程进入 _Stage.pptList
      await tester.tap(find.text('操作系统'));
      await pumpUntilSettled(tester);
      expect(find.text('操作系统导论'), findsOneWidget);

      // 4. 点击课件进入 _Stage.viewer
      await tester.tap(find.text('操作系统导论'));
      await pumpUntilSettled(tester);

      // 5. 验证已处于 _Stage.viewer
      expect(find.byType(CoursewareViewer), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);

      // 6. 在 Viewer 深度浏览状态下，突然发生平台切换
      await PlatformManager().setPlatform(PlatformType.chaoxing);
      await pumpUntilSettled(tester);

      // 7. 严格断言：
      // - CoursewareViewer 必须被完全销毁卸载
      expect(find.byType(CoursewareViewer), findsNothing);
      // - 返回按钮必须消失
      expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
      // - 课件页未崩溃，成功复位为 courseList
      expect(find.byType(CoursewarePage), findsOneWidget);
    });

    testWidgets('在 _Stage.pptList 打开删除弹窗状态下切换平台，弹窗自动关闭且无空引用异常', (tester) async {
      // 1. 初始化平台并写入课件
      await PlatformManager().setPlatform(PlatformType.rainClassroom);
      await PptCache.save(
        'lesson-103',
        'ppt-203',
        _pptData('编译原理第3讲', []),
        courseId: '',
        courseName: '编译原理',
      );

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

      // 进入第二层
      await tester.tap(find.text('编译原理'));
      await pumpUntilSettled(tester);
      expect(find.text('编译原理第3讲'), findsOneWidget);

      // 点击删除图标打开删除确认抽屉
      await tester.tap(find.byIcon(Icons.delete_outline));
      await pumpUntilSettled(tester);

      // 验证删除抽屉已弹出
      expect(find.text('确定删除「编译原理第3讲」吗？'), findsOneWidget);

      // 此时切换平台
      await PlatformManager().setPlatform(PlatformType.chaoxing);
      await pumpUntilSettled(tester);

      // 验证抽屉关闭，未发生空指针异常，页面复位
      expect(find.text('确定删除「编译原理第3讲」吗？'), findsNothing);
      expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
      expect(find.byType(CoursewarePage), findsOneWidget);
    });

    testWidgets('在深度层级并发连续切换平台，防竞态正常生效且最终状态一致', (tester) async {
      await PlatformManager().setPlatform(PlatformType.rainClassroom);
      await PptCache.save(
        'lesson-104',
        'ppt-204',
        _pptData('数据库系统概论', ['']),
        courseId: '',
        courseName: '数据库系统',
      );

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

      // 进入 _Stage.pptList
      await tester.tap(find.text('数据库系统'));
      await pumpUntilSettled(tester);

      // 进入 _Stage.viewer
      await tester.tap(find.text('数据库系统概论'));
      await pumpUntilSettled(tester);
      expect(find.byType(CoursewareViewer), findsOneWidget);

      // 连续快速触发多次切换
      final f1 = PlatformManager().setPlatform(PlatformType.chaoxing);
      final f2 = PlatformManager().setPlatform(PlatformType.rainClassroom);
      final f3 = PlatformManager().setPlatform(PlatformType.chaoxing);

      await Future.wait([f1, f2, f3]);
      await pumpUntilSettled(tester);

      // 最终必须处于 chaoxing 平台、_Stage.courseList、Viewer 完全销毁
      expect(PlatformManager().currentPlatform, equals(PlatformType.chaoxing));
      expect(find.byType(CoursewareViewer), findsNothing);
      expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
      expect(find.byType(CoursewarePage), findsOneWidget);
    });

    testWidgets('手动 _goBack 路径对比基准：viewer -> pptList -> courseList 正常工作', (tester) async {
      await PlatformManager().setPlatform(PlatformType.rainClassroom);
      await PptCache.save(
        'lesson-105',
        'ppt-205',
        _pptData('软件工程第5讲', ['']),
        courseId: '',
        courseName: '软件工程',
      );

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

      // 进入第二层
      await tester.tap(find.text('软件工程'));
      await pumpUntilSettled(tester);

      // 进入第三层
      await tester.tap(find.text('软件工程第5讲'));
      await pumpUntilSettled(tester);
      expect(find.byType(CoursewareViewer), findsOneWidget);

      // 点击返回，退回第二层
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
      await pumpUntilSettled(tester);
      expect(find.byType(CoursewareViewer), findsNothing);
      expect(find.text('软件工程第5讲'), findsOneWidget);

      // 再次点击返回，退回第一层
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
      await pumpUntilSettled(tester);
      expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
      expect(find.text('软件工程'), findsOneWidget);
    });
  });
}
