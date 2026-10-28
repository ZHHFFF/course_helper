import 'dart:async';

import 'package:course_helper/models/answer_result.dart';
import 'package:course_helper/pages/widget/answer_search_dialog.dart';
import 'package:course_helper/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final state in ['results', 'loading', 'error', 'empty']) {
      testWidgets('窄屏键盘下检索弹窗可滚动和关闭 $brightness $state', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 600);
        tester.view.viewInsets = const FakeViewPadding(bottom: 220);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);

        final search = Completer<AnswerSearchSnapshot>();
        final answer = AnswerSearchResult(
          answer: 'A',
          source: '很长的真实检索来源名称，用于验证标签换行和窄屏布局',
          confidence: .6,
          sourceType: AnswerSourceType.aiProvider,
          explanation: List.filled(8, '这是一段较长的答案说明。').join(),
        );
        AnswerSearchResult? applied;
        var returned = false;
        final input = TextEditingController(text: '课堂中尚未提交的作答');
        addTearDown(input.dispose);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null));

        await tester.pumpWidget(MaterialApp(
          theme: appMaterialTheme(
            brightness: brightness,
            pageTransitions: const PageTransitionsTheme(),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(1.2),
            ),
            child: MiuixTheme(
              data: appMiuixTheme(brightness),
              child: child!,
            ),
          ),
          home: Scaffold(body: Builder(builder: (context) => Column(
            children: [
              TextField(controller: input),
              TextButton(
                onPressed: () async {
                  applied = await showDialog<AnswerSearchResult>(
                    context: context,
                    builder: (_) => AnswerSearchDialog(
                      question: StandardizedQuestion(
                        questionText: '',
                        questionType: 'multiple',
                        imageUrls: ['https://example.invalid/question.png'],
                        options: [
                          StandardizedOption(key: 'A', value: '选项一'),
                          StandardizedOption(key: 'B', value: '选项二'),
                        ],
                      ),
                      initial: state == 'results'
                          ? AnswerSearchSnapshot(results: [answer], fromCache: true)
                          : null,
                      onSearch: ({required forceRefresh}) => search.future,
                    ),
                  );
                  returned = true;
                },
                child: const Text('打开检索'),
              ),
            ],
          ))),
        ));
        await tester.tap(find.text('打开检索'));
        // loading 有持续动画，不能 pumpAndSettle。
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        if (state == 'error') {
          search.completeError(StateError(List.filled(30, '服务暂时不可用').join('\n')));
        } else if (state == 'empty') {
          search.complete(const AnswerSearchSnapshot(results: []));
        }
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('关闭').hitTestable(), findsOneWidget);
        final dialogScroll = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(SingleChildScrollView),
        ).first;
        final scrollable = find.descendant(
          of: dialogScroll,
          matching: find.byType(Scrollable),
        ).first;
        if (state == 'results' || state == 'error') {
          expect(tester.state<ScrollableState>(scrollable)
              .position.maxScrollExtent, greaterThan(0));
        }

        if (state == 'results') {
          await tester.scrollUntilVisible(find.text('复制答案'), 80,
              scrollable: scrollable);
          await tester.tap(find.text('复制答案'));
          await tester.pump();
          expect(copied, 'A');
          await tester.tap(find.widgetWithIcon(FilledButton, Icons.check_circle_outline));
        } else {
          await tester.tap(find.text('关闭'));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(returned, isTrue);
        expect(applied, state == 'results' ? same(answer) : isNull);
        expect(input.text, '课堂中尚未提交的作答');
        expect(find.byType(AnswerSearchDialog), findsNothing);
        if (!search.isCompleted) {
          // 覆盖关闭后请求才结束，不能 setState 到已销毁的弹窗。
          search.complete(const AnswerSearchSnapshot(results: []));
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
