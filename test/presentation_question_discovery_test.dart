import 'dart:async';

import 'package:course_helper/api/api_service.dart';
import 'package:course_helper/pages/presentation.dart';
import 'package:course_helper/pages/widget/courseware_question_details.dart';
import 'package:course_helper/pages/widget/courseware_question_discovery_card.dart';
import 'package:course_helper/setting/auto_answer_setting.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/classroom_test_env.dart';
import 'support/json_http_adapter.dart';

Map<String, dynamic> _ppt(String id, int pages, {int questionIndex = 1}) => {
  'code': 0,
  'data': {
    'title': '课件 $id',
    'slides': [
      for (var i = 0; i < pages; i++)
        {
          'index': 777 + i,
          if (i == questionIndex)
            'problem': {
              'problemId': 'problem-$id',
              'problemType': 1,
              'body': '题干 $id',
              'options': [
                {'key': 'A', 'value': '选项 $id'},
              ],
            },
        },
    ],
  },
};

void main() {
  late ClassroomTestEnv env;
  late Map<String, Map<String, dynamic>> ppts;
  late List<String> requests;
  setUp(() async {
    env = await ClassroomTestEnv.create();
    await AutoAnswerSetting.ensureLoaded();
    await AutoAnswerSetting.setAutoSearch(false);
    await AutoAnswerSetting.setAutoSelect(false);
    await AutoAnswerSetting.setAutoSubmit(true);
    ppts = {'A': _ppt('A', 3), 'B': _ppt('B', 4)};
    requests = [];
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((options) async {
        requests.add(options.path);
        final id = options.uri.queryParameters['presentation_id'];
        return ppts[id] ?? {'code': 1};
      }),
    );
  });
  tearDown(() async => env.dispose());

  dynamic state(WidgetTester tester) =>
      tester.state(find.byType(PresentationPage));

  Future<void> mount(WidgetTester tester, {String lesson = 'lesson'}) async {
    await tester.pumpWidget(
      classroomTestApp(
        Scaffold(
          body: PresentationPage(
            key: ValueKey(lesson),
            lessonId: lesson,
            title: '课堂',
          ),
        ),
      ),
    );
    await flushClassroomTasks(tester);
  }

  Future<void> showPpt(
    WidgetTester tester,
    String id,
    int page, {
    String op = 'showpresentation',
  }) async {
    final Future<void> pending = state(
      tester,
    ).debugHandleMessage({'op': op, 'presentation': id, 'slideindex': page});
    await flushClassroomTasks(tester);
    await pending;
    await tester.pump(const Duration(milliseconds: 400));
  }

  double? visiblePage(WidgetTester tester) =>
      tester.widget<PageView>(find.byType(PageView)).controller!.page;

  Future<void> openHint(WidgetTester tester, String id, {int? page}) async {
    final card = find.byWidgetPredicate(
      (widget) =>
          widget is CoursewareQuestionDiscoveryCard &&
          widget.batch.presentationId == id,
    );
    final hint = find.descendant(
      of: card,
      matching: find.textContaining(
        page == null ? '发现课件题目 · 第' : '发现课件题目 · 第 $page 页 ·',
      ),
    );
    await Scrollable.ensureVisible(tester.element(hint), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(hint);
    await tester.pumpAndSettle();
  }

  Future<void> jump(WidgetTester tester) async {
    await tester.tap(find.textContaining('跳转到第'));
    await flushClassroomTasks(tester);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // 教师发布事件原有的自动答题轮询在下一轮检查 mounted 后退出。
    await tester.pump(const Duration(milliseconds: 500));
    await flushClassroomTasks(tester);
    expect(tester.takeException(), isNull);
    expect(requests.where((url) => url.contains('/answer')), isEmpty);
  }

  testWidgets('整份识题、查看不改课堂；第86页严格使用下标85，跳页不解锁且教师页不变', (tester) async {
    ppts['A'] = _ppt('A', 86, questionIndex: 85);
    await mount(tester);
    await showPpt(tester, 'A', 1, op: 'hello');
    expect(find.text('发现课件题目 · 第 86 页 · 单选题'), findsOneWidget);
    expect(find.text('题目发布'), findsNothing);
    expect(visiblePage(tester), 0);
    await openHint(tester, 'A');
    expect(find.text('题干 A'), findsOneWidget);
    expect(find.text('A. 选项 A'), findsOneWidget);
    expect(visiblePage(tester), 0);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(visiblePage(tester), 0);
    await openHint(tester, 'A');
    await jump(tester);
    expect(visiblePage(tester), 85);
    expect(find.text('提交'), findsNothing);
    expect(find.textContaining('86/86', findRichText: true), findsOneWidget);
    await tester.tap(find.text('回到当前页'));
    await flushClassroomTasks(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(visiblePage(tester), 0);
    await finish(tester);
  });

  testWidgets('同PPT hello重连、重复控制和A/B/A重载均更新原提示，不新增重复条目', (tester) async {
    await mount(tester);
    await showPpt(tester, 'A', 1, op: 'hello');
    await showPpt(tester, 'A', 1, op: 'hello');
    await showPpt(tester, 'A', 1);
    expect(find.byType(CoursewareQuestionDiscoveryCard), findsOneWidget);
    await showPpt(tester, 'B', 1);
    await showPpt(tester, 'A', 1);
    final batches = tester
        .widgetList<CoursewareQuestionDiscoveryCard>(
          find.byType(CoursewareQuestionDiscoveryCard),
        )
        .map((widget) => widget.batch);
    expect(batches.map((batch) => batch.presentationId), ['A', 'B']);
    expect(batches.map((batch) => batch.questions.length), [1, 1]);
    await finish(tester);
  });

  testWidgets('历史提示保留自己的题干和课件，返回教师课件及教师原页', (tester) async {
    await mount(tester);
    await showPpt(tester, 'A', 1);
    await showPpt(tester, 'B', 3);
    await openHint(tester, 'A');
    expect(find.text('题干 A'), findsOneWidget);
    expect(find.text('题干 B'), findsNothing);
    expect(visiblePage(tester), 2);
    await jump(tester);
    expect(visiblePage(tester), 1);
    expect(find.textContaining('2/3', findRichText: true), findsOneWidget);
    expect(find.text('提交'), findsNothing);
    await tester.tap(find.text('回到当前页'));
    await flushClassroomTasks(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(visiblePage(tester), 2);
    expect(find.textContaining('3/4', findRichText: true), findsOneWidget);
    await finish(tester);
  });

  testWidgets('详情打开期间教师切换课件，详情仍是原快照，按钮仍可主动跳回原课件', (tester) async {
    await mount(tester);
    await showPpt(tester, 'A', 1);
    await openHint(tester, 'A');
    await showPpt(tester, 'B', 3);
    expect(find.byType(CoursewareQuestionDetails), findsOneWidget);
    expect(find.text('题干 A'), findsOneWidget);
    await jump(tester);
    expect(find.textContaining('2/3', findRichText: true), findsOneWidget);
    await tester.tap(find.text('回到当前页'));
    await flushClassroomTasks(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('3/4', findRichText: true), findsOneWidget);
    await finish(tester);
  });

  testWidgets('历史跳页请求迟到时不能覆盖等待期间教师的新翻页', (tester) async {
    await mount(tester);
    await showPpt(tester, 'A', 1);
    await showPpt(tester, 'B', 2);
    final historical = Completer<Map<String, dynamic>>();
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((options) {
        requests.add(options.path);
        return historical.future;
      }),
    );
    await openHint(tester, 'A');
    await tester.tap(find.text('跳转到第 2 页'));
    await flushClassroomTasks(tester);
    await state(tester).debugHandleMessage({'op': 'slide', 'slideindex': 4});
    historical.complete(ppts['A']!);
    await flushClassroomTasks(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(visiblePage(tester), 3);
    expect(find.textContaining('4/4', findRichText: true), findsOneWidget);
    await finish(tester);
  });

  testWidgets('历史查看期间教师翻页回到教师课件，多个迟到页码以最新消息为准', (tester) async {
    await mount(tester);
    await showPpt(tester, 'A', 1);
    await showPpt(tester, 'B', 1);
    await openHint(tester, 'A');
    await jump(tester);
    final teacherPpt = Completer<Map<String, dynamic>>();
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((_) => teacherPpt.future),
    );
    final Future<void> first = state(
      tester,
    ).debugHandleMessage({'op': 'slide', 'slideindex': 2});
    await flushClassroomTasks(tester);
    final Future<void> last = state(tester).debugHandleMessage({
      'op': 'slidenav',
      'slide': {'si': 4},
    });
    await flushClassroomTasks(tester);
    teacherPpt.complete(ppts['B']!);
    await flushClassroomTasks(tester);
    await Future.wait([first, last]);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('4/4', findRichText: true), findsOneWidget);
    expect(visiblePage(tester), 3);
    await finish(tester);
  });

  testWidgets('同课件重新扫描题目变化更新提示，旧详情指纹不能跳到新题', (tester) async {
    await mount(tester);
    await showPpt(tester, 'A', 1);
    await openHint(tester, 'A');
    await showPpt(tester, 'B', 1);
    ppts['A'] = _ppt('changed', 3);
    await jump(tester);
    expect(find.text('课件题目已变化，请查看最新提示'), findsOneWidget);
    expect(visiblePage(tester), 0);
    expect(find.text('提交'), findsNothing);
    // 先让反馈条消失，避免底部反馈条遮住时间线的点击位置。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await openHint(tester, 'A');
    expect(find.text('题干 changed'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('本地详情和跳页不改变教师已发布题目的倒计时，也不新增发布事件', (tester) async {
    await mount(tester);
    await showPpt(tester, 'A', 2);
    await state(tester).debugHandleMessage({
      'op': 'unlockproblem',
      'problem': {'prob': 'problem-A', 'limit': 90},
    });
    await tester.pump();
    expect(find.text('1:30'), findsOneWidget);
    await openHint(tester, 'A');
    await jump(tester);
    expect(find.textContaining(RegExp(r'^1:[0-5]\d$')), findsOneWidget);
    expect(find.text('0:00'), findsNothing);
    expect(find.text('题目发布'), findsNothing);
    await finish(tester);
  });

  testWidgets('不同lesson相同PPT不继承上一课堂本地提示', (tester) async {
    await mount(tester, lesson: 'first');
    await showPpt(tester, 'A', 1);
    await mount(tester, lesson: 'second');
    expect(find.byType(CoursewareQuestionDiscoveryCard), findsNothing);
    await showPpt(tester, 'A', 1);
    final card = tester.widget<CoursewareQuestionDiscoveryCard>(
      find.byType(CoursewareQuestionDiscoveryCard),
    );
    expect(card.batch.questions.single.lessonId, 'second');
    await finish(tester);
  });

  testWidgets('未知题型可只读查看及跳页，不触发题型标签异常', (tester) async {
    final raw = _ppt('unknown', 2);
    raw['data']['slides'][1]['problem'] = {
      'problemId': 'unknown',
      'problemType': 99,
      'body': '未知类型的完整题干',
    };
    ppts['A'] = raw;
    await mount(tester);
    await showPpt(tester, 'A', 1);
    expect(find.text('发现课件题目 · 第 2 页 · 未知题型'), findsOneWidget);
    await openHint(tester, 'A');
    expect(find.text('未知题型'), findsOneWidget);
    await jump(tester);
    expect(visiblePage(tester), 1);
    expect(find.text('未知题型'), findsOneWidget);
    expect(find.text('提交'), findsNothing);
    await finish(tester);
  });

  testWidgets('旧课件加载迟到不产生提示，只有最新课件扫描结果进入时间线', (tester) async {
    await mount(tester);
    final old = Completer<Map<String, dynamic>>();
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((options) {
        requests.add(options.path);
        return options.uri.queryParameters['presentation_id'] == 'A'
            ? old.future
            : Future.value(ppts['B']!);
      }),
    );
    final Future<void> first = state(tester).debugHandleMessage({
      'op': 'showpresentation',
      'presentation': 'A',
      'slideindex': 1,
    });
    await flushClassroomTasks(tester);
    await showPpt(tester, 'B', 3);
    old.complete(ppts['A']!);
    await flushClassroomTasks(tester);
    await first;
    final cards = tester.widgetList<CoursewareQuestionDiscoveryCard>(
      find.byType(CoursewareQuestionDiscoveryCard),
    );
    expect(cards.map((card) => card.batch.presentationId), ['B']);
    expect(visiblePage(tester), 2);
    await finish(tester);
  });

  testWidgets('历史跳页请求期间离开课堂，迟到响应不能操作已销毁页面', (tester) async {
    await mount(tester);
    await showPpt(tester, 'A', 1);
    await showPpt(tester, 'B', 1);
    final pending = Completer<Map<String, dynamic>>();
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((options) {
        requests.add(options.path);
        return pending.future;
      }),
    );
    await openHint(tester, 'A');
    await tester.tap(find.text('跳转到第 2 页'));
    await flushClassroomTasks(tester);
    await tester.pumpWidget(const SizedBox());
    pending.complete(ppts['A']!);
    await flushClassroomTasks(tester);
    expect(find.byType(CoursewareQuestionDiscoveryCard), findsNothing);
    await finish(tester);
  });

  testWidgets('教师切换加载尚未完成时主动查看历史课件，返回仍使用教师目标课件及页码', (tester) async {
    await mount(tester);
    await showPpt(tester, 'A', 1);
    await showPpt(tester, 'B', 2);
    await openHint(tester, 'A');
    final pendingTeacher = Completer<Map<String, dynamic>>();
    ApiService.debugSetHttpClientAdapter(
      JsonHttpAdapter((options) {
        requests.add(options.path);
        final id = options.uri.queryParameters['presentation_id'];
        return id == 'C' ? pendingTeacher.future : Future.value(ppts[id]!);
      }),
    );
    final Future<void> teacher = state(tester).debugHandleMessage({
      'op': 'showpresentation',
      'presentation': 'C',
      'slideindex': 4,
    });
    await flushClassroomTasks(tester);
    await jump(tester);
    expect(find.textContaining('2/3', findRichText: true), findsOneWidget);
    pendingTeacher.complete(_ppt('C', 5));
    await flushClassroomTasks(tester);
    await teacher;
    expect(visiblePage(tester), 1);
    await tester.tap(find.text('回到当前页'));
    await flushClassroomTasks(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('4/5', findRichText: true), findsOneWidget);
    expect(visiblePage(tester), 3);
    await finish(tester);
  });

  testWidgets('本地未发布题与正式历史发题共存且互不解锁，正式事件仍可查看作答', (tester) async {
    ppts['A']!['data']['slides'][2]['problem'] = {
      'problemId': 'published-A',
      'problemType': 1,
      'body': '已发布的历史题干',
      'options': [
        {'key': 'A', 'value': '历史选项'},
      ],
    };
    await mount(tester);
    final Future<void> loading = state(tester).debugHandleMessage({
      'op': 'hello',
      'presentation': 'A',
      'slideindex': 1,
      'timeline': [
        {
          'type': 'problem',
          'prob': 'published-A',
          'pres': 'A',
          'si': 3,
          'dt': DateTime.now().millisecondsSinceEpoch,
        },
      ],
    });
    await flushClassroomTasks(tester);
    await loading;
    expect(find.text('题目发布'), findsOneWidget);
    await openHint(tester, 'A', page: 2);
    await jump(tester);
    expect(find.text('提交'), findsNothing);
    expect(find.text('0:00'), findsNothing);
    final formal = find.text('题目发布');
    await Scrollable.ensureVisible(tester.element(formal), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(formal);
    await flushClassroomTasks(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('提交'), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);
    expect(visiblePage(tester), 2);
    await finish(tester);
  });
}
