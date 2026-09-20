/// 单测用的临时环境
///
/// 缓存层要落盘，落盘位置来自 `path_provider`（在单测里没有平台实现），
/// 所以这里做两件事：
/// 1. 把 `path_provider` 的 MethodChannel 指到一个临时目录
/// 2. 把 `SharedPreferences` 换成内存版（`AnswerSearchApi` 读配置要用）
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:course_helper/cache/answer_cache.dart';
import 'package:course_helper/cache/answer_queue.dart';
import 'package:course_helper/cache/course_cache.dart';
import 'package:course_helper/cache/ppt_cache.dart';
import 'package:course_helper/utils/storage.dart';

class CacheTestEnv {
  /// 本次用例独占的临时目录
  final Directory root;

  CacheTestEnv._(this.root);

  static const MethodChannel _channel =
      MethodChannel('plugins.flutter.io/path_provider');

  /// 准备环境，返回临时目录
  static Future<CacheTestEnv> create() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final dir = await Directory.systemTemp.createTemp('course_helper_test_');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getApplicationSupportDirectory':
        case 'getTemporaryDirectory':
        case 'getLibraryDirectory':
        case 'getStorageDirectory':
          return dir.path;
        default:
          return null;
      }
    });

    SharedPreferences.setMockInitialValues({});
    await StorageManager.initialize();

    // 静态状态跨用例残留，逐个清掉
    CourseCache.debugResetRoot();
    PptCache.clearMemory();
    AnswerCache.clearMemory();
    AnswerQueue.debugReset();

    return CacheTestEnv._(dir);
  }

  /// 收尾：还原 channel、删临时目录
  Future<void> dispose() async {
    AnswerQueue.debugReset();
    AnswerCache.clearMemory();
    PptCache.clearMemory();
    CourseCache.debugResetRoot();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);

    try {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    } catch (_) {
      // 临时目录删不掉不影响用例结论
    }
  }
}
