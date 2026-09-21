/// AI 检索队列（AnswerQueue）单测
///
/// 队列是「进课堂后一次丢进去几十道题」的唯一入口，所以必须锁住：
/// - 并发闸门真的卡在 2
/// - 同一道题在飞的时候不会重复请求
/// - 命中缓存时一次请求都不发
/// - 退课堂时排队中的任务能被作废
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/cache/answer_cache.dart';
import 'package:course_helper/cache/answer_queue.dart';
import 'package:course_helper/models/answer_result.dart';

import 'support/cache_test_env.dart';

StandardizedQuestion _question(String text) => StandardizedQuestion(
      questionText: text,
      questionType: 'single',
      options: [
        StandardizedOption(key: 'A', value: '苹果'),
        StandardizedOption(key: 'B', value: '桌子'),
      ],
      problemId: 'p-$text',
    );

AnswerSearchResult _answer(String value) => AnswerSearchResult(
      answer: value,
      source: 'AI 检索',
      confidence: 0.9,
      sourceType: AnswerSourceType.aiProvider,
      answerKeys: [value],
    );

AnswerJob _job(String hash, {String? text}) => AnswerJob(
      lessonId: 'lesson-1',
      hash: hash,
      question: _question(text ?? hash),
    );

void main() {
  late CacheTestEnv env;

  setUp(() async {
    env = await CacheTestEnv.create();
  });

  tearDown(() async {
    await env.dispose();
  });

  group('闸门', () {
    test('没配置 AI 时直接返回 null，不排队', () async {
      final result = await AnswerQueue.submit(_job('h1'));
      expect(result, isNull);
      expect(AnswerQueue.pendingCount.value, 0);
    });

    test('指纹为空时返回 null', () async {
      AnswerQueue.debugForceEnabled = true;
      expect(await AnswerQueue.submit(_job('   ')), isNull);
    });
  });

  group('并发与去重', () {
    test('同时最多只跑 2 个', () async {
      var active = 0;
      var peak = 0;

      AnswerQueue.debugForceEnabled = true;
      AnswerQueue.debugSearchOverride = (question) async {
        active++;
        peak = math.max(peak, active);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        active--;
        return [_answer('A')];
      };

      final futures = List.generate(
        6,
        (i) => AnswerQueue.submit(_job('hash-$i')),
      );
      final results = await Future.wait(futures);

      expect(peak, AnswerQueue.maxConcurrent);
      expect(results.every((r) => r != null), isTrue);
      expect(results.every((r) => r!.usable), isTrue);
      expect(AnswerQueue.pendingCount.value, 0);
      expect(AnswerQueue.runningCount.value, 0);
    });

    test('同一道题并发提交 → 只请求一次', () async {
      var calls = 0;
      AnswerQueue.debugForceEnabled = true;
      AnswerQueue.debugSearchOverride = (question) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return [_answer('A')];
      };

      final futures = List.generate(
        3,
        (_) => AnswerQueue.submit(_job('same-hash', text: '同一道题')),
      );
      final results = await Future.wait(futures);

      expect(calls, 1);
      expect(results.length, 3);
      expect(results.every((r) => r!.hash == 'same-hash'), isTrue);
    });

    test('命中缓存 → 不再请求，且标记 fromCache', () async {
      var calls = 0;
      AnswerQueue.debugForceEnabled = true;
      AnswerQueue.debugSearchOverride = (question) async {
        calls++;
        return [_answer('A')];
      };

      final first = await AnswerQueue.submit(_job('h-cache'));
      expect(first!.fromCache, isFalse);
      expect(calls, 1);

      final second = await AnswerQueue.submit(_job('h-cache'));
      expect(second!.fromCache, isTrue);
      expect(calls, 1);
    });

    test('命中缓存 → 也要广播（契约：拿到非 null 结果就一定广播一次）', () async {
      // 这是之前的真 bug：submit() 在缓存命中时直接 return，
      // 广播只写在 _process() 里 —— 于是缓存命中的题订阅者收不到通知，
      // 界面上的自动预选就不触发（表现是「预填没实现」）。
      // 现在广播统一在 submit() 的出口，两条路径行为一致。
      var calls = 0;
      AnswerQueue.debugForceEnabled = true;
      AnswerQueue.debugSearchOverride = (question) async {
        calls++;
        return [_answer('A')];
      };

      // 第一次：真去请求，结果顺手写进缓存
      await AnswerQueue.submit(_job('h-hit-broadcast'));
      expect(calls, 1);

      // 第二次：命中缓存 —— 不发请求，但**必须广播**
      final broadcast = <AnswerJobResult>[];
      final sub = AnswerQueue.results.listen(broadcast.add);
      final second = await AnswerQueue.submit(_job('h-hit-broadcast'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(second!.fromCache, isTrue);
      expect(calls, 1, reason: '命中缓存不该再发请求');
      expect(broadcast.length, 1, reason: '命中缓存也必须广播一次');
      expect(broadcast.first.hash, 'h-hit-broadcast');
      expect(broadcast.first.fromCache, isTrue);
    });

    test('forceRefresh 会绕过缓存重新请求', () async {
      var calls = 0;
      AnswerQueue.debugForceEnabled = true;
      AnswerQueue.debugSearchOverride = (question) async {
        calls++;
        return [_answer('A')];
      };

      await AnswerQueue.submit(_job('h-force'));
      await AnswerQueue.submit(
        AnswerJob(
          lessonId: 'lesson-1',
          hash: 'h-force',
          question: _question('h-force'),
          forceRefresh: true,
        ),
      );

      expect(calls, 2);
    });
  });

  group('结果与失败', () {
    test('检索成功 → 结果写进缓存并广播出来', () async {
      AnswerQueue.debugForceEnabled = true;
      AnswerQueue.debugSearchOverride =
          (question) async => [_answer('A')];

      final broadcast = <AnswerJobResult>[];
      final sub = AnswerQueue.results.listen(broadcast.add);

      final result = await AnswerQueue.submit(_job('h-ok'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(result!.status, CachedAnswerStatus.ok);
      expect(result.best!.answer, 'A');
      expect(broadcast.length, 1);
      expect(broadcast.first.hash, 'h-ok');

      // 真的落到了缓存里
      AnswerCache.clearMemory();
      expect(await AnswerCache.read('lesson-1', 'h-ok'), isNotNull);
    });

    test('检索抛异常 → 缓存为 failed，并把原因带上', () async {
      AnswerQueue.debugForceEnabled = true;
      AnswerQueue.debugSearchOverride =
          (question) async => throw StateError('boom');

      final result = await AnswerQueue.submit(_job('h-fail'));

      expect(result!.status, CachedAnswerStatus.failed);
      expect(result.answer.error, contains('boom'));
      expect(result.usable, isFalse);
      // failed 在重试间隔内仍然「新鲜」，避免翻页刷屏重试
      expect(result.answer.isFresh(), isTrue);
    });

    test('检索成功但没结果 → 缓存为 empty（不是 failed）', () async {
      AnswerQueue.debugForceEnabled = true;
      AnswerQueue.debugSearchOverride = (question) async => [];

      final result = await AnswerQueue.submit(_job('h-empty'));

      expect(result!.status, CachedAnswerStatus.empty);
      expect(result.error, isNull);
    });
  });

  group('退课堂', () {
    test('cancelPending 作废排队中的任务，已在飞的不受影响', () async {
      final gate = Completer<void>();
      AnswerQueue.debugForceEnabled = true;
      AnswerQueue.debugSearchOverride = (question) async {
        await gate.future;
        return [_answer('A')];
      };

      final futures = List.generate(
        6,
        (i) => AnswerQueue.submit(_job('h-cancel-$i')),
      );

      // 等 2 个进闸门、其余 4 个排上队
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(AnswerQueue.runningCount.value, AnswerQueue.maxConcurrent);
      expect(AnswerQueue.pendingCount.value, 4);

      AnswerQueue.cancelPending();
      expect(AnswerQueue.pendingCount.value, 0);

      gate.complete();
      final results = await Future.wait(futures);

      expect(results.where((r) => r == null).length, 4);
      expect(results.where((r) => r != null).length, 2);
    });

    test('空队列调用 cancelPending 不炸', () {
      AnswerQueue.cancelPending();
      expect(AnswerQueue.pendingCount.value, 0);
    });
  });
}
