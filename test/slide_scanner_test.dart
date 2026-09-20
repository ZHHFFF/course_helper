/// PPT 逐页识题（SlideScanner）单测
///
/// 这套逻辑是「后台自动识题」的地基：它决定了整份 PPT 里
/// 哪些页有题、哪些题需要视觉识别、哪些是重复的。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/cache/slide_scanner.dart';
import 'package:course_helper/models/presentation.dart';

Shape _textShape(String text) => Shape(
      text: text,
      fill: Fill(backColor: '#FFFFFF', transparency: 0, visible: false),
      line: Line(
        dashStyle: 'msoLineSolid',
        backColor: '#000000',
        visible: false,
        weight: 0,
      ),
      width: 400,
      height: 40,
      left: 0,
      top: 0,
      rotation: 0,
      zOrderPosition: 0,
      pptShapeId: 1,
      pptShapeType: 1,
    );

Problem _problem({
  String problemId = 'p1',
  int problemType = 1,
  String body = '下面哪个是水果？',
  List<ProblemOption>? options,
}) {
  return Problem(
    problemId: problemId,
    problemType: problemType,
    body: body,
    score: 100,
    remark: '',
    answers: const [],
    hasRemark: false,
    options: options ??
        [
          ProblemOption(key: 'A', value: '苹果'),
          ProblemOption(key: 'B', value: '桌子'),
        ],
  );
}

PresentationSlide _slide({
  int index = 0,
  String cover = '',
  String coverAlt = '',
  List<Shape> shapes = const [],
  Problem? problem,
}) {
  return PresentationSlide(
    id: 'slide-$index',
    index: index,
    cover: cover,
    coverAlt: coverAlt,
    thumbnail: '',
    shapes: shapes,
    note: '',
    problem: problem,
  );
}

void main() {
  group('基本扫描', () {
    test('只有带 problem 的页才算题', () {
      final result = SlideScanner.scanSlides([
        _slide(index: 1, coverAlt: 'https://img/1.png'), // 没题
        _slide(index: 2, coverAlt: 'https://img/2.png', problem: _problem()),
        _slide(index: 3, coverAlt: 'https://img/3.png'), // 没题
        _slide(index: 4, coverAlt: 'https://img/4.png', problem: _problem(problemId: 'p2', body: '第二题')),
      ]);

      expect(result.total, 2);
      expect(result.bySlideIndex.keys.toSet(), {1, 3});
      expect(result.bySlideIndex[1]!.question.problemId, 'p1');
      expect(result.bySlideIndex[3]!.question.problemId, 'p2');
      expect(result.forSlide(0), isNull);
    });

    test('题号/题型/选项都带出来了', () {
      final result = SlideScanner.scanSlides([
        _slide(index: 1, problem: _problem(problemType: 2)),
      ]);

      final q = result.questions.single.question;
      expect(q.questionType, 'multiple');
      expect(q.typeLabel, '多选题');
      expect(q.options.map((o) => o.key).toList(), ['A', 'B']);
      expect(q.problemId, 'p1');
    });
  });

  group('去重', () {
    test('同一道题出现在两页 → 只留第一次出现的那页', () {
      final result = SlideScanner.scanSlides([
        _slide(index: 1, problem: _problem()),
        _slide(index: 2, problem: _problem()), // 题目页 / 答题页
      ]);

      expect(result.total, 1);
      expect(result.duplicateCount, 1);
      expect(result.bySlideIndex.keys.toList(), [0]);
    });

    test('题干相同但选项不同 → 不去重（是两道题）', () {
      final result = SlideScanner.scanSlides([
        _slide(index: 1, problem: _problem(problemId: 'p1')),
        _slide(
          index: 2,
          problem: _problem(
            problemId: 'p2',
            options: [
              ProblemOption(key: 'A', value: '苹果'),
              ProblemOption(key: 'B', value: '香蕉'),
            ],
          ),
        ),
      ]);

      expect(result.total, 2);
      expect(result.duplicateCount, 0);
    });
  });

  group('需要识图的情况', () {
    test('题干和选项全空、只有图 → needsVision，不进自动队列', () {
      final result = SlideScanner.scanSlides([
        _slide(
          index: 1,
          coverAlt: 'https://img/only-image.png',
          problem: _problem(body: '', options: []),
        ),
      ]);

      expect(result.total, 1);
      expect(result.visionOnly.length, 1);
      expect(result.autoSearchable, isEmpty);
      expect(result.questions.single.needsVision, isTrue);
      // 有图 → 仍然是「可用」的题，只是要用户手动点
      expect(result.questions.single.question.hasImage, isTrue);
    });

    test('题干为空但课件上有文字 → 不算需要识图', () {
      final result = SlideScanner.scanSlides([
        _slide(
          index: 1,
          coverAlt: 'https://img/1.png',
          shapes: [_textShape('这段文字就是题干')],
          problem: _problem(body: ''),
        ),
      ]);

      expect(result.questions.single.needsVision, isFalse);
      expect(result.autoSearchable.length, 1);
      expect(result.questions.single.question.effectiveText, '这段文字就是题干');
    });
  });

  group('空壳与异常数据', () {
    test('题干、选项、图片全空 → 跳过并计数', () {
      final result = SlideScanner.scanSlides([
        _slide(index: 1, problem: _problem(body: '', options: [])),
      ]);

      expect(result.total, 0);
      expect(result.skippedNotUsable, 1);
    });

    test('空列表不炸', () {
      final result = SlideScanner.scanSlides([]);
      expect(result.isEmpty, isTrue);
      expect(result.total, 0);
    });

    test('problemType 未知时按选项特征推断题型', () {
      // problemType=99 落不到任何已知题型 → 'unknown'，
      // 再由选项兜底推断（两个选项且没有正确答案标记 → 判为判断题）
      final result = SlideScanner.scanSlides([
        _slide(index: 1, problem: _problem(problemType: 99)),
      ]);

      expect(result.total, 1);
      expect(result.questions.single.question.questionType, 'judgement');
    });
  });

  group('页内文字与图片提取', () {
    test('slideTextOf 拼接所有文本框并跳过空文本', () {
      final slide = _slide(
        index: 1,
        shapes: [_textShape('第一行'), _textShape('  '), _textShape('第二行')],
      );
      expect(SlideScanner.slideTextOf(slide), '第一行\n第二行');
    });

    test('slideImageOf 优先 coverAlt', () {
      expect(
        SlideScanner.slideImageOf(
          _slide(index: 1, cover: 'https://img/low.png', coverAlt: 'https://img/high.png'),
        ),
        'https://img/high.png',
      );
      expect(
        SlideScanner.slideImageOf(_slide(index: 1, cover: 'https://img/low.png')),
        'https://img/low.png',
      );
      expect(SlideScanner.slideImageOf(_slide(index: 1)), '');
    });

    test('imageUrlsOf 按页序去重，空地址跳过', () {
      final urls = SlideScanner.imageUrlsOf([
        _slide(index: 1, coverAlt: 'https://img/1.png'),
        _slide(index: 2), // 没图
        _slide(index: 3, coverAlt: 'https://img/1.png'), // 重复
        _slide(index: 4, coverAlt: 'https://img/4.png'),
      ]);
      expect(urls, ['https://img/1.png', 'https://img/4.png']);
    });
  });
}
