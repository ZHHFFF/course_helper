/// 答案检索 API 模块
/// 支持可插拔的检索源：内置答案 > AI 检索
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/answer_result.dart';
import '../models/presentation.dart';
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
class AIAnswerProvider implements AnswerSearchProvider {
  final String apiUrl;
  final String apiKey;
  final String model;

  AIAnswerProvider({
    required this.apiUrl,
    required this.apiKey,
    required this.model,
  });

  @override
  String get name => 'AI检索';

  @override
  Future<List<AnswerSearchResult>> search(StandardizedQuestion question) async {
    if (apiUrl.isEmpty || apiKey.isEmpty) return [];

    try {
      final prompt = _buildPrompt(question);
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
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
                  '对于选择题，answer为选项字母(如A或AB)；对于判断题为"对"或"错"；'
                  '对于填空/简答题，直接给出答案文本。'
                  'explanation中先说明为什么选这个答案，再补充相关知识或解析。'
                  '如果不确定答案，confidence设为0.3以下。'
                  '只返回JSON，不要返回其他内容。',
            },
            {
              'role': 'user',
              'content': prompt,
            },
          ],
          'temperature': 0.3,
        }),
      );

      final content = response.data['choices']?[0]?['message']?['content']
          as String?;
      if (content == null) return [];

      return _parseAIResponse(content);
    } catch (e) {
      debugPrint('AI 检索失败：$e');
      return [];
    }
  }

  String _buildPrompt(StandardizedQuestion question) {
    final buffer = StringBuffer();
    buffer.writeln('题型：${question.questionType}');
    buffer.writeln('题干：${question.questionText}');

    if (question.options.isNotEmpty) {
      buffer.writeln('选项：');
      for (final opt in question.options) {
        buffer.writeln('${opt.key}. ${opt.value}');
      }
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

      if (answer.isEmpty) return [];

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

  /// 从雨课堂 Problem 构建标准化题目
  static StandardizedQuestion fromRainClassroomProblem(Problem problem) {
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

    return StandardizedQuestion(
      questionText: problem.body,
      questionType: questionType,
      options: options,
      rawAnswerData: null,
    );
  }
}

