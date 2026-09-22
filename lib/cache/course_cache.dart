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
import '../utils/image_cache_key.dart';

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

/// 一门已缓存课程在磁盘上的元信息（`lessons/<lessonId>/meta.json`）。
///
/// 为什么需要它：缓存目录是按 **lessonId** 组织的（雨课堂里每上一次课就是一个
/// 新 lessonId），而「课程」这个概念用的是 **courseId**。两者的对应关系以前
/// 从来没落过盘 —— `PresentationPage(title: course.name)` 只在内存里，进程一退
/// 就没了，于是课件页只能看到一串 lessonId 数字，既不知道是哪门课、也没法按
/// 课程聚合。
///
/// 从 v4.8.8 起，每次进课堂都会把 `{courseId, courseName}` 写进 meta.json。
/// 老缓存没有这个文件，首次重新进入那门课时会被回填（见 [CourseCache.listLessons]
/// 的兜底）。
class LessonMeta {
  const LessonMeta({
    required this.lessonId,
    this.courseId = '',
    this.courseName = '',
    this.updatedAt = 0,
  });

  /// 缓存目录名（= `safeName(lessonId)`）
  final String lessonId;

  /// 课程 ID（雨课堂的 `course_id`）
  final String courseId;

  /// 课程名（用于列表展示）
  final String courseName;

  /// 最后一次写入时间（毫秒时间戳）
  final int updatedAt;

  /// 展示名：课程名优先，退回 lessonId（老缓存 / 未回填）
  String get displayName => courseName.trim().isEmpty ? lessonId : courseName;
}

/// 课件页第一层的列表项：一门课 + 它的缓存概况。
class CachedLesson {
  const CachedLesson({
    required this.lessonId,
    required this.courseId,
    required this.name,
    required this.presentationCount,
    required this.updatedAt,
  });

  final String lessonId;
  final String courseId;

  /// 展示名（课程名，或老缓存的兜底名）
  final String name;

  /// 该 lessonId 下缓存了几份 PPT
  final int presentationCount;

  final int updatedAt;

  bool get hasPresentations => presentationCount > 0;
}

/// 课件页第二层的列表项：一份已缓存的 PPT。
class CachedPresentation {
  const CachedPresentation({
    required this.lessonId,
    required this.presentationId,
    required this.title,
    required this.slideCount,
    required this.savedAt,
    required this.bytes,
  });

  /// 它属于哪节课的缓存目录（查看 / 删除都要用它定位文件）
  final String lessonId;

  final String presentationId;
  final String title;
  final int slideCount;

  /// 落盘时间（毫秒时间戳）
  final int savedAt;

  /// json 文件大小（图片另计，由整门课一起管理）
  final int bytes;

  String get displayTitle => title.trim().isEmpty ? presentationId : title;
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
  // 课件管理（课件页用）
  //
  // 需求原文：「一个是缓存的 ppt，增加查看缓存的 ppt，和删除的按钮，
  //          取消自动删除 ppt」
  // ---------------------------------------------------------------------------

  static const String _metaFileName = 'meta.json';
  static const String _imagesDirName = 'images';

  /// 某节课的元信息文件
  static Future<File> metaFile(String lessonId) async =>
      File(p.join((await lessonDir(lessonId)).path, _metaFileName));

