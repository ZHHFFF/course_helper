import 'package:course_helper/cache/cached_image.dart';
import 'package:course_helper/cache/slide_scanner.dart';
import 'package:course_helper/models/courseware_question_discovery.dart';
import 'package:course_helper/models/presentation.dart';
import 'package:course_helper/pages/widget/courseware_question_details.dart';
import 'package:course_helper/pages/widget/courseware_question_discovery_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/cache_test_env.dart';
import 'support/classroom_test_env.dart';

CoursewareQuestionBatch _batch(
  List<Map<String, dynamic>> problems, {
  String lesson = 'lesson',
  String presentationId = 'ppt',
  String cover = '',
}) {
  final presentation = Presentation.fromJson({
    'slides': [
      for (final problem in problems)
        {'index': 999, 'problem': problem, 'cover': cover},
    ],
  });
  return CoursewareQuestionBatch.fromScan(
    lessonId: lesson,
    presentationId: presentationId,
    title: '课件',
    scan: SlideScanner.scan(presentation),
    slides: presentation.slides,
  );
}

Map<String, dynamic> _problem(int number, {int type = 1, String? body}) => {
  'problemId': '$number',
  'problemType': type,
  'body': body ?? '题干 $number',
  'options': [
    {'key': 'A', 'value': '<b>完整选项</b>'},
  ],
};

void main() {
  late CacheTestEnv env;
  setUp(() async => env = await CacheTestEnv.create());
  tearDown(() async => env.dispose());

  test('沿用 scanner 去重和数组下标，身份同时包含课时、课件、下标及指纹', () {
    final batch = _batch([_problem(1), _problem(2, body: '题干 1')]);
    expect(batch.questions, hasLength(1));
    final discovery = batch.questions.single;
    expect(discovery.pageNumber, 1, reason: '不能用服务器的 index:999 作为数组下标');
    expect(discovery.identity, ('lesson', 'ppt', 0, discovery.item.hash));
    expect(
      _batch([_problem(1)], lesson: 'other').questions.single.identity,
      isNot(discovery.identity),
    );
    expect(
      _batch([_problem(1)], presentationId: 'other').questions.single.identity,
      isNot(discovery.identity),
    );
  });

  Future<void> mount(
    WidgetTester tester,
    CoursewareQuestionBatch batch, {
    bool dark = false,
    Future<void> Function(CoursewareQuestionDiscovery)? onJump,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: dark ? ThemeData.dark() : ThemeData.light(),
      home: MiuixTheme(
        data: dark ? MiuixThemeData.dark() : MiuixThemeData.light(),
        child: Scaffold(
          body: CoursewareQuestionDiscoveryCard(
            batch: batch,
            isCurrent: true,
            onJump: onJump ?? (_) async {},
          ),
        ),
      ),
    ),
  );

  for (final entry in {
    1: '单选题',
    2: '多选题',
    3: '投票题',
    4: '填空题',
    5: '简答题',
    6: '判断题',
  }.entries) {
    testWidgets('详情展示完整题干及选项：${entry.value}，关闭不跳页', (tester) async {
      final body = '完整题干\n' * 100;
      var jumps = 0;
      await mount(
        tester,
        _batch([_problem(1, type: entry.key, body: body)]),
        onJump: (_) async => jumps++,
      );
      await tester.tap(find.text('发现课件题目 · 第 1 页 · ${entry.value}'));
      await tester.pumpAndSettle();
      expect(find.byType(CoursewareQuestionDetails), findsOneWidget);
      expect(find.text(entry.value), findsOneWidget);
      expect(
        tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((widget) => widget.data),
        contains(
          body.trim().replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' '),
        ),
      );
      expect(find.text('A. 完整选项'), findsOneWidget);
      expect(find.text('仅供查看，发现题目不代表老师已发布。'), findsOneWidget);
      expect(jumps, 0);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(jumps, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('多题默认折叠，展开可查看和独立跳页，收起后恢复汇总', (tester) async {
    final jumps = <CoursewareQuestionDiscovery>[];
    await mount(
      tester,
      _batch([for (var i = 0; i < 4; i++) _problem(i)]),
      onJump: (discovery) async => jumps.add(discovery),
    );
    expect(find.text('发现课件题目 · 共 4 题'), findsOneWidget);
    expect(find.text('发现课件题目 · 第 4 页 · 单选题'), findsNothing);
    await tester.tap(find.text('展开题目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发现课件题目 · 第 4 页 · 单选题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳转到第 4 页'));
    await tester.pumpAndSettle();
    expect(jumps.single.item.slideIndex, 3);
    await tester.tap(find.text('收起题目'));
    await tester.pumpAndSettle();
    expect(find.text('发现课件题目 · 第 4 页 · 单选题'), findsNothing);
  });

  testWidgets('纯图片题明确未识别内容，同时展示题目插图、选项图和原页预览', (tester) async {
    const cover = 'https://img/cover.png';
    const bodyImage = 'https://img/body.png';
    const optionImage = 'https://img/option.png';
    await tester.runAsync(() async {
      for (final url in [cover, bodyImage, optionImage]) {
        final file = await SlideImageStore.fileFor('lesson', url);
        await file.writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
      }
    });
    await mount(
      tester,
      _batch([
        {
          'problemId': 'image',
          'problemType': 1,
          'body': '<img src="$bodyImage">',
          'options': [
            {'key': 'A', 'value': '<img src="$optionImage">'},
          ],
        },
      ], cover: cover),
    );
    await tester.tap(find.text('发现课件题目 · 第 1 页 · 单选题'));
    await flushClassroomTasks(tester);
    expect(find.text('未获取到题干文字，图片内容尚未识别，请查看原页。'), findsOneWidget);
    expect(find.text('A. 图片选项（见题目相关图片）'), findsOneWidget);
    final images = tester
        .widgetList<Image>(find.byType(Image))
        .map((widget) => widget.image)
        .whereType<SlideImage>();
    expect(images.map((image) => image.url), [bodyImage, optionImage, cover]);
    expect(images.every((image) => image.lessonId == 'lesson'), isTrue);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色模式沿用 Miuix 主题，详情可以主动跳页', (tester) async {
    var jumps = 0;
    await mount(
      tester,
      _batch([_problem(1)]),
      dark: true,
      onJump: (_) async => jumps++,
    );
    await tester.tap(find.text('发现课件题目 · 第 1 页 · 单选题'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(CoursewareQuestionDetails));
    expect(
      MiuixTheme.of(context).colors.surface,
      MiuixThemeData.dark().colors.surface,
    );
    await tester.tap(find.text('跳转到第 1 页'));
    await tester.pumpAndSettle();
    expect(jumps, 1);
    expect(tester.takeException(), isNull);
  });
}
