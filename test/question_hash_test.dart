/// 题目指纹（QuestionHash）单测
///
/// 重点锁住两件事：
/// 1. 「同义不同形」的题要落到同一个指纹（否则缓存命中率会很难看）
/// 2. 「形似不同题」绝对不能撞到同一个指纹（否则会把 A 题的答案填到 B 题上）
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/cache/question_hash.dart';
import 'package:course_helper/models/answer_result.dart';

StandardizedQuestion _q({
  String text = '',
  String type = 'single',
  List<StandardizedOption> options = const [],
  String slideText = '',
  List<String> images = const [],
  String problemId = '',
}) {
  return StandardizedQuestion(
    questionText: text,
    questionType: type,
    options: options,
    slideText: slideText,
    imageUrls: images,
    problemId: problemId,
  );
}

StandardizedOption _opt(String key, String value) =>
    StandardizedOption(key: key, value: value);

void main() {
  group('归一化：形不同、义相同 → 同一指纹', () {
    test('空白差异（半角/全角/连续空格）不影响', () {
      final a = _q(
        text: '下列 哪个 是 正确 的？',
        options: [_opt('A', '苹果'), _opt('B', '香蕉')],
      );
      final b = _q(
        text: '下列　哪个　是　正确　的',
        options: [_opt('A', '苹果'), _opt('B', '香蕉')],
      );
      expect(QuestionHash.of(a), QuestionHash.of(b));
    });

    test('全角字母数字转半角后一致', () {
      expect(
        QuestionHash.of(_q(text: 'ＡＢＣ１２３')),
        QuestionHash.of(_q(text: 'ABC123')),
      );
    });

    test('HTML 标签与实体被剥掉后一致', () {
      expect(
        QuestionHash.of(_q(text: '<p>你好&nbsp;<b>世界</b></p>')),
        QuestionHash.of(_q(text: '你好 世界')),
      );
    });

    test('首尾标点不影响', () {
      expect(
        QuestionHash.of(_q(text: '这是题目。')),
        QuestionHash.of(_q(text: '这是题目')),
      );
    });

    test('大小写不影响', () {
      expect(
        QuestionHash.of(_q(text: 'HTTP 是什么')),
        QuestionHash.of(_q(text: 'http 是什么')),
      );
    });

    test('选项里的空白/全角差异不影响', () {
      final a = _q(
        text: '题',
        options: [_opt('A', '苹 果'), _opt('B', '香　蕉')],
      );
      final b = _q(
        text: '题',
        options: [_opt('A', '苹果'), _opt('B', '香蕉')],
      );
      expect(QuestionHash.of(a), QuestionHash.of(b));
    });
  });

  group('区分度：不同题 → 不同指纹', () {
    test('选项顺序不同 → 指纹不同（顺序变了，答案字母的含义就变了）', () {
      final a = _q(
        text: '哪个是水果？',
        options: [_opt('A', '苹果'), _opt('B', '桌子')],
      );
      final b = _q(
        text: '哪个是水果？',
        options: [_opt('A', '桌子'), _opt('B', '苹果')],
      );
      expect(QuestionHash.of(a), isNot(QuestionHash.of(b)));
    });

    test('题型不同 → 指纹不同', () {
      final a = _q(text: '这题对吗', type: 'single');
      final b = _q(text: '这题对吗', type: 'judgement');
      expect(QuestionHash.of(a), isNot(QuestionHash.of(b)));
    });

    test('题干不同 → 指纹不同', () {
      expect(
        QuestionHash.of(_q(text: '第一题')),
        isNot(QuestionHash.of(_q(text: '第二题'))),
      );
    });

    test('中间的标点不能被删掉（「A、B 两点」不是「AB 两点」）', () {
      expect(
        QuestionHash.of(_q(text: 'A、B 两点距离')),
        isNot(QuestionHash.of(_q(text: 'AB 两点距离'))),
      );
    });
  });

  group('题干缺失时的兜底', () {
    test('题干为空 → 用课件文字', () {
      expect(
        QuestionHash.of(_q(text: '', slideText: '课件上的题干')),
        QuestionHash.of(_q(text: '课件上的题干')),
      );
    });

    test('不同页的课件文字不同 → 指纹不同', () {
      expect(
        QuestionHash.of(_q(text: '', slideText: '第一页的题')),
        isNot(QuestionHash.of(_q(text: '', slideText: '第二页的题'))),
      );
    });

    test('题干+选项都空 → 退化为 problemId（pid- 前缀）', () {
      final hash = QuestionHash.of(_q(problemId: 'prob-123'));
      expect(hash, startsWith('pid-'));
      expect(hash, isNot(QuestionHash.of(_q(problemId: 'prob-456'))));
    });

    test('连 problemId 都没有 → 退化为图片地址（img- 前缀）', () {
      final hash = QuestionHash.of(_q(images: ['https://a/1.png']));
      expect(hash, startsWith('img-'));
      expect(
        hash,
        isNot(QuestionHash.of(_q(images: ['https://a/2.png']))),
      );
    });

    test('兜底键都是 64 位十六进制（pid-/img- 后）', () {
      final hash = QuestionHash.of(_q(problemId: 'p1'));
      expect(RegExp(r'^pid-[0-9a-f]{64}$').hasMatch(hash), isTrue);
    });
  });

  group('工具方法', () {
    test('toHalfWidth 只动全角区，不动中文', () {
      expect(QuestionHash.toHalfWidth('ＡＢＣ１２３！？'), 'ABC123!?');
      expect(QuestionHash.toHalfWidth('中文abc'), '中文abc');
      expect(QuestionHash.toHalfWidth('全角\u3000空格'), '全角 空格');
    });

    test('normalize 空串返回空串', () {
      expect(QuestionHash.normalize(''), '');
      expect(QuestionHash.normalize('   '), '');
    });
  });
}
