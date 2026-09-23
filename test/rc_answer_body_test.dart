// 钉住雨课堂答题请求的编码行为 —— 防「多选题静默少交选项」回归。
//
// 真机 bug（2026-09-23）：多选题预选了多个选项，实际只提交了一个。
//
// 根因：`RCCourseApi.answer()` 只设了 `authorization`，**没有 `Content-Type`**。
// Dio 看到 body 是 `Map` 又没有 JSON content-type，就按
// `application/x-www-form-urlencoded` 编码，于是
//
//     result: ['A','B']  →  result=A&result=B   （重复参数）
//
// 服务端按标量绑定 `result`，只取到第一个 'A' —— 第二个选项就丢了。
// 单选之所以一直正常：`result=['A']` 编成 `result=A`，两种写法服务端都能吃。
//
// 所以这个文件做两件事：
//   1. 断言 `answerHeaders()` 里带上了 `Content-Type: application/json`
//   2. 断言带这组头编码出来的 body 是 JSON、且 `result` 是数组
//      （而不是被展平成重复参数）
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/api/course.dart';

/// 按 `answer()` 的方式编码一次请求体，返回实际会发出去的字符串。
Future<String> encodeBody(Map<String, String> headers, Map<String, dynamic> body) {
  final options = RequestOptions(
    path: '/api/v3/lesson/problem/answer',
    method: 'POST',
    headers: headers,
    data: body,
  );
  return BackgroundTransformer().transformRequest(options);
}

void main() {
  group('答题请求头', () {
    test('必须带 Content-Type: application/json', () {
      final headers = RCCourseApi.answerHeaders('tok');
      // 漏掉这行 = 多选答案被编成表单 → 只提交第一个选项
      expect(headers['Content-Type'], 'application/json');
      expect(headers['authorization'], 'Bearer tok');
    });
  });

  group('多选（problemType=2）请求体', () {
    test('result 必须是数组，不能被展平成重复参数', () async {
      final headers = RCCourseApi.answerHeaders('tok');
      final body = RCCourseApi.buildAnswerBody(
        problemId: 'p1',
        problemType: 2,
        timestampMs: 1700000000000,
        options: ['A', 'B'],
      );

      expect(body['result'], ['A', 'B']);

      final encoded = await encodeBody(headers, body);

      // 这是修复前真实发生过的形态，绝不能再出现
      expect(encoded.contains('result=A&result=B'), isFalse,
          reason: '被 urlencode 展平了：$encoded');

      // 必须是 JSON，且 result 是数组
      expect(encoded.trimLeft().startsWith('{'), isTrue,
          reason: 'body 不是 JSON：$encoded');
      expect(encoded.contains('"result":["A","B"]'), isTrue,
          reason: 'result 没有编成数组：$encoded');
    });

    test('三个选项也要完整带上', () async {
      final body = RCCourseApi.buildAnswerBody(
        problemId: 'p1',
        problemType: 2,
        timestampMs: 1,
        options: ['A', 'B', 'D'],
      );
      final encoded = await encodeBody(RCCourseApi.answerHeaders('t'), body);
      expect(encoded.contains('"result":["A","B","D"]'), isTrue,
          reason: encoded);
    });
  });

  group('对照：单选（problemType=1）', () {
    test('result 仍是数组（单个元素）', () async {
      final body = RCCourseApi.buildAnswerBody(
        problemId: 'p1',
        problemType: 1,
        timestampMs: 1,
        options: ['C'],
      );
      final encoded = await encodeBody(RCCourseApi.answerHeaders('t'), body);
      expect(encoded.contains('"result":["C"]'), isTrue, reason: encoded);
    });
  });

  group('简答（problemType=5）', () {
    test('result 是 {content, pics, videos} 结构，不受本次改动影响', () {
      final body = RCCourseApi.buildAnswerBody(
        problemId: 'p1',
        problemType: 5,
        timestampMs: 1,
        content: '我的答案',
      );
      final result = body['result'] as Map;
      expect(result['content'], '我的答案');
      expect(result['videos'], isEmpty);
      expect(result['pics'], isNotEmpty);
    });

    test('带图片时 pics 里是 pic/thumb 两项', () {
      final body = RCCourseApi.buildAnswerBody(
        problemId: 'p1',
        problemType: 5,
        timestampMs: 1,
        content: '',
        imageUrls: ['https://x/a.png'],
      );
      final pics = (body['result'] as Map)['pics'] as List;
      expect(pics.length, 1);
      expect(pics.first['pic'], 'https://x/a.png');
      expect(pics.first['thumb'], 'https://x/a.png?imageView2/2/w/568');
    });
  });

  group('retry 包一层 problems', () {
    test('retry=true 时外层是 {problems: [...]}', () {
      final body = RCCourseApi.buildAnswerBody(
        problemId: 'p1',
        problemType: 2,
        timestampMs: 1,
        options: ['A', 'B'],
        retry: true,
      );
      final problems = body['problems'] as List;
      expect(problems.length, 1);
      expect(problems.first['problemId'], 'p1');
      expect(problems.first['result'], ['A', 'B']);
      expect(problems.first.containsKey('retry_times'), isTrue);
    });
  });
}
