/// 答案检索模块数据模型
/// 定义标准化的题目、选项和检索结果

/// 标准化题目 - 从学习通或雨课堂题目数据中提取
class StandardizedQuestion {
  /// 题干文本（从服务器题目数据中提取）
  final String questionText;

  /// 题型：single / multiple / judgement / fillBlank / shortAnswer / polling / unknown
  final String questionType;

  final List<StandardizedOption> options;

  /// 原始答案数据（学习通特有，包含 isanswer 标记）
  final Map<String, dynamic>? rawAnswerData;

  /// 课件文本：雨课堂 PPT 当前页里所有形状的文字
  /// 有些题目的题干只写在 PPT 上、problem.body 为空，这里可以兜底
  final String slideText;

  /// 带题图片地址列表（雨课堂当前页 PPT 封面 / 学习通题干里的插图）
  final List<String> imageUrls;

  /// 拉取图片所需的请求头（学习通图片需要鉴权）
  final Map<String, String>? imageHeaders;

  StandardizedQuestion({
    required this.questionText,
    required this.questionType,
    this.options = const [],
    this.rawAnswerData,
    this.slideText = '',
    this.imageUrls = const [],
    this.imageHeaders,
  });

  /// 实际用于提问的文本：优先题干，其次课件文本
  String get effectiveText {
    if (questionText.trim().isNotEmpty) return questionText.trim();
    return slideText.trim();
  }

  /// 是否拿到了可用的题干文本
  bool get hasText => effectiveText.isNotEmpty;

  /// 是否带有可识别的图片
  bool get hasImage => imageUrls.any((u) => u.trim().isNotEmpty);

  /// 是否需要靠图片来识别题目（没文本、但有图）
  bool get needsImageRecognition => !hasText && hasImage;

  /// 题型中文名
  String get typeLabel => typeLabelOf(questionType);

  /// 是否选择题（单选 / 多选 / 判断 / 投票）
  bool get isChoice =>
      questionType == 'single' ||
      questionType == 'multiple' ||
      questionType == 'judgement' ||
      questionType == 'polling';

  /// 是否多选类
  bool get isMultipleChoice =>
      questionType == 'multiple' || questionType == 'polling';

  /// 题目是否完整（有文本或有图）
  bool get isUsable => hasText || hasImage;

  static String typeLabelOf(String type) {
    switch (type) {
      case 'single':
        return '单选题';
      case 'multiple':
        return '多选题';
      case 'judgement':
        return '判断题';
      case 'fillBlank':
        return '填空题';
      case 'shortAnswer':
        return '简答题';
      case 'polling':
        return '投票题';
      default:
        return '未知题型';
    }
  }

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

  /// 从 HTML 中提取图片地址
  static List<String> extractImageUrls(String html) {
    final urls = <String>[];
    final reg = RegExp(
      r'''<img[^>]+src\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final m in reg.allMatches(html)) {
      final url = m.group(1)?.trim() ?? '';
      if (url.isEmpty) continue;
      if (url.startsWith('data:')) continue;
      if (!urls.contains(url)) urls.add(url);
    }
    return urls;
  }

  /// 从学习通 quiz 数据构建标准化题目
  factory StandardizedQuestion.fromChaoxing(
    Map<String, dynamic> quiz, {
    Map<String, String>? imageHeaders,
    String Function(String url)? resolveImageUrl,
  }) {
    final rawType = quiz['type'];
    final type = rawType is int ? rawType : int.tryParse('$rawType');

    final contentHtml = quiz['content'] as String? ?? '';
    final questionText = extractPlainText(contentHtml);

    final answers = quiz['answer'] as List? ?? [];
    final options = answers.map<StandardizedOption>((opt) {
      final optHtml = opt['content'] as String? ?? '';
      return StandardizedOption(
        key: opt['name']?.toString() ?? '',
        value: extractPlainText(optHtml),
        isCorrect: opt['isanswer'] == true,
      );
    }).toList();

    final questionType = _chaoxingType(type, options);

    // 题干里的插图（学习通图片需要鉴权头）
    var imageUrls = extractImageUrls(contentHtml);
    if (resolveImageUrl != null) {
      imageUrls = imageUrls.map(resolveImageUrl).toList();
    }

    return StandardizedQuestion(
      questionText: questionText,
      questionType: questionType,
      options: options,
      rawAnswerData: quiz,
      imageUrls: imageUrls,
      imageHeaders: imageHeaders,
    );
  }

  /// 学习通题型判定：优先用 type 字段，缺失时按选项特征推断
  static String _chaoxingType(int? type, List<StandardizedOption> options) {
    if (type != null) {
      switch (type) {
        case 0:
          return 'single';
        case 1:
          return 'multiple';
        case 2:
          return 'fillBlank';
        case 3:
        case 16:
          return 'judgement';
        case 4:
          return 'shortAnswer';
        case 5:
          return 'polling';
        default:
          break;
      }
    }
    return inferTypeFromOptions(options);
  }

  /// 按选项特征推断题型（服务器没给 type 时的兜底）
  static String inferTypeFromOptions(List<StandardizedOption> options) {
    if (options.isEmpty) return 'unknown';

    final labels = options.map((o) => o.value.trim()).toList();
    final isJudgementSet = labels.length == 2 &&
        labels.every((v) =>
            v == '对' ||
            v == '错' ||
            v == '正确' ||
            v == '错误' ||
            v == '是' ||
            v == '否' ||
            v == 'True' ||
            v == 'False');
    if (isJudgementSet) return 'judgement';

    final correctCount = options.where((o) => o.isCorrect == true).length;
    if (correctCount > 1) return 'multiple';
    if (correctCount == 1) return 'single';

    // 没有任何正确答案标记时，看选项数量粗略判断
    return options.length <= 2 ? 'judgement' : 'single';
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
    buffer.writeln(effectiveText);
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
