/// 题目答案缓存（AnswerCache / CachedAnswer）单测
///
/// 包含两半：
/// - 纯逻辑：序列化往返、新鲜度判定、可用性判定
/// - 落盘：真的写文件、再读回来（跑在临时目录里）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/cache/answer_cache.dart';
import 'package:course_helper/cache/course_cache.dart';
import 'package:course_helper/models/answer_result.dart';

import 'support/cache_test_env.dart';

AnswerSearchResult _result({
  String answer = 'A',
  String source = 'AI 检索',
  double confidence = 0.9,
  String? explanation = '因为苹果是水果',
  AnswerSourceType type = AnswerSourceType.aiProvider,
  List<String> keys = const ['A'],
}) {
  return AnswerSearchResult(
    answer: answer,
    source: source,
    confidence: confidence,
    explanation: explanation,
    sourceType: type,
    answerKeys: keys,
  );
}

CachedAnswer _ok(String hash) => CachedAnswer(
      hash: hash,
      problemId: 'p1',
      questionType: 'single',
      questionPreview: '下面哪个是水果？',
      status: CachedAnswerStatus.ok,
      results: [_result()],
      updatedAt: DateTime.now(),
    );

void main() {
  group('CachedAnswer 判定', () {
    test('ok 且有条目 → usable', () {
      final answer = _ok('h1');
      expect(answer.usable, isTrue);
      expect(answer.best!.answer, 'A');
      expect(answer.shouldSkipRefetch(), isTrue);
    });

    test('ok 但没有条目 → 不算 usable', () {
      final answer = CachedAnswer(
        hash: 'h1',
        status: CachedAnswerStatus.ok,
        updatedAt: DateTime.now(),
      );
      expect(answer.usable, isFalse);
      expect(answer.best, isNull);
    });

    test('empty/failed 在重试间隔内算新鲜（避免每翻一页重打一次）', () {
      final answer = CachedAnswer(
        hash: 'h1',
        status: CachedAnswerStatus.failed,
        error: '超时',
        updatedAt: DateTime.now(),
      );
      expect(answer.shouldSkipRefetch(), isTrue);
      expect(answer.usable, isFalse);
    });

    test('empty/failed 超过重试间隔 → 不再新鲜，会触发重试', () {
      final answer = CachedAnswer(
        hash: 'h1',
        status: CachedAnswerStatus.empty,
        updatedAt: DateTime.now().subtract(
          AnswerCache.retryAfter + const Duration(minutes: 1),
        ),
      );
      expect(answer.shouldSkipRefetch(), isFalse);
    });

    test('ok 永远新鲜（跟着课程目录一起被 7 天策略清掉）', () {
      final answer = CachedAnswer(
        hash: 'h1',
        status: CachedAnswerStatus.ok,
        results: [_result()],
        updatedAt: DateTime.now().subtract(const Duration(days: 30)),
      );
      expect(answer.shouldSkipRefetch(), isTrue);
    });
  });

  group('CachedAnswer 序列化', () {
    test('往返后内容一致', () {
      final original = _ok('h1');
      final restored = CachedAnswer.fromJson(original.toJson())!;

      expect(restored.hash, 'h1');
      expect(restored.problemId, 'p1');
      expect(restored.questionType, 'single');
      expect(restored.questionPreview, '下面哪个是水果？');
      expect(restored.status, CachedAnswerStatus.ok);
      expect(restored.results.length, 1);
      expect(restored.results.first.answer, 'A');
      expect(restored.results.first.confidence, 0.9);
      expect(restored.results.first.explanation, '因为苹果是水果');
      expect(restored.results.first.sourceType, AnswerSourceType.aiProvider);
      expect(restored.results.first.answerKeys, ['A']);
    });

    test('builtin 来源类型也能往返', () {
      final original = CachedAnswer(
        hash: 'h2',
        status: CachedAnswerStatus.ok,
        results: [_result(type: AnswerSourceType.builtin, keys: const [])],
        updatedAt: DateTime.now(),
      );
      final restored = CachedAnswer.fromJson(original.toJson())!;
      expect(restored.results.first.sourceType, AnswerSourceType.builtin);
    });

    test('未知 status / sourceType 有兜底，不抛异常', () {
      final restored = CachedAnswer.fromJson({
        'hash': 'h3',
        'status': 'something-new',
        'results': [
          {'answer': 'B', 'sourceType': 'future-type', 'confidence': 0.5},
        ],
        'updatedAt': 1,
      })!;

      expect(restored.status, CachedAnswerStatus.empty);
      expect(restored.results.first.sourceType, AnswerSourceType.aiProvider);
    });

    test('缺 hash → 返回 null（这条缓存没法用）', () {
      expect(CachedAnswer.fromJson({'status': 'ok'}), isNull);
    });

    test('results 字段类型不对 → 当成空列表，不炸', () {
      final restored = CachedAnswer.fromJson({
        'hash': 'h4',
        'status': 'ok',
        'results': 'not-a-list',
        'updatedAt': 1,
      })!;
      expect(restored.results, isEmpty);
    });
  });

  group('CourseCache.safeName', () {
    test('正常 lessonId 原样保留', () {
      expect(CourseCache.safeName('12345'), '12345');
      expect(CourseCache.safeName('abc-def_1'), 'abc-def_1');
    });

    test('路径穿越字符被换成下划线', () {
      // '../../etc' → 前 6 个字符全被替换，只剩 etc
      expect(CourseCache.safeName('../../etc'), '______etc');
      // '.' / '..' 这类名字本身也会被替换成下划线，落盘后不再有特殊含义
      expect(CourseCache.safeName('..'), '__');
      expect(CourseCache.safeName('.'), '_');
      expect(CourseCache.safeName('a/b\\c'), 'a_b_c');
    });

    test('空串 / 纯空白 → unknown', () {
      expect(CourseCache.safeName(''), 'unknown');
      expect(CourseCache.safeName('   '), 'unknown');
    });

    test('超长名字被截断', () {
      final long = 'a' * 200;
      expect(CourseCache.safeName(long).length, 80);
    });
  });

  group('落盘读写', () {
    late CacheTestEnv env;

    setUp(() async {
      env = await CacheTestEnv.create();
    });

    tearDown(() async {
      await env.dispose();
    });

    test('写入 → 清内存 → 仍能从磁盘读回', () async {
      await AnswerCache.write('lesson-1', 'hash-a', _ok('hash-a'));
      AnswerCache.clearMemory();

      final loaded = await AnswerCache.read('lesson-1', 'hash-a');
      expect(loaded, isNotNull);
      expect(loaded!.usable, isTrue);
      expect(loaded.results.first.answer, 'A');
    });

    test('不同课程互相隔离', () async {
      await AnswerCache.write('lesson-1', 'hash-a', _ok('hash-a'));
      AnswerCache.clearMemory();

      expect(await AnswerCache.read('lesson-2', 'hash-a'), isNull);
      expect(await AnswerCache.read('lesson-1', 'hash-a'), isNotNull);
    });

    test('readMemory 在写入后立刻可命中', () async {
      await AnswerCache.write('lesson-1', 'hash-a', _ok('hash-a'));
      expect(AnswerCache.readMemory('lesson-1', 'hash-a'), isNotNull);
      expect(AnswerCache.readMemory('lesson-1', 'hash-other'), isNull);
    });

    test('remove 之后读不到', () async {
      await AnswerCache.write('lesson-1', 'hash-a', _ok('hash-a'));
      await AnswerCache.remove('lesson-1', 'hash-a');
      expect(await AnswerCache.read('lesson-1', 'hash-a'), isNull);
    });

    test('preload 把整节课的缓存读进内存', () async {
      await AnswerCache.write('lesson-1', 'hash-a', _ok('hash-a'));
      await AnswerCache.write('lesson-1', 'hash-b', _ok('hash-b'));
      await AnswerCache.write('lesson-1', 'hash-c', _ok('hash-c'));
      AnswerCache.clearMemory();

      final count = await AnswerCache.preload('lesson-1');
      expect(count, 3);
      expect(AnswerCache.readMemory('lesson-1', 'hash-b'), isNotNull);
    });

    test('preload 空目录返回 0，不抛异常', () async {
      expect(await AnswerCache.preload('never-used'), 0);
    });

    test('坏 JSON 被当成「没有缓存」，不抛异常', () async {
      final dir = await CourseCache.questionsDir('lesson-1');
      await File('${dir.path}/broken.json').writeAsString('{ not json');

      expect(await AnswerCache.read('lesson-1', 'broken'), isNull);
      // 其它缓存不受影响
      await AnswerCache.write('lesson-1', 'hash-a', _ok('hash-a'));
      expect(await AnswerCache.read('lesson-1', 'hash-a'), isNotNull);
    });
  });
}
