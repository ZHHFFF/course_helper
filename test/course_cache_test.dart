/// 课程缓存目录管理（CourseCache）单测
///
/// 重点锁住**保留策略**：这块出问题要么静默丢掉用户数据（清早了），
/// 要么缓存无限长大（清晚了），而且都不会报错，所以必须有用例盯着。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:course_helper/cache/course_cache.dart';

import 'support/cache_test_env.dart';

/// 课程结束标记的文件名（和 `CourseCache` 里保持一致）
const String _finishedMarker = '.finished';

Future<File> _marker(String lessonId) async {
  final dir = await CourseCache.lessonDir(lessonId);
  return File(p.join(dir.path, _finishedMarker));
}

/// 往某节课里塞一个文件，让它「有内容」
Future<File> _seed(String lessonId, {String name = 'a.json'}) async {
  final dir = await CourseCache.questionsDir(lessonId);
  final file = File(p.join(dir.path, name));
  await file.writeAsString(jsonEncode({'hello': 'world'}));
  return file;
}

void main() {
  late CacheTestEnv env;

  setUp(() async {
    env = await CacheTestEnv.create();
  });

  tearDown(() async {
    await env.dispose();
  });

  group('目录结构', () {
    test('按课程隔离，不同课不同目录', () async {
      final a = await CourseCache.questionsDir('lesson-a');
      final b = await CourseCache.questionsDir('lesson-b');

      expect(a.path, isNot(b.path));
      expect(await a.exists(), isTrue);
      expect(await b.exists(), isTrue);
    });

    test('ppt 与 questions 是同一节课下的两个子目录', () async {
      final lesson = await CourseCache.lessonDir('lesson-a');
      final ppt = await CourseCache.pptDir('lesson-a');
      final questions = await CourseCache.questionsDir('lesson-a');

      expect(p.dirname(ppt.path), lesson.path);
      expect(p.dirname(questions.path), lesson.path);
      expect(ppt.path, isNot(questions.path));
    });

    test('create: false 时不会凭空造目录', () async {
      final dir = await CourseCache.questionsDir('never-used', create: false);
      expect(await dir.exists(), isFalse);
    });

    test('lessonId 里的非法字符被白名单化', () async {
      final dir = await CourseCache.lessonDir('a/b:c');
      expect(p.basename(dir.path), 'a_b_c');
    });
  });

  group('JSON 读写', () {
    test('写进去能原样读回来', () async {
      final dir = await CourseCache.questionsDir('lesson-a');
      final file = File(p.join(dir.path, 'x.json'));

      await CourseCache.writeJson(file, {'a': 1, 'b': '中文'});
      final loaded = await CourseCache.readJson(file);

      expect(loaded, isNotNull);
      expect(loaded!['a'], 1);
      expect(loaded['b'], '中文');
    });

    test('文件不存在 → null，不抛异常', () async {
      final dir = await CourseCache.questionsDir('lesson-a');
      expect(
        await CourseCache.readJson(File(p.join(dir.path, 'nope.json'))),
        isNull,
      );
    });

    test('坏 JSON → null，不抛异常', () async {
      final dir = await CourseCache.questionsDir('lesson-a');
      final file = File(p.join(dir.path, 'broken.json'));
      await file.writeAsString('{ 这不是 json');

      expect(await CourseCache.readJson(file), isNull);
    });

    test('写入后不留下 .tmp 残留', () async {
      final dir = await CourseCache.questionsDir('lesson-a');
      final file = File(p.join(dir.path, 'x.json'));
      await CourseCache.writeJson(file, {'a': 1});

      final leftovers = await dir
          .list()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('覆盖写会替换掉旧内容', () async {
      final dir = await CourseCache.questionsDir('lesson-a');
      final file = File(p.join(dir.path, 'x.json'));

      await CourseCache.writeJson(file, {'v': 1});
      await CourseCache.writeJson(file, {'v': 2});

      final loaded = await CourseCache.readJson(file);
      expect(loaded!['v'], 2);
    });
  });

  group('课程结束标记', () {
    test('没打过标记时读回 null', () async {
      expect(await CourseCache.finishedAt('lesson-a'), isNull);
    });

    test('markFinished 之后能读回时间', () async {
      await CourseCache.markFinished('lesson-a');
      final at = await CourseCache.finishedAt('lesson-a');

      expect(at, isNotNull);
      expect(
        DateTime.now().difference(at!).inMinutes,
        lessThan(1),
      );
    });

    test('标记文件损坏时读回 null，不抛异常', () async {
      await CourseCache.markFinished('lesson-a');
      await (await _marker('lesson-a')).writeAsString('不是数字');

      expect(await CourseCache.finishedAt('lesson-a'), isNull);
    });
  });

  group('清理策略', () {
    test('刚用过的课程不会被清掉', () async {
      await _seed('fresh');

      final report = await CourseCache.cleanup();

      expect(report.isEmpty, isTrue);
      expect(
        await (await CourseCache.questionsDir('fresh', create: false)).exists(),
        isTrue,
      );
    });

    test('课程结束超过 24 小时 → 整门课被清掉', () async {
      await _seed('long-done');
      await (await _marker('long-done')).writeAsString(
        '${DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch}',
      );

      final report = await CourseCache.cleanup();

      expect(report.removedLessons, contains('long-done'));
      expect(report.removedBytes, greaterThan(0));
      expect(
        await (await CourseCache.lessonDir('long-done', create: false)).exists(),
        isFalse,
      );
    });

    test('课程结束不到 24 小时 → 保留（下课后还能回去翻）', () async {
      await _seed('just-done');
      await (await _marker('just-done')).writeAsString(
        '${DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch}',
      );

      final report = await CourseCache.cleanup();

      expect(report.removedLessons, isNot(contains('just-done')));
      expect(
        await (await CourseCache.questionsDir('just-done', create: false))
            .exists(),
        isTrue,
      );
    });

    test('超过 7 天没有任何写入 → 被清掉', () async {
      final file = await _seed('stale');
      await file.setLastModified(
        DateTime.now().subtract(const Duration(days: 8)),
      );

      final report = await CourseCache.cleanup();

      expect(report.removedLessons, contains('stale'));
    });

    test('刚过 7 天边界之内的保留', () async {
      final file = await _seed('almost-stale');
      await file.setLastModified(
        DateTime.now().subtract(const Duration(days: 6)),
      );

      final report = await CourseCache.cleanup();

      expect(report.removedLessons, isNot(contains('almost-stale')));
    });

    test('结束标记时间优先于写入时间（不能靠最近写过就躲过清理）', () async {
      final file = await _seed('done-but-recent-write');
      // 文件是刚写的，但课程已经结束 30 小时了
      await (await _marker('done-but-recent-write')).writeAsString(
        '${DateTime.now().subtract(const Duration(hours: 30)).millisecondsSinceEpoch}',
      );
      await file.setLastModified(DateTime.now());

      final report = await CourseCache.cleanup();

      expect(report.removedLessons, contains('done-but-recent-write'));
    });

    test('一次清理能处理多门课，且不误伤该留的', () async {
      await _seed('keep-me');
      await _seed('drop-1');
      await _seed('drop-2');

      // drop-1：课程结束超过 24 小时
      await (await _marker('drop-1')).writeAsString(
        '${DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch}',
      );

      // drop-2：所有文件都 10 天没动过
      final old = DateTime.now().subtract(const Duration(days: 10));
      final dir = await CourseCache.questionsDir('drop-2');
      await for (final entity in dir.list()) {
        if (entity is File) await entity.setLastModified(old);
      }

      final report = await CourseCache.cleanup();

      expect(report.removedLessons, containsAll(['drop-1', 'drop-2']));
      expect(report.removedLessons, isNot(contains('keep-me')));
    });

    test('没有任何课程目录时清理是空操作', () async {
      final report = await CourseCache.cleanup();
      expect(report.isEmpty, isTrue);
    });
  });

  group('统计与清空', () {
    test('stats 统计课程数与字节数', () async {
      await _seed('one');
      await _seed('two');

      final stats = await CourseCache.stats();

      expect(stats.lessons, 2);
      expect(stats.bytes, greaterThan(0));
    });

    test('空缓存 stats 返回 0', () async {
      final stats = await CourseCache.stats();
      expect(stats.lessons, 0);
      expect(stats.bytes, 0);
    });

    test('clearLesson 只清指定那一门', () async {
      await _seed('one');
      await _seed('two');

      final freed = await CourseCache.clearLesson('one');

      expect(freed, greaterThan(0));
      expect(
        await (await CourseCache.lessonDir('one', create: false)).exists(),
        isFalse,
      );
      expect(
        await (await CourseCache.lessonDir('two', create: false)).exists(),
        isTrue,
      );
    });

    test('clearAll 清掉所有课程', () async {
      await _seed('one');
      await _seed('two');

      await CourseCache.clearAll();

      final stats = await CourseCache.stats();
      expect(stats.lessons, 0);
      expect(stats.bytes, 0);
    });

    test('clearLesson 对不存在的课程返回 0', () async {
      expect(await CourseCache.clearLesson('never-used'), 0);
    });
  });
}
