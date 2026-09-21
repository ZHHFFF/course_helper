import 'package:course_helper/utils/answer_filling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('blankCount：数题干里有几个空', () {
    test('没有标记 → 0', () {
      expect(AnswerFilling.blankCount('请写出下列名词的定义'), 0);
    });

    test('一个空', () {
      expect(AnswerFilling.blankCount('水的化学式是[填空1]'), 1);
    });

    test('三个空', () {
      expect(
        AnswerFilling.blankCount('[填空1] 是首都，[填空2] 是港口，[填空3] 是山脉'),
        3,
      );
    });

    test('不带数字的 [填空] 也算一个空', () {
      expect(AnswerFilling.blankCount('答案是[填空]'), 1);
    });

    test('混排：带数字和不带数字都要算', () {
      expect(AnswerFilling.blankCount('[填空1] 和 [填空]'), 2);
    });

    test('不在方括号里的「填空」不算', () {
      expect(AnswerFilling.blankCount('这是一道填空题'), 0);
    });
  });

  group('fieldFor：按题型决定写哪个字段', () {
    test('单选(1) → choice', () {
      expect(AnswerFilling.fieldFor(1, '题干'), AnswerField.choice);
    });

    test('多选(2) → choice', () {
      expect(AnswerFilling.fieldFor(2, '题干'), AnswerField.choice);
    });

    test('投票(3) → choice', () {
      expect(AnswerFilling.fieldFor(3, '题干'), AnswerField.choice);
    });

    test('判断(6) → choice', () {
      expect(AnswerFilling.fieldFor(6, '题干'), AnswerField.choice);
    });

    test('填空(4) 且有 [填空N] → fillBlanks', () {
      expect(AnswerFilling.fieldFor(4, '[填空1] 和 [填空2]'),
          AnswerField.fillBlanks);
    });

    test('填空(4) 但没有标记 → fillSingle（UI 是单个输入框）', () {
      expect(AnswerFilling.fieldFor(4, '请写出答案'), AnswerField.fillSingle);
    });

    test('简答(5) → shortAnswer', () {
      expect(AnswerFilling.fieldFor(5, '请论述'), AnswerField.shortAnswer);
    });

    test('未知题型 → 按 choice 处理', () {
      expect(AnswerFilling.fieldFor(99, '题干'), AnswerField.choice);
    });

    test('回归：填空(4) 绝不能落进 choice', () {
      // 这是之前的真 bug —— 填空题被写成 _textAnswer，UI 读的却是 _answer
      for (final body in ['[填空1]', '[填空1][填空2]', '无标记的填空题']) {
        expect(AnswerFilling.fieldFor(4, body), isNot(AnswerField.choice),
            reason: '题干「$body」被误判成选择题');
      }
    });
  });

  group('splitBlanks：把答案文本拆到每个空', () {
    test('顿号分隔', () {
      expect(AnswerFilling.splitBlanks('北京、上海、广州', 3),
          ['北京', '上海', '广州']);
    });

    test('中文逗号', () {
      expect(AnswerFilling.splitBlanks('北京，上海', 2), ['北京', '上海']);
    });

    test('英文逗号', () {
      expect(AnswerFilling.splitBlanks('A,B,C', 3), ['A', 'B', 'C']);
    });

    test('分号', () {
      expect(AnswerFilling.splitBlanks('A;B', 2), ['A', 'B']);
    });

    test('换行', () {
      expect(AnswerFilling.splitBlanks('第一空\n第二空', 2), ['第一空', '第二空']);
    });

    test('混用多种分隔符', () {
      expect(AnswerFilling.splitBlanks('A、B，C;D\nE', 5), ['A', 'B', 'C', 'D', 'E']);
    });

    test('分隔符周围有空格 → 去掉', () {
      expect(AnswerFilling.splitBlanks('  A , B  ', 2), ['A', 'B']);
    });

    test('空片段被跳过', () {
      expect(AnswerFilling.splitBlanks('A,,B', 2), ['A', 'B']);
    });

    test('答案比空位多 → 截断到空位数', () {
      expect(AnswerFilling.splitBlanks('A,B,C,D', 2), ['A', 'B']);
    });

    test('答案比空位少 → 补空串（长度必须等于空位数）', () {
      final r = AnswerFilling.splitBlanks('A', 3);
      expect(r.length, 3);
      expect(r, ['A', '', '']);
    });

    test('只有分隔符 → 空列表（调用方应放弃填充）', () {
      expect(AnswerFilling.splitBlanks('、，;', 3), isEmpty);
    });

    test('空字符串 → 空列表', () {
      expect(AnswerFilling.splitBlanks('', 2), isEmpty);
    });

    test('空白字符串 → 空列表', () {
      expect(AnswerFilling.splitBlanks('   ', 2), isEmpty);
    });

    test('空位数为 0 → 空列表（避免除零/越界）', () {
      expect(AnswerFilling.splitBlanks('A,B', 0), isEmpty);
    });

    test('负数空位 → 空列表', () {
      expect(AnswerFilling.splitBlanks('A,B', -1), isEmpty);
    });

    test('答案里本身含逗号的内容会被拆开（已知取舍）', () {
      // AI 返回「1,000 米」时会被拆成两个空 —— 目前无法区分，
      // 但空位数以题干为准，多出来的会被截掉，不会越界
      final r = AnswerFilling.splitBlanks('1,000 米、2,000 米', 2);
      expect(r.length, 2);
    });

    test('返回的列表长度永远等于空位数', () {
      for (final ans in ['A', 'A,B', 'A,B,C,D,E']) {
        for (final n in [1, 2, 3]) {
          final r = AnswerFilling.splitBlanks(ans, n);
          if (r.isNotEmpty) {
            expect(r.length, n, reason: '答案「$ans」+ $n 个空');
          }
        }
      }
    });
  });
}
