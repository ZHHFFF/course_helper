import 'package:flutter/foundation.dart';

import 'api_service.dart';
import '../utils/encrypt.dart';
import '../models/active.dart';
import '../models/course.dart';

class CXCourseApi extends Api {
  CXCourseApi([super.user]);

  /// 获取课程列表
  static Future<Map<String, dynamic>?> getCourses() async {
    final url = 'https://mooc1-api.chaoxing.com/mycourse/backclazzdata?view=json&getTchClazzType=1&mcode=';
    
    final response = await ApiService.sendRequest(url);
    return response?.data;
  }

  /// 获取处理后的课程列表
  static Future<List<Course>?> getCoursesList() async {
    final coursesData = await getCourses();
    
    if (coursesData == null || coursesData['result'] != 1) {
      return null;
    }

    List<Course> courses = [];
    List<dynamic> channelList = coursesData['channelList'];

    for (var channel in channelList) {
      if (channel['content']['course'] != null) {
        courses.add(Course.fromCXJson(channel));
      }
    }

    return courses.where((course) => course.state).toList();
  }

  /// 获取加入课程时间作为参数
  Future<String?> getJoinClassTime(String courseId, String classId, String cpi) async {
    final url = 'https://mooc1-api.chaoxing.com/gas/clazzperson';
    final params = {
      'courseid': courseId,
      'clazzid': classId,
      'userid': user!.uid,
      'personid': cpi,
      'view': 'json',
      'fields': 'clazzid,popupagreement,personid,clazzname,createtime'
    };

    final response = await ApiService.sendRequest(url, params: params);
    if (response == null) return null;

    return response.data['data'][0]['createtime'];
  }

  /// 获取任务活动列表
  Future<Map<String, dynamic>?> getTaskActivityList(String courseId, String classId, String cpi, String joinClassTime) async {
    final url = 'https://mobilelearn.chaoxing.com/ppt/activeAPI/taskactivelist';

    final params = {
      'courseId': courseId,
      'classId': classId,
      'uid': user!.uid,
      'cpi': cpi,
      'joinclasstime': joinClassTime
    };
    params.addAll(EncryptionUtil.getEncParams(params));

    final response = await ApiService.sendRequest(url, method: 'GET', params: params);
    return response?.data;
  }

  /// 获取任务活动列表（Web）
  static Future<Map<String, dynamic>?> getTaskActivityListWeb(String courseId, String classId) async {
    final url = 'https://mobilelearn.chaoxing.com/v2/apis/active/student/activelist';

    final timeStampMS = DateTime.now().millisecondsSinceEpoch.toString();
    final params = {
      'fid': '0',
      'courseId': courseId,
      'classId': classId,
      'showNotStartedActive': '0',
      '_': timeStampMS
    };

    final response = await ApiService.sendRequest(url, method: 'GET', params: params);
    return response?.data;
  }

  /// 获取合并处理后的活动列表
  Future<List<Active>?> getActiveList(String courseId, String classId, String cpi) async {
    final joinClassTime = await getJoinClassTime(courseId, classId, cpi) ?? '';
      
    final results = await Future.wait([
      getTaskActivityList(courseId, classId, cpi, joinClassTime),
      getTaskActivityListWeb(courseId, classId),
    ]);
      
    final taskData = results[0];
    final webTaskData = results[1];

    if (taskData == null || webTaskData == null) {
      return null;
    }

    List<Active> contentList = [];
    List<dynamic> activeList = taskData['activeList'];
    List<dynamic> webActiveList = webTaskData['data']['activeList'];

    Map<String, dynamic> activeMap = {
      for (var activeItem in webActiveList) activeItem['id'].toString(): activeItem
    };

    for (var activeData in activeList) {
      Active active = Active.fromJson(activeData);
      String activeId = activeData['id'].toString();

      if (activeMap.containsKey(activeId)) {
        var activeItem = activeMap[activeId];
        if (active.status) {
          if (active.description.isEmpty) {
            active.description = activeItem['nameFour'];
          }
        }

        if (active.activeType == ActiveType.signIn ||
            active.activeType == ActiveType.signOut) {
          final otherId = activeItem['otherId'];
          if (otherId != null) {
            try {
              active.signType = getSignTypeFromIndex(int.parse(otherId));
            } catch (e) {
              debugPrint('解析 otherId 失败：$otherId, 错误：$e');
            }
          }
        }
      }
      contentList.add(active);
    }

    return contentList;
  }
}

class RCCourseApi extends Api {
  RCCourseApi([super.user]);

  // userId -> [bearerToken, lessonToken]
  static final Map<String, List<String>> _tokens = {};

  /// 获取当前用户的 bearerToken
  String? get bearerToken => _tokens[user!.uid]?[0];

  String? get lessonToken => _tokens[user!.uid]?[1];

  void _setToken(String bearerToken, String lessonToken) {
    _tokens[user!.uid] = [bearerToken, lessonToken];
  }

  static Future<Map<String, dynamic>?> getCourses() async {
    final url = '/v/course_meta/learning_list/';
    final response = await ApiService.sendRequest(url);
    return response?.data;
  }

  /// 获取正在上课的课程
  static Future<List<dynamic>?> getOnLesson() async {
    // final url = '/api/v3/classroom/on-lesson-upcoming-exam';
    final url = '/api/v3/classroom/on-lesson';
    final response = await ApiService.sendRequest(url);
    if (response?.data['code'] == 0){
      return response?.data['data']['onLessonClassrooms'];
    }
    return null;
  }

