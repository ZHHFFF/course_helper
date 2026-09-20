/// 答案检索 API 模块
/// 支持可插拔的检索源：内置答案 > AI 检索
///
/// 能力说明：
/// 1. 题型识别：自动区分单选 / 多选 / 判断 / 填空 / 简答，并提示 AI 按题型作答
/// 2. 课件识图：雨课堂题目只写在 PPT 上时，自动把当前页图片发给多模态模型识别
/// 3. 连通测试：设置页可一键测试 API 是否可用
/// 4. 地址容错：只填 base_url（如 .../compatible-mode/v1）也会自动补上 /chat/completions
/// 5. 可诊断：失败原因、实际请求地址、HTTP 状态码、耗时都会记录下来供界面展示
library;
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/gateway.dart';
import '../models/answer_result.dart';
import '../models/presentation.dart';
import '../utils/app_logger.dart';
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
        answerKeys: AnswerSearchResult.lettersOf(answer),
      ),
    ];
  }
}

/// 单次 AI 请求的诊断信息（供界面展示，便于排查）
class AIRequestInfo {
  /// 实际请求的地址（已自动补全）
  final String url;
  final String model;
  final int? statusCode;
  final int? latencyMs;
  final String? error;

  const AIRequestInfo({
    required this.url,
    required this.model,
    this.statusCode,
    this.latencyMs,
    this.error,
  });

  String get latencyText =>
      latencyMs == null ? '' : '${(latencyMs! / 1000).toStringAsFixed(2)} 秒';

  /// 多行摘要，直接丢进界面
  String get summary {
    final buffer = StringBuffer();
    buffer.writeln('请求地址：$url');
    buffer.writeln('模型：$model');
    if (statusCode != null) buffer.writeln('HTTP 状态码：$statusCode');
    if (latencyMs != null) buffer.writeln('耗时：$latencyText');
    if (error != null && error!.trim().isNotEmpty) {
      buffer.writeln('错误：${error!.trim()}');
    }
    return buffer.toString().trim();
  }
}

/// 服务端返回的错误体（OpenAI 兼容格式）
class ServerErrorInfo {
  final String? code;
  final String? message;

  const ServerErrorInfo({this.code, this.message});

  bool get isEmpty =>
      (code == null || code!.trim().isEmpty) &&
      (message == null || message!.trim().isEmpty);

  /// "invalid_api_key: Invalid API-key provided." 形式
  String get text {
    final c = code?.trim() ?? '';
    final m = message?.trim() ?? '';
    if (c.isEmpty) return m;
    if (m.isEmpty) return c;
    return '$c: $m';
  }
}

/// AI 服务商预设
class AIProviderPreset {
  final String name;
  final String apiUrl;

  /// 建议的模型名（用户可改）
  final String model;

  /// 提示文案
  final String hint;

  const AIProviderPreset({
    required this.name,
    required this.apiUrl,
    required this.model,
    this.hint = '',
  });
}

/// AI 检索源
/// 调用 OpenAI 兼容的 Chat Completions API 进行答案检索
/// 支持多模态：题目只有图片时，会把图片以 base64 形式一起发过去
class AIAnswerProvider implements AnswerSearchProvider {
  /// 用户填写的地址（可能是 base_url，也可能是完整 endpoint）
  final String apiUrl;
  final String apiKey;
  final String model;

  /// 是否关闭思考模式（仅对混合思考模型生效，如 qwen3.8-flash）
  final bool disableThinking;

  /// 接收超时（秒）
  final int timeoutSeconds;

  /// 最近一次检索失败的原因（供界面提示）
  String? lastError;

  /// 最近一次请求的诊断信息
  AIRequestInfo? lastRequestInfo;

  /// 单张图片大小上限，超过则不发（避免请求体过大）
  static const int _maxImageBytes = 5 * 1024 * 1024;

  /// 最多附带几张图片
  static const int _maxImages = 3;

  /// 回答长度上限
  static const int _maxTokens = 2048;

  /// 默认接收超时（秒）——思考型模型官方建议 ≥180s
  static const int defaultTimeoutSeconds = 180;

  AIAnswerProvider({
    required this.apiUrl,
    required this.apiKey,
    required this.model,
    this.disableThinking = true,
    this.timeoutSeconds = defaultTimeoutSeconds,
  });

  @override
  String get name => 'AI检索';

