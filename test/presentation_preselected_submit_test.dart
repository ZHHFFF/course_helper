import 'package:course_helper/api/api_service.dart';
import 'package:course_helper/api/course.dart';
import 'package:course_helper/cache/answer_draft_store.dart';
import 'package:course_helper/cache/course_cache.dart';
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

  Future<void> reenter(WidgetTester tester) async {
    await finish(tester);
    await tester.runAsync(AnswerDraftStore.flush);
    AccountManager.allAccounts.clear();
    await mount(tester);
  }

  testWidgets('退出重进恢复预选答案，普通退出不标记课堂结束，恢复后可自动提交', (tester) async {
    await mount(tester);
    await select(tester, 'B');
    await reenter(tester);
    expect(await tester.runAsync(() => CourseCache.finishedAt('lesson')), isNull);
    expect(tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
        .groupValue, 'B');
    await publish(tester);
    expect(submissions, hasLength(1));
    expect(submissions.single['result'], ['B']);
    await finish(tester);
  });

  testWidgets('取消预选后退出重进，旧选项不能重新出现', (tester) async {
    await mount(tester);
    await select(tester, 'B');
    tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
        .onChanged(null);
    await tester.pump();
    await reenter(tester);
    expect(tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
        .groupValue, isNull);
    await finish(tester);
  });

  testWidgets('简答题重进恢复输入框和实际提交内容', (tester) async {
    (slide['problem'] as Map)['problemType'] = 5;
    await mount(tester);
    await tester.enterText(find.byType(TextField), '我核对后的答案');
    await reenter(tester);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '我核对后的答案');
    await publish(tester);
    expect(submissions.single['result']['content'], '我核对后的答案');
    await finish(tester);
  });

  testWidgets('多空填空题重进后各空按原顺序恢复', (tester) async {
    (slide['problem'] as Map)['problemType'] = 4;
    (slide['problem'] as Map)['body'] = '第一空[填空1]，第二空[填空2]';
    await mount(tester);
    await tester.enterText(find.byType(TextField).at(0), '答案一');
    await tester.enterText(find.byType(TextField).at(1), '答案二');
    await reenter(tester);
    expect(tester.widget<TextField>(find.byType(TextField).at(0))
        .controller!.text, '答案一');
    expect(tester.widget<TextField>(find.byType(TextField).at(1))
        .controller!.text, '答案二');
    await finish(tester);
  });

  testWidgets('服务端确认下课才清理草稿，退出重进不会写回旧答案', (tester) async {
    await mount(tester);
    await select(tester, 'B');
    final Future<void> ending = state(tester).debugHandleMessage({
      'op': 'hello', 'message': 'lesson finished',
    });
    await flushClassroomTasks(tester);
    await ending;
    final saved = await tester.runAsync(
      () => AnswerDraftStore.readLesson('lesson'),
    );
    expect(saved!.finished, isTrue);
    expect(saved.answers, isEmpty);
    await reenter(tester);
    expect(tester.widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
        .groupValue, isNull);
    await publish(tester);
    expect(submissions, isEmpty);
    await finish(tester);
  });

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