  /// 获取处理后的课程列表
  static Future<List<Course>?> getCoursesList([List<dynamic>? onLessonCourses]) async {
    late Map<String, dynamic>? courses;
    if (onLessonCourses == null) {
      final results = await Future.wait([getCourses(), getOnLesson()]);
      courses = results[0] as Map<String, dynamic>?;
      onLessonCourses = results[1] as List<dynamic>?;
    } else {
      courses = await getCourses();
    }

    if (courses == null || onLessonCourses == null) {
      return null;
    }
    if (courses['data'].isEmpty || courses['data'].isEmpty) {
      return null;
    }

    Map<String, dynamic> coursesMap = {
      for (var courseItem in courses['data']) courseItem['course_id'].toString(): courseItem
    };

    List<Course> contentList = [];

    for (var onLessonCourseItem in onLessonCourses){
      final String courseId = onLessonCourseItem['courseId'];
      if (coursesMap.containsKey(courseId)) {
        var courseItem = coursesMap[courseId];
        courseItem['lesson_id'] = onLessonCourseItem['lessonId'];
        final courseObject = Course.fromRCJson(courseItem);
        contentList.add(courseObject);
      }
    }

    return contentList;
  }

  /// 获取**全部**课程（不 join「正在上课」）
  ///
  /// 与 [getCoursesList] 的区别：那个只遍历 `on-lesson` 返回的课，也就是
  /// **当前正在上课**的课（课程 tab 的空态文案「暂无正在上课的课程」即由此而来），
  /// `lessonId` 也只有那些课才有。
  ///
  /// 但 `/v/course_meta/learning_list/` 返回的 `courses['data']` 本来就是
  /// **我这学期选过的全部课程** —— 只是被 join 过滤掉了。课件页需要全量，
  /// 所以这里不 join，直接全转。
  ///
  /// ⚠️ 这样拿到的 `Course.lessonId` 恒为 `null`（`lesson_id` 只有正在上课的课
  /// 才有）。课件页与缓存目录的关联必须**走 `courseId`**，见
  /// `CourseCache.findLessonIdsByCourseId`。
  static Future<List<Course>?> getAllCourses() async {
    final courses = await getCourses();
    if (courses == null) return null;

    final data = courses['data'];
    if (data is! List || data.isEmpty) return null;

    final list = <Course>[];
    for (final item in data) {
      if (item is! Map) continue;
      try {
        list.add(Course.fromRCJson(Map<String, dynamic>.from(item)));
      } catch (e) {
        debugPrint('解析课程失败：$e');
      }
    }
    return list.isEmpty ? null : list;
  }

  Future<int?> checkIn(String lessonId) async {
    final url = '/api/v3/lesson/checkin';
    final jsonData = {
      'source': 21,
      'lessonId': lessonId,
      'joinIfNotIn': true
    };
    final response = await ApiService.sendRequest(url, method: 'POST', body: jsonData, userId: user?.uid);
    if (response == null) return null;
    
    final data = response.data;
    final int code = data['code'];
    if (code == 0) {
      final bearerToken = response.headers.value('set-auth')!;
      final lessonToken = data['data']['lessonToken'];
      _setToken(bearerToken, lessonToken);
      return 0;
    } else {
      return code;
    }
  }

  Future<int?> scan(String qrCodeUrl) async {
    final url = '/api/v3/app/scan';
    final jsonData = {'url': qrCodeUrl};
    final response = await ApiService.sendRequest(url, method: 'POST', body: jsonData, userId: user?.uid);
    if (response == null) return null;
    
    final data = response.data;
    final int code = data['code'];
    if (code == 0) {
      final lessonId = data['data']['value'];
      final response = await checkIn(lessonId);
      return response;
    } else {
      return code;
    }
  }

  Future<Map<String, dynamic>?> getPresentation(String presentationId) async {
    final url = '/api/v3/lesson/presentation/fetch?presentation_id=$presentationId';
    if (bearerToken == null) {
      return null;
    }
    final headers = {'authorization': 'Bearer $bearerToken'};
    final response = await ApiService.sendRequest(url, headers: headers, userId: user?.uid);
    return response?.data['data'];
  }

  /// 提交答案
  Future<Map<String, dynamic>?> answer(String problemId, int problemType,
      {bool retry = false, int? time, List<String>? options, String? content, List<String>? imageUrls}) async {
    final url = retry ?
    '/api/v3/lesson/problem/retry' : '/api/v3/lesson/problem/answer';
    if (bearerToken == null) {
      return null;
    }
    final headers = {'authorization': 'Bearer $bearerToken'};
    final timeStampMS = time ?? DateTime.now().millisecondsSinceEpoch;
    late dynamic result;
    if (problemType == 5) {
      var pics = [];
      if (imageUrls != null) {
        for (var imageUrl in imageUrls) {
          pics.add({
            'pic': imageUrl,
            'thumb': '$imageUrl?imageView2/2/w/568'
          });
        }
      } else {
        pics = [{'pic': '', 'thumb': ''}];
      }
      result = {'content': content ?? '', 'pics': pics, 'videos': []};
    } else {
      result = options;
    }
    var jsonData = {
      'problemId': problemId,
      'dt': timeStampMS,
      'problemType': problemType,
      'result': result
    };
    if (retry) {
      jsonData['retry_times'] = null;
      jsonData = {'problems': [jsonData]};
    }
    final response = await ApiService.sendRequest(url, method: 'POST', headers: headers, body: jsonData, userId: user?.uid);
    return response?.data;
  }
}