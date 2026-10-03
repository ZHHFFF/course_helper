import 'package:course_helper/api/api_service.dart';
import 'package:course_helper/api/course.dart';
import 'package:course_helper/models/user.dart';
import 'package:course_helper/platform.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/cache_test_env.dart';
import 'support/json_http_adapter.dart';

void main() {
  late CacheTestEnv env;
  late RCCourseApi api;
  late RequestOptions request;
  var response = <String, dynamic>{};
  final endpoints = <String, Future<Map<String, dynamic>?> Function()>{
    '/api/v3/lesson/presentation/fetch?presentation_id=p': () =>
        api.getPresentation('p'),
    '/api/v3/lesson-summary/student?lesson_id=l': () =>
        api.getLessonSummary('l'),
    '/api/v3/lesson-summary/student/presentation?presentation_id=p&lesson_id=l':
        () => api.getLessonSummaryPresentation('p', 'l'),
    '/api/v3/classroom-report/student/lesson-info?lesson_id=l&lessonId=l': () =>
        api.getClassroomReportLessonInfo('l'),
    '/v2/api/web/lessonafter/presentation/p?classroom_id=c': () =>
        api.getLessonAfterPresentationDetail('p', 'c'),
    '/v2/api/web/cards/detlist/w?classroom_id=c': () =>
        api.getCardsDetList('w', 'c'),
  };

  setUp(() async {
    env = await CacheTestEnv.create();
    PlatformManager.debugReset();
    RCCourseApi.debugClearTokens();
    await ApiService.initialize();
    api = RCCourseApi(
      User(
        uid: 'request-owner',
        name: '',
        avatar: '',
        phone: '',
        school: '',
        platform: 'rainClassroom',
      ),
    );
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((options) async {
        request = options;
        return response;
      }),
    );
  });
  tearDown(() async {
    RCCourseApi.debugClearTokens();
    PlatformManager.debugReset();
    await env.dispose();
  });

  for (final endpoint in endpoints.entries) {
    test('${endpoint.key}: 保留 URL、GET、账号和每次读取的 bearer', () async {
      response = {
        'code': 0,
        'data': {'slides': []},
      };
      expect(await endpoint.value(), {'slides': []});
      expect(request.path, endpoint.key);
      expect(request.method, 'GET');
      expect(request.extra['userId'], 'request-owner');
      expect(request.headers['xtbz'], 'ykt');
      expect(request.headers.containsKey('authorization'), isFalse);

      for (final token in ['first', 'second']) {
        api.debugStoreTokensForLesson('l', token, 'lesson-token');
        await endpoint.value();
        expect(request.headers['authorization'], 'Bearer $token');
      }
    });

    test('${endpoint.key}: 缺省 code 和坏 data 的兼容契约', () async {
      for (final body in [
        {
          'code': 0,
          'data': {'id': 7},
        },
        {
          'data': {'id': 7},
        },
        {
          'code': null,
          'data': {'id': 7},
        },
      ]) {
        response = body;
        expect(await endpoint.value(), {'id': 7});
      }
      for (final body in <Map<String, dynamic>>[
        {},
        {
          'code': 1,
          'data': {'id': 7},
        },
        {
          'code': '0',
          'data': {'id': 7},
        },
        {'code': 0, 'data': null},
        {'code': 0, 'data': []},
        {'code': 0, 'data': 'invalid'},
      ]) {
        response = body;
        expect(await endpoint.value(), isNull);
      }
    });
  }
}
