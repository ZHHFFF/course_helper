import 'dart:io';
import 'dart:ui' as ui;

import 'package:course_helper/main.dart';
import 'package:course_helper/pages/courses/list.dart';
import 'package:course_helper/session/account.dart';
import 'package:course_helper/utils/test_data_seeder.dart';
import 'package:course_helper/models/answer_result.dart';
import 'package:course_helper/pages/widget/answer_search_dialog.dart';
import 'package:course_helper/navigation/miuix_page_route.dart';
import 'package:course_helper/pages/login.dart';
import 'package:course_helper/pages/widget/accounts_selector.dart';
import 'package:course_helper/setting/theme_setting.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/classroom_test_env.dart';

const _output = String.fromEnvironment('VISUAL_ALIGNMENT_DIR');
const _capture = ValueKey('visual-alignment');

Future<void> _snapshot(WidgetTester tester, String name) async {
  if (_output.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_output/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  late ClassroomTestEnv env;
  setUp(() async {
    env = await ClassroomTestEnv.create();
    ThemeSetting.uiScale.value = 1;
    ThemeSetting.blurEnabled.value = false;
    ThemeSetting.floatingNavBar.value = false;
  });
  tearDown(() async {
    ThemeSetting.mode.value = ThemeMode.system;
    ThemeSetting.uiScale.value = 1;
    ThemeSetting.blurEnabled.value = true;
    await env.dispose();
  });

  testWidgets('主题切换首帧同步两套控件，并保留输入和路由', (tester) async {
    ThemeSetting.mode.value = ThemeMode.light;
    await tester.pumpWidget(const MyApp());
    await flushClassroomTasks(tester);
    await tester.pumpAndSettle();
    navigatorKey.currentState!.push(
      MiuixPageRoute<void>(builder: (_) => const _Controls()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '切换前的作答');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      ThemeSetting.mode.value = mode;
      await tester.pump();
      final context = tester.element(find.byType(_Controls));
      expect(
        Theme.of(context).colorScheme.primary,
        MiuixTheme.of(context).colors.primary,
      );
      expect(
        Theme.of(context).scaffoldBackgroundColor,
        MiuixTheme.of(context).colors.background,
      );
      expect(find.text('切换前的作答'), findsOneWidget);
      expect(navigatorKey.currentState!.canPop(), isTrue);
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await flushClassroomTasks(tester);
  });

  testWidgets('跟随系统切换首帧同步已打开的弹窗，保留底层输入', (tester) async {
    ThemeSetting.mode.value = ThemeMode.system;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(const MyApp());
    await flushClassroomTasks(tester);
    await tester.pumpAndSettle();
    navigatorKey.currentState!.push(
      MiuixPageRoute<void>(builder: (_) => const _Controls()),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '系统切换前的作答');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看弹窗'));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(tester.element(find.byType(AlertDialog)));
    for (final brightness in [Brightness.dark, Brightness.light]) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pump();
      final context = tester.element(find.byType(AlertDialog));
      expect(Theme.of(context).brightness, brightness);
      expect(Theme.of(context).colorScheme.primary,
          MiuixTheme.of(context).colors.primary);
      expect(Theme.of(context).dialogTheme.backgroundColor,
          MiuixTheme.of(context).colors.surfaceContainer);
      expect(ModalRoute.of(context), same(route));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('系统切换前的作答'), findsOneWidget);
    expect(navigatorKey.currentState!.canPop(), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await flushClassroomTasks(tester);
  });

  for (final dark in [false, true]) {
    for (final width in [320.0, 390.0]) {
      for (final scale in [1.0, 1.2]) {
        testWidgets('全局视觉/输入/弹窗 dark=$dark width=$width scale=$scale', (
          tester,
        ) async {
          if (_output.isNotEmpty) {
            final oldBanner = WidgetsApp.debugAllowBannerOverride;
            WidgetsApp.debugAllowBannerOverride = false;
            addTearDown(() => WidgetsApp.debugAllowBannerOverride = oldBanner);
            await tester.runAsync(() async {
              for (final entry in {
                'Roboto':
                    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
                'MaterialIcons':
                    '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              }.entries) {
                final font = FontLoader(entry.key);
                font.addFont(
                  Future.value(
                    ByteData.sublistView(await File(entry.value).readAsBytes()),
                  ),
                );
                await font.load();
              }
            });
          }
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 844);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          ThemeSetting.mode.value = dark ? ThemeMode.dark : ThemeMode.light;
          ThemeSetting.uiScale.value = scale;
          await tester.pumpWidget(
            const RepaintBoundary(key: _capture, child: MyApp()),
          );
          await flushClassroomTasks(tester);
          await tester.pumpAndSettle();
          final capture = width == 390 && scale == 1;
          final prefix = dark ? 'dark' : 'light';
          if (capture) {
            // 仅预览构建使用现有离线种子，不发送已登录课程请求。
            if (TestDataSeeder.enabled) {
              AccountManager.setCurrentSessionTemp('visual-preview');
              final dynamic courses = tester.state(find.byType(CoursesPage));
              courses.refreshCourses();
              await flushClassroomTasks(tester);
              AccountManager.setCurrentSessionTemp(null);
            }
            final tabs = tester.widget<PageView>(find.byType(PageView).first);
            for (var i = 0; i < 4; i++) {
              tabs.controller!.jumpToPage(i);
              await flushClassroomTasks(tester);
              await tester.pumpAndSettle();
              await _snapshot(tester, '$prefix-tab-$i');
            }
          }

          navigatorKey.currentState!.push(
            MiuixPageRoute<void>(builder: (_) => const _Controls()),
          );
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(_Controls));
          final material = Theme.of(context);
          final miuix = MiuixTheme.of(context);
          expect(material.scaffoldBackgroundColor, miuix.colors.background);
          expect(tester.getTopLeft(find.byType(AccountsSelector)).dx, 16);
          expect(material.colorScheme.primary, miuix.colors.primary);
          expect(material.cardTheme.color, miuix.colors.surfaceContainer);
          expect(
            material.dialogTheme.backgroundColor,
            miuix.colors.surfaceContainer,
          );
          final input = tester.widget<InputDecorator>(
            find.descendant(
              of: find.byType(TextField).first,
              matching: find.byType(InputDecorator),
            ),
          );
          expect(input.decoration.fillColor, miuix.colors.secondaryVariant);
          for (final entry in {
            '兼容主操作': miuix.colors.primary,
            '禁用操作': miuix.colors.disabledPrimaryButton,
          }.entries) {
            final surface = tester.widget<Material>(
              find
                  .descendant(
                    of: find.widgetWithText(ElevatedButton, entry.key),
                    matching: find.byType(Material),
                  )
                  .first,
            );
            expect(surface.color, entry.value);
            expect(surface.elevation, 0);
          }
          final materialText = tester.renderObject<RenderParagraph>(
            find.text('兼容控件'),
          );
          final miuixText = tester.renderObject<RenderParagraph>(
            find.text('Miuix 控件'),
          );
          expect(
            materialText.text.style!.fontSize,
            miuixText.text.style!.fontSize,
          );
          await tester.enterText(find.byType(TextField).first, '输入仍然正常');
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          expect(find.text('输入仍然正常'), findsOneWidget);
          if (capture) await _snapshot(tester, '$prefix-controls');
          await tester.tap(find.text('查看弹窗'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          if (capture) await _snapshot(tester, '$prefix-dialog');
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text('输入仍然正常'), findsOneWidget);
          showDialog<void>(
            context: context,
            builder: (_) => AnswerSearchDialog(
              question: StandardizedQuestion(
                questionText: '以下哪项是课件中的题目？',
                questionType: 'single',
                options: [StandardizedOption(key: 'A', value: '示例选项')],
              ),
              initial: AnswerSearchSnapshot(
                fromCache: true,
                results: [
                  AnswerSearchResult(
                    answer: 'A',
                    source: '本地预览',
                    confidence: .95,
                    sourceType: AnswerSourceType.builtin,
                  ),
                ],
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('答案检索'), findsOneWidget);
          if (capture) await _snapshot(tester, '$prefix-answer-search');
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          if (capture) {
            navigatorKey.currentState!.push(
              MiuixPageRoute<void>(
                builder: (_) => const LoginPage(initialLoginType: 'password'),
              ),
            );
            await tester.pumpAndSettle();
            await _snapshot(tester, '$prefix-login');
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await flushClassroomTasks(tester);
        });
      }
    }
  }
}

class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('统一控件预览', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          const MiuixCard(
            insideMargin: EdgeInsets.all(16),
            child: MiuixText('Miuix 控件'),
          ),
          const SizedBox(height: 12),
          const Card(
            margin: EdgeInsets.zero,
            child: Padding(padding: EdgeInsets.all(16), child: Text('兼容控件')),
          ),
          const SizedBox(height: 16),
          const TextField(decoration: InputDecoration(labelText: '填写答案')),
          const SizedBox(height: 12),
          const TextField(
            enabled: false,
            decoration: InputDecoration(labelText: '只读状态'),
          ),
          const SizedBox(height: 12),
          MiuixButton(
            colors: MiuixButtonDefaults.buttonColorsPrimary(context),
            onPressed: () {},
            child: const MiuixText('Miuix 主操作'),
          ),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: () {}, child: const Text('兼容主操作')),
          const SizedBox(height: 12),
          const ElevatedButton(onPressed: null, child: Text('禁用操作')),
          const SizedBox(height: 12),
          AccountsSelector(
            initiallyExpanded: false,
            onSelectionChanged: (_) {},
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('课堂提示'),
                content: const Text('弹窗沿用统一的卡片表面、圆角和文字层级。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            child: const Text('查看弹窗'),
          ),
        ],
      ),
    ),
  );
}
