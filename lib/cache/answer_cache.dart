/// 题目 → 建议答案 的缓存
///
/// 键是 [QuestionHash.of] 算出来的内容指纹，所以「同一道题」不管出现在哪一页、
/// 题干里的空白/全角半角有没有差别，都会落到同一条缓存上。
/// 值里存的是 AI 给出的答案（**只是建议，永远不会自动提交**）。
///
/// 落盘位置：`lessons/<lessonId>/questions/<hash>.json`
///
/// 有效期策略：
/// - `ok`（拿到答案）→ 长期有效，跟着课程目录一起被 7 天策略清掉
/// - `empty` / `failed` → 只保留 [retryAfter] 分钟。
///   不留长是怕「当时网络不好」的结果被永久钉住；
///   但也不能完全不记，否则每翻一次页就重打一次 AI。
library;

import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/answer_result.dart';
import '../utils/app_logger.dart';
import 'course_cache.dart';

/// 一条缓存的状态
enum CachedAnswerStatus {
  /// 拿到了答案
  ok,

  /// 请求成功但模型没给出可用答案（比如题型是投票、或者题干太短）
  empty,

  /// 请求本身失败（超时、鉴权、模型报错）
  failed,
}

/// 一条题目答案缓存
@immutable
class CachedAnswer {
  /// 题目指纹
  final String hash;

  /// 服务器给的题目 ID（可能为空）
  final String problemId;

  /// 题型（single / multiple / ...）
  final String questionType;

  /// 题干摘要，只用于人工排查时肉眼认题，不参与逻辑
  final String questionPreview;

  final CachedAnswerStatus status;

  /// 建议答案列表（按置信度降序）
  final List<AnswerSearchResult> results;

  /// 失败原因（[status] 为 failed 时有值）
  final String? error;

  final DateTime updatedAt;

  const CachedAnswer({
    required this.hash,
    this.problemId = '',
    this.questionType = '',
    this.questionPreview = '',
    required this.status,
    this.results = const [],
    this.error,
    required this.updatedAt,
  });

  /// 这次要不要**跳过重新请求**？
  ///
  /// 注意名字 —— 原来叫 `isFresh`，很容易被读成「答案是否有效」，
  /// 但它的真实语义是「**要不要跳过重新请求**」：
  /// - `ok` → 跳过（已经有答案了）
  /// - `empty` / `failed` → [AnswerCache.retryAfter] 内跳过
  ///   （别猛敲 API），过了就允许重试
  ///
  /// 判断「有没有可用的答案」请用 [usable]，别用这个。
  bool shouldSkipRefetch({DateTime? now}) {
    if (status == CachedAnswerStatus.ok) return true;
    final age = (now ?? DateTime.now()).difference(updatedAt);
    return age < AnswerCache.retryAfter;
  }

  /// 是否有可展示的建议答案
  bool get usable =>
      status == CachedAnswerStatus.ok && results.isNotEmpty;

  /// 置信度最高的那条
  AnswerSearchResult? get best => results.isEmpty ? null : results.first;

  Map<String, dynamic> toJson() => {
        'version': 1,
        'hash': hash,
        'problemId': problemId,
        'questionType': questionType,
        'questionPreview': questionPreview,
        'status': status.name,
        'error': error,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        'results': results.map(_resultToJson).toList(),
      };

