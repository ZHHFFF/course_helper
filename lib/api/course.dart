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

  /// 答题请求的请求头。
  ///
  /// ⚠️⚠️ `Content-Type` 必须显式写成 JSON，**不能省**。
  ///
  /// 踩过的坑（真机 bug：多选题预选了多个，实际只提交了一个）：
  /// 这里原来只有 `authorization`，Dio 看到 body 是 `Map` 又没有 JSON
  /// content-type，就按 `application/x-www-form-urlencoded` 编码。于是
  /// `result: ['A','B']` 被展平成 `result=A&result=B`（重复参数），
  /// 服务端按标量绑定 `result` → **只取到第一个 'A'**，第二个选项直接丢了。
  ///
  /// 单选之所以一直正常，是因为 `result=['A']` 编成 `result=A`，
  /// 表单和 JSON 两种写法服务端都能吃 —— 所以这个坑只在多选暴露。
  ///
  /// 实测（`test/rc_answer_body_test.dart` 钉住了这个行为）：
  /// ```text
  /// 不加 → problemId=p1&dt=...&problemType=2&result=A&result=B
  /// 加了 → {"problemId":"p1","dt":...,"problemType":2,"result":["A","B"]}
  /// ```
  /// 后者才和已知可用的雨课堂实现一致（`result` 是选项字母数组）。
  ///
  /// 抽成静态方法是为了能被单测直接断言 —— 这行漏掉的表现是「静默少交选项」，
  /// 界面上完全看不出来，只能靠测试兜。
  static Map<String, String> answerHeaders(String bearerToken) => {
        'authorization': 'Bearer $bearerToken',
        'Content-Type': 'application/json',
      };

  /// 构造答题请求体（纯函数，便于单测）。
  ///
  /// 选择题（含多选）的 `result` 必须是**选项 key 的数组**，不能是拼接字符串 ——
  /// 服务端就是按数组解析的。`retry` 时外面再包一层 `{'problems': [...]}`。
  static Map<String, dynamic> buildAnswerBody({
    required String problemId,
    required int problemType,
    required int timestampMs,
    List<String>? options,
    String? content,
    List<String>? imageUrls,
    bool retry = false,
  }) {
    dynamic result;
    if (problemType == 5) {
      // 简答题：content + 图片
      var pics = <Map<String, String>>[];
      if (imageUrls != null) {
        for (final imageUrl in imageUrls) {
          pics.add({
            'pic': imageUrl,
            'thumb': '$imageUrl?imageView2/2/w/568',
          });
        }
      } else {
        pics = [
          {'pic': '', 'thumb': ''}
        ];
      }
      result = {'content': content ?? '', 'pics': pics, 'videos': []};
    } else {
      result = options;
    }

    Map<String, dynamic> jsonData = {
      'problemId': problemId,
      'dt': timestampMs,
      'problemType': problemType,
      'result': result,
    };
    if (retry) {
      jsonData['retry_times'] = null;
      jsonData = {
        'problems': [jsonData]
      };
    }
    return jsonData;
  }

  /// 提交答案
  Future<Map<String, dynamic>?> answer(String problemId, int problemType,
      {bool retry = false, int? time, List<String>? options, String? content, List<String>? imageUrls}) async {
    final url = retry ?
    '/api/v3/lesson/problem/retry' : '/api/v3/lesson/problem/answer';
    if (bearerToken == null) {
      return null;
    }
    final headers = answerHeaders(bearerToken!);
    final jsonData = buildAnswerBody(
      problemId: problemId,
      problemType: problemType,
      timestampMs: time ?? DateTime.now().millisecondsSinceEpoch,
      options: options,
      content: content,
      imageUrls: imageUrls,
      retry: retry,
    );
    final response = await ApiService.sendRequest(url, method: 'POST', headers: headers, body: jsonData, userId: user?.uid);
    return response?.data;
  }
}