/// 题目指纹（questionHash）
///
/// 用途：把「题干 + 题型 + 选项」归一化后算 SHA-256，作为答案缓存的键。
/// 这样同一道题即使因为页面重新解析导致排版/空白/全角半角略有差异，
/// 也能落到同一个指纹上，从而复用已经拿到的 AI 答案。
///
/// 设计要点：
/// 1. 只做「格式化」层面的归一化，不做语义归一化（不做同义词替换、不排序选项）
/// 2. **选项顺序必须保留** —— 选项顺序一变，答案字母的含义就变了
///    （原来 B 是「苹果」，重排后 B 成了「香蕉」），排序会让答案映射错位
/// 3. 题干优先取 `problem.body`；body 为空时用**课件文字**兜底。
///    这一条很关键：雨课堂有些题 body 是空的、题干画在 PPT 上，
///    此时如果只拿选项算指纹，两道选项相同的题就会撞成同一个 key，
///    导致 A 题复用 B 题的答案。
/// 4. 题干和选项都为空时（题目完全只存在于图片里），内容指纹毫无区分度，
///    退化为使用服务器给的 problemId
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/answer_result.dart';

class QuestionHash {
  QuestionHash._();

  /// 空白字符：半角空白 + 全角空格(U+3000) + 不换行空格(U+00A0)
  static final RegExp _whitespace = RegExp(r'[\s\u3000\u00a0]+');

  /// 生成题目指纹（64 位十六进制 SHA-256）
  static String of(StandardizedQuestion question) {
    // 题干优先用 problem.body，为空时退回课件文字（PPT 上画的题干）
    final rawBody = question.questionText.trim().isNotEmpty
        ? question.questionText
        : question.slideText;
    final body = normalize(rawBody);
    final options = question.options
        .map((o) => '${normalize(o.key)}:${normalize(o.value)}')
        .join('|');

    // 题干和选项都拿不到 → 内容指纹没有区分度，改用 problemId 兜底
    if (body.isEmpty && options.isEmpty) {
      final problemId = question.problemId.trim();
      if (problemId.isNotEmpty) {
        return 'pid-${_sha256(problemId)}';
      }
      // 连 problemId 都没有（理论上不会发生），退到图片地址，至少能区分不同页
      final image =
          question.imageUrls.isEmpty ? '' : question.imageUrls.first.trim();
      return 'img-${_sha256(image)}';
    }

    return _sha256('$body|${question.questionType}|$options');
  }

  /// 归一化单段文本
  ///
  /// 顺序：去 HTML → 全角转半角 → 去掉所有空白 → 转小写 → 去掉首尾标点
  static String normalize(String raw) {
    if (raw.isEmpty) return '';
    var text = StandardizedQuestion.extractPlainText(raw);
    text = toHalfWidth(text);
    text = text.replaceAll(_whitespace, '');
    text = text.toLowerCase();
    text = _trimEdgePunctuation(text);
    return text;
  }

  /// 全角字符转半角
  ///
  /// 全角区 U+FF01..U+FF5E 与 ASCII U+0021..U+007E 一一对应，差值 0xFEE0；
  /// 全角空格 U+3000 单独映射为普通空格。
  static String toHalfWidth(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (rune == 0x3000) {
        buffer.write(' ');
      } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
        buffer.writeCharCode(rune - 0xFEE0);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// 去掉首尾的标点/符号（保留中间部分）
  ///
  /// 只动首尾：题干末尾有没有问号、句号不应该影响指纹，
  /// 但中间的标点可能是有意义的（比如「A、B 两点」），不能乱删。
  static String _trimEdgePunctuation(String text) {
    var start = 0;
    var end = text.length;
    while (start < end && !_isMeaningful(text.codeUnitAt(start))) {
      start++;
    }
    while (end > start && !_isMeaningful(text.codeUnitAt(end - 1))) {
      end--;
    }
    return text.substring(start, end);
  }

  /// 是否算「有意义的字符」（字母、数字、CJK、假名、希腊字母）
  static bool _isMeaningful(int code) {
    if (code >= 0x30 && code <= 0x39) return true; // 0-9
    if (code >= 0x61 && code <= 0x7a) return true; // a-z（已转小写）
    if (code >= 0x4e00 && code <= 0x9fff) return true; // CJK 统一表意文字
    if (code >= 0x3040 && code <= 0x30ff) return true; // 日文假名
    if (code >= 0x0370 && code <= 0x03ff) return true; // 希腊字母
    return false;
  }

  static String _sha256(String input) =>
      sha256.convert(utf8.encode(input)).toString();
}
