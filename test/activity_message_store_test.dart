import 'package:course_helper/push/easemob.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:course_helper/api/api_service.dart';
import 'package:course_helper/pages/courses/list.dart';
import 'package:course_helper/pages/courses/content.dart';
import 'package:course_helper/session/account.dart';
import 'support/classroom_test_env.dart';
import 'support/json_http_adapter.dart';

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? latest;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      latest = route;
}

void main() {
  test(
    'unread counts isolate course/class and reset on account switch',
    () async {
      final store = ActivityMessageStore()..clearAll();
      var changes = 0;
      final subscription = store.changes.listen((_) => changes++);
      store.add('course', 'class1');
      store.add('course', 'class1');
      store.add('course', 'class2');
      expect(store.countOf('course', 'class1'), 2);
      expect(store.countOf('course', 'class2'), 1);
      store.clear('course', 'class1');
      expect(store.countOf('course', 'class1'), 0);
      expect(store.countOf('course', 'class2'), 1);
      store.clearAll();
      expect(store.countOf('course', 'class2'), 0);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 5);
      await subscription.cancel();
    },
  );
  testWidgets(
    'unread sorting opens the displayed course and clears only its badge',
    (tester) async {
      final env = (await tester.runAsync(ClassroomTestEnv.create))!;
      final store = ActivityMessageStore()..clearAll();
      AccountManager.setCurrentSessionTemp('uid');
      ApiService.debugSetHttpClientAdapter(
        JsonHttpAdapter(
          (_) async => {
            'result': 1,
            'channelList': [
              for (final id in ['a', 'b'])
                {
                  'content': {
                    'id': 'class-$id',
                    'cpi': 'cpi-$id',
                    'state': 0,
                    'course': {
                      'data': [
                        {
                          'id': id,
                          'name': 'course-$id',
                          'teacherfactor': 'teacher',
                        },
                      ],
                    },
                  },
                },
            ],
          },
        ),
      );
      final observer = _RouteObserver();
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [observer],
            home: MiuixTheme(
              data: MiuixThemeData.light(),
              child: const CoursesPage(),
            ),
          ),
        );
        await flushClassroomTasks(tester);
        store.add('b', 'class-b');
        await flushClassroomTasks(tester);
        expect(
          tester.getTopLeft(find.text('course-b')).dy,
          lessThan(tester.getTopLeft(find.text('course-a')).dy),
        );
        final card = tester.widget<MiuixCard>(
          find.ancestor(
            of: find.text('course-b'),
            matching: find.byType(MiuixCard),
          ),
        );
        card.onPressed!();
        final route = observer.latest as MaterialPageRoute;
        final destination =
            route.builder(tester.element(find.byType(CoursesPage)))
                as CourseContentPage;
        expect(destination.courseId, 'b');
        expect(destination.classId, 'class-b');
        expect(store.countOf('b', 'class-b'), 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await flushClassroomTasks(tester);
        store.clearAll();
        await tester.runAsync(env.dispose);
      }
    },
  );
}
