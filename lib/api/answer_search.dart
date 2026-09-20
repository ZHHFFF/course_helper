/// 答案检索 API 模块
/// 支持可插拔的检索源：内置答案 > AI 检索
///
/// 能力说明：
/// 1. 题型识别：自动区分单选 / 多选 / 判断 / 填空 / 简答，并提示 AI 按题型作答
/// 2. 课件识图：雨课堂题目只写在 PPT 上时，自动把当前页图片发给多模态模型识别
/// 3. 连通测试：设置页可一键测试 API 是否可用
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/answer_result.dart';
import '../models/presentation.dart';
import '../utils/network_error.dart';
import '../utils/storage.dart';

/// 检索源抽象接口 - 可插拔
abstract class AnswerSearchProvider {
  String get name;

  Future<List<AnswerSearchResult>> search(StandardizedQuestion question);
}

/// 内置答案检索源
/// 优先使用项目已有的答案数据（学习通服务器返回的 isanswer 标记）
class BuiltinAnswerProvider implements AnswerSearchProvider {
  @override
  String get name => '内置答案';

  @override
  Future<List<AnswerSearchResult>> search(StandardizedQuestion question) async {
    if (!question.hasBuiltinAnswer) return [];

    final answer = question.builtinAnswer!;

    // 对于填空/简答题，提取详细答案文本
    String displayAnswer = answer;
    if (question.questionType == 'fillBlank' ||
        question.questionType == 'shortAnswer') {
      final details = question.builtinAnswerDetails;
      if (details.isNotEmpty) {
        displayAnswer = details.join('；');
      }
    }

    return [
      AnswerSearchResult(
        answer: displayAnswer,
        source: '服务器返回',
        confidence: 1.0,
        explanation: '此答案来自服务器直接返回的正确答案标记(isanswer=true)，可信度最高',
        sourceType: AnswerSourceType.builtin,
      ),
    ];
  }
}

/// AI 检索源
/// 调用 OpenAI 兼容的 Chat Completions API 进行答案检索
/// 支持多模态：题目只有图片时，会把图片以 base64 形式一起发过去
class AIAnswerProvider implements AnswerSearchProvider {
  final String apiUrl;
  final String apiKey;
  final String model;

  /// 最近一次检索失败的原因（供界面提示）
  String? lastError;

  /// 单张图片大小上限，超过则不发（避免请求体过大）
  static const int _maxImageBytes = 5 * 1024 * 1024;

  /// 最多附带几张图片
  static const int _maxImages = 3;

  AIAnswerProvider({
    required this.apiUrl,
    required this.apiKey,
    required this.model,
  });

  @override
  String get name => 'AI检索';

  @override
  Future<List<AnswerSearchResult>> search(StandardizedQuestion question) async {
    lastError = null;

    if (apiUrl.isEmpty || apiKey.isEmpty) {
      lastError = '未配置 API 地址或 API Key';
      return [];
    }

    if (!question.isUsable) {
      lastError = '没有拿到题目内容（题干为空且没有课件图片）';
      return [];
    }

    try {
      final prompt = _buildPrompt(question);
      final imageParts = await _loadImageDataUrls(question);

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));

      final response = await dio.post(
        apiUrl,
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
        data: jsonEncode({
          'model': model,
          'messages': [
            {
              'role': 'system',
              'content': '你是一个答题助手。请根据题目和选项作答。'
                  '要求先给出答案，再给出分析过程。'
                  '以JSON格式回复：{"answer": "答案", "confidence": 0.0到1.0的数值, "explanation": "分析过程"}。'
                  '对于选择题，answer为选项字母(如A或AB)，多选题必须给出全部正确选项；'
                  '对于判断题为"对"或"错"；'
                  '对于填空/简答题，直接给出答案文本。'
                  'explanation中先说明为什么选这个答案，再补充相关知识或解析。'
                  '如果题目以图片形式给出，请先仔细识别图片中的题干和选项，再作答。'
                  '如果不确定答案，confidence设为0.3以下。'
                  '只返回JSON，不要返回其他内容。',
            },
            {
              'role': 'user',
              'content': _buildUserContent(prompt, imageParts),
            },
          ],
          'temperature': 0.3,
        }),
      );

      final content = response.data['choices']?[0]?['message']?['content']
          as String?;
      if (content == null) {
        lastError = 'AI 返回内容为空';
        return [];
      }

