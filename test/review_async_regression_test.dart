import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/api/api_service.dart';
import 'package:course_helper/pages/courses/list.dart';
import 'package:course_helper/pages/courses/content.dart';
import 'package:course_helper/pages/courses/settings.dart';
import 'package:course_helper/pages/actives/evaluate.dart';
import 'package:course_helper/pages/actives/questionnaire.dart';
import 'package:course_helper/pages/actives/quiz.dart';
import 'package:course_helper/pages/actives/sign_in/sign_in.dart';
import 'package:course_helper/pages/actives/topic_discuss.dart';
import 'package:course_helper/pages/actives/vote.dart';
import 'package:course_helper/models/active.dart';
import 'package:course_helper/pages/login.dart';
import 'package:course_helper/pages/presentation.dart';
import 'package:course_helper/session/account.dart';
import 'package:course_helper/utils/storage.dart';

import 'support/classroom_test_env.dart';
import 'support/json_http_adapter.dart';

Map<String, dynamic> _courses(String name) => {
  'result': 1,
  'channelList': [
    {
      'content': {
        'id': name,
        'cpi': '',
        'state': 0,
        'course': {
          'data': [
            {'id': name, 'name': name},
          ],
        },
      },
    },
  ],
};

void main() {
  late ClassroomTestEnv env;
  setUp(() async => env = await ClassroomTestEnv.create());
  tearDown(() async => env.dispose());

  testWidgets('课堂 A 尚未返回时切到 B，最终显示 B 的页数', (tester) async {
    final a = Completer<Map<String, dynamic>>();
    final b = Completer<Map<String, dynamic>>();
    final requested = <String>[];
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((options) {
        final id = options.uri.queryParameters['presentation_id']!;
        requested.add(id);
        return id == 'A' ? a.future : b.future;
      }),
    );
    await tester.pumpWidget(
      classroomTestApp(const PresentationPage(lessonId: 'lesson', title: '课堂')),
    );
    await flushClassroomTasks(tester);
    final dynamic state = tester.state(find.byType(PresentationPage));
    final Future<void> first = state.debugHandleMessage({
      'op': 'hello',
      'presentation': 'A',
      'slideindex': 1,
    });
    await flushClassroomTasks(tester);
    final Future<void> second = state.debugHandleMessage({
      'op': 'showpresentation',
      'presentation': 'B',
      'slideindex': 2,
    });
    await flushClassroomTasks(tester);
    b.complete(emptyPresentationResponse(3));
    await flushClassroomTasks(tester);
    a.complete(emptyPresentationResponse(1));
    await flushClassroomTasks(tester);
    await Future.wait([first, second]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(requested, contains('B'));
    expect(find.textContaining('2/3', findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  });

  testWidgets('较早的课程请求后返回，不能覆盖刷新后的新课程', (tester) async {
    final first = Completer<Map<String, dynamic>>();
    final second = Completer<Map<String, dynamic>>();
    var requests = 0;
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((_) => ++requests == 1 ? first.future : second.future),
    );
    AccountManager.setCurrentSessionTemp('uid');
    await tester.pumpWidget(classroomTestApp(const CoursesPage()));
    await flushClassroomTasks(tester);
    final dynamic state = tester.state(find.byType(CoursesPage));
    state.refreshCourses();
    await flushClassroomTasks(tester);
    second.complete(_courses('新课程'));
    await flushClassroomTasks(tester);
    first.complete(_courses('旧课程'));
    await flushClassroomTasks(tester);
    await tester.pump();
    expect(find.text('新课程'), findsOneWidget);
    expect(find.text('旧课程'), findsNothing);
  });

  testWidgets('加载课件期间收到更新页码，完成后实际停在最新页', (tester) async {
    final response = Completer<Map<String, dynamic>>();
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((_) => response.future),
    );
    await tester.pumpWidget(
      classroomTestApp(const PresentationPage(lessonId: 'lesson', title: '课堂')),
    );
    await flushClassroomTasks(tester);
    final dynamic state = tester.state(find.byType(PresentationPage));
    final Future<void> loading = state.debugHandleMessage({
      'op': 'hello',
      'presentation': 'A',
      'slideindex': 1,
    });
    await flushClassroomTasks(tester);
    await state.debugHandleMessage({'op': 'slide', 'slideindex': 3});
    await tester.pump();
    response.complete(emptyPresentationResponse(4));
    await flushClassroomTasks(tester);
    await loading;
    await tester.pump(const Duration(milliseconds: 400));
    final pager = tester.widget<PageView>(find.byType(PageView));
    expect(pager.controller!.page, 2);
    expect(find.textContaining('3/4', findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await flushClassroomTasks(tester);
  });

  testWidgets('课程静默刷新网络失败时保留已显示的课程', (tester) async {
    var requests = 0;
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((_) async {
        if (++requests == 1) return _courses('已有课程');
        throw DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.connectionError,
        );
      }),
    );
    AccountManager.setCurrentSessionTemp('uid');
    await tester.pumpWidget(classroomTestApp(const CoursesPage()));
    await flushClassroomTasks(tester);
    expect(find.text('已有课程'), findsOneWidget);
    final dynamic state = tester.state(find.byType(CoursesPage));
    state.updateWithOnLessonCourses(<Map<String, dynamic>>[]);
    await flushClassroomTasks(tester);
    expect(find.text('已有课程'), findsOneWidget);
  });

  testWidgets('手动刷新与相同数据的静默刷新重叠时必须退出 loading', (tester) async {
    final pending = Completer<Map<String, dynamic>>();
    var requests = 0;
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((_) async {
        if (++requests == 2) return pending.future;
        return _courses('已有课程');
      }),
    );
    AccountManager.setCurrentSessionTemp('uid');
    await tester.pumpWidget(classroomTestApp(const CoursesPage()));
    await flushClassroomTasks(tester);
    final dynamic state = tester.state(find.byType(CoursesPage));
    state.refreshCourses();
    await flushClassroomTasks(tester);
    state.updateWithOnLessonCourses(<Map<String, dynamic>>[]);
    await flushClassroomTasks(tester);
    pending.complete(_courses('已有课程'));
    await flushClassroomTasks(tester);
    expect(find.text('已有课程'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  Active active(int type) => Active(
    type: type,
    id: 'activity',
    name: '活动',
    description: '',
    startTime: 0,
    url: 'https://example.test/quiz',
    attendNum: 0,
    status: true,
    signType: SignType.normal,
    extras: {'topicId': 'topic'},
  );

  final activityPages = <String, Widget Function()>{
    '课程内容': () => const CourseContentPage(
      courseId: 'course',
      courseName: '课程',
      classId: 'class',
      cpi: '',
    ),
    '投票': () =>
        VotePage(active: active(43), courseId: 'course', classId: 'class'),
    '评分': () =>
        EvaluatePage(active: active(23), courseId: 'course', classId: 'class'),
    '问卷': () => QuestionnairePage(
      active: active(14),
      courseId: 'course',
      classId: 'class',
    ),
    '测验': () =>
        QuizPage(active: active(42), courseId: 'course', classId: 'class'),
    '讨论': () => Material(
      type: MaterialType.transparency,
      child: TopicDiscussPage(active: active(5)),
    ),
    '签到': () => SignInPage(
      active: active(2),
      courseId: 'course',
      classId: 'class',
      cpi: '',
    ),
  };
  for (final entry in activityPages.entries) {
    testWidgets('${entry.key}请求尚未完成时返回，迟到响应不能 setState', (tester) async {
      await StorageManager.prefs.setString(
        'chaoxing_accounts',
        jsonEncode([
          {'uid': 'uid', 'name': '用户'},
        ]),
      );
      await AccountManager.initialize();
      AccountManager.setCurrentSessionTemp('uid');
      final response = Completer<Map<String, dynamic>>();
      var requests = 0;
      ApiService.debugSetHttpClientAdapter(
        JsonHttpAdapter((_) {
          requests++;
          return response.future;
        }),
      );
      await tester.pumpWidget(classroomTestApp(entry.value()));
      await flushClassroomTasks(tester);
      expect(requests, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      response.complete({});
      await flushClassroomTasks(tester);
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in <String, Widget Function()>{
    '主题讨论': () => TopicDiscussPage(active: active(5)),
    '课程设置': () => const CourseSettingsPage(courseId: 'course'),
  }.entries) {
    testWidgets('${entry.key}作为独立路由时输入框必须有 Material 宿主', (tester) async {
      await tester.pumpWidget(classroomTestApp(entry.value()));
      await flushClassroomTasks(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('二维码请求期间离开登录页不能再弹出对话框', (tester) async {
    final response = Completer<Map<String, dynamic>>();
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((_) => response.future),
    );
    await tester.pumpWidget(
      classroomTestApp(const LoginPage(initialLoginType: 'qrcode')),
    );
    await flushClassroomTasks(tester);
    await tester.pumpWidget(const SizedBox());
    response.complete({'uuid': 'qr', 'enc': 'enc'});
    await flushClassroomTasks(tester);
    expect(tester.takeException(), isNull);
  });

  test('二维码授权响应晚于 dispose 时不能回调登录成功', () async {
    final authorization = Completer<Map<String, dynamic>>();
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((options) async {
        if (options.path.contains('refreshQRCode')) {
          return {'uuid': 'qr', 'enc': 'enc'};
        }
        return authorization.future;
      }),
    );
    final qr = QRCodeLoginState();
    expect(await qr.initialize(), isTrue);
    var completions = 0;
    qr.startPolling((_) => completions++);
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    qr.dispose();
    authorization.complete({'status': true});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(completions, 0);
  });
}
