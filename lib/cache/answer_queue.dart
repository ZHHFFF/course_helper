/// AI 检索队列
///
/// 进课堂后会把整份 PPT 里的题一次性丢进来，但**不能一次性打出去**：
/// - 并发太高会被服务端限速，还挤占正在播放的 PPT 的带宽
/// - 同一道题可能被多个页面引用，重复请求纯属浪费
///
/// 所以这里做两件事：
/// 1. **并发闸门**：[maxConcurrent] 个（默认 2）同时在飞，其余排队
/// 2. **in-flight 去重**：同一个题目指纹在飞的时候，后来的调用直接等同一个 Future
///
/// 队列本身不认识 UI，检索完通过 [results] 广播出去，谁关心谁订阅。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/answer_search.dart';
import '../models/answer_result.dart';
import '../utils/app_logger.dart';
import 'answer_cache.dart';

/// 一个待检索的任务
@immutable
class AnswerJob {
  /// 哪节课（决定缓存写到哪个目录）
  final String lessonId;

  /// 题目指纹（缓存键，也是 in-flight 去重的键）
  final String hash;

  final StandardizedQuestion question;

  /// 忽略缓存、强制重新检索
  final bool forceRefresh;

  const AnswerJob({
    required this.lessonId,
    required this.hash,
    required this.question,
    this.forceRefresh = false,
  });
}

/// 一个任务的结果
@immutable
class AnswerJobResult {
  final String hash;
  final CachedAnswer answer;

  /// true 表示直接命中缓存、没发请求
  final bool fromCache;

  const AnswerJobResult({
    required this.hash,
    required this.answer,
    required this.fromCache,
  });

  bool get usable => answer.usable;

  AnswerSearchResult? get best => answer.best;

  String? get error => answer.error;

  CachedAnswerStatus get status => answer.status;
}

class AnswerQueue {
  AnswerQueue._();

  static const String _tag = 'AnswerQueue';

  /// 同时在飞的请求数
  static const int maxConcurrent = 2;

  /// 排队上限：真到这一步说明题目多到离谱，多出来的丢掉，
  /// 免得内存里堆几千个 completer
  static const int maxPending = 200;

  static final List<_QueuedJob> _pending = [];
  static final Map<String, Future<AnswerJobResult?>> _inFlight = {};
  static int _running = 0;

