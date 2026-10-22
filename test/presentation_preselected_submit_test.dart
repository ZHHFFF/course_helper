import 'package:course_helper/api/api_service.dart';
import 'package:course_helper/api/course.dart';
import 'package:course_helper/models/user.dart';
import 'package:course_helper/pages/presentation.dart';
import 'package:course_helper/session/account.dart';
import 'package:course_helper/setting/auto_answer_setting.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/classroom_test_env.dart';
import 'support/json_http_adapter.dart';

void main() {
  late ClassroomTestEnv env;
  late List<Map<String, dynamic>> submissions;
  late Map<String, dynamic> slide;

  setUp(() async {
    env = await ClassroomTestEnv.create();
    RCCourseApi.debugClearTokens();
    await AutoAnswerSetting.ensureLoaded();
    await AutoAnswerSetting.setAutoSearch(false);
    await AutoAnswerSetting.setAutoSelect(false);
    await AutoAnswerSetting.setAutoSubmit(true);
    AutoAnswerSetting.delayMinMs.value = 0;
    AutoAnswerSetting.delayMaxMs.value = 0;
    submissions = [];
    slide = {
      'index': 1,
      'problem': {
        'problemId': 'p1',
        'problemType': 1,
        'body': '题目一',
        'options': [
          {'key': 'A', 'value': '选项一'},
          {'key': 'B', 'value': '选项二'},
        ],
      },
    };
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((options) async {
        if (options.path.contains('/problem/answer')) {
          submissions.add(Map<String, dynamic>.from(options.data as Map));
          return {'code': 0};
        }
        if (options.uri.queryParameters.containsKey('presentation_id')) {
          return {
            'code': 0,
            'data': {
              'slides': [
                slide,
                {
                  'index': 2,
                  'problem': {
                    'problemId': 'p2',
                    'problemType': 1,
                    'body': '题目二',
                    'options': [
                      {'key': 'A', 'value': '另一题选项'},
                    ],
                  },
                },
              ],
            },
          };
        }
        return {'code': 0};
      }),
    );
  });

  tearDown(() async {
    AccountManager.allAccounts.clear();
    RCCourseApi.debugClearTokens();
    AutoAnswerSetting.delayMinMs.value = 300;
    AutoAnswerSetting.delayMaxMs.value = 800;
    await env.dispose();
  });

  dynamic state(WidgetTester tester) =>
      tester.state(find.byType(PresentationPage));

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      classroomTestApp(const PresentationPage(lessonId: 'lesson', title: '课堂')),
    );
    await flushClassroomTasks(tester);
    final Future<void> loading = state(tester).debugHandleMessage({
      'op': 'hello',
      'presentation': 'ppt',
      'slideindex': 1,
    });
    await flushClassroomTasks(tester);
    await loading;
    await tester.pump(const Duration(milliseconds: 400));
    // 课件加载后才加入提交账号，避免测试触发真实签到和 WebSocket。
    final user = User.fromJson({'uid': 'test-user', 'platform': 'rainClassroom'});
    AccountManager.allAccounts.add(user);
    RCCourseApi(user).debugStoreTokensForLesson('lesson', 'bearer', 'lesson-token');
  }

  Future<void> select(WidgetTester tester, String value) async {
    tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
        .onChanged(value);
    await tester.pump();
  }

  Future<void> publish(WidgetTester tester) async {
    await state(tester).debugHandleMessage({
      'op': 'unlockproblem',
      'problem': {'prob': 'p1', 'limit': 60},
    });
    await flushClassroomTasks(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    await flushClassroomTasks(tester);
    expect(tester.takeException(), isNull);
  }

  testWidgets('无搜索缓存时直接提交预选答案，不等待搜索也不覆盖选项', (tester) async {
    await mount(tester);
    await select(tester, 'B');
    await publish(tester);
    expect(submissions, hasLength(1));
    expect(submissions.single['problemId'], 'p1');
    expect(submissions.single['result'], ['B']);
    await finish(tester);
  });

  testWidgets('扫描未收录的空题干题仍提交已选答案', (tester) async {
    (slide['problem'] as Map)['body'] = '';
    await mount(tester);
    await select(tester, 'B');
    await publish(tester);
    expect(submissions, hasLength(1));
    expect(submissions.single['result'], ['B']);
    await finish(tester);
  });

  testWidgets('翻到另一题后发布原题，恢复并提交原题预选答案', (tester) async {
    await mount(tester);
    await select(tester, 'B');
    await state(tester).debugHandleMessage({'op': 'slide', 'slideindex': 2});
    await tester.pump(const Duration(milliseconds: 400));
    await select(tester, 'A');
    await publish(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await flushClassroomTasks(tester);
    expect(submissions, hasLength(1));
    expect(submissions.single['problemId'], 'p1');
    expect(submissions.single['result'], ['B']);
    await finish(tester);
  });

  testWidgets('等待搜索期间手动选择答案，无缓存也能继续提交', (tester) async {
    await mount(tester);
    await publish(tester);
    expect(submissions, isEmpty);
    await select(tester, 'B');
    await tester.pump(const Duration(milliseconds: 500));
    await flushClassroomTasks(tester);
    expect(submissions, hasLength(1));
    expect(submissions.single['result'], ['B']);
    await finish(tester);
  });

  testWidgets('自动提交关闭时预选答案不触发请求', (tester) async {
    await mount(tester);
    await select(tester, 'B');
    await AutoAnswerSetting.setAutoSubmit(false);
    await publish(tester);
    expect(submissions, isEmpty);
    await finish(tester);
  });
}
