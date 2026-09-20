/// 课程级缓存目录管理
///
/// 目录结构（`<应用文档目录>/ppt_cache/`）：
/// ```
/// ppt_cache/
///   lessons/
///     <lessonId>/
///       ppt/
///         <presentationId>.json      PPT 元数据（整份 slides 的原始 JSON）
///       questions/
///         <questionHash>.json        题目 → 建议答案
///       .finished                    课程结束标记（内容是结束时刻的毫秒时间戳）
/// ```
///
/// 隔离策略：**按课程隔离**。每节课一个目录，不同课的题目缓存互不干扰；
/// 同一道题在两节课里出现会各存一份，代价可忽略。
///
/// 清理策略（两个条件满足任意一个就删整个课程目录）：
/// 1. 目录里有 `.finished` 标记，且标记时间已经过了 [finishGrace]（默认 24 小时）
/// 2. 目录里最后一次写入已经过了 [idleKeep]（默认 7 天）
///
/// 之所以先写标记再延迟 24 小时删，是为了防「下课了但用户还在翻 PPT」——
/// 下课后当场删掉会把用户正在看的页面一并清掉。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';

/// 一次清理的结果
class CacheCleanupReport {
  /// 被删掉的课程目录名（已脱敏的 lessonId）
  final List<String> removedLessons = [];

  /// 释放的字节数
  int removedBytes = 0;

  bool get isEmpty => removedLessons.isEmpty;

  @override
  String toString() =>
      '清理 ${removedLessons.length} 门课，释放 ${(removedBytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

class CourseCache {
  CourseCache._();

  static const String _rootName = 'ppt_cache';
  static const String _lessonsDirName = 'lessons';
  static const String _finishedMarker = '.finished';
  static const String _tag = 'CourseCache';

  /// 多久没有任何写入就认为这门课的缓存可以丢了
  static const Duration idleKeep = Duration(days: 7);

  /// 课程结束后延迟多久清理
  static const Duration finishGrace = Duration(hours: 24);

  static Directory? _root;
  static Future<Directory>? _initializing;

  /// 测试用：清掉已缓存的根目录（换临时目录时用）
  @visibleForTesting
  static void debugResetRoot() {
    _root = null;
    _initializing = null;
  }

  /// 缓存根目录
  ///
  /// 懒初始化：多个模块同时第一次调用时共享同一次创建过程，
  /// 避免并发 `create()` 撞车。
  static Future<Directory> root() async {
    final cached = _root;
    if (cached != null) return cached;

    final pending = _initializing;
    if (pending != null) return pending;

    final future = _createRoot();
    _initializing = future;
    try {
      return await future;
    } finally {
      _initializing = null;
    }
  }

  static Future<Directory> _createRoot() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, _rootName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _root = dir;
    return dir;
  }

