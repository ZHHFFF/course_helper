import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:course_helper/api/api_service.dart';
import 'package:course_helper/cache/course_cache.dart';
import 'package:course_helper/pages/presentation.dart';
import 'package:course_helper/pages/login.dart';
import 'package:course_helper/pages/courses/list.dart';
import 'package:course_helper/platform.dart';
import 'package:course_helper/session/account.dart';
import 'package:course_helper/utils/storage.dart';

import 'support/cache_test_env.dart';

class _Adapter implements HttpClientAdapter {
  final Future<Map<String, dynamic>> Function(RequestOptions) respond;
  _Adapter(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(await respond(options)),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
  @override
  void close({bool force = false}) {}
}

Widget _app(Widget child) => MaterialApp(
  home: MiuixTheme(data: MiuixThemeData.light(), child: child),
);

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
}

Map<String, dynamic> _ppt(int pages) => {
  'code': 0,
  'data': {
    'slides': [
      for (var i = 0; i < pages; i++) {'index': i + 1},
    ],
  },
};

void main() {
  late CacheTestEnv env;
  setUp(() async {
    env = await CacheTestEnv.create();
    PlatformManager.debugReset();
    await AccountManager.initialize();
    await ApiService.initialize();
    await PlatformManager().initialize();
    await CourseCache.root();
  });
  tearDown(() async {
    AccountManager.setCurrentSessionTemp(null);
    PlatformManager.debugReset();
    await env.dispose();
  });

  for (final op in ['hello', 'showpresentation']) {
    testWidgets('切换新课件不能丢弃 $op 携带的课堂历史题目', (tester) async {
      final a = Completer<Map<String, dynamic>>();
      final b = Completer<Map<String, dynamic>>();
      ApiService.debugSetHttpClientAdapter(
        _Adapter(
          (options) => options.uri.queryParameters['presentation_id'] == 'A'
              ? a.future
              : b.future,
        ),
      );
      await tester.pumpWidget(
        _app(const PresentationPage(lessonId: 'lesson', title: '课堂')),
      );
      await _flush(tester);
      final dynamic state = tester.state(find.byType(PresentationPage));
      final Future<void> first = state.debugHandleMessage({
        'op': op,
        'presentation': 'A',
        'slideindex': 1,
        'timeline': [
          {
            'type': 'problem',
            'prob': 'old-problem',
            'pres': 'A',
            'si': 1,
            'dt': DateTime.now().millisecondsSinceEpoch,
          },
        ],
      });
      await _flush(tester);
      final Future<void> second = state.debugHandleMessage({
        'op': 'showpresentation',
        'presentation': 'B',
        'slideindex': 2,
      });
      await _flush(tester);
      b.complete(_ppt(3));
      await _flush(tester);
      a.complete({
        'code': 0,
        'data': {
          'slides': [
            {
              'index': 1,
              'problem': {
                'problemId': 'old-problem',
                'problemType': 1,
                'body': '历史题目正文',
              },
            },
          ],
        },
      });
      await _flush(tester);
      await Future.wait([first, second]);
      await tester.pump(const Duration(milliseconds: 400));
      final hasHistory = find.text('题目发布').evaluate().isNotEmpty;
      final showsLatest = find
          .textContaining('2/3', findRichText: true)
          .evaluate()
          .isNotEmpty;
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        1,
      );
      var canOpenHistory = false;
      if (hasHistory) {
        await tester.tap(find.text('题目发布'));
        await _flush(tester);
        await tester.pump(const Duration(milliseconds: 400));
        canOpenHistory = find.text('历史题目正文').evaluate().isNotEmpty;
      }
      await tester.pumpWidget(const SizedBox());
      await _flush(tester);
      expect(showsLatest, isTrue);
      expect(hasHistory, isTrue, reason: '$op 中的历史题目应保留，不随旧课件加载取消而消失');
      expect(canOpenHistory, isTrue, reason: '历史条目必须可以打开原题目');
    });
  }

  testWidgets('同 PPT 重复消息不能因后一请求失败而丢弃前一成功响应', (tester) async {
    final firstResponse = Completer<Map<String, dynamic>>();
    final secondResponse = Completer<Map<String, dynamic>>();
    var requests = 0;
    ApiService.debugSetHttpClientAdapter(
      _Adapter(
        (_) => ++requests == 1 ? firstResponse.future : secondResponse.future,
      ),
    );
    await tester.pumpWidget(
      _app(const PresentationPage(lessonId: 'lesson', title: '课堂')),
    );
    await _flush(tester);
    final dynamic state = tester.state(find.byType(PresentationPage));
    final Future<void> first = state.debugHandleMessage({
      'op': 'hello',
      'presentation': 'A',
      'slideindex': 1,
    });
    await _flush(tester);
    final Future<void> second = state.debugHandleMessage({
      'op': 'showpresentation',
      'presentation': 'A',
      'slideindex': 2,
    });
    await _flush(tester);
    secondResponse.complete({'code': 1});
    await _flush(tester);
    firstResponse.complete(_ppt(3));
    await _flush(tester);
    await Future.wait([first, second]);
    await tester.pump(const Duration(milliseconds: 400));
    final showsLatest = find
        .textContaining('2/3', findRichText: true)
        .evaluate()
        .isNotEmpty;
    final actualPage = find.byType(PageView).evaluate().isEmpty
        ? null
        : tester.widget<PageView>(find.byType(PageView)).controller!.page;
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(showsLatest, isTrue, reason: '同一 PPT 已有成功响应，最新页码必须仍可显示');
    expect(actualPage, 1);
    expect(requests, 1, reason: '重复控制消息共用尚未结束的同 PPT 请求');
  });

  testWidgets('重复课件消息期间更晚的独立翻页仍优先', (tester) async {
    final response = Completer<Map<String, dynamic>>();
    ApiService.debugSetHttpClientAdapter(_Adapter((_) => response.future));
    await tester.pumpWidget(
      _app(const PresentationPage(lessonId: 'lesson', title: '课堂')),
    );
    await _flush(tester);
    final dynamic state = tester.state(find.byType(PresentationPage));
    final Future<void> first = state.debugHandleMessage({
      'op': 'hello',
      'presentation': 'A',
      'slideindex': 1,
    });
    final Future<void> second = state.debugHandleMessage({
      'op': 'showpresentation',
      'presentation': 'A',
      'slideindex': 2,
    });
    await _flush(tester);
    await state.debugHandleMessage({'op': 'slide', 'slideindex': 3});
    response.complete(_ppt(4));
    await _flush(tester);
    await Future.wait([first, second]);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(find.textContaining('3/4', findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
  });

  testWidgets('A B A 快速切换复用等待中的 A 并停在最后指定页', (tester) async {
    final a = Completer<Map<String, dynamic>>();
    final b = Completer<Map<String, dynamic>>();
    final requests = <String>[];
    ApiService.debugSetHttpClientAdapter(
      _Adapter((options) {
        final id = options.uri.queryParameters['presentation_id']!;
        requests.add(id);
        return id == 'A' ? a.future : b.future;
      }),
    );
    await tester.pumpWidget(
      _app(const PresentationPage(lessonId: 'lesson', title: '课堂')),
    );
    await _flush(tester);
    final dynamic state = tester.state(find.byType(PresentationPage));
    final Future<void> first = state.debugHandleMessage({
      'op': 'hello',
      'presentation': 'A',
      'slideindex': 1,
    });
    await _flush(tester);
    final Future<void> second = state.debugHandleMessage({
      'op': 'showpresentation',
      'presentation': 'B',
      'slideindex': 1,
    });
    await _flush(tester);
    final Future<void> last = state.debugHandleMessage({
      'op': 'showpresentation',
      'presentation': 'A',
      'slideindex': 3,
    });
    await _flush(tester);
    b.complete(_ppt(1));
    await _flush(tester);
    a.complete(_ppt(4));
    await _flush(tester);
    await Future.wait([first, second, last]);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(find.textContaining('3/4', findRichText: true), findsOneWidget);
    expect(requests, ['A', 'B']);
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
  });

  testWidgets('账号切换后旧账号的在线课堂轮询响应不能覆盖新课程', (tester) async {
    await PlatformManager().setPlatform(PlatformType.rainClassroom);
    AccountManager.setCurrentSessionTemp('old');
    final oldPoll = Completer<Map<String, dynamic>>();
    var onLessonRequests = 0;
    ApiService.debugSetHttpClientAdapter(
      _Adapter((options) async {
        if (options.path.endsWith('/on-lesson')) {
          if (++onLessonRequests == 2) return oldPoll.future;
          final uid = options.extra['userId'];
          return {
            'code': 0,
            'data': {
              'onLessonClassrooms': [
                {'courseId': '$uid-course', 'lessonId': '$uid-lesson'},
              ],
            },
          };
        }
        final uid = options.extra['userId'];
        return {
          'data': [
            {
              'course_id': '$uid-course',
              'classroom_id': '$uid-class',
              'course_name': uid == 'new' ? '新账号课程' : '旧账号课程',
            },
          ],
        };
      }),
    );
    await tester.pumpWidget(_app(const CoursesPage()));
    await _flush(tester);
    final dynamic state = tester.state(find.byType(CoursesPage));
    state.onVisibilityChanged(true);
    await tester.pump(const Duration(seconds: 3));
    await _flush(tester);
    expect(onLessonRequests, 2);
    AccountManager.setCurrentSessionTemp('new');
    AccountChangeNotifier().notifyAccountChanged();
    await _flush(tester);
    expect(find.text('新账号课程'), findsOneWidget);
    oldPoll.complete({
      'code': 0,
      'data': {
        'onLessonClassrooms': [
          {'courseId': 'old-course', 'lessonId': 'old-lesson'},
        ],
      },
    });
    await _flush(tester);
    final newCourseVisible = find.text('新账号课程').evaluate().isNotEmpty;
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(newCourseVisible, isTrue, reason: '旧账号轮询响应不能生成新代次刷新并清空新账号课程');
  });

  testWidgets('重叠轮询中先发后到的响应不能清空仍在上课的课程', (tester) async {
    await PlatformManager().setPlatform(PlatformType.rainClassroom);
    AccountManager.setCurrentSessionTemp('uid');
    final oldPoll = Completer<Map<String, dynamic>>();
    var onLessonRequests = 0;
    ApiService.debugSetHttpClientAdapter(
      _Adapter((options) async {
        if (options.path.endsWith('/on-lesson')) {
          if (++onLessonRequests == 3) return oldPoll.future;
          return {
            'code': 0,
            'data': {
              'onLessonClassrooms': [
                {'courseId': 'course', 'lessonId': 'lesson'},
              ],
            },
          };
        }
        return {
          'data': [
            {
              'course_id': 'course',
              'classroom_id': 'class',
              'course_name': '正在上课的课程',
            },
          ],
        };
      }),
    );
    await tester.pumpWidget(_app(const CoursesPage()));
    await _flush(tester);
    final dynamic state = tester.state(find.byType(CoursesPage));
    state.onVisibilityChanged(true);
    // 第一轮建立在线课堂快照；下一轮慢响应与后续不变的快响应重叠。
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 3));
      await _flush(tester);
    }
    expect(onLessonRequests, 4);
    expect(find.text('正在上课的课程'), findsOneWidget);
    oldPoll.complete({
      'code': 0,
      'data': {'onLessonClassrooms': []},
    });
    await _flush(tester);
    final currentCourseVisible = find.text('正在上课的课程').evaluate().isNotEmpty;
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(currentCourseVisible, isTrue);
  });

  testWidgets('静默刷新收到成功的空课程列表时必须清空旧课程', (tester) async {
    await PlatformManager().setPlatform(PlatformType.rainClassroom);
    AccountManager.setCurrentSessionTemp('uid');
    var empty = false;
    ApiService.debugSetHttpClientAdapter(
      _Adapter((options) async {
        if (options.path.endsWith('/on-lesson')) {
          return {
            'code': 0,
            'data': {
              'onLessonClassrooms': [
                {'courseId': 'course', 'lessonId': 'lesson'},
              ],
            },
          };
        }
        return {
          'data': empty
              ? []
              : [
                  {
                    'course_id': 'course',
                    'classroom_id': 'class',
                    'course_name': '旧课程',
                  },
                ],
        };
      }),
    );
    await tester.pumpWidget(_app(const CoursesPage()));
    await _flush(tester);
    expect(find.text('旧课程'), findsOneWidget);
    empty = true;
    final dynamic state = tester.state(find.byType(CoursesPage));
    state.updateWithOnLessonCourses(<Map<String, dynamic>>[]);
    await _flush(tester);
    final oldCourseVisible = find.text('旧课程').evaluate().isNotEmpty;
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(oldCourseVisible, isFalse, reason: '成功的空数据不能被 null 失败标记误判为网络失败');
  });

  testWidgets('二维码关闭后迟到的用户信息不能弹出用户新打开的页面', (tester) async {
    await PlatformManager().setPlatform(PlatformType.rainClassroom);
    const captcha = MethodChannel('flutter_tencent_captcha');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captcha, (_) async => true);
    const captchaEvents = MethodChannel(
      'flutter_tencent_captcha/event_channel',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(captchaEvents, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(captcha, null),
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(captchaEvents, null),
    );
    final profile = Completer<Map<String, dynamic>>();
    var profileRequests = 0;
    ApiService.debugSetHttpClientAdapter(
      _Adapter((options) async {
        if (options.path.endsWith('/pre-info')) {
          return {
            'code': 0,
            'data': {'token': 'qr'},
          };
        }
        if (options.path.endsWith('/user_info')) {
          profileRequests++;
          return profile.future;
        }
        return {'code': 0, 'data': <String, dynamic>{}};
      }),
    );
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.light(),
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('起始页面')),
        ),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const LoginPage(initialLoginType: 'qrcode'),
        ),
      ),
    );
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(profileRequests, 1);
    expect(find.text('二维码登录'), findsWidgets);
    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 400));
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('新打开的页面')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    profile.complete({
      'data': {
        'user_profile': {
          'user_id': 'uid',
          'name': '用户',
          'avatar': '',
          'avatar_96': '',
          'phone_number': '',
          'school': '',
        },
      },
    });
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 400));
    final newPageVisible = find.text('新打开的页面').evaluate().isNotEmpty;
    final cancelledAccountWasSaved =
        AccountManager.getAccountById('uid') != null;
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
    expect(newPageVisible, isTrue, reason: '已关闭的二维码流程不能 pop 后来打开的无关页面');
    expect(cancelledAccountWasSaved, isFalse, reason: '已取消的扫码流程不能继续落盘新增账号');
  });

  testWidgets('正常扫码仍保存账号并关闭二维码对话框', (tester) async {
    await PlatformManager().setPlatform(PlatformType.rainClassroom);
    const channels = [
      MethodChannel('flutter_tencent_captcha'),
      MethodChannel('flutter_tencent_captcha/event_channel'),
    ];
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => true);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
    }
    final profile = Completer<Map<String, dynamic>>();
    ApiService.debugSetHttpClientAdapter(
      _Adapter((options) async {
        if (options.path.endsWith('/pre-info')) {
          return {
            'code': 0,
            'data': {'token': 'qr'},
          };
        }
        if (options.path.endsWith('/user_info')) return profile.future;
        return {'code': 0, 'data': <String, dynamic>{}};
      }),
    );
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.light(),
        child: const MaterialApp(home: LoginPage(initialLoginType: 'qrcode')),
      ),
    );
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      ModalRoute.of(tester.element(find.byType(LoginPage)))!.isCurrent,
      isFalse,
    );
    profile.complete({
      'data': {
        'user_profile': {
          'user_id': 'uid',
          'name': '用户',
          'avatar': '',
          'avatar_96': '',
          'phone_number': '',
          'school': '',
        },
      },
    });
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(AccountManager.getAccountById('uid')?.name, '用户');
    expect(
      StorageManager.prefs.getString('rainclassroom_accounts'),
      contains('uid'),
    );
    expect(find.byType(LoginPage), findsOneWidget);
    expect(
      ModalRoute.of(tester.element(find.byType(LoginPage)))!.isCurrent,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    await _flush(tester);
  });
}