  /// 实际请求的地址（自动补全 /chat/completions）
  String get effectiveUrl => AnswerSearchApi.normalizeApiUrl(apiUrl);

  /// 是否为「混合思考」模型（这些模型默认开思考，且接受 enable_thinking 参数）
  bool get isThinkingModel {
    final m = model.trim().toLowerCase();
    return m.startsWith('qwen3') || m.startsWith('qvq');
  }

  /// 是否需要在请求体里注入 enable_thinking
  bool get injectThinkingFlag => disableThinking && isThinkingModel;

  /// 组装请求体（单独抽出来方便测试）
  Map<String, dynamic> buildRequestBody(
    String prompt,
    List<String> imageDataUrls,
  ) {
    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {'role': 'user', 'content': _buildUserContent(prompt, imageDataUrls)},
      ],
      'temperature': 0.3,
      'max_tokens': _maxTokens,
      'stream': false,
    };
    if (injectThinkingFlag) {
      body['enable_thinking'] = false;
    }
    return body;
  }

  @override
  Future<List<AnswerSearchResult>> search(StandardizedQuestion question) async {
    lastError = null;
    lastRequestInfo = null;

    if (apiUrl.trim().isEmpty || apiKey.trim().isEmpty) {
      lastError = '未配置 API 地址或 API Key';
      return [];
    }

    if (!question.isUsable) {
      lastError = '没有拿到题目内容（题干为空且没有课件图片）';
      return [];
    }

    final url = effectiveUrl;
    final stopwatch = Stopwatch()..start();

    try {
      final prompt = _buildPrompt(question);
      final imageParts = await _loadImageDataUrls(question);

      AppLogger.i(
        '答案检索',
        '开始检索：题型=${question.typeLabel} 题干长度=${question.effectiveText.length} '
        '选项数=${question.options.length} 图片数=${imageParts.length}',
      );
      AppLogger.i(
        '答案检索',
        '请求地址=$url 模型=$model 关闭思考=$injectThinkingFlag 超时=${timeoutSeconds}s',
      );

      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: Duration(seconds: timeoutSeconds),
        // 4xx 也交给自己处理，方便读出服务端的具体报错
        validateStatus: (code) => code != null && code < 500,
      ));
      dio.interceptors.add(const LoggingInterceptor(tag: 'AI请求'));

      final response = await dio.post(
        url,
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
        ),
        data: jsonEncode(buildRequestBody(prompt, imageParts)),
      );
      stopwatch.stop();

      final code = response.statusCode ?? 0;
      if (code != 200) {
        final server = AnswerSearchApi.parseErrorBody(response.data);
        lastError = AnswerSearchApi.formatHttpError(code, server);
        lastRequestInfo = AIRequestInfo(
          url: url,
          model: model,
          statusCode: code,
          latencyMs: stopwatch.elapsedMilliseconds,
          error: lastError,
        );
        AppLogger.e('答案检索', 'HTTP $code → $lastError');
        debugPrint('AI 检索失败：$lastError');
        return [];
      }

      lastRequestInfo = AIRequestInfo(
        url: url,
        model: model,
        statusCode: code,
        latencyMs: stopwatch.elapsedMilliseconds,
      );

      final message = _readMessage(response.data);
      final rawContent = message['content'];
      var content = rawContent is String ? rawContent.trim() : '';

      // 思考型模型可能把内容放在 reasoning_content 里
      if (content.isEmpty) {
        final rawReasoning = message['reasoning_content'];
        content = rawReasoning is String ? rawReasoning.trim() : '';
      }

      if (content.isEmpty) {
        lastError = 'AI 返回内容为空（HTTP 200，但 message.content 为空）';
        lastRequestInfo = AIRequestInfo(
          url: url,
          model: model,
          statusCode: code,
          latencyMs: stopwatch.elapsedMilliseconds,
          error: lastError,
        );
        AppLogger.e('答案检索', lastError!);
        return [];
      }

      AppLogger.i('答案检索',
          'HTTP 200，用时 ${stopwatch.elapsedMilliseconds}ms，返回 ${content.length} 字符');

      return _parseAIResponse(content);
    } catch (e) {
      stopwatch.stop();
      final info = describeError(e);

      String? serverText;
      int? statusCode;
      if (e is DioException) {
        statusCode = e.response?.statusCode;
        final server = AnswerSearchApi.parseErrorBody(e.response?.data);
        if (!server.isEmpty) serverText = server.text;
      }

      lastError = serverText == null ? info.message : '${info.message}｜$serverText';
      lastRequestInfo = AIRequestInfo(
        url: url,
        model: model,
        statusCode: statusCode,
        latencyMs: stopwatch.elapsedMilliseconds,
        error: lastError,
      );
      AppLogger.e('答案检索', '请求异常：$lastError');
      debugPrint('AI 检索失败：$e');
      return [];
    }
  }

  /// 取 choices[0].message
  Map<String, dynamic> _readMessage(dynamic data) {
    try {
      final choices = data['choices'];
      if (choices is List && choices.isNotEmpty) {
        final message = choices[0]['message'];
        if (message is Map) return Map<String, dynamic>.from(message);
      }
    } catch (_) {
      // 忽略，下面返回空 map
    }
    return <String, dynamic>{};
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
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
    ));
    dio.interceptors
        .add(const LoggingInterceptor(tag: 'AI图片', logResponseBody: false));

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
          AppLogger.w('AI图片', '图片过大，跳过：$url (${bytes.length} bytes)');
          debugPrint('图片过大，跳过：$url (${bytes.length} bytes)');
          continue;
        }
        final mime = _guessMime(url, resp.headers);
        result.add('data:$mime;base64,${base64Encode(bytes)}');
      } catch (e) {
        AppLogger.w('AI图片', '图片下载失败（$url）：$e');
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
        buffer.writeln('注意：本题为单选题，只能选一个选项。');
        break;
      case 'judgement':
        buffer.writeln('注意：本题为判断题，请在选项里选出代表「对」或「错」的那一项。');
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
      final keys = question.options
          .map((o) => o.key.trim())
          .where((k) => k.isNotEmpty)
          .join('、');
      buffer.writeln('answerKeys 只能从这些选项字母里选：$keys');
    } else if (question.hasImage) {
      buffer.writeln('选项可能同样出现在图片中，请一并识别。');
    }

    return buffer.toString();
  }

  /// 系统提示词
  static const String _systemPrompt =
      '你是一个答题助手。请根据题目和选项作答，先给出答案，再给出分析过程。\n'
      '以 JSON 格式回复，字段如下：\n'
      '{"answerKeys": ["A", "C"], "answer": "AC", "confidence": 0.85, "explanation": "分析过程"}\n'
      '字段要求：\n'
      '1. answerKeys 是正确选项的字母数组，只能取题目给出的选项字母。\n'
      '   · 单选题只给 1 个；多选题必须给出全部正确项；\n'
      '   · 判断题请选代表「对」或「错」的那一项字母；\n'
      '   · 填空题、简答题没有选项时返回空数组 []。\n'
      '2. answer 是答案文本：选择题为选项字母（如 A 或 AC）；判断题填所选选项的原文；'
      '填空/简答题直接给答案文本。\n'
      '3. confidence 是 0 到 1 之间的数值，不确定时设 0.3 以下。\n'
      '4. explanation 先说明为什么选这个答案，再补充相关知识或解析。\n'
      '题目以图片形式给出时，先仔细识别图片中的题干和选项，再作答。\n'
      '只返回 JSON，不要返回其他内容。';

  List<AnswerSearchResult> _parseAIResponse(String rawContent) {
    final content = AnswerSearchApi.stripCodeFence(rawContent);

    try {
      final jsonStr = content.contains('{')
          ? content.substring(
              content.indexOf('{'), content.lastIndexOf('}') + 1)
          : content;

      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;

      final answer = _readAnswerText(parsed['answer']);
      final answerKeys = _readAnswerKeys(parsed['answerKeys']);
      final confidence = (parsed['confidence'] as num?)?.toDouble() ?? 0.5;
      final explanation = parsed['explanation']?.toString();

      // answer 为空但给了 answerKeys 时，用 key 拼一个
      final finalAnswer = answer.isEmpty ? answerKeys.join() : answer;

      if (finalAnswer.isEmpty) {
        lastError = 'AI 未给出答案（返回的 JSON 里 answer 与 answerKeys 都为空）';
        return [];
      }

      return [
        AnswerSearchResult(
          answer: finalAnswer,
          source: 'AI ($model)',
          confidence: confidence,
          explanation: explanation,
          sourceType: AnswerSourceType.aiProvider,
          answerKeys: answerKeys,
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

  /// answer 可能是字符串，也可能是数组
  static String _readAnswerText(dynamic raw) {
    if (raw == null) return '';
    if (raw is String) return raw.trim();
    if (raw is List) {
      return raw
          .map((e) => (e ?? '').toString().trim())
          .where((e) => e.isNotEmpty)
          .join();
    }
    return raw.toString().trim();
  }

  /// answerKeys 可能是数组，也可能是 "AC" 这种字符串
  static List<String> _readAnswerKeys(dynamic raw) {
    if (raw == null) return const [];
    if (raw is String) return AnswerSearchResult.lettersOf(raw);
    if (raw is List) {
      final keys = <String>[];
      for (final item in raw) {
        for (final letter in AnswerSearchResult.lettersOf('${item ?? ''}')) {
          if (!keys.contains(letter)) keys.add(letter);
        }
      }
      return keys;
    }
    return const [];
  }
}

/// API 连通测试结果
class AIConnectionTestResult {
  final bool success;

  /// 一句话结论
  final String message;

  /// 详细信息（模型回复片段 / 错误原文 / 请求诊断）
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
  static const _disableThinkingKey = 'answer_search_disable_thinking';
  static const _timeoutKey = 'answer_search_timeout_seconds';

  /// 默认关闭思考模式（思考型模型慢约 3 倍）
  static const bool defaultDisableThinking = true;

  /// 默认接收超时
  static const int defaultTimeoutSeconds = AIAnswerProvider.defaultTimeoutSeconds;

  /// 内置的服务商预设
  ///
  /// 若构建时注入了 `GATEWAY_URL`（见 `lib/config/gateway.dart`），
  /// 会在最前面插入「官方服务」——学生只要把卡号粘贴到 API Key 就能用。
  static final List<AIProviderPreset> presets = [
    if (hasOfficialGateway)
      AIProviderPreset(
        name: kOfficialGatewayName,
        apiUrl: kOfficialGatewayUrl,
        model: kOfficialGatewayModel,
        hint: kOfficialGatewayHint,
      ),
    AIProviderPreset(
      name: '阿里云百炼',
      apiUrl:
          'https://ws-9vvakflm7lid50hq.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
      model: 'qwen3.8-flash',
      hint: '新域名要带 WorkspaceId；API Key 分地域，北京的 Key 只能打北京的地址。'
          '地址只填到 /compatible-mode/v1 即可，App 会自动补上 /chat/completions。',
    ),
    AIProviderPreset(
      name: '百炼（旧域名）',
      apiUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      model: 'qwen3.8-flash',
      hint: '阿里云百炼通用域名，适用于没有专属 WorkspaceId 的账号。',
    ),
    AIProviderPreset(
      name: 'DeepSeek',
      apiUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      hint: 'DeepSeek 官方接口，模型名 deepseek-chat / deepseek-reasoner。',
    ),
    AIProviderPreset(
      name: 'OpenAI',
      apiUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini',
      hint: '需要能访问 OpenAI 的网络环境；识图用 gpt-4o。',
    ),
    AIProviderPreset(
      name: '自定义',
      apiUrl: '',
      model: '',
      hint: '填任意 OpenAI 兼容接口，地址写到 /v1 或完整 /chat/completions 都可以。',
    ),
  ];

  /// 把用户填的地址补全成真正的接口地址
  ///
  /// - `https://xxx/compatible-mode/v1`        → 补 `/chat/completions`
  /// - `https://xxx/compatible-mode`           → 补 `/v1/chat/completions`
  /// - `https://xxx/v1`                        → 补 `/chat/completions`
  /// - 已以 `/chat/completions` 结尾           → 原样返回
  /// - 其他形态                                → 原样返回，由「测试连接」报错提示
  static String normalizeApiUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';

    // 复制粘贴时常见的引号
    if (url.length >= 2) {
      final first = url.substring(0, 1);
      final last = url.substring(url.length - 1);
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        url = url.substring(1, url.length - 1).trim();
      }
    }

    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isEmpty) return '';

    final lower = url.toLowerCase();
    if (lower.endsWith('/chat/completions') ||
        lower.endsWith('/completions') ||
        lower.endsWith('/responses')) {
      return url;
    }
    if (lower.endsWith('/compatible-mode')) {
      return '$url/v1/chat/completions';
    }
    if (lower.endsWith('/compatible-mode/v1') || lower.endsWith('/v1')) {
      return '$url/chat/completions';
    }
    return url;
  }

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

    final storedUrl = (prefs.getString(_apiUrlKey) ?? '').trim();
    final storedModel = (prefs.getString(_modelKey) ?? '').trim();

    // 地址/模型没填过、而构建时配了官方网关 → 自动用官方服务，
    // 学生只要把卡号填到 API Key 就能用（「零配置」）
    final apiUrl = storedUrl.isEmpty && hasOfficialGateway
        ? kOfficialGatewayUrl
        : storedUrl;
    final model = storedModel.isEmpty && hasOfficialGateway
        ? kOfficialGatewayModel
        : (storedModel.isEmpty ? 'gpt-3.5-turbo' : storedModel);

    final apiKey = prefs.getString(_apiKeyKey) ?? '';
    final disableThinking =
        prefs.getBool(_disableThinkingKey) ?? defaultDisableThinking;
    final timeoutSeconds =
        prefs.getInt(_timeoutKey) ?? defaultTimeoutSeconds;

    if (apiUrl.isNotEmpty && apiKey.isNotEmpty) {
      _aiProvider = AIAnswerProvider(
        apiUrl: apiUrl,
        apiKey: apiKey,
        model: model,
        disableThinking: disableThinking,
        timeoutSeconds: timeoutSeconds <= 0 ? defaultTimeoutSeconds : timeoutSeconds,
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

  /// 最近一次 AI 请求的诊断信息（没有则为 null）
  static AIRequestInfo? get lastRequestInfo => _aiProvider?.lastRequestInfo;

  /// 保存 AI 配置
  static Future<void> saveAIConfig({
    required bool enabled,
    required String apiUrl,
    required String apiKey,
    required String model,
    bool? disableThinking,
    int? timeoutSeconds,
  }) async {
    final prefs = StorageManager.prefs;
    await prefs.setBool(_enabledKey, enabled);
    await prefs.setString(_apiUrlKey, apiUrl);
    await prefs.setString(_apiKeyKey, apiKey);
    await prefs.setString(_modelKey, model);
    if (disableThinking != null) {
      await prefs.setBool(_disableThinkingKey, disableThinking);
    }
    if (timeoutSeconds != null) {
      await prefs.setInt(_timeoutKey, timeoutSeconds);
    }
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
      'disableThinking':
          prefs.getBool(_disableThinkingKey) ?? defaultDisableThinking,
      'timeoutSeconds': prefs.getInt(_timeoutKey) ?? defaultTimeoutSeconds,
    };
  }

  /// API 连通测试 - 发一条最小请求，验证地址 / Key / 模型是否可用
  static Future<AIConnectionTestResult> testConnection({
    required String apiUrl,
    required String apiKey,
    required String model,
    bool disableThinking = defaultDisableThinking,
    int timeoutSeconds = defaultTimeoutSeconds,
  }) async {
    final rawUrl = apiUrl.trim();
    final key = apiKey.trim();
    final modelName = model.trim().isEmpty ? 'gpt-3.5-turbo' : model.trim();
    final url = normalizeApiUrl(rawUrl);

    if (rawUrl.isEmpty) {
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
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: Duration(seconds: timeoutSeconds),
      // 4xx 也交给自己处理，方便读出具体报错
      validateStatus: (code) => code != null && code < 500,
    ));

    final body = <String, dynamic>{
      'model': modelName,
      'messages': [
        {'role': 'user', 'content': '你好，请回复"ok"两个字。'},
      ],
      'max_tokens': 16,
      'stream': false,
    };
    // 与正式检索保持一致：思考型模型关掉思考，避免测试等到超时
    final lowerModel = modelName.toLowerCase();
    if (disableThinking &&
        (lowerModel.startsWith('qwen3') || lowerModel.startsWith('qvq'))) {
      body['enable_thinking'] = false;
    }

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
        data: jsonEncode(body),
      );
      stopwatch.stop();

      final code = response.statusCode ?? 0;
      final latency = stopwatch.elapsedMilliseconds;
      final urlLine = '请求地址：$url\n模型：$modelName';

      if (code == 200) {
        String? reply;
        try {
          final choices = response.data['choices'];
          if (choices is List && choices.isNotEmpty) {
            final message = choices[0]['message'];
            final rawContent = message is Map ? message['content'] : null;
            if (rawContent is String && rawContent.trim().isNotEmpty) {
              reply = rawContent.trim();
            } else {
              final rawReasoning =
                  message is Map ? message['reasoning_content'] : null;
              if (rawReasoning is String && rawReasoning.trim().isNotEmpty) {
                reply = rawReasoning.trim();
              }
            }
          }
        } catch (_) {
          reply = null;
        }
        return AIConnectionTestResult(
          success: true,
          message: '连接成功，模型可用',
          detail: '$urlLine\n模型回复：'
              '${(reply ?? '').trim().isEmpty ? '(空)' : reply!.trim()}',
          latencyMs: latency,
        );
      }

      final server = parseErrorBody(response.data);
      return AIConnectionTestResult(
        success: false,
        message: formatHttpError(code, server),
        detail: '$urlLine\n服务端原始返回：\n'
            '${server.isEmpty ? (response.data?.toString() ?? '(空)') : server.text}',
        latencyMs: latency,
      );
    } catch (e) {
      stopwatch.stop();
      final info = describeError(e);

      String? serverText;
      if (e is DioException) {
        final server = parseErrorBody(e.response?.data);
        if (!server.isEmpty) serverText = server.text;
      }

      return AIConnectionTestResult(
        success: false,
        message: '连接失败：${info.message}',
        detail: '请求地址：$url\n模型：$modelName\n'
            '${serverText == null ? info.error.toString() : '服务端原始返回：\n$serverText'}',
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    }
  }

  /// HTTP 状态码 → 人话（带上服务端错误码与信息）
  static String formatHttpError(int code, ServerErrorInfo? server) {
    String base;
    switch (code) {
      case 400:
        base = '请求被拒绝（400）：模型名称或请求参数不对';
        break;
      case 401:
        base = '认证失败（401）：API Key 无效，或 Key 与接口地域不匹配';
        break;
      case 403:
        base = '认证失败（403）：API Key 无权限';
        break;
      case 404:
        base = '接口不存在（404）：地址可能少了 /chat/completions';
        break;
      case 429:
        base = '请求过于频繁（429）：额度不足或触发限流';
        break;
      default:
        if (code >= 500) {
          base = '服务端错误（HTTP $code）';
        } else {
          base = '请求失败（HTTP $code）';
        }
    }
    if (server == null || server.isEmpty) return base;
    return '$base｜$code → ${server.text}';
  }

  /// 从错误响应体里取服务端错误码与错误信息
  ///
  /// 兼容 `{"error":{"code":"...","message":"..."}}` 与 `{"code":..,"message":..}`
  static ServerErrorInfo parseErrorBody(dynamic data) {
    if (data == null) return const ServerErrorInfo();

    if (data is Map) {
      final err = data['error'];
      if (err is Map) {
        return ServerErrorInfo(
          code: _asText(err['code']),
          message: _asText(err['message']),
        );
      }
      if (err is String && err.trim().isNotEmpty) {
        return ServerErrorInfo(message: err);
      }
      final String? code = _asText(data['code']);
      final String? message = _asText(data['message']);
      if ((code != null && code.isNotEmpty) ||
          (message != null && message.isNotEmpty)) {
        return ServerErrorInfo(code: code, message: message);
      }
      return const ServerErrorInfo();
    }

    final text = data.toString().trim();
    if (text.isEmpty) return const ServerErrorInfo();
    return ServerErrorInfo(
        message: text.length > 500 ? text.substring(0, 500) : text);
  }

  /// 安全转字符串：null 仍是 null，其余走 toString
  static String? _asText(dynamic value) => value?.toString();

  /// 去掉 ```json ... ``` 这类 Markdown 代码围栏
  static String stripCodeFence(String raw) {
    var text = raw.trim();
    if (!text.startsWith('```')) return text;

    // 去掉开头的 ``` 或 ```json
    final firstNewline = text.indexOf('\n');
    if (firstNewline == -1) {
      return text.replaceAll('`', '').trim();
    }
    text = text.substring(firstNewline + 1);

    // 去掉结尾的 ```
    final endFence = text.lastIndexOf('```');
    if (endFence != -1) {
      text = text.substring(0, endFence);
    }
    return text.trim();
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
