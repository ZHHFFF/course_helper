import 'package:course_helper/api/api_service.dart';
import 'package:course_helper/cache/course_cache.dart';
import 'package:course_helper/platform.dart';
import 'package:course_helper/session/account.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cache_test_env.dart';

/// 课堂/课程异步回归的隔离环境；初始化和清理顺序与原用例一致。
class ClassroomTestEnv {
  ClassroomTestEnv._(this._cache);

  final CacheTestEnv _cache;

  static Future<ClassroomTestEnv> create() async {
    final cache = await CacheTestEnv.create();
    PlatformManager.debugReset();
    await AccountManager.initialize();
    await ApiService.initialize();
    await PlatformManager().initialize();
    await CourseCache.root();
    return ClassroomTestEnv._(cache);
  }

  Future<void> dispose() async {
    AccountManager.setCurrentSessionTemp(null);
    PlatformManager.debugReset();
    await _cache.dispose();
  }
}

Widget classroomTestApp(Widget child) => MaterialApp(
  home: MiuixTheme(data: MiuixThemeData.light(), child: child),
);

/// 保持原来的 8 轮 pump/runAsync；不能用 settle 吞掉受控请求竞态。
Future<void> flushClassroomTasks(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
}

Map<String, dynamic> emptyPresentationResponse(int pages) => {
  'code': 0,
  'data': {
    'slides': [
      for (var i = 0; i < pages; i++) {'index': i + 1},
    ],
  },
};
