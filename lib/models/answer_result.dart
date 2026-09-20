/// 答案检索模块数据模型
/// 定义标准化的题目、选项和检索结果

/// 标准化题目 - 从学习通或雨课堂题目数据中提取
class StandardizedQuestion {
  final String questionText;
  final String questionType;
  final List<StandardizedOption> options;

  /// 原始答案数据（学习通特有，包含 isanswer 标记）
  final Map<String, dynamic>? rawAnswerData;

  StandardizedQuestion({
    required this.questionText,
    required this.questionType,
    this.options = const [],
    this.rawAnswerData,
  });

  /// 从 HTML 中提取纯文本
  static String extractPlainText(String html) {
    String text = html.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = text.replaceAll('&nbsp;', ' ');
    text = text.replaceAll('&amp;', '&');
    text = text.replaceAll('&lt;', '<');
    text = text.replaceAll('&gt;', '>');
    text = text.replaceAll('&quot;', '"');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  /// 从学习通 quiz 数据构建标准化题目
  factory StandardizedQuestion.fromChaoxing(Map<String, dynamic> quiz) {
    final type = quiz['type'] as int? ?? 0;
    String questionType;
    switch (type) {
      case 0:
        questionType = 'single';
        break;
      case 1:
        questionType = 'multiple';
        break;
      case 2:
        questionType = 'fillBlank';
        break;
      case 3:
      case 16:
        questionType = 'judgement';
        break;
      case 4:
        questionType = 'shortAnswer';
        break;
      default:
        questionType = 'unknown';
    }

    final contentHtml = quiz['content'] as String? ?? '';
    final questionText = extractPlainText(contentHtml);

    final answers = quiz['answer'] as List? ?? [];
    final options = answers.map<StandardizedOption>((opt) {
      final contentHtml = opt['content'] as String? ?? '';
      return StandardizedOption(
        key: opt['name']?.toString() ?? '',
        value: extractPlainText(contentHtml),
        isCorrect: opt['isanswer'] == true,
      );
    }).toList();

    return StandardizedQuestion(
      questionText: questionText,
      questionType: questionType,
      options: options,
      rawAnswerData: quiz,
    );
  }

  /// 是否有内置答案数据（学习通服务器返回的 isanswer 标记）
  bool get hasBuiltinAnswer {
    if (rawAnswerData == null) return false;
    final answers = rawAnswerData!['answer'] as List? ?? [];
    return answers.any((opt) => opt['isanswer'] == true);
  }

  /// 获取内置正确答案
  String? get builtinAnswer {
    if (!hasBuiltinAnswer) return null;
    final answers = rawAnswerData!['answer'] as List;
    final correct =
        answers.where((opt) => opt['isanswer'] == true).toList();
    return correct.map((opt) => opt['name'].toString()).join('');
  }

  /// 获取内置答案的详情（用于填空/简答题）
  List<String> get builtinAnswerDetails {
    if (!hasBuiltinAnswer) return [];
    final answers = rawAnswerData!['answer'] as List;
    return answers.map<String?>((opt) {
      final content = opt['content'] as String? ?? '';
      return extractPlainText(content);
    }).where((s) => s != null && s.isNotEmpty).cast<String>().toList();
  }

  /// 生成用于检索的文本摘要
  String toSearchQuery() {
    final buffer = StringBuffer();
    buffer.writeln(questionText);
    if (options.isNotEmpty) {
      for (final opt in options) {
        buffer.writeln('${opt.key}. ${opt.value}');
      }
    }
    return buffer.toString().trim();
  }
}

/// 标准化选项
class StandardizedOption {
  final String key;
  final String value;

  /// 是否为正确答案（学习通从 isanswer 获取，雨课堂为 null）
  final bool? isCorrect;

  StandardizedOption({
    required this.key,
    required this.value,
    this.isCorrect,
  });
}

/// 答案检索结果
class AnswerSearchResult {
  /// 答案文本（选项字母如 "A"/"AB"，或直接答案文本）
  final String answer;

  /// 来源描述
  final String source;

  /// 置信度 0.0-1.0
  final double confidence;

  /// 可选的说明
  final String? explanation;

  /// 来源类型
  final AnswerSourceType sourceType;

  AnswerSearchResult({
    required this.answer,
    required this.source,
    required this.confidence,
    this.explanation,
    required this.sourceType,
  });
}

/// 答案来源类型
enum AnswerSourceType {
  /// 内置答案 - 从服务器返回数据中提取（学习通 isanswer=true）
  builtin,

  /// AI 检索 - 通过 AI API 获取
  aiProvider,
}

extension AnswerSourceTypeExtension on AnswerSourceType {
  String get label {
    switch (this) {
      case AnswerSourceType.builtin:
        return '内置答案';
      case AnswerSourceType.aiProvider:
        return 'AI检索';
    }
  }
}

