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

    Course? findExisting(String classId, String courseId) {
      if (classId.isNotEmpty && courseMap.containsKey(classId)) return courseMap[classId];
      if (courseId.isNotEmpty && courseMap.containsKey(courseId)) return courseMap[courseId];
      for (final c in courseMap.values) {
        if (classId.isNotEmpty && c.classId == classId) return c;
        if (courseId.isNotEmpty && c.courseId == courseId) return c;
      }
      return null;
    }

    // 1. 先录入移动端学习列表（信息最完整）
    if (learningList != null) {
      for (final item in learningList) {
        if (item is! Map) continue;
        try {
          final c = Course.fromRCJson(Map<String, dynamic>.from(item));
          final key = c.classId.isNotEmpty ? c.classId : c.courseId;
          if (key.isNotEmpty) {
            courseMap[key] = c;
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

          final existing = findExisting(classId, courseId);
          if (existing == null) {
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

          final existing = findExisting(classId, courseId);
          if (existing == null) {
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
            // 找到对应的已有课程条目，原地更新为已结课（同时补齐缺失的 classId/courseId）
            final existingKey = existing.classId.isNotEmpty && courseMap.containsKey(existing.classId)
                ? existing.classId
                : (existing.courseId.isNotEmpty && courseMap.containsKey(existing.courseId)
                    ? existing.courseId
                    : key);
            courseMap[existingKey] = Course(
              courseId: existing.courseId.isNotEmpty ? existing.courseId : courseId,
              classId: existing.classId.isNotEmpty ? existing.classId : classId,
              image: existing.image.isNotEmpty ? existing.image : teacherAvatar,
              name: existing.name.isNotEmpty ? existing.name : rawName,
              teacher: existing.teacher.isNotEmpty ? existing.teacher : teacherName,
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
    // 排序：进行中正在上课排最前，进行中排中，已结课排后
    list.sort((a, b) {
      final aLive = a.lessonId != null && a.lessonId!.isNotEmpty;
      final bLive = b.lessonId != null && b.lessonId!.isNotEmpty;
      if (aLive && !bLive) return -1;
      if (!aLive && bLive) return 1;
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
  /// 1. 尝试从活动本身提取的 presentationId、已缓存数据进行直连或装载；
  /// 2. 签到进课堂获取鉴权凭证（宽容处理，支持传入 classroomId 并保留降级策略）；
  /// 3. 多路发现 presentationId：
  ///    - 直接活动提取（content/res_list）
  ///    - 学生历史报告 / 详情 API (`lesson-summary/student`, `classroom-report/student/lesson-info`, `lesson/presentation/active`)
  ///    - Web 端课后课件接口 (`/v2/api/web/lessonafter/{id}/presentation`)
  ///    - 实时课堂 WebSocket 握手
  ///    - 课件资料卡片接口 (`/v2/api/web/cards/detlist`)
  /// 4. 多路拉取整份 PPT 元数据并落盘缓存到 `PptCache` 与 `CourseCache`。
  static Future<Presentation?> crawlLessonPresentation({
    required String lessonId,
    required String courseId,
    required String courseName,
    String? classroomId,
    String? presentationId,
    List<String>? presentationIds,
    RCActivity? activity,
    User? user,
  }) async {
    final effectiveClassroomId = (classroomId != null && classroomId.trim().isNotEmpty)
        ? classroomId.trim()
        : (activity?.classroomId ?? '').trim();

    final candidatePresIds = <String>{};
    if (presentationId != null && presentationId.trim().isNotEmpty) {
      candidatePresIds.add(presentationId.trim());
    }
    if (presentationIds != null) {
      for (final id in presentationIds) {
        if (id.trim().isNotEmpty) candidatePresIds.add(id.trim());
      }
    }
    if (activity != null) {
      for (final id in activity.presentationIds) {
        if (id.trim().isNotEmpty) candidatePresIds.add(id.trim());
      }
    }

    // 0. 优先命中本地缓存
    for (final pid in candidatePresIds) {
      final cached = await PptCache.load(lessonId, pid);
      if (cached != null && cached.slides.isNotEmpty) {
        AppLogger.i(_tag, '命中本地课件缓存：$pid (${cached.slides.length} 页)');
        return cached;
      }
    }

    final api = RCCourseApi(user);

    // 1. 签到进课堂（宽容处理，携带 classroomId，避免 set-auth 断言崩溃）
    try {
      final checkInRes = await api.checkIn(lessonId, classroomId: effectiveClassroomId);
      if (checkInRes != 0 && api.bearerToken == null) {
        AppLogger.d(_tag, '历史课堂签到返回 code=$checkInRes，进入多路探测链路');
      }
    } catch (e) {
      AppLogger.d(_tag, '签到异常（历史课堂忽略）：$e');
    }

    // 2. 多路探测 presentationId 与课件数据
    // 链路 A：通过 /api/v3/lesson-summary/student 探测
    Map<String, dynamic>? summaryData;
    try {
      summaryData = await api.getLessonSummary(lessonId);
      if (summaryData != null) {
        final presentations = summaryData['presentations'];
        if (presentations is List) {
          for (final p in presentations) {
            if (p is Map && p['id'] != null) {
              final pid = p['id'].toString().trim();
              if (pid.isNotEmpty) candidatePresIds.add(pid);
            }
          }
        }
      }
    } catch (e) {
      AppLogger.d(_tag, 'lesson-summary 探测失败: $e');
    }

    // 链路 B：通过 Web 端 /v2/api/web/lessonafter/{lessonId}/presentation 探测
    if (candidatePresIds.isEmpty && effectiveClassroomId.isNotEmpty) {
      try {
        final webPresList = await api.getLessonAfterPresentations(lessonId, effectiveClassroomId);
        if (webPresList != null && webPresList.isNotEmpty) {
          for (final p in webPresList) {
            final pid = (p['id'] ?? p['presentation_id'])?.toString().trim();
            if (pid != null && pid.isNotEmpty) candidatePresIds.add(pid);
          }
        }
      } catch (e) {
        AppLogger.d(_tag, 'lessonafter presentation 探测失败: $e');
      }
    }

    // 链路 C：通过 /api/v3/classroom-report/student/lesson-info 探测
    if (candidatePresIds.isEmpty) {
      try {
        final reportData = await api.getClassroomReportLessonInfo(lessonId);
        if (reportData != null) {
          final presentations = reportData['presentations'] ?? reportData['presentation_list'];
          if (presentations is List) {
            for (final p in presentations) {
              if (p is Map && p['id'] != null) {
                final pid = p['id'].toString().trim();
                if (pid.isNotEmpty) candidatePresIds.add(pid);
              }
            }
          }
          final singlePres = reportData['presentation'];
          if (singlePres is Map && singlePres['id'] != null) {
            final pid = singlePres['id'].toString().trim();
            if (pid.isNotEmpty) candidatePresIds.add(pid);
          }
        }
      } catch (e) {
        AppLogger.d(_tag, 'classroom-report 探测失败: $e');
      }
    }

    // 链路 D：在线实时课堂 WebSocket 握手探测（仅在有 lessonToken 时尝试）
    final lessonToken = api.lessonToken;
    if (candidatePresIds.isEmpty && lessonToken != null) {
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
            if (data is Map) {
              if (data['presentation'] != null) {
                final pres = data['presentation'].toString().trim();
                if (pres.isNotEmpty) candidatePresIds.add(pres);
              }
              if (data['timeline'] is List) {
                for (final ev in data['timeline']) {
                  if (ev['type'] == 'slide' && ev['pres'] != null) {
                    final pres = ev['pres'].toString().trim();
                    if (pres.isNotEmpty) candidatePresIds.add(pres);
                  }
                }
              }
              if (candidatePresIds.isNotEmpty || data['op'] == 'hello' || data['message'] == 'lesson finished') {
                if (!completer.isCompleted) completer.complete();
              }
            }
          } catch (_) {}
        });

        await completer.future.timeout(const Duration(seconds: 3), onTimeout: () {});
        await sub.cancel();
        await ws.close();
      } catch (e) {
        AppLogger.d(_tag, 'WS 探测 presentationId 失败: $e');
      }
    }

    // 备用兜底：若握手或接口探测仍未拿到 presentationId，尝试将 lessonId 本身作为 presentationId
    if (candidatePresIds.isEmpty) {
      candidatePresIds.add(lessonId);
    }

    // 3. 拉取整份 PPT 元数据并落盘缓存
    Presentation? firstPresentation;
    for (final presId in candidatePresIds) {
      try {
        Map<String, dynamic>? pptData;

        // 尝试 1：/api/v3/lesson/presentation/fetch
        pptData = await api.getPresentation(presId);

        // 尝试 2：/api/v3/lesson-summary/student/presentation
        if (pptData == null || (pptData['slides'] == null && pptData['presentation'] == null)) {
          final summaryPres = await api.getLessonSummaryPresentation(presId, lessonId);
          if (summaryPres != null && (summaryPres['slides'] != null || summaryPres['presentation'] != null)) {
            pptData = summaryPres;
          }
        }

        // 尝试 3：/v2/api/web/lessonafter/presentation/{presentationId}
        if ((pptData == null || (pptData['slides'] == null && pptData['presentation'] == null)) && effectiveClassroomId.isNotEmpty) {
          final webPres = await api.getLessonAfterPresentationDetail(presId, effectiveClassroomId);
          if (webPres != null && (webPres['slides'] != null || webPres['presentation'] != null || webPres['Slides'] != null)) {
            pptData = webPres;
          }
        }

        if (pptData != null) {
          final pres = Presentation.fromJson(pptData);
          if (pres.slides.isNotEmpty) {
            await PptCache.save(
              lessonId,
              presId,
              pptData,
              courseId: courseId,
              courseName: courseName,
            );
            firstPresentation ??= pres;
            AppLogger.i(_tag, '成功抓取并缓存 PPT: $presId (${pres.slides.length} 页)');
            break;
          }
        }
      } catch (e) {
        AppLogger.w(_tag, '拉取课件 presentation $presId 失败：$e');
      }
    }

    // 4. 若为 Type 2 课件资料或仍为空，尝试拉取课件资料卡片 /v2/api/web/cards/detlist/{coursewareId}
    if (firstPresentation == null && effectiveClassroomId.isNotEmpty) {
      try {
        final cardData = await api.getCardsDetList(lessonId, effectiveClassroomId);
        if (cardData != null) {
          final title = (cardData['Title'] ?? cardData['title'] ?? activity?.title ?? courseName).toString();
          final rawSlides = cardData['Slides'] ?? cardData['slides'] ?? cardData['Cards'] ?? cardData['cards'] ?? cardData['det_list'];
          if (rawSlides is List && rawSlides.isNotEmpty) {
            final List<Map<String, dynamic>> slides = [];
            for (var i = 0; i < rawSlides.length; i++) {
              final item = rawSlides[i];
              if (item is Map) {
                slides.add({
                  'id': (item['id'] ?? item['Index'] ?? i + 1).toString(),
                  'index': i + 1,
                  'cover': (item['Cover'] ?? item['cover'] ?? item['url'] ?? item['image'] ?? '').toString(),
                  'shapes': const [],
                  'note': (item['text'] ?? item['desc'] ?? '').toString(),
                });
              }
            }
            if (slides.isNotEmpty) {
              final constructed = {
                'title': title,
                'width': 720,
                'height': 540,
                'version': '1.0',
                'slides': slides,
              };
              await PptCache.save(
                lessonId,
                lessonId,
                constructed,
                courseId: courseId,
                courseName: courseName,
              );
              final pres = Presentation.fromJson(constructed);
              firstPresentation = pres;
              AppLogger.i(_tag, '成功从课件资料卡片抓取并缓存 PPT: $lessonId (${pres.slides.length} 页)');
            }
          }
        }
      } catch (e) {
        AppLogger.d(_tag, '课件资料卡片抓取失败: $e');
      }
    }

    return firstPresentation;
  }
}