      return _parseAIResponse(content);
    } catch (e) {
      final info = describeError(e);
      lastError = info.message;
      debugPrint('AI 检索失败：$e');
      return [];
    }
  }

  /// 组装 user 消息：纯文本，或 文本 + 图片
  Object _buildUserContent(String prompt, List<String> imageDataUrls) {
    if (imageDataUrls.isEmpty) return prompt;

    final parts = <Map<String, dynamic>>[
      {'type': 'text', 'text': prompt},
    ];
    for (final dataUrl in imageDataUrls) {
      parts.add({
        'type': 'image_url',
        'image_url': {'url': dataUrl},
      });
    }
    return parts;
  }

  /// 把题目关联的图片下载下来，转成 base64 data URL
  /// 这样不受图片防盗链、鉴权头等限制
  Future<List<String>> _loadImageDataUrls(StandardizedQuestion question) async {
    final urls = question.imageUrls
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .take(_maxImages)
        .toList();
    if (urls.isEmpty) return [];

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 25),
    ));

    final result = <String>[];
    for (final url in urls) {
      try {
        if (url.startsWith('data:')) {
          result.add(url);
          continue;
        }
        final resp = await dio.get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            headers: question.imageHeaders,
          ),
        );
        final bytes = resp.data;
        if (bytes == null || bytes.isEmpty) continue;
        if (bytes.length > _maxImageBytes) {
          debugPrint('图片过大，跳过：$url (${bytes.length} bytes)');
          continue;
        }
        final mime = _guessMime(url, resp.headers);
        result.add('data:$mime;base64,${base64Encode(bytes)}');
      } catch (e) {
        debugPrint('图片下载失败（$url）：$e');
      }
    }
    return result;
  }

  String _guessMime(String url, Headers? headers) {
    final contentType = headers?.value('content-type');
    if (contentType != null && contentType.startsWith('image/')) {
      return contentType.split(';').first.trim();
    }
    final lower = url.toLowerCase();
    if (lower.contains('.png')) return 'image/png';
    if (lower.contains('.gif')) return 'image/gif';
    if (lower.contains('.webp')) return 'image/webp';
    if (lower.contains('.bmp')) return 'image/bmp';
    return 'image/jpeg';
  }

  String _buildPrompt(StandardizedQuestion question) {
    final buffer = StringBuffer();

    buffer.writeln('题型：${question.typeLabel}');
    switch (question.questionType) {
      case 'multiple':
      case 'polling':
        buffer.writeln('注意：本题为多选题，答案可能不止一个，请给出全部正确选项字母（如 ABD）。');
        break;
      case 'single':
        buffer.writeln('注意：本题为单选题，只选一个选项。');
        break;
      case 'judgement':
        buffer.writeln('注意：本题为判断题，答案只能是「对」或「错」。');
        break;
      default:
        break;
    }

    if (question.hasText) {
      buffer.writeln('题干：${question.effectiveText}');
      if (question.slideText.trim().isNotEmpty &&
          question.slideText.trim() != question.effectiveText) {
        buffer.writeln('课件内容（供参考）：${question.slideText.trim()}');
      }
    } else if (question.hasImage) {
      buffer.writeln('题干没有以文字形式提供，请从下方附带的课件图片中识别题目内容后作答。');
    }

    if (question.options.isNotEmpty) {
      buffer.writeln('选项：');
      for (final opt in question.options) {
        buffer.writeln('${opt.key}. ${opt.value}');
      }
    } else if (question.hasImage) {
      buffer.writeln('选项可能同样出现在图片中，请一并识别。');
    }

    return buffer.toString();
  }

  List<AnswerSearchResult> _parseAIResponse(String content) {
    try {
      // 尝试从回复中提取 JSON
      final jsonStr = content.contains('{')
          ? content.substring(
              content.indexOf('{'), content.lastIndexOf('}') + 1)
          : content;

      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      final answer = parsed['answer'] as String? ?? '';
      final confidence = (parsed['confidence'] as num?)?.toDouble() ?? 0.5;
      final explanation = parsed['explanation'] as String?;

      if (answer.isEmpty) {
        lastError = 'AI 未给出答案';
        return [];
      }

      return [
        AnswerSearchResult(
          answer: answer,
          source: 'AI ($model)',
          confidence: confidence,
          explanation: explanation,
          sourceType: AnswerSourceType.aiProvider,
        ),
      ];
    } catch (e) {
      // JSON 解析失败时，使用原始回复作为答案
      return [
        AnswerSearchResult(
          answer: content.trim(),
          source: 'AI ($model)',
          confidence: 0.2,
          explanation: 'AI返回格式无法解析，使用原始回复（可信度低）',
          sourceType: AnswerSourceType.aiProvider,
        ),
      ];
    }
  }
}

