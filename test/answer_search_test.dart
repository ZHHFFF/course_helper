import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:course_helper/models/answer_result.dart';
import 'package:course_helper/utils/network_error.dart';

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

    // ===== 以下为本次新增能力的测试 =====

    test('题型中文名应该正确', () {
      expect(StandardizedQuestion.typeLabelOf('single'), '单选题');
      expect(StandardizedQuestion.typeLabelOf('multiple'), '多选题');
      expect(StandardizedQuestion.typeLabelOf('judgement'), '判断题');
      expect(StandardizedQuestion.typeLabelOf('fillBlank'), '填空题');
      expect(StandardizedQuestion.typeLabelOf('shortAnswer'), '简答题');
      expect(StandardizedQuestion.typeLabelOf('polling'), '投票题');
      expect(StandardizedQuestion.typeLabelOf('whatever'), '未知题型');
    });

    test('服务器没给 type 时，应按正确答案个数推断多选', () {
      final quiz = {
        'content': '以下说法正确的是',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': true},
          {'name': 'B', 'content': 'B', 'isanswer': true},
          {'name': 'C', 'content': 'C', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.questionType, 'multiple');
      expect(question.isMultipleChoice, true);
    });

    test('服务器没给 type 时，对/错 两个选项应推断为判断题', () {
      final quiz = {
        'content': '这是一个判断',
        'answer': [
          {'name': 'A', 'content': '对', 'isanswer': true},
          {'name': 'B', 'content': '错', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.questionType, 'judgement');
      expect(question.isChoice, true);
    });

    test('type 16 应识别为判断题', () {
      final quiz = {
        'type': 16,
        'content': '判断题',
        'answer': [
          {'name': 'A', 'content': '对', 'isanswer': true},
          {'name': 'B', 'content': '错', 'isanswer': false},
        ],
      };
      expect(StandardizedQuestion.fromChaoxing(quiz).questionType, 'judgement');
    });

    test('应从题干 HTML 中提取图片地址', () {
      final quiz = {
        'type': 0,
        'content': '<p>看图作答</p><img src="https://a.com/1.png"/>'
            '<img src="https://a.com/2.jpg"/>',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': true},
          {'name': 'B', 'content': 'B', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.imageUrls.length, 2);
      expect(question.imageUrls[0], 'https://a.com/1.png');
      expect(question.hasImage, true);
    });

    test('图片地址应支持自定义解析函数', () {
      final quiz = {
        'type': 0,
        'content': '<img src="/img/x.png"/>',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': true},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(
        quiz,
        resolveImageUrl: (url) => 'https://cdn.example.com$url',
      );
      expect(question.imageUrls.first, 'https://cdn.example.com/img/x.png');
    });

    test('题干为空但课件有文字时，应使用课件文字作为题干', () {
      final question = StandardizedQuestion(
        questionText: '',
        questionType: 'single',
        slideText: '1. 关于麻醉前评估，下列说法正确的是',
        options: [
          StandardizedOption(key: 'A', value: '选项A'),
          StandardizedOption(key: 'B', value: '选项B'),
        ],
      );

      expect(question.hasText, true);
      expect(question.effectiveText, '1. 关于麻醉前评估，下列说法正确的是');
      expect(question.isUsable, true);
      expect(question.needsImageRecognition, false);
    });

    test('题干和课件文字都没有，但有图片时，应标记为需要识图', () {
      final question = StandardizedQuestion(
        questionText: '',
        questionType: 'single',
        imageUrls: const ['https://a.com/slide.png'],
      );

      expect(question.hasText, false);
      expect(question.hasImage, true);
      expect(question.needsImageRecognition, true);
      expect(question.isUsable, true);
    });

    test('题干、课件文字、图片都没有时，应视为不可用', () {
      final question = StandardizedQuestion(
        questionText: '',
        questionType: 'single',
      );

      expect(question.isUsable, false);
    });

    test('toSearchQuery 应在题干为空时使用课件文字', () {
      final question = StandardizedQuestion(
        questionText: '',
        questionType: 'single',
        slideText: '课件上的题干',
        options: [
          StandardizedOption(key: 'A', value: '甲'),
        ],
      );

      expect(question.toSearchQuery(), contains('课件上的题干'));
      expect(question.toSearchQuery(), contains('A. 甲'));
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

    test('sourceType label', () {
      expect(AnswerSourceType.builtin.label, '内置答案');
      expect(AnswerSourceType.aiProvider.label, 'AI检索');
    });
  });

  group('网络错误识别', () {
    test('SocketException 应归类为网络错误', () {
      final info = describeError(const SocketException('failed'));
      expect(info.isNetwork, true);
      expect(info.message, contains('网络'));
    });

    test('TimeoutException 应归类为网络错误', () {
      final info = describeError(TimeoutException('timeout'));
      expect(info.isNetwork, true);
      expect(info.message, contains('超时'));
    });

    test('字符串形式的 SocketException 也应被识别', () {
      final info = describeError(Exception('SocketException: failed host lookup'));
      expect(info.isNetwork, true);
    });

    test('普通业务异常不应被误判为网络错误', () {
      final info = describeError(StateError('业务错误'));
      expect(info.isNetwork, false);
      expect(describeErrorShort(StateError('业务错误')), contains('业务错误'));
    });

    test('isNetworkError 便捷方法', () {
      expect(isNetworkError(const SocketException('x')), true);
      expect(isNetworkError(ArgumentError('x')), false);
    });
  });
}
