/// 用户实际作答的持久草稿；与搜索得到的建议答案分开保存。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/app_logger.dart';
import 'course_cache.dart';

class AnswerDraft {
  final List<String>? options;
  final String? text;

  AnswerDraft({List<String>? options, this.text})
    : options = options == null ? null : List<String>.unmodifiable(options);

  Map<String, dynamic> toJson() => {'options': options, 'text': text};

  static AnswerDraft fromJson(Map<String, dynamic> json) => AnswerDraft(
    options: (json['options'] as List?)?.map((v) => v.toString()).toList(),
    text: json['text'] as String?,
  );
}

class LessonAnswerDrafts {
  final bool finished;
  final Map<String, AnswerDraft> answers;

  const LessonAnswerDrafts({this.finished = false, this.answers = const {}});
}

class AnswerDraftStore {
  AnswerDraftStore._();

  // 所有读、改、写串行化：快速切题/退出重进不能读到较早版本，
  // 课堂结束清理后，迟到的保存也不能把答案写回去。
  static Future<void> _pending = Future<void>.value();

  static Future<T> _serial<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static Future<void> flush() => _pending;

  static String key(String presentationId, String problemId) =>
      '${presentationId.length}:$presentationId$problemId';

  static Future<File> _file(String lessonId) async => File(
    p.join((await CourseCache.lessonDir(lessonId, create: false)).path,
        'answer_drafts.json'),
  );

  static Future<LessonAnswerDrafts> _read(String lessonId) async {
    final json = await CourseCache.readJson(await _file(lessonId));
    if (json == null) return const LessonAnswerDrafts();
    if (json['finished'] == true) {
      return const LessonAnswerDrafts(finished: true);
    }
    final answers = <String, AnswerDraft>{};
    final entries = json['answers'];
    if (entries is Map) {
      for (final entry in entries.entries) {
        try {
          if (entry.value is Map) {
            answers[entry.key.toString()] = AnswerDraft.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
          }
        } catch (e) {
          AppLogger.w('AnswerDraftStore', '忽略损坏的作答草稿：$e');
        }
      }
    }
    return LessonAnswerDrafts(answers: answers);
  }

  static Future<LessonAnswerDrafts> readLesson(String lessonId) =>
      _serial(() async {
        try {
          return await _read(lessonId);
        } catch (e) {
          AppLogger.w('AnswerDraftStore', '读取作答草稿失败：$e');
          return const LessonAnswerDrafts();
        }
      });

  /// 空答案也要保存，防止取消选择/清空输入后又恢复旧答案。
  static Future<void> save(
    String lessonId,
    String presentationId,
    String problemId,
    AnswerDraft draft,
  ) => _serial(() async {
    try {
      final saved = await _read(lessonId);
      if (saved.finished) return;
      final answers = Map<String, AnswerDraft>.of(saved.answers);
      answers[key(presentationId, problemId)] = draft;
      await CourseCache.writeJson(await _file(lessonId), {
        'version': 1,
        'finished': false,
        'answers': answers.map((key, value) => MapEntry(key, value.toJson())),
      });
    } catch (e) {
      AppLogger.w('AnswerDraftStore', '保存作答草稿失败：$e');
    }
  });

  /// 只在服务端确认课堂结束时调用；保留结束标记，删除全部实际作答。
  static Future<void> finishLesson(String lessonId) => _serial(() async {
    try {
      await CourseCache.writeJson(await _file(lessonId), {
        'version': 1,
        'finished': true,
        'answers': <String, dynamic>{},
      });
    } catch (e) {
      AppLogger.w('AnswerDraftStore', '清理课堂作答失败：$e');
    }
  });
}