/// API 连通测试结果
class AIConnectionTestResult {
  final bool success;

  /// 一句话结论
  final String message;

  /// 详细信息（模型回复片段 / 错误原文）
  final String? detail;

  /// 耗时（毫秒）
  final int? latencyMs;

  const AIConnectionTestResult({
    required this.success,
    required this.message,
    this.detail,
    this.latencyMs,
  });

  String get latencyText =>
      latencyMs == null ? '' : '${(latencyMs! / 1000).toStringAsFixed(2)} 秒';
}

/// 答案检索 API 主入口
class AnswerSearchApi {
  static final BuiltinAnswerProvider _builtinProvider = BuiltinAnswerProvider();
  static AIAnswerProvider? _aiProvider;
  static bool _initialized = false;

  static const _enabledKey = 'answer_search_enabled';
  static const _apiUrlKey = 'answer_search_api_url';
  static const _apiKeyKey = 'answer_search_api_key';
  static const _modelKey = 'answer_search_model';

  static Future<void> initialize() async {
    if (_initialized) return;
    _loadAIConfig();
    _initialized = true;
  }

  static void _loadAIConfig() {
    final prefs = StorageManager.prefs;
    final enabled = prefs.getBool(_enabledKey) ?? false;
    if (!enabled) {
      _aiProvider = null;
      return;
    }

    final apiUrl = prefs.getString(_apiUrlKey) ?? '';
    final apiKey = prefs.getString(_apiKeyKey) ?? '';
    final model = prefs.getString(_modelKey) ?? 'gpt-3.5-turbo';

    if (apiUrl.isNotEmpty && apiKey.isNotEmpty) {
      _aiProvider = AIAnswerProvider(
        apiUrl: apiUrl,
        apiKey: apiKey,
        model: model,
      );
    } else {
      _aiProvider = null;
    }
  }

  /// 重新加载配置（设置变更后调用）
  static void reloadConfig() {
    _loadAIConfig();
  }

  /// 检索答案 - 按优先级依次尝试各检索源
  ///
  /// 优先级：内置答案(1.0) > AI检索
  /// 结果按置信度降序排列
  static Future<List<AnswerSearchResult>> search(
      StandardizedQuestion question) async {
    await initialize();

    final results = <AnswerSearchResult>[];

    // 0. 题目本身没拿到内容，直接返回，由界面给出明确提示
    if (!question.isUsable) return results;

    // 1. 内置答案（学习通服务器返回的 isanswer）
    final builtinResults = await _builtinProvider.search(question);
    results.addAll(builtinResults);

    // 2. AI 检索（仅当配置了 API 时）
    if (_aiProvider != null) {
      final aiResults = await _aiProvider!.search(question);
      results.addAll(aiResults);
    }

    // 按置信度降序排列
    results.sort((a, b) => b.confidence.compareTo(a.confidence));

    return results;
  }

  /// 是否已配置 AI 检索
  static bool get isAIConfigured => _aiProvider != null;

  /// 最近一次 AI 检索失败原因（没有失败则为 null）
  static String? get lastAIError => _aiProvider?.lastError;

  /// 保存 AI 配置
  static Future<void> saveAIConfig({
    required bool enabled,
    required String apiUrl,
    required String apiKey,
    required String model,
  }) async {
    final prefs = StorageManager.prefs;
    await prefs.setBool(_enabledKey, enabled);
    await prefs.setString(_apiUrlKey, apiUrl);
    await prefs.setString(_apiKeyKey, apiKey);
    await prefs.setString(_modelKey, model);
    _loadAIConfig();
  }

  /// 获取当前 AI 配置
  static Map<String, dynamic> getAIConfig() {
    final prefs = StorageManager.prefs;
    return {
      'enabled': prefs.getBool(_enabledKey) ?? false,
      'apiUrl': prefs.getString(_apiUrlKey) ?? '',
      'apiKey': prefs.getString(_apiKeyKey) ?? '',
      'model': prefs.getString(_modelKey) ?? 'gpt-3.5-turbo',
    };
  }

