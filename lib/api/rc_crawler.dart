import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket;

import '../cache/ppt_cache.dart';
import '../models/course.dart';
import '../models/presentation.dart';
import '../models/rc_activity.dart';
import '../models/user.dart';
import '../platform.dart';
import '../session/account.dart';
import '../utils/app_logger.dart';
import 'api_service.dart';
import 'course.dart';

/// 雨课堂爬虫模块
///
/// 核心参考：
/// - Ajax's Blog: 雨课堂全量活动 `/v2/api/web/logs/learn/{classroom_id}`
/// - 结课归档接口 `/v2/api/web/classroom_archive` 与 Web 课程 `/v2/api/web/courses/list?identity=2`
/// - 课堂回放与全量课件 PPT 元数据拉取
class RCCrawler {
  static const String _tag = 'RCCrawler';

  /// 纯函数：从响应数据中提取课程列表
  static List<Map<String, dynamic>> extractCoursesList(dynamic responseData) {
    if (responseData == null) return const [];
    dynamic listData;
    if (responseData is Map) {
      final data = responseData['data'];
      if (data is Map) {
        listData = data['list'] ?? data['courses'] ?? data['classroom_list'];
      } else if (data is List) {
        listData = data;
      } else {
        listData = responseData['list'] ?? responseData['courses'];
      }
    } else if (responseData is List) {
      listData = responseData;
    }

    if (listData is! List) return const [];

    final result = <Map<String, dynamic>>[];
    for (final item in listData) {
      if (item is Map) {
        result.add(Map<String, dynamic>.from(item));
      }
    }
    return result;
  }

  /// 纯函数：合并三路来源的雨课堂课程（去重并保留结课标记）
  ///
  /// 来源 1：移动端学习列表 [learningList]（`/v/course_meta/learning_list/`）
  /// 来源 2：Web 端在修课程 [webCourses]（`/v2/api/web/courses/list?identity=2`）
  /// 来源 3：已归档历史课程 [archivedCourses]（`/v2/api/web/classroom_archive`）
  static List<Course> mergeCourses({
    List<dynamic>? learningList,
    List<Map<String, dynamic>>? webCourses,
    List<Map<String, dynamic>>? archivedCourses,
    Map<String, String>? onLessonMap, // courseId -> lessonId
  }) {
    final Map<String, Course> courseMap = {};

    // 1. 先录入移动端学习列表（信息最完整）
    if (learningList != null) {
      for (final item in learningList) {
        if (item is! Map) continue;
        try {
          final c = Course.fromRCJson(Map<String, dynamic>.from(item));
          if (c.classId.isNotEmpty) {
            courseMap[c.classId] = c;
          } else if (c.courseId.isNotEmpty) {
            courseMap[c.courseId] = c;
          }
        } catch (_) {}
      }
    }

    // 2. 补入 Web 端在修课程
    if (webCourses != null) {
      for (final item in webCourses) {
        try {
          final classId = (item['classroom_id'] ?? item['classroomId'] ?? item['class_id'] ?? item['id'] ?? '').toString();
          final courseId = (item['course_id'] ?? item['courseId'] ?? '').toString();
          final key = classId.isNotEmpty ? classId : courseId;
          if (key.isEmpty) continue;

          if (!courseMap.containsKey(key)) {
            final teacherName = item['teacher'] is Map
                ? (item['teacher']['name'] ?? '未知教师').toString()
                : (item['teacher_name'] ?? item['teacher'] ?? '未知教师').toString();
            final teacherAvatar = item['teacher'] is Map
                ? (item['teacher']['avatar'] ?? '').toString()
                : (item['teacher_avatar'] ?? '').toString();

            courseMap[key] = Course(
              courseId: courseId,
              classId: classId,
              image: teacherAvatar,
              name: (item['course_name'] ?? item['name'] ?? '未知课程').toString(),
              teacher: teacherName,
              note: (item['classroom_name'] ?? '').toString(),
              state: true,
            );
          }
        } catch (_) {}
      }
    }

    // 3. 补入已归档/已结课历史课程
    if (archivedCourses != null) {
      for (final item in archivedCourses) {
        try {
          final classId = (item['classroom_id'] ?? item['classroomId'] ?? item['class_id'] ?? item['id'] ?? '').toString();
          final courseId = (item['course_id'] ?? item['courseId'] ?? '').toString();
          final key = classId.isNotEmpty ? classId : courseId;
          if (key.isEmpty) continue;

          final rawName = (item['course_name'] ?? item['name'] ?? '未知课程').toString();
          final teacherName = item['teacher'] is Map
              ? (item['teacher']['name'] ?? '未知教师').toString()
              : (item['teacher_name'] ?? item['teacher'] ?? '未知教师').toString();
          final teacherAvatar = item['teacher'] is Map
              ? (item['teacher']['avatar'] ?? '').toString()
              : (item['teacher_avatar'] ?? '').toString();

          final note = item['classroom_name']?.toString() ?? '';
          final displayNote = note.isNotEmpty ? '$note [已结课]' : '已结课';

          if (!courseMap.containsKey(key)) {
            courseMap[key] = Course(
              courseId: courseId,
              classId: classId,
              image: teacherAvatar,
              name: rawName,
              teacher: teacherName,
              note: displayNote,
              state: false, // 标记为已结课
            );
          } else {
            // 如果已存在但归档列表中有它，更新状态为已结课
            final existing = courseMap[key]!;
            courseMap[key] = Course(
              courseId: existing.courseId,
              classId: existing.classId,
              image: existing.image,
              name: existing.name,
              teacher: existing.teacher,
              note: displayNote,
              state: false,
              lessonId: existing.lessonId,
            );
          }
        } catch (_) {}
      }
    }

    // 4. 挂接正在上课的 lessonId（若有）
    if (onLessonMap != null && onLessonMap.isNotEmpty) {
      for (final entry in onLessonMap.entries) {
        for (final key in courseMap.keys) {
          final c = courseMap[key]!;
          if (c.courseId == entry.key || c.classId == entry.key) {
            courseMap[key] = Course(
              courseId: c.courseId,
              classId: c.classId,
              image: c.image,
              name: c.name,
              teacher: c.teacher,
              note: c.note,
              state: c.state,
              lessonId: entry.value,
              settings: c.settings,
            );
          }
        }
      }
    }

    final list = courseMap.values.toList();
    // 排序：进行中课程排前面，已结课排后面
    list.sort((a, b) {
      if (a.state && !b.state) return -1;
      if (!a.state && b.state) return 1;
      return a.name.compareTo(b.name);
    });

    return list;
  }