  /// 写入 / 合并课程元信息。
  ///
  /// 空字符串**不会**覆盖已有值 —— 调用方（例如学习通路径）可能拿不到
  /// courseName，不能因此把之前记好的名字抹掉。
  static Future<void> writeMeta(
    String lessonId, {
    String courseId = '',
    String courseName = '',
  }) async {
    final hasCourseId = courseId.trim().isNotEmpty;
    final hasCourseName = courseName.trim().isNotEmpty;
    if (!hasCourseId && !hasCourseName) return;

    try {
      final existing = await readMeta(lessonId);
      await writeJson(await metaFile(lessonId), {
        'lessonId': lessonId,
        'courseId': hasCourseId ? courseId : (existing?.courseId ?? ''),
        'courseName': hasCourseName ? courseName : (existing?.courseName ?? ''),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      AppLogger.w(_tag, '写课程元信息失败：$e');
    }
  }

  /// 读课程元信息（不存在返回 null）
  static Future<LessonMeta?> readMeta(String lessonId) async {
    try {
      final json = await readJson(await metaFile(lessonId));
      if (json == null) return null;
      return LessonMeta(
        lessonId: lessonId,
        courseId: (json['courseId'] ?? '').toString(),
        courseName: (json['courseName'] ?? '').toString(),
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// 列出所有已缓存的课程（按最后写入时间倒序）。
  ///
  /// 老缓存（没有 meta.json）用「该课第一份 PPT 的标题」兜底当展示名 ——
  /// 至少比一串 lessonId 数字可读；下次进课堂时会被正式回填。
  static Future<List<CachedLesson>> listLessons() async {
    final result = <CachedLesson>[];
    try {
      final lessonsRoot =
          Directory(p.join((await root()).path, _lessonsDirName));
      if (!await lessonsRoot.exists()) return result;

      await for (final entity in lessonsRoot.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final dirName = p.basename(entity.path);

        final ppts = await listPresentations(dirName);
        final meta = await readMeta(dirName);

        result.add(CachedLesson(
          lessonId: dirName,
          courseId: meta?.courseId ?? '',
          name: meta?.displayName ??
              (ppts.isNotEmpty ? ppts.first.displayTitle : dirName),
          presentationCount: ppts.length,
          updatedAt: meta?.updatedAt != null && meta!.updatedAt > 0
              ? meta.updatedAt
              : (ppts.isNotEmpty
                  ? ppts.first.savedAt
                  : await _dirModifiedMs(entity)),
        ));
      }
    } catch (e) {
      AppLogger.w(_tag, '列课程缓存失败：$e');
    }

    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  /// 列出某节课缓存的所有 PPT（按落盘时间倒序）。
  static Future<List<CachedPresentation>> listPresentations(
      String lessonId) async {
    final result = <CachedPresentation>[];
    try {
      final dir = await pptDir(lessonId, create: false);
      if (!await dir.exists()) return result;

      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.json')) continue;

        try {
          final json = await readJson(entity);
          if (json == null) continue;
          final data = json['data'];
          final slides = data is Map ? data['slides'] : null;

          result.add(CachedPresentation(
            lessonId: lessonId,
            presentationId: (json['presentationId'] ??
                    p.basenameWithoutExtension(entity.path))
                .toString(),
            title: (data is Map ? (data['title'] ?? '') : '').toString(),
            slideCount: slides is List ? slides.length : 0,
            savedAt: (json['savedAt'] as num?)?.toInt() ?? 0,
            bytes: await entity.length(),
          ));
        } catch (e) {
          AppLogger.d(_tag, '读课件失败 ${p.basename(entity.path)}：$e');
        }
      }
    } catch (e) {
      AppLogger.w(_tag, '列课件失败：$e');
    }

    result.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return result;
  }

  /// 删掉一份课件（json + 它**独占**的图片），返回释放的字节数。
  ///
  /// ⚠️ 图片是同一节课的**所有 PPT 共享** `ppt/images/` 一个目录的，同一张源图
  /// 可能被多份 PPT 引用（甚至同一份 PPT 的多页引用）。所以不能把「这份 PPT
  /// 引用的图片」直接删掉 —— 先删 json，再重新收集**剩余 PPT 还引用着的**图片
  /// 指纹，只清理不在这个集合里的文件（孤儿）。
  static Future<int> deletePresentation(
    String lessonId,
    String presentationId,
  ) async {
    var freed = 0;
    try {
      final dir = await pptDir(lessonId, create: false);
      final target =
          File(p.join(dir.path, '${safeFile(presentationId)}.json'));
      if (await target.exists()) {
        freed += await target.length();
        await target.delete();
      }
      freed += await _sweepOrphanImages(lessonId);
      AppLogger.i(_tag, '已删除课件 $presentationId');
    } catch (e) {
      AppLogger.w(_tag, '删除课件失败：$e');
    }
    return freed;
  }

  /// 按 courseId 找出所有相关的 lessonId。
  ///
  /// 同一门课会有多个 lessonId（每次上课都是一个新的），所以返回列表。
  /// 老缓存没有 meta.json → 关联不上，只能靠「进课堂时回填」逐步补齐。
  static Future<List<String>> findLessonIdsByCourseId(String courseId) async {
    if (courseId.trim().isEmpty) return const [];
    final result = <String>[];
    for (final lesson in await listLessons()) {
      if (lesson.courseId == courseId) result.add(lesson.lessonId);
    }
    return result;
  }

  /// 清掉某门课下所有 lessonId 的缓存（课件页「删除该课全部课件」用）。
  static Future<int> clearCourse(String courseId) async {
    var freed = 0;
    for (final lessonId in await findLessonIdsByCourseId(courseId)) {
      freed += await clearLesson(lessonId);
    }
    return freed;
  }

  /// 删掉 `ppt/images/` 里已经没有任何 PPT 引用的图片，返回释放字节数。
  ///
  /// 引用关系怎么求：每份 PPT 的 json 里 `slides[].cover / coverAlt / thumbnail`
  /// 就是图片 URL，取 [imageCacheDigest] 即落盘文件名主体。
  static Future<int> _sweepOrphanImages(String lessonId) async {
    var freed = 0;
    try {
      final imagesDir = Directory(
        p.join((await pptDir(lessonId, create: false)).path, _imagesDirName),
      );
      if (!await imagesDir.exists()) return 0;

      // 1) 收集所有 PPT 还引用着的图片指纹
      final referenced = <String>{};
      final ppt = await pptDir(lessonId, create: false);
      await for (final entity in ppt.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.json')) continue;
        final json = await readJson(entity);
        final data = json?['data'];
        if (data is! Map) continue;
        final slides = data['slides'];
        if (slides is! List) continue;
        for (final slide in slides) {
          if (slide is! Map) continue;
          for (final key in const ['cover', 'coverAlt', 'thumbnail']) {
            final url = slide[key]?.toString() ?? '';
            if (url.trim().isNotEmpty) referenced.add(imageCacheDigest(url));
          }
        }
      }

      // 2) 清掉不在集合里的文件
      await for (final entity in imagesDir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (referenced.contains(p.basenameWithoutExtension(entity.path))) {
          continue;
        }
        try {
          freed += await entity.length();
          await entity.delete();
        } catch (_) {
          // 单个文件删不掉不影响整体
        }
      }
    } catch (e) {
      AppLogger.w(_tag, '清理孤儿图片失败：$e');
    }
    return freed;
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

  /// 目录自身的最后修改时间（毫秒时间戳）。
  ///
  /// 比 [_lastModified] 轻得多：只 `stat` 一层，不递归扫文件。
  /// 课件页要按「最近使用」排序，对没写过 meta.json 的老缓存用它兜底。
  static Future<int> _dirModifiedMs(Directory dir) async {
    try {
      return (await dir.stat()).modified.millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
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

  /// presentationId 理论上是纯数字，但仍然白名单化一遍再当文件名。
  ///
  /// 从 `PptCache` 提上来的：`PptCache` 要写、本文件要读/删，
  /// 两处各写一份白名单逻辑迟早会写歪（写歪就是「列表里有、点进去 404」）。
  static String safeFile(String raw) {
    final trimmed = raw.trim();
    final buffer = StringBuffer();
    for (final rune in trimmed.runes) {
      final isDigit = rune >= 0x30 && rune <= 0x39;
      final isAlpha =
          (rune >= 0x41 && rune <= 0x5a) || (rune >= 0x61 && rune <= 0x7a);
      final isDash = rune == 0x5f || rune == 0x2d;
      buffer.write(
          isDigit || isAlpha || isDash ? String.fromCharCode(rune) : '_');
    }
    final name = buffer.toString();
    return name.isEmpty ? 'unknown' : name;
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

/// 某门课该关联哪些 lessonId 的缓存目录（纯函数，可单测）
///
/// 两条来源：
/// 1. **`meta.json` 里 courseId 对上的**（v4.8.8 起每次进课堂才会写）
/// 2. **兜底 —— 按目录名对**：缓存目录名就是 `safeName(lessonId)`，
///    而在课的课能从接口拿到 `lessonId`（`getAllCourses()` 刻意不 join，
///    所以那边恒为 null；`getCoursesList()` 才有）。
///
/// 为什么必须有第 2 条：v4.8.8 之前的版本**从来没写过 meta.json**，
/// 用户手里已有的缓存全都是「无 courseId」的。没有兜底的话，
/// 课件页会列出所有课程、但点进去每门课都是「还没有缓存课件」——
/// 而缓存其实好好地躺在「未关联课程」那一档里。
///
/// [cachedDirNames] 传的是缓存目录名集合（= `listLessons()` 里的 lessonId）。
Set<String> resolveLessonIdsForCourse({
  required String courseId,
  required Map<String, List<String>> lessonIdsByCourseId,
  required Set<String> cachedDirNames,
  String? onLessonId,
}) {
  // 空 courseId 是「没有 meta.json 的旧缓存」在 byCourse 里的那个桶，
  // 不是一门真实的课 —— 绝不能把它当课程去认领缓存。
  if (courseId.trim().isEmpty) return <String>{};

  final ids = <String>{...?lessonIdsByCourseId[courseId]};

  final raw = onLessonId?.trim() ?? '';
  if (raw.isNotEmpty) {
    final dir = CourseCache.safeName(raw);
    if (cachedDirNames.contains(dir)) ids.add(dir);
  }

  return ids;
}
