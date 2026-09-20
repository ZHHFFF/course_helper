/// 答案检索模块数据模型
/// 定义标准化的题目、选项和检索结果
library;

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

  /// 服务器给这道题的唯一 ID（雨课堂 problemId / 学习通题目 ID）
  ///
  /// 仅用于「题干与选项都为空、内容指纹没有区分度」时兜底当缓存键，
  /// 不参与正常的内容指纹计算 —— 见 `QuestionHash.of()`。
  final String problemId;

  StandardizedQuestion({
    required this.questionText,
    required this.questionType,
    this.options = const [],
    this.rawAnswerData,
    this.slideText = '',
    this.imageUrls = const [],
    this.imageHeaders,
    this.problemId = '',
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

  /// AI 明确给出的选项 key 列表（如 ["A", "C"]）
  /// 非选择题（填空/简答）为空
  final List<String> answerKeys;

  AnswerSearchResult({
    required this.answer,
    required this.source,
    required this.confidence,
    this.explanation,
    required this.sourceType,
    this.answerKeys = const [],
  });

  /// 把答案映射到题目实际存在的选项 key 上，用于一键回填选项
  ///
  /// 匹配顺序：
  /// 1. 判断题（选项值是「对/错/正确/错误/√/×」等）优先映射
  /// 2. 使用 [answerKeys]
  /// 3. 从 [answer] 文本里抠出英文字母（"AC" / "A,C" / "选A和C" 都能识别）
  ///
  /// 返回值只包含题目真实存在的 key，并按选项原始顺序排列。
  /// 匹配不到时返回空列表。
  List<String> matchOptionKeys(List<StandardizedOption> options) {
    if (options.isEmpty) return const [];

    // 1. 判断题：选项值本身就是「对 / 错」时，key 可能不是字母
    if (answerKeys.isEmpty) {
      final judgementKey = judgementOptionKey(options, answer);
      if (judgementKey != null) return [judgementKey];
    }

    final upperKeys = <String>[];
    for (final opt in options) {
      final key = opt.key.trim().toUpperCase();
      if (key.isNotEmpty && !upperKeys.contains(key)) upperKeys.add(key);
    }
    if (upperKeys.isEmpty) return const [];

    final matched = <String>{};

    void collect(String raw) {
      for (final letter in lettersOf(raw)) {
        if (upperKeys.contains(letter)) matched.add(letter);
      }
    }

    for (final key in answerKeys) {
      collect(key);
    }
    if (matched.isEmpty) {
      collect(answer);
    }
    if (matched.isEmpty) return const [];

    return options
        .where((o) => matched.contains(o.key.trim().toUpperCase()))
        .map((o) => o.key)
        .toList();
  }

  /// 从文本里抠出所有英文字母并大写去重
  ///
  /// "AC" / "A,C" / "选A和C" 都会得到 [A, C]
  static List<String> lettersOf(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const [];

    final result = <String>[];
    for (final match in RegExp('[A-Za-z]').allMatches(text)) {
      final letter = match.group(0)!.toUpperCase();
      if (!result.contains(letter)) result.add(letter);
    }
    return result;
  }

  /// 判断题答案 → 选项 key
  ///
  /// 「对 / 正确 / 是 / T / √」映射到值为「对」的那个选项，
  /// 「错 / 错误 / 否 / F / ×」映射到值为「错」的那个选项。
  static String? judgementOptionKey(
    List<StandardizedOption> options,
    String answer,
  ) {
    final text = answer.trim();
    if (text.isEmpty) return null;

    final lower = text.toLowerCase();
    bool? wantTrue;

    // 先判否定，避免「不正确」被当成「正确」
    if (lower.contains('不正确') ||
        lower.contains('错误') ||
        lower.contains('错') ||
        lower.contains('否') ||
        lower.contains('false') ||
        text.contains('×') ||
        text.contains('✗') ||
        lower == 'f' ||
        lower == 'n') {
      wantTrue = false;
    } else if (lower.contains('正确') ||
        lower.contains('对') ||
        lower.contains('是') ||
        lower.contains('true') ||
        text.contains('√') ||
        text.contains('✓') ||
        lower == 't' ||
        lower == 'y') {
      wantTrue = true;
    }

    if (wantTrue == null) return null;

    const trueWords = ['对', '正确', '是', '√', '✓', 'true', 'yes', 't', 'y'];
    const falseWords = ['错', '错误', '否', '×', '✗', 'false', 'no', 'f', 'n'];

    for (final opt in options) {
      final value = opt.value.trim().toLowerCase();
      if (wantTrue && trueWords.contains(value)) return opt.key;
      if (!wantTrue && falseWords.contains(value)) return opt.key;
    }
    return null;
  }
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
