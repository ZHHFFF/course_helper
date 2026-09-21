/// 「把 AI 给的答案写进作答区」这一步的纯逻辑
///
/// 抽出来单独放，是为了能写单测 —— 这部分最容易悄悄出错：
/// 不同题型读的字段不一样（见 `_buildAnswerOptions()` 的分支），
/// 写错字段的表现是「填了等于没填」，在 UI 上很难看出原因。
///
/// 这个文件**不依赖 Flutter**，所以 `flutter test` 里能直接跑。
library;

/// 作答区该写哪个字段
enum AnswerField {
  /// 单选 / 多选 / 判断 / 投票 → `_answer`（选项 key 列表）
  choice,

  /// 填空题，题干里有 `[填空N]` 标记 → `_answer`（每空一项）
  fillBlanks,

  /// 填空题，没有标记 → UI 退化成单个输入框，读 `_textAnswer`
  fillSingle,

  /// 简答题 → `_textAnswer`
  shortAnswer,
}

class AnswerFilling {
  AnswerFilling._();

  /// 填空题的标记，和 `_buildFillBlankInputs()` 里用的正则保持一致
  static final RegExp blankPattern = RegExp(r'\[填空\d*\]');

  /// 题干里有几个空
  static int blankCount(String body) => blankPattern.allMatches(body).length;

  /// 按题型决定该写哪个字段
  ///
  /// 这里的 problemType 是雨课堂的原始值：
  /// 1 单选 / 2 多选 / 3 投票 / 4 填空 / 5 简答 / 6 判断
  static AnswerField fieldFor(int problemType, String body) {
    if (problemType == 4) {
      return blankCount(body) > 0
          ? AnswerField.fillBlanks
          : AnswerField.fillSingle;
    }
    if (problemType == 5) return AnswerField.shortAnswer;
    return AnswerField.choice;
  }

  /// 把 AI 给的答案文本拆成每个空的答案
  ///
  /// AI 可能返回 `A、B` / `A,B` / `A; B` / `A\nB` 等各种写法，
  /// 统一按分隔符拆。**空位数以题干为准**：多了截断，少了补空串
  /// （补空串而不是丢弃，否则 `_answer` 的长度和输入框数量对不上）。
  ///
  /// 返回空列表表示「没拆出任何有效答案」，调用方应该放弃填充。
  static List<String> splitBlanks(String answer, int count) {
    if (count <= 0) return const [];
    final parts = answer
        .split(RegExp(r'[\n,，;；、]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return const [];

    final list = List<String>.filled(count, '');
    for (var i = 0; i < count && i < parts.length; i++) {
      list[i] = parts[i];
    }
    return list;
  }
}
