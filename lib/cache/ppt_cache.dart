/// PPT 元数据缓存
///
/// 雨课堂取 PPT 是**一次性**接口：
/// `GET /api/v3/lesson/presentation/fetch?presentation_id=xxx`
/// 一次返回整份 `{title, width, height, slides[]}`，每个 slide 里带
/// `id/index/cover/coverAlt/thumbnail/shapes[]/note/problem?`。
///
/// 也就是说「题目信息」本来就躺在这一个响应里，不需要逐页下载、
/// 更不需要图像识别 —— 这是整个自动识题能做得又准又快的前提。
///
/// 这个类负责把这坨 JSON 落盘，好处有两个：
/// 1. 老师来回切换同一份 PPT 时不用重复请求（课堂上很常见）
/// 2. 断网/请求失败时可以退回上次的缓存，页面不至于空白
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/presentation.dart';
import '../utils/app_logger.dart';
import 'course_cache.dart';

class PptCache {
  PptCache._();

  static const String _tag = 'PptCache';

  /// 内存层：同一份 PPT 在同一节课里会被反复读（每次 showpresentation 都读）
  static final Map<String, Map<String, dynamic>> _memory = {};

  static String _key(String lessonId, String presentationId) =>
      '${CourseCache.safeName(lessonId)}/$presentationId';

  /// 读缓存（先内存，再磁盘）；没有则返回 null
  static Future<Presentation?> load(
    String lessonId,
    String presentationId,
  ) async {
    if (presentationId.trim().isEmpty) return null;

    final key = _key(lessonId, presentationId);
    final hot = _memory[key];
    if (hot != null) {
      return _parse(hot);
    }

    try {
      final dir = await CourseCache.pptDir(lessonId, create: false);
      final file = File(p.join(dir.path, '${_safeFile(presentationId)}.json'));
      final json = await CourseCache.readJson(file);
      if (json == null) return null;

      final data = json['data'];
      if (data is! Map) return null;
      final raw = Map<String, dynamic>.from(data);
      _memory[key] = raw;
      AppLogger.d(_tag, '命中 PPT 缓存：$presentationId');
      return _parse(raw);
    } catch (e) {
      AppLogger.w(_tag, '读 PPT 缓存失败：$e');
      return null;
    }
  }

  /// 写缓存
  static Future<void> save(
    String lessonId,
    String presentationId,
    Map<String, dynamic> raw,
  ) async {
    if (presentationId.trim().isEmpty || raw.isEmpty) return;

    _memory[_key(lessonId, presentationId)] = raw;

    try {
      final dir = await CourseCache.pptDir(lessonId);
      final file = File(p.join(dir.path, '${_safeFile(presentationId)}.json'));
      await CourseCache.writeJson(file, {
        'presentationId': presentationId,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'data': raw,
      });
      AppLogger.i(_tag, '已缓存 PPT 元数据：$presentationId');
    } catch (e) {
      AppLogger.w(_tag, '写 PPT 缓存失败：$e');
    }
  }

  /// 清掉内存层（换课程 / 退出课堂时调用）
  static void clearMemory() => _memory.clear();

  static Presentation? _parse(Map<String, dynamic> raw) {
    try {
      return Presentation.fromJson(raw);
    } catch (e) {
      AppLogger.w(_tag, '解析 PPT 缓存失败：$e');
      return null;
    }
  }

  /// presentationId 理论上是纯数字，但仍然白名单化一遍再当文件名
  static String _safeFile(String raw) {
    final trimmed = raw.trim();
    final buffer = StringBuffer();
    for (final rune in trimmed.runes) {
      final isDigit = rune >= 0x30 && rune <= 0x39;
      final isAlpha = (rune >= 0x41 && rune <= 0x5a) || (rune >= 0x61 && rune <= 0x7a);
      final isDash = rune == 0x5f || rune == 0x2d;
      buffer.write(isDigit || isAlpha || isDash ? String.fromCharCode(rune) : '_');
    }
    final name = buffer.toString();
    return name.isEmpty ? 'unknown' : name;
  }
}