  /// 获取 Web 端未归档课程列表
  static Future<List<Map<String, dynamic>>?> getWebCourses({String? userId}) async {
    final url = '/v2/api/web/courses/list?identity=2';
    final response = await ApiService.sendRequest(url, userId: userId);
    return extractCoursesList(response?.data);
  }

  /// 获取 Web 端已归档/已结课历史课程列表
  static Future<List<Map<String, dynamic>>?> getArchivedCourses({String? userId}) async {
    final url = '/v2/api/web/classroom_archive';
    final response = await ApiService.sendRequest(url, userId: userId);
    return extractCoursesList(response?.data);
  }

  /// 拉取指定班级/课程的教学活动与课件日志
  static Future<List<RCActivity>?> getCourseActivities(
    String classroomId, {
    String? userId,
  }) async {
    if (classroomId.trim().isEmpty) return null;
    final url = '/v2/api/web/logs/learn/$classroomId?actype=-1&page=0&offset=500&sort=-1';
    final response = await ApiService.sendRequest(url, userId: userId);
    if (response?.data == null) return null;
    return RCActivity.parseActivitiesJson(response!.data, classroomId: classroomId);
  }

  /// 抓取指定历史课堂的课件 PPT 并落盘到本地缓存
  ///
  /// 流程：
  /// 1. 签到进课堂获取鉴权凭证（Bearer Token 与 Lesson Token）
  /// 2. 通过轻量 WebSocket 握手获取 presentationId（备用以 lessonId 兜底）
  /// 3. 请求 `/api/v3/lesson/presentation/fetch` 拉取整份 PPT 元数据
  /// 4. 存入 `PptCache` 并写入 `CourseCache` 元数据
  static Future<Presentation?> crawlLessonPresentation({
    required String lessonId,
    required String courseId,
    required String courseName,
    User? user,
  }) async {
    final api = RCCourseApi(user);
    // 1. 签到进课堂
    final checkInRes = await api.checkIn(lessonId);
    if (checkInRes != 0 && api.bearerToken == null) {
      AppLogger.w(_tag, '课堂签到失败 (code=$checkInRes): $lessonId');
    }

    final lessonToken = api.lessonToken;

    final presentationIds = <String>{};

    // 2. 探测 presentationId（优先通过 WebSocket hello 握手）
    if (lessonToken != null) {
      try {
        final currentServerName = PlatformManager().currentServer.name;
        final wsUrl = currentServerName == 'yuketang'
            ? 'wss://www.yuketang.cn/wsapp/'
            : 'wss://$currentServerName.yuketang.cn/wsapp/';

        final ws = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 4));
        final completer = Completer<void>();

        final helloData = {
          "op": "hello",
          "userid": user?.uid ?? AccountManager.currentSessionId,
          "role": "student",
          "auth": lessonToken,
          "lessonid": lessonId,
        };
        ws.add(jsonEncode(helloData));

        final sub = ws.listen((msg) {
          try {
            final data = jsonDecode(msg);
            if (data['presentation'] != null) {
              final pres = data['presentation'].toString().trim();
              if (pres.isNotEmpty) presentationIds.add(pres);
            }
            if (data['timeline'] is List) {
              for (final ev in data['timeline']) {
                if (ev['type'] == 'slide' && ev['pres'] != null) {
                  final pres = ev['pres'].toString().trim();
                  if (pres.isNotEmpty) presentationIds.add(pres);
                }
              }
            }
            if (!completer.isCompleted) completer.complete();
          } catch (_) {}
        });

        await completer.future.timeout(const Duration(seconds: 3), onTimeout: () {});
        await sub.cancel();
        await ws.close();
      } catch (e) {
        AppLogger.d(_tag, 'WS 探测 presentationId 失败 (尝试备用途径): $e');
      }
    }

    // 备用兜底：若握手未拿到 presentationId，尝试将 lessonId 本身作为 presentationId
    if (presentationIds.isEmpty) {
      presentationIds.add(lessonId);
    }

    // 3. 拉取整份 PPT 元数据并落盘缓存
    Presentation? firstPresentation;
    for (final presId in presentationIds) {
      try {
        final pptData = await api.getPresentation(presId);
        if (pptData != null) {
          await PptCache.save(
            lessonId,
            presId,
            pptData,
            courseId: courseId,
            courseName: courseName,
          );
          final pres = Presentation.fromJson(pptData);
          firstPresentation ??= pres;
          AppLogger.i(_tag, '成功抓取并缓存 PPT: $presId (${pres.slides.length} 页)');
        }
      } catch (e) {
        AppLogger.w(_tag, '拉取课件 presentation $presId 失败：$e');
      }
    }

    return firstPresentation;
  }
}
