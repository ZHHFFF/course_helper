/// PPT 逐页识题
///
/// 核心前提（也是这套方案能又快又准的原因）：
/// 雨课堂取整份 PPT 是**一个** HTTP 响应，每页的题目信息
/// （`slide.problem`：题号、题型、题干、选项）就在那个响应里。
///
/// 所以「识题」根本不需要下载图片、不需要翻页、不需要视觉模型 ——
/// 整份 PPT 拿到手的那一刻，几十毫秒就能把所有题扫出来。
/// 只有当某页的题干和选项**全是空**（题目整个画成图片）时才需要图片识别，
/// 那种情况这里标记为 [SlideQuestion.needsVision]，交给用户手动触发。
///
/// 这是「某一页获取完成就立即判断有没有题」的最强形式：
/// 整份 PPT 是一次性到的，所以是「拿到就全判完」。
library;

import 'package:flutter/foundation.dart';

import '../api/answer_search.dart';
import '../models/answer_result.dart';
import '../models/presentation.dart';
import 'question_hash.dart';

/// 从 PPT 里扫出来的一道题
@immutable
class SlideQuestion {
  /// 幻灯片下标（0-based）
  final int slideIndex;

  /// 题目指纹（缓存键）
  final String hash;

  final StandardizedQuestion question;

  /// 题干和选项都拿不到，只有一张图 —— 需要视觉模型才能读题
  final bool needsVision;

  const SlideQuestion({
    required this.slideIndex,
    required this.hash,
    required this.question,
    required this.needsVision,
  });

  /// 是否值得进后台 AI 队列
  ///
  /// 需要视觉识别的题不进队列：那种请求又慢又贵，交给用户手动点「搜索答案」。
  bool get autoSearchable => !needsVision;

  String get typeLabel => question.typeLabel;
}

/// 一次扫描的结果
class SlideScanResult {
  /// 去重后的题目列表，按页序排列
  final List<SlideQuestion> questions;

  /// 页下标 → 该页的题（没有题的页不在表里）
  final Map<int, SlideQuestion> bySlideIndex;

  /// 指纹 → 题（同一道题出现在多页时只保留第一次出现的页）
  final Map<String, SlideQuestion> byHash;

  /// 有 problem 但内容全空、连图都没有，问也没法问，直接跳过
  final int skippedNotUsable;

  /// 重复题（同一道题在后续页又出现）的数量
  final int duplicateCount;

  const SlideScanResult({
    required this.questions,
    required this.bySlideIndex,
    required this.byHash,
    this.skippedNotUsable = 0,
    this.duplicateCount = 0,
  });

  const SlideScanResult.empty()
      : questions = const [],
        bySlideIndex = const {},
        byHash = const {},
        skippedNotUsable = 0,
        duplicateCount = 0;

  bool get isEmpty => questions.isEmpty;

  int get total => questions.length;

  /// 需要进后台 AI 队列的题目
  List<SlideQuestion> get autoSearchable =>
      questions.where((q) => q.autoSearchable).toList();

  /// 需要视觉识别的题目
  List<SlideQuestion> get visionOnly =>
      questions.where((q) => q.needsVision).toList();

  SlideQuestion? forSlide(int slideIndex) => bySlideIndex[slideIndex];
}

class SlideScanner {
  SlideScanner._();

  /// 扫整份 PPT
  static SlideScanResult scan(Presentation presentation) =>
      scanSlides(presentation.slides);

  static SlideScanResult scanSlides(List<PresentationSlide> slides) {
    final questions = <SlideQuestion>[];
    final bySlideIndex = <int, SlideQuestion>{};
    final byHash = <String, SlideQuestion>{};
    var skipped = 0;
    var duplicates = 0;

    for (var i = 0; i < slides.length; i++) {
      final slide = slides[i];
      final problem = slide.problem;
      if (problem == null) continue;

      final question = AnswerSearchApi.fromRainClassroomProblem(
        problem,
        slideText: slideTextOf(slide),
        imageUrl: slideImageOf(slide),
      );

      // 题干、选项、图片全都拿不到 —— 服务器给了个空壳，跳过
      if (!question.isUsable) {
        skipped++;
        continue;
      }

      final hash = QuestionHash.of(question);

      // 同一道题被多页引用（雨课堂很常见：题目页 + 答题页）
      if (byHash.containsKey(hash)) {
        duplicates++;
        continue;
      }

      final item = SlideQuestion(
        slideIndex: i,
        hash: hash,
        question: question,
        needsVision: !question.hasText,
      );

      questions.add(item);
      bySlideIndex[i] = item;
      byHash[hash] = item;
    }

    return SlideScanResult(
      questions: questions,
      bySlideIndex: bySlideIndex,
      byHash: byHash,
      skippedNotUsable: skipped,
      duplicateCount: duplicates,
    );
  }

  /// 一页 PPT 里的所有文字
  ///
  /// 题干为空时拿它当题目内容（很多题是把题干做成文本框放在页面上）。
  static String slideTextOf(PresentationSlide slide) {
    if (slide.shapes.isEmpty) return '';

    final buffer = StringBuffer();
    for (final shape in slide.shapes) {
      final text = shape.text?.trim() ?? '';
      if (text.isEmpty) continue;
      buffer.writeln(text);
    }
    return buffer.toString().trim();
  }

  /// 一页 PPT 的图片地址（优先 `coverAlt`，它比 `cover` 清晰）
  static String slideImageOf(PresentationSlide slide) {
    final alt = slide.coverAlt.trim();
    if (alt.isNotEmpty) return alt;
    return slide.cover.trim();
  }

  /// 整份 PPT 需要预取的图片地址（按页序、去重）
  static List<String> imageUrlsOf(List<PresentationSlide> slides) {
    final urls = <String>[];
    final seen = <String>{};
    for (final slide in slides) {
      final url = slideImageOf(slide);
      if (url.isEmpty) continue;
      if (seen.add(url)) urls.add(url);
    }
    return urls;
  }
}