  /// 排队中的任务数（UI 显示「还有 x 题在检索」）
  static final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);

  /// 正在请求的任务数
  static final ValueNotifier<int> runningCount = ValueNotifier<int>(0);

  /// 已完成的任务数（本次进课堂累计）
  static final ValueNotifier<int> completedCount = ValueNotifier<int>(0);

  static final StreamController<AnswerJobResult> _results =
      StreamController<AnswerJobResult>.broadcast();

  /// 每检索完一题就推一条
  static Stream<AnswerJobResult> get results => _results.stream;

  /// 测试用：替换掉真正的检索实现（真实实现在单测里跑不了）
  @visibleForTesting
  static Future<List<AnswerSearchResult>> Function(
          StandardizedQuestion question)?
      debugSearchOverride;

  /// 测试用：绕过「没配 AI 就整体跳过」的闸门
  @visibleForTesting
  static bool debugForceEnabled = false;

  /// 测试用：把队列状态清干净，避免用例之间互相污染
  @visibleForTesting
  static void debugReset() {
    for (final item in _pending) {
      if (!item.completer.isCompleted) item.completer.complete(null);
    }
    _pending.clear();
    _inFlight.clear();
    _running = 0;
    completedCount.value = 0;
    pendingCount.value = 0;
    runningCount.value = 0;
    debugSearchOverride = null;
    debugForceEnabled = false;
  }

  /// 提交一个任务
  ///
  /// 返回 null 的情况：没配置 AI、指纹为空、排队已满、或者退课堂时被取消。
  /// 调用方拿到 null 就当「这题没有建议答案」处理即可。
  ///
  /// **契约：只要拿到非 null 的结果，[results] 流上一定会收到对应的一条。**
  /// 不管这结果是「缓存命中」还是「真去请求」——
  /// 广播统一放在 [submit] 的出口（[_broadcast]），不再散落在各条分支里。
  ///
  /// （之前广播只在 `_process()` 里，导致缓存命中的题不广播，
  ///   订阅者收不到通知、自动预选不触发。这是接口契约的漏洞，
  ///   不是调用方该去绕的问题。）
  static Future<AnswerJobResult?> submit(AnswerJob job) async {
    await AnswerSearchApi.initialize();

    // 没配 AI 就不排队了，省得给整份 PPT 刷一堆空缓存
    if (!debugForceEnabled && !AnswerSearchApi.isAIConfigured) return null;
    if (job.hash.trim().isEmpty) return null;

    // 路径 1：缓存命中 —— 不请求，但**同样要广播**
    if (!job.forceRefresh) {
      final hit = await AnswerCache.read(job.lessonId, job.hash);
      if (hit != null && hit.isFresh()) {
        final result = AnswerJobResult(
          hash: job.hash,
          answer: hit,
          fromCache: true,
        );
        _broadcast(result);
        return result;
      }
    }

    // 路径 2：同一道题正在飞 → 搭车。
    // 不广播：发起者拿到结果时会广播一次，搭车的再广播就重复了。
    final existing = _inFlight[job.hash];
    if (existing != null) return existing;

    // 路径 3：真正去请求 —— 由**发起者**负责广播
    final future = _process(job);
    _inFlight[job.hash] = future;
    try {
      final result = await future;
      if (result != null) _broadcast(result);
      return result;
    } finally {
      _inFlight.remove(job.hash);
    }
  }

  /// 唯一的广播出口
  ///
  /// 集中在一处，保证「不管走哪条路径，订阅者收到的次数都一样」。
  static void _broadcast(AnswerJobResult result) {
    completedCount.value = completedCount.value + 1;
    if (!_results.isClosed) _results.add(result);
  }

  /// 丢进队列，等闸门放行
  static Future<AnswerJobResult?> _process(AnswerJob job) async {
    final raw = await _schedule(job);
    // 被取消
    if (raw == null) return null;

    final status = raw.results.isNotEmpty
        ? CachedAnswerStatus.ok
        : (raw.failed ? CachedAnswerStatus.failed : CachedAnswerStatus.empty);

    final value = CachedAnswer(
      hash: job.hash,
      problemId: job.question.problemId,
      questionType: job.question.questionType,
      questionPreview: _preview(job.question),
      status: status,
      results: raw.results,
      error: raw.error,
      updatedAt: DateTime.now(),
    );

    await AnswerCache.write(job.lessonId, job.hash, value);

    // 只产出结果，**不广播** —— 广播统一由 submit() 负责，
    // 否则「缓存命中」和「真去请求」两条路径的行为会不一致。
    return AnswerJobResult(hash: job.hash, answer: value, fromCache: false);
  }

  static Future<_RawAnswer?> _schedule(AnswerJob job) {
    if (_pending.length >= maxPending) {
      AppLogger.w(_tag, '排队已满，丢弃题目 ${job.hash}');
      return Future<_RawAnswer?>.value(null);
    }

    final completer = Completer<_RawAnswer?>();
    _pending.add(_QueuedJob(job: job, completer: completer));
    _updateCounts();
    _pump();
    return completer.future;
  }

  /// 把队列里能跑的都放出去
  static void _pump() {
    while (_running < maxConcurrent && _pending.isNotEmpty) {
      final item = _pending.removeAt(0);
      _running++;
      _updateCounts();
      // 不 await：闸门靠 _running 计数控制，不靠串行等待
      unawaited(_execute(item));
    }
  }

  static Future<void> _execute(_QueuedJob item) async {
    try {
      final override = debugSearchOverride;
      final results = override != null
          ? await override(item.job.question)
          : await AnswerSearchApi.search(item.job.question);
      final error = override != null ? null : AnswerSearchApi.lastAIError;
      if (!item.completer.isCompleted) {
        item.completer.complete(_RawAnswer(
          results: results,
          error: error,
          // 结果为空 + 有错误信息 = 请求真的失败了，而不是「模型说不知道」
          failed: results.isEmpty && error != null,
        ));
      }
    } catch (e) {
      if (!item.completer.isCompleted) {
        item.completer.complete(
          _RawAnswer(results: const [], error: '$e', failed: true),
        );
      }
    } finally {
      _running--;
      _updateCounts();
      _pump();
    }
  }

  /// 退课堂时把还没开跑的任务全部作废
  ///
  /// 已经在飞的那几个不打断 —— 请求已经发出去了，让它跑完顺手把结果缓存下来，
  /// 下次进同一节课还能用上。
  static void cancelPending() {
    if (_pending.isEmpty) return;
    final count = _pending.length;
    for (final item in _pending) {
      if (!item.completer.isCompleted) item.completer.complete(null);
    }
    _pending.clear();
    _updateCounts();
    AppLogger.i(_tag, '取消 $count 个排队中的检索任务');
  }

  /// 换课程时重置计数器（内存缓存由 AnswerCache 负责清）
  static void resetCounters() {
    completedCount.value = 0;
    _updateCounts();
  }

  static void _updateCounts() {
    pendingCount.value = _pending.length;
    runningCount.value = _running;
  }

  static String _preview(StandardizedQuestion question) {
    final text = question.effectiveText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= 120) return text;
    return '${text.substring(0, 120)}…';
  }
}

class _QueuedJob {
  final AnswerJob job;
  final Completer<_RawAnswer?> completer;

  _QueuedJob({required this.job, required this.completer});
}

/// 队列内部用的原始结果（还没写缓存）
@immutable
class _RawAnswer {
  final List<AnswerSearchResult> results;
  final String? error;
  final bool failed;

  const _RawAnswer({
    required this.results,
    this.error,
    this.failed = false,
  });
}
