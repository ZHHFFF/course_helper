import 'package:course_helper/cache/cached_image.dart';
import 'package:course_helper/cache/slide_scanner.dart';
import 'package:course_helper/models/courseware_question_discovery.dart';
import 'package:course_helper/models/presentation.dart';
import 'package:course_helper/pages/widget/courseware_question_details.dart';
import 'package:course_helper/pages/widget/courseware_question_discovery_card.dart';
import 'package:course_helper/pages/widget/classroom_timeline_card.dart';
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
  int leadingSlides = 0,
  String title = '课件',
}) {
  final presentation = Presentation.fromJson({
    'slides': [
      for (var i = 0; i < leadingSlides; i++) {'index': 999},
      for (final problem in problems)
        {'index': 999, 'problem': problem, 'cover': cover},
    ],
  });
  return CoursewareQuestionBatch.fromScan(
    lessonId: lesson,
    presentationId: presentationId,
    title: title,
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
    bool isCurrent = true,
    String timeLabel = '刚刚',
    double scale = 1,
    Future<void> Function(CoursewareQuestionDiscovery)? onJump,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: dark ? ThemeData.dark() : ThemeData.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: MiuixTheme(
        data: dark ? MiuixThemeData.dark() : MiuixThemeData.light(),
        child: Scaffold(
          body: SingleChildScrollView(
            child: CoursewareQuestionDiscoveryCard(
              batch: batch,
              isCurrent: isCurrent,
              timeLabel: timeLabel,
              onJump: onJump ?? (_) async {},
            ),
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
      await tester.tap(find.text('第 1 页'));
      await tester.pumpAndSettle();
      expect(find.byType(CoursewareQuestionDetails), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(CoursewareQuestionDetails),
          matching: find.text(entry.value),
        ),
        findsOneWidget,
      );
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
    expect(find.text('共 4 题'), findsOneWidget);
    expect(find.text('第 4 页'), findsNothing);
    await tester.tap(find.text('展开题目'));
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text('第 4 页')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 4 页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳转到第 4 页'));
    await tester.pumpAndSettle();
    expect(jumps.single.item.slideIndex, 3);
    await Scrollable.ensureVisible(tester.element(find.text('收起题目')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起题目'));
    await tester.pumpAndSettle();
    expect(find.text('第 4 页'), findsNothing);
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
    await tester.tap(find.text('第 1 页'));
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
    await tester.tap(find.text('第 1 页'));
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

  testWidgets('参考布局：圆形图标、独立卡片、实际页码、题型、时间和两行摘要', (tester) async {
    const body = '下列关于全麻药物作用机制的描述，正确的是。这里是实际扫描的完整题干，预览只显示两行，详情保留全部内容。';
    final batch = _batch([_problem(86, body: body)], leadingSlides: 85);
    await mount(tester, batch);
    expect(find.text('第 86 页'), findsOneWidget);
    expect(find.text('发现课件题目'), findsOneWidget);
    expect(find.text('单选题'), findsOneWidget);
    expect(find.text('刚刚'), findsOneWidget);
    expect(find.text('查看题目详情'), findsOneWidget);
    final preview = tester.widget<Text>(find.text(body));
    expect(preview.maxLines, 2);
    expect(preview.overflow, TextOverflow.ellipsis);
    final icon = tester.getRect(find.byIcon(Icons.quiz_outlined));
    final content = tester.getRect(find.byType(MiuixCard));
    expect(icon.right, lessThan(content.left));
    expect(icon.top, content.top);
    expect(
      tester.getTopLeft(find.text('刚刚')).dx,
      greaterThan(tester.getTopLeft(find.text('发现课件题目')).dx),
    );
    expect(find.byType(ClassroomTimelineCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情入口和摘要均可点击，查看不跳页，完整文字不被摘要截断', (tester) async {
    final body = '真实的长题干文字。' * 60;
    var jumps = 0;
    await mount(
      tester,
      _batch([_problem(1, body: body)]),
      onJump: (_) async => jumps++,
    );
    await tester.tap(find.text('查看题目详情'));
    await tester.pumpAndSettle();
    final detail = find.byType(CoursewareQuestionDetails);
    expect(
      find.descendant(of: detail, matching: find.text(body)),
      findsOneWidget,
    );
    expect(jumps, 0);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(body));
    await tester.pumpAndSettle();
    expect(detail, findsOneWidget);
    expect(jumps, 0);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史卡片显示原课件与真实时间标签，纯图片摘要不伪造文字', (tester) async {
    await mount(
      tester,
      _batch(
        [_problem(1, body: '<img src="https://img/body.png">')],
        cover: 'https://img/page.png',
        title: '旧课件',
      ),
      isCurrent: false,
      timeLabel: '4分钟前',
    );
    expect(find.text('历史课件 · 旧课件'), findsOneWidget);
    expect(find.text('4分钟前'), findsOneWidget);
    expect(find.text('图片内容尚未识别，请查看原页。'), findsOneWidget);
    expect(find.byType(Image), findsNothing, reason: '预览不额外请求图片，详情沿用原有图片加载流程');
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    for (final scale in [1.2, 2.0]) {
      testWidgets('窄屏、大字号布局无溢出：dark=$dark scale=$scale', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await mount(
          tester,
          _batch([
            for (var i = 0; i < 4; i++) _problem(i, body: '$i：${'长题干。' * 80}'),
          ]),
          dark: dark,
          scale: scale,
          timeLabel: '10/14 17:23',
        );
        await tester.tap(find.text('展开题目'));
        await tester.pumpAndSettle();
        expect(find.text('查看题目详情'), findsNWidgets(4));
        await Scrollable.ensureVisible(
          tester.element(find.text('查看题目详情').last),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final colors = MiuixTheme.of(
          tester.element(find.byType(CoursewareQuestionDiscoveryCard)),
        ).colors;
        final cards = tester.widgetList<MiuixCard>(find.byType(MiuixCard));
        expect(
          cards.every((card) => card.colors == null),
          isTrue,
          reason: '内容卡片使用主题默认颜色，不能写死白色',
        );
        expect(
          colors.surfaceContainer,
          (dark ? MiuixThemeData.dark() : MiuixThemeData.light())
              .colors
              .surfaceContainer,
        );
      });
    }
  }
}
