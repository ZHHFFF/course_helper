import 'package:flutter_test/flutter_test.dart';
import 'package:course_helper/models/active.dart';
import 'package:course_helper/models/presentation.dart';
import 'package:course_helper/push/lesson_start_tracker.dart';
import 'package:course_helper/utils/answer_filling.dart';
import 'package:course_helper/utils/quiz_html.dart';

void main() {
  test('未知活动不能进入签到分支', () {
    final active = Active.fromJson({
      'activeType': 98765,
      'id': '',
      'status': 1,
    });
    expect(active.activeType, ActiveType.unknown);
    expect(Active.fromJson({'activeType': 2}).activeType, ActiveType.signIn);
  });

  test('服务端空位元数据优先于题干，复制发题时间后仍保留', () {
    final problem = Problem.fromJson({
      'problemType': 4,
      'body': '无文本标记的填空题',
      'blanks': [
        {
          'num': 1,
          'answers': ['甲'],
        },
        {
          'num': 2,
          'answers': ['乙'],
        },
      ],
    });
    expect(problem.blankCount, 2);
    expect(problem.copyWith(dt: 20).blanks.last.answers, ['乙']);
    expect(
      AnswerFilling.fieldFor(
        4,
        problem.body,
        declaredBlankCount: problem.blanks.length,
      ),
      AnswerField.fillBlanks,
    );
    expect(Problem.fromJson({'body': '[填空1]与[填空2]'}).blankCount, 2);
  });

  test('新 questionList 字段仍能解析嵌套与多行题干', () {
    final html = 'questionList = [\n{"title":"题干含 ];", "nested":[1,2]}\n];';
    expect(
      extractQuizJson(html, 'questionList'),
      '[\n{"title":"题干含 ];", "nested":[1,2]}\n]',
    );
  });

  test('初始空课堂建立基线，新开课仅提醒一次，同课程新课节继续提醒', () {
    final tracker = LessonStartTracker();
    expect(tracker.update('user|server', []), isEmpty);
    final lesson = {'courseId': '1', 'lessonId': '10'};
    expect(tracker.update('user|server', [lesson]), [lesson]);
    expect(tracker.update('user|server', [lesson, lesson]), isEmpty);
    final next = {'courseId': '1', 'lessonId': '11'};
    expect(tracker.update('user|server', [next]), [next]);
    expect(tracker.update('other|server', [next]), isEmpty);
    tracker.reset();
    expect(tracker.update('other|server', [next]), isEmpty);
  });
}
