import 'dart:convert';

import 'package:course_helper/utils/quiz_html.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('multiline nested quiz JSON and delimiter text survive extraction', () {
    final quiz = [
      {
        'title': 'text ]; and }; with "quotes" and \\slashes',
        'options': [
          [1, 2],
          3,
        ],
      },
    ];
    final html =
        'const quizList = ${const JsonEncoder.withIndent('  ').convert(quiz)};\n'
        'var active={"id":2}; var other=[99];';
    expect(jsonDecode(extractQuizJson(html, 'quizList')!), quiz);
    expect(jsonDecode(extractQuizJson(html, 'active')!), {'id': 2});
  });
  test('same line subsequent scripts are not included', () {
    expect(extractQuizJson('quizList=[1]; other=[2];', 'quizList'), '[1]');
    expect(
      extractQuizJson('inactive={}; active = {"id":1};', 'active'),
      '{"id":1}',
    );
  });
  test('missing, incomplete and mismatched assignments return null', () {
    expect(extractQuizJson('other=[];', 'quizList'), isNull);
    expect(extractQuizJson('quizList=[{"a":1}', 'quizList'), isNull);
    expect(extractQuizJson('quizList=[};', 'quizList'), isNull);
  });
}