  /// API 连通测试 - 发一条最小请求，验证地址 / Key / 模型是否可用
  static Future<AIConnectionTestResult> testConnection({
    required String apiUrl,
    required String apiKey,
    required String model,
  }) async {
    final url = apiUrl.trim();
    final key = apiKey.trim();
    final modelName = model.trim().isEmpty ? 'gpt-3.5-turbo' : model.trim();

    if (url.isEmpty) {
      return const AIConnectionTestResult(
        success: false,
        message: 'API 地址为空，请先填写',
      );
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return const AIConnectionTestResult(
        success: false,
        message: 'API 地址格式不对，需要以 http:// 或 https:// 开头',
      );
    }
    if (key.isEmpty) {
      return const AIConnectionTestResult(
        success: false,
        message: 'API Key 为空，请先填写',
      );
    }

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      // 4xx 也交给自己处理，方便读出具体报错
      validateStatus: (code) => code != null && code < 500,
    ));

    final stopwatch = Stopwatch()..start();
    try {
      final response = await dio.post(
        url,
        options: Options(
          headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          },
        ),
        data: jsonEncode({
          'model': modelName,
          'messages': [
            {'role': 'user', 'content': '你好，请回复"ok"两个字。'},
          ],
          'max_tokens': 16,
        }),
      );
      stopwatch.stop();

      final code = response.statusCode ?? 0;
      final latency = stopwatch.elapsedMilliseconds;

      if (code == 200) {
        String? reply;
        try {
          reply = response.data['choices']?[0]?['message']?['content']
              as String?;
        } catch (_) {
          reply = null;
        }
        return AIConnectionTestResult(
          success: true,
          message: '连接成功，模型可用',
          detail: '模型：$modelName'
              '\n模型回复：${(reply ?? '').trim().isEmpty ? '(空)' : reply!.trim()}',
          latencyMs: latency,
        );
      }

      return AIConnectionTestResult(
        success: false,
        message: _httpErrorText(code),
        detail: _extractServerMessage(response.data),
        latencyMs: latency,
      );
    } catch (e) {
      stopwatch.stop();
      final info = describeError(e);
      return AIConnectionTestResult(
        success: false,
        message: '连接失败：${info.message}',
        detail: info.error.toString(),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  static String _httpErrorText(int code) {
    switch (code) {
      case 400:
        return '请求被拒绝（400）：模型名称可能不对';
      case 401:
        return '认证失败（401）：API Key 无效';
      case 403:
        return '认证失败（403）：API Key 无权限';
      case 404:
        return '接口不存在（404）：请检查 API 地址';
      case 429:
        return '请求过于频繁（429）：额度不足或触发限流';
      default:
        return '请求失败（HTTP $code）';
    }
  }

  static String? _extractServerMessage(dynamic data) {
    try {
      if (data is Map) {
        final err = data['error'];
        if (err is Map && err['message'] != null) {
          return err['message'].toString();
        }
        if (err != null) return err.toString();
        if (data['message'] != null) return data['message'].toString();
      }
      return data?.toString();
    } catch (_) {
      return null;
    }
  }

  /// 从雨课堂 Problem 构建标准化题目
  ///
  /// [slideText] 当前 PPT 页里的文字（problem.body 为空时的兜底）
  /// [imageUrl]  当前 PPT 页的图片地址（题目只写在 PPT 上时交给多模态模型识别）
  static StandardizedQuestion fromRainClassroomProblem(
    Problem problem, {
    String slideText = '',
    String imageUrl = '',
    Map<String, String>? imageHeaders,
  }) {
    String questionType;
    switch (problem.problemType) {
      case 1:
        questionType = 'single';
        break;
      case 2:
        questionType = 'multiple';
        break;
      case 3:
        questionType = 'polling';
        break;
      case 4:
        questionType = 'fillBlank';
        break;
      case 5:
        questionType = 'shortAnswer';
        break;
      case 6:
        questionType = 'judgement';
        break;
      default:
        questionType = 'unknown';
    }

    final options = problem.options
            ?.map((opt) => StandardizedOption(
                  key: opt.key,
                  value: opt.value,
                  isCorrect: null,
                ))
            .toList() ??
        [];

    // 服务器没给题型时，按选项特征兜底推断
    if (questionType == 'unknown' && options.isNotEmpty) {
      questionType = StandardizedQuestion.inferTypeFromOptions(options);
    }

    final bodyText = StandardizedQuestion.extractPlainText(problem.body);

    return StandardizedQuestion(
      questionText: bodyText,
      questionType: questionType,
      options: options,
      rawAnswerData: null,
      slideText: slideText,
      imageUrls: imageUrl.trim().isEmpty ? const [] : [imageUrl.trim()],
      imageHeaders: imageHeaders,
    );
  }
}