  /// 某节课的目录
  static Future<Directory> lessonDir(String lessonId,
      {bool create = true}) async {
    final dir =
        Directory(p.join((await root()).path, _lessonsDirName, safeName(lessonId)));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 某节课的 PPT 元数据目录
  static Future<Directory> pptDir(String lessonId, {bool create = true}) async {
    final dir = Directory(p.join((await lessonDir(lessonId, create: create)).path, 'ppt'));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 某节课的题目答案目录
  static Future<Directory> questionsDir(String lessonId,
      {bool create = true}) async {
    final dir =
        Directory(p.join((await lessonDir(lessonId, create: create)).path, 'questions'));
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 写入「这节课结束了」标记
  static Future<void> markFinished(String lessonId) async {
    try {
      final dir = await lessonDir(lessonId);
      final marker = File(p.join(dir.path, _finishedMarker));
      await marker.writeAsString(
        '${DateTime.now().millisecondsSinceEpoch}',
        flush: true,
      );
      AppLogger.i(_tag, '已标记课程结束：${safeName(lessonId)}');
    } catch (e) {
      AppLogger.w(_tag, '写课程结束标记失败：$e');
    }
  }

  /// 读取「这节课结束了」标记时间（没有标记返回 null）
  static Future<DateTime?> finishedAt(String lessonId) async {
    try {
      final dir = await lessonDir(lessonId, create: false);
      final marker = File(p.join(dir.path, _finishedMarker));
      if (!await marker.exists()) return null;
      final ms = int.tryParse((await marker.readAsString()).trim());
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// 清掉某节课的全部缓存
  static Future<int> clearLesson(String lessonId) async {
    try {
      final dir = await lessonDir(lessonId, create: false);
      if (!await dir.exists()) return 0;
      final bytes = await _deleteDir(dir);
      AppLogger.i(_tag, '已清空课程缓存 ${safeName(lessonId)}');
      return bytes;
    } catch (e) {
      AppLogger.w(_tag, '清空课程缓存失败：$e');
      return 0;
    }
  }

  /// 清掉所有课程缓存（设置页的「清空缓存」用）
  static Future<int> clearAll() async {
    try {
      final lessonsRoot =
          Directory(p.join((await root()).path, _lessonsDirName));
      if (!await lessonsRoot.exists()) return 0;
      final bytes = await _deleteDir(lessonsRoot);
      AppLogger.i(_tag, '已清空全部课程缓存');
      return bytes;
    } catch (e) {
      AppLogger.w(_tag, '清空全部缓存失败：$e');
      return 0;
    }
  }

  /// 按策略清理过期课程目录
  ///
  /// 建议在进入课堂时、以及 App 启动时各跑一次（都很便宜：
  /// 只是 `stat` 一层目录，没有大文件扫描）。
  static Future<CacheCleanupReport> cleanup() async {
    final report = CacheCleanupReport();
    try {
      final lessonsRoot =
          Directory(p.join((await root()).path, _lessonsDirName));
      if (!await lessonsRoot.exists()) return report;

      final now = DateTime.now();
      await for (final entity in lessonsRoot.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final reason = await _expireReason(entity, now);
        if (reason == null) continue;

        final name = p.basename(entity.path);
        final bytes = await _deleteDir(entity);
        report.removedLessons.add(name);
        report.removedBytes += bytes;
        AppLogger.i(_tag, '清理课程缓存 $name（$reason）');
      }
    } catch (e) {
      AppLogger.w(_tag, '清理缓存失败：$e');
    }
    return report;
  }

  /// 当前缓存占用（字节）与课程数量
  static Future<({int bytes, int lessons})> stats() async {
    var bytes = 0;
    var lessons = 0;
    try {
      final lessonsRoot =
          Directory(p.join((await root()).path, _lessonsDirName));
      if (!await lessonsRoot.exists()) return (bytes: 0, lessons: 0);

      await for (final entity in lessonsRoot.list(followLinks: false)) {
        if (entity is! Directory) continue;
        lessons++;
        bytes += await _dirSize(entity);
      }
    } catch (e) {
      AppLogger.w(_tag, '统计缓存占用失败：$e');
    }
    return (bytes: bytes, lessons: lessons);
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  /// 判断课程目录是否该过期；返回 null 表示保留
  static Future<String?> _expireReason(Directory dir, DateTime now) async {
    final marker = File(p.join(dir.path, _finishedMarker));
    if (await marker.exists()) {
      try {
        final ms = int.tryParse((await marker.readAsString()).trim());
        if (ms != null) {
          final finished = DateTime.fromMillisecondsSinceEpoch(ms);
          if (now.difference(finished) >= finishGrace) {
            return '课程已结束超过 ${finishGrace.inHours} 小时';
          }
        }
      } catch (_) {
        // 标记文件损坏 → 忽略，退回按写入时间判断
      }
    }

    final lastWrite = await _lastModified(dir);
    if (lastWrite == null) return null;
    if (now.difference(lastWrite) >= idleKeep) {
      return '超过 ${idleKeep.inDays} 天未使用';
    }
    return null;
  }

  /// 目录内最后一次写入时间
  static Future<DateTime?> _lastModified(Directory dir) async {
    DateTime? latest;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (latest == null || stat.modified.isAfter(latest)) {
            latest = stat.modified;
          }
        } catch (_) {
          // 单个文件 stat 失败不影响整体判断
        }
      }
    } catch (_) {
      return null;
    }
    return latest;
  }

  static Future<int> _dirSize(Directory dir) async {
    var bytes = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          bytes += await entity.length();
        } catch (_) {
          // 文件刚好被删掉时 length() 会抛，忽略
        }
      }
    } catch (_) {
      // 目录不存在/无权限，按 0 处理
    }
    return bytes;
  }

  /// 递归删除并返回释放的字节数
  static Future<int> _deleteDir(Directory dir) async {
    final bytes = await _dirSize(dir);
    try {
      await dir.delete(recursive: true);
    } catch (e) {
      AppLogger.w(_tag, '删除目录失败 ${dir.path}：$e');
    }
    return bytes;
  }

  /// lessonId 可能带各种奇怪字符（甚至 `../`），落盘前统一白名单化
  ///
  /// 只保留字母、数字、下划线、连字符，其余一律换成下划线，
  /// 保证结果既不是空串也不是 `.` / `..`。
  static String safeName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'unknown';

    final buffer = StringBuffer();
    for (final rune in trimmed.runes) {
      final isDigit = rune >= 0x30 && rune <= 0x39;
      final isUpper = rune >= 0x41 && rune <= 0x5a;
      final isLower = rune >= 0x61 && rune <= 0x7a;
      final isDash = rune == 0x5f /* _ */ || rune == 0x2d /* - */;
      buffer.write(isDigit || isUpper || isLower || isDash
          ? String.fromCharCode(rune)
          : '_');
    }

    final name = buffer.toString();
    if (name.isEmpty || name == '.' || name == '..') return 'unknown';
    // 兜住 Windows/Android 都不喜欢的超长文件名
    return name.length <= 80 ? name : name.substring(0, 80);
  }

  /// 读一个 JSON 文件（不存在或解析失败都返回 null）
  static Future<Map<String, dynamic>?> readJson(File file) async {
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (e) {
      AppLogger.w(_tag, '读取缓存失败 ${p.basename(file.path)}：$e');
      return null;
    }
  }

  /// 写一个 JSON 文件
  ///
  /// 先写 `.tmp` 再 rename，避免进程被杀时留下半截文件
  /// （下次读到坏 JSON 会当成「没有缓存」，虽然不致命但会白跑一次 AI）。
  /// 临时名带自增序号，两个并发写同一个目标时也不会互相覆盖。
  static int _tmpSeq = 0;

  static Future<void> writeJson(File file, Map<String, dynamic> data) async {
    File? tmp;
    try {
      final parent = file.parent;
      if (!await parent.exists()) await parent.create(recursive: true);

      tmp = File('${file.path}.${++_tmpSeq}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (e) {
      AppLogger.w(_tag, '写入缓存失败 ${p.basename(file.path)}：$e');
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 清理临时文件失败不影响主流程
      }
    }
  }
}