  static CachedAnswer? fromJson(Map<String, dynamic> json) {
    try {
      final hash = json['hash']?.toString() ?? '';
      if (hash.isEmpty) return null;

      final rawResults = json['results'];
      final results = <AnswerSearchResult>[];
      if (rawResults is List) {
        for (final item in rawResults) {
          if (item is Map) {
            results.add(_resultFromJson(Map<String, dynamic>.from(item)));
          }
        }
      }

      return CachedAnswer(
        hash: hash,
        problemId: json['problemId']?.toString() ?? '',
        questionType: json['questionType']?.toString() ?? '',
        questionPreview: json['questionPreview']?.toString() ?? '',
        status: _statusFromName(json['status']?.toString()),
        results: results,
        error: json['error']?.toString(),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['updatedAt'] as num?)?.toInt() ?? 0,
        ),
      );
    } catch (e) {
      AppLogger.w('AnswerCache', '解析缓存条目失败：$e');
      return null;
    }
  }

  static Map<String, dynamic> _resultToJson(AnswerSearchResult r) => {
        'answer': r.answer,
        'source': r.source,
        'confidence': r.confidence,
        'explanation': r.explanation,
        'sourceType': r.sourceType.name,
        'answerKeys': r.answerKeys,
      };

  static AnswerSearchResult _resultFromJson(Map<String, dynamic> json) {
    return AnswerSearchResult(
      answer: json['answer']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      explanation: json['explanation']?.toString(),
      sourceType: _sourceTypeFromName(json['sourceType']?.toString()),
      answerKeys: (json['answerKeys'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  static CachedAnswerStatus _statusFromName(String? name) {
    switch (name) {
      case 'ok':
        return CachedAnswerStatus.ok;
      case 'empty':
        return CachedAnswerStatus.empty;
      case 'failed':
        return CachedAnswerStatus.failed;
      default:
        return CachedAnswerStatus.empty;
    }
  }

  static AnswerSourceType _sourceTypeFromName(String? name) {
    switch (name) {
      case 'builtin':
        return AnswerSourceType.builtin;
      case 'aiProvider':
        return AnswerSourceType.aiProvider;
      default:
        return AnswerSourceType.aiProvider;
    }
  }
}

class AnswerCache {
  AnswerCache._();

  static const String _tag = 'AnswerCache';

  /// 失败/空结果多久后允许重试
  static const Duration retryAfter = Duration(minutes: 15);

  /// 内存里最多留多少条（LRU）
  static const int maxMemoryEntries = 400;

  static final LinkedHashMap<String, CachedAnswer> _memory = LinkedHashMap();

  static String _key(String lessonId, String hash) =>
      '${CourseCache.safeName(lessonId)}/$hash';

  /// 同步读内存层（UI 拿缓存渲染时走这条，不会 await）
  static CachedAnswer? readMemory(String lessonId, String hash) =>
      _memory[_key(lessonId, hash)];

  /// 读缓存：内存 → 磁盘
  static Future<CachedAnswer?> read(String lessonId, String hash) async {
    final hot = readMemory(lessonId, hash);
    if (hot != null) return hot;

    try {
      final dir = await CourseCache.questionsDir(lessonId, create: false);
      final file = File(p.join(dir.path, '${_safeFile(hash)}.json'));
      final json = await CourseCache.readJson(file);
      if (json == null) return null;

      final parsed = CachedAnswer.fromJson(json);
      if (parsed == null) return null;
      _remember(_key(lessonId, hash), parsed);
      return parsed;
    } catch (e) {
      AppLogger.w(_tag, '读缓存失败（$hash）：$e');
      return null;
    }
  }

  /// 进课堂时一次性把整节课的缓存读进内存
  ///
  /// 这样切页时展示建议答案完全是同步的，不会闪一下「检索中」。
  static Future<int> preload(String lessonId) async {
    var count = 0;
    try {
      final dir = await CourseCache.questionsDir(lessonId, create: false);
      if (!await dir.exists()) return 0;

      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final json = await CourseCache.readJson(entity);
        if (json == null) continue;
        final parsed = CachedAnswer.fromJson(json);
        if (parsed == null) continue;
        _remember(_key(lessonId, parsed.hash), parsed);
        count++;
      }
      AppLogger.i(_tag, '预载 $count 条题目缓存（${CourseCache.safeName(lessonId)}）');
    } catch (e) {
      AppLogger.w(_tag, '预载缓存失败：$e');
    }
    return count;
  }

  /// 写缓存
  static Future<void> write(
    String lessonId,
    String hash,
    CachedAnswer value,
  ) async {
    if (hash.trim().isEmpty) return;
    _remember(_key(lessonId, hash), value);

    try {
      final dir = await CourseCache.questionsDir(lessonId);
      final file = File(p.join(dir.path, '${_safeFile(hash)}.json'));
      await CourseCache.writeJson(file, value.toJson());
    } catch (e) {
      AppLogger.w(_tag, '写缓存失败（$hash）：$e');
    }
  }

  /// 删掉某条缓存（「重新检索」时用）
  static Future<void> remove(String lessonId, String hash) async {
    _memory.remove(_key(lessonId, hash));
    try {
      final dir = await CourseCache.questionsDir(lessonId, create: false);
      final file = File(p.join(dir.path, '${_safeFile(hash)}.json'));
      if (await file.exists()) await file.delete();
    } catch (e) {
      AppLogger.w(_tag, '删缓存失败（$hash）：$e');
    }
  }

  /// 清内存层（退出课堂 / 换账号时调用）
  static void clearMemory() => _memory.clear();

  static void _remember(String key, CachedAnswer value) {
    _memory.remove(key);
    _memory[key] = value;
    while (_memory.length > maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// 指纹里有 `pid-` / `img-` 前缀和连字符，白名单化后当文件名
  static String _safeFile(String raw) {
    final trimmed = raw.trim();
    final buffer = StringBuffer();
    for (final rune in trimmed.runes) {
      final isDigit = rune >= 0x30 && rune <= 0x39;
      final isLower = rune >= 0x61 && rune <= 0x7a;
      final isUpper = rune >= 0x41 && rune <= 0x5a;
      final isDash = rune == 0x5f || rune == 0x2d;
      buffer.write(isDigit || isLower || isUpper || isDash
          ? String.fromCharCode(rune)
          : '_');
    }
    final name = buffer.toString();
    return name.isEmpty ? 'unknown' : name;
  }
}
