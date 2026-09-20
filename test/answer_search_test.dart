import 'package:flutter_test/flutter_test.dart';
import 'package:course_helper/models/answer_result.dart';

void main() {
  group('StandardizedQuestion', () {
    test('fromChaoxing should extract question text and options', () {
      final quiz = {
        'type': 0,
        'content': '<p>以下哪个是正确的？</p>',
        'answer': [
          {'name': 'A', 'content': '<p>选项A</p>', 'isanswer': false},
          {'name': 'B', 'content': '<p>选项B</p>', 'isanswer': true},
          {'name': 'C', 'content': '<p>选项C</p>', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);

      expect(question.questionType, 'single');
      expect(question.questionText, '以下哪个是正确的？');
      expect(question.options.length, 3);
      expect(question.options[0].key, 'A');
      expect(question.options[0].value, '选项A');
      expect(question.options[1].isCorrect, true);
    });

    test('hasBuiltinAnswer should detect isanswer=true', () {
      final quiz = {
        'type': 0,
        'content': 'test',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': true},
          {'name': 'B', 'content': 'B', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.hasBuiltinAnswer, true);
      expect(question.builtinAnswer, 'A');
    });

    test('hasBuiltinAnswer should return false when no isanswer', () {
      final quiz = {
        'type': 0,
        'content': 'test',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': false},
          {'name': 'B', 'content': 'B', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.hasBuiltinAnswer, false);
      expect(question.builtinAnswer, null);
    });

    test('extractPlainText should strip HTML tags', () {
      final result = StandardizedQuestion.extractPlainText(
        '<p>Hello <b>World</b></p>',
      );
      expect(result, 'Hello World');
    });

    test('multiple choice should join correct options', () {
      final quiz = {
        'type': 1,
        'content': '多选题',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': true},
          {'name': 'B', 'content': 'B', 'isanswer': false},
          {'name': 'C', 'content': 'C', 'isanswer': true},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.questionType, 'multiple');
      expect(question.builtinAnswer, 'AC');
    });
  });

  group('AnswerSearchResult', () {
    test('should create with all fields', () {
      final result = AnswerSearchResult(
        answer: 'A',
        source: '服务器返回',
        confidence: 1.0,
        explanation: 'test',
        sourceType: AnswerSourceType.builtin,
      );

      expect(result.answer, 'A');
      expect(result.confidence, 1.0);
      expect(result.sourceType, AnswerSourceType.builtin);
    });
  });
}

