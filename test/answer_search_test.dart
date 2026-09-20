import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:course_helper/api/answer_search.dart';
import 'package:course_helper/models/answer_result.dart';
import 'package:course_helper/utils/network_error.dart';

void main() {
  group('StandardizedQuestion', () {
    test('fromChaoxing should extract question text and options', () {
      final quiz = {
        'type': 0,
        'content': '<p>以下哪个是正确的？</p>',
        'answer': [
          {'name': 'A', 'content': '<p>选项A</p>', 'isanswer': false},
          {'name': 'B', 'content': '<p>选项B</p>', 'isanswer': true},
          {'name': 'C', 'content': '<p>选项C</p>', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);

      expect(question.questionType, 'single');
      expect(question.questionText, '以下哪个是正确的？');
      expect(question.options.length, 3);
      expect(question.options[0].key, 'A');
      expect(question.options[0].value, '选项A');
      expect(question.options[1].isCorrect, true);
    });

    test('hasBuiltinAnswer should detect isanswer=true', () {
      final quiz = {
        'type': 0,
        'content': 'test',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': true},
          {'name': 'B', 'content': 'B', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.hasBuiltinAnswer, true);
      expect(question.builtinAnswer, 'A');
    });

    test('hasBuiltinAnswer should return false when no isanswer', () {
      final quiz = {
        'type': 0,
        'content': 'test',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': false},
          {'name': 'B', 'content': 'B', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.hasBuiltinAnswer, false);
      expect(question.builtinAnswer, null);
    });

    test('extractPlainText should strip HTML tags', () {
      final result = StandardizedQuestion.extractPlainText(
        '<p>Hello <b>World</b></p>',
      );
      expect(result, 'Hello World');
    });

    test('multiple choice should join correct options', () {
      final quiz = {
        'type': 1,
        'content': '多选题',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': true},
          {'name': 'B', 'content': 'B', 'isanswer': false},
          {'name': 'C', 'content': 'C', 'isanswer': true},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.questionType, 'multiple');
      expect(question.builtinAnswer, 'AC');
    });

    // ===== 以下为本次新增能力的测试 =====

    test('题型中文名应该正确', () {
      expect(StandardizedQuestion.typeLabelOf('single'), '单选题');
      expect(StandardizedQuestion.typeLabelOf('multiple'), '多选题');
      expect(StandardizedQuestion.typeLabelOf('judgement'), '判断题');
      expect(StandardizedQuestion.typeLabelOf('fillBlank'), '填空题');
      expect(StandardizedQuestion.typeLabelOf('shortAnswer'), '简答题');
      expect(StandardizedQuestion.typeLabelOf('polling'), '投票题');
      expect(StandardizedQuestion.typeLabelOf('whatever'), '未知题型');
    });

    test('服务器没给 type 时，应按正确答案个数推断多选', () {
      final quiz = {
        'content': '以下说法正确的是',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': true},
          {'name': 'B', 'content': 'B', 'isanswer': true},
          {'name': 'C', 'content': 'C', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.questionType, 'multiple');
      expect(question.isMultipleChoice, true);
    });

    test('服务器没给 type 时，对/错 两个选项应推断为判断题', () {
      final quiz = {
        'content': '这是一个判断',
        'answer': [
          {'name': 'A', 'content': '对', 'isanswer': true},
          {'name': 'B', 'content': '错', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.questionType, 'judgement');
      expect(question.isChoice, true);
    });

    test('type 16 应识别为判断题', () {
      final quiz = {
        'type': 16,
        'content': '判断题',
        'answer': [
          {'name': 'A', 'content': '对', 'isanswer': true},
          {'name': 'B', 'content': '错', 'isanswer': false},
        ],
      };
      expect(StandardizedQuestion.fromChaoxing(quiz).questionType, 'judgement');
    });

    test('应从题干 HTML 中提取图片地址', () {
      final quiz = {
        'type': 0,
        'content': '<p>看图作答</p><img src="https://a.com/1.png"/>'
            '<img src="https://a.com/2.jpg"/>',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': true},
          {'name': 'B', 'content': 'B', 'isanswer': false},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(quiz);
      expect(question.imageUrls.length, 2);
      expect(question.imageUrls[0], 'https://a.com/1.png');
      expect(question.hasImage, true);
    });

    test('图片地址应支持自定义解析函数', () {
      final quiz = {
        'type': 0,
        'content': '<img src="/img/x.png"/>',
        'answer': [
          {'name': 'A', 'content': 'A', 'isanswer': true},
        ],
      };

      final question = StandardizedQuestion.fromChaoxing(
        quiz,
        resolveImageUrl: (url) => 'https://cdn.example.com$url',
      );
      expect(question.imageUrls.first, 'https://cdn.example.com/img/x.png');
    });

    test('题干为空但课件有文字时，应使用课件文字作为题干', () {
      final question = StandardizedQuestion(
        questionText: '',
        questionType: 'single',
        slideText: '1. 关于麻醉前评估，下列说法正确的是',
        options: [
          StandardizedOption(key: 'A', value: '选项A'),
          StandardizedOption(key: 'B', value: '选项B'),
        ],
      );

      expect(question.hasText, true);
      expect(question.effectiveText, '1. 关于麻醉前评估，下列说法正确的是');
      expect(question.isUsable, true);
      expect(question.needsImageRecognition, false);
    });

    test('题干和课件文字都没有，但有图片时，应标记为需要识图', () {
      final question = StandardizedQuestion(
        questionText: '',
        questionType: 'single',
        imageUrls: const ['https://a.com/slide.png'],
      );

      expect(question.hasText, false);
      expect(question.hasImage, true);
      expect(question.needsImageRecognition, true);
      expect(question.isUsable, true);
    });

    test('题干、课件文字、图片都没有时，应视为不可用', () {
      final question = StandardizedQuestion(
        questionText: '',
        questionType: 'single',
      );

      expect(question.isUsable, false);
    });

    test('toSearchQuery 应在题干为空时使用课件文字', () {
      final question = StandardizedQuestion(
        questionText: '',
        questionType: 'single',
        slideText: '课件上的题干',
        options: [
          StandardizedOption(key: 'A', value: '甲'),
        ],
      );

      expect(question.toSearchQuery(), contains('课件上的题干'));
      expect(question.toSearchQuery(), contains('A. 甲'));
    });
  });

  group('AnswerSearchResult', () {
    test('should create with all fields', () {
      final result = AnswerSearchResult(
        answer: 'A',
        source: '服务器返回',
        confidence: 1.0,
        explanation: 'test',
        sourceType: AnswerSourceType.builtin,
      );

      expect(result.answer, 'A');
      expect(result.confidence, 1.0);
      expect(result.sourceType, AnswerSourceType.builtin);
    });

    test('sourceType label', () {
      expect(AnswerSourceType.builtin.label, '内置答案');
      expect(AnswerSourceType.aiProvider.label, 'AI检索');
    });
  });

  group('网络错误识别', () {
    test('SocketException 应归类为网络错误', () {
      final info = describeError(const SocketException('failed'));
      expect(info.isNetwork, true);
      expect(info.message, contains('网络'));
    });

    test('TimeoutException 应归类为网络错误', () {
      final info = describeError(TimeoutException('timeout'));
      expect(info.isNetwork, true);
      expect(info.message, contains('超时'));
    });

    test('字符串形式的 SocketException 也应被识别', () {
      final info = describeError(Exception('SocketException: failed host lookup'));
      expect(info.isNetwork, true);
    });

    test('普通业务异常不应被误判为网络错误', () {
      final info = describeError(StateError('业务错误'));
      expect(info.isNetwork, false);
      expect(describeErrorShort(StateError('业务错误')), contains('业务错误'));
    });

    test('isNetworkError 便捷方法', () {
      expect(isNetworkError(const SocketException('x')), true);
      expect(isNetworkError(ArgumentError('x')), false);
    });
  });

  // ===== v3 新增：地址补全 / 请求体 / 错误解析 / 答案回填 =====

  group('API 地址补全 normalizeApiUrl', () {
    test('百炼新域名 base_url 应自动补 /chat/completions', () {
      const raw =
          'https://ws-9vvakflm7lid50hq.cn-beijing.maas.aliyuncs.com/compatible-mode/v1';
      expect(
        AnswerSearchApi.normalizeApiUrl(raw),
        '$raw/chat/completions',
      );
    });

    test('旧的 dashscope 域名同样补全', () {
      const raw = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
      expect(AnswerSearchApi.normalizeApiUrl(raw), '$raw/chat/completions');
    });

    test('只写到 /compatible-mode 时应补 /v1/chat/completions', () {
      expect(
        AnswerSearchApi.normalizeApiUrl('https://a.com/compatible-mode'),
        'https://a.com/compatible-mode/v1/chat/completions',
      );
    });

    test('/v1 结尾应补 /chat/completions', () {
      expect(
        AnswerSearchApi.normalizeApiUrl('https://api.deepseek.com/v1'),
        'https://api.deepseek.com/v1/chat/completions',
      );
    });

    test('已经是完整接口地址时保持不变', () {
      const full = 'https://api.openai.com/v1/chat/completions';
      expect(AnswerSearchApi.normalizeApiUrl(full), full);
    });

    test('结尾多余的斜杠应被去掉', () {
      expect(
        AnswerSearchApi.normalizeApiUrl('https://a.com/v1///'),
        'https://a.com/v1/chat/completions',
      );
    });

    test('带引号的地址应能处理', () {
      expect(
        AnswerSearchApi.normalizeApiUrl('"https://a.com/v1"'),
        'https://a.com/v1/chat/completions',
      );
    });

    test('空地址返回空字符串', () {
      expect(AnswerSearchApi.normalizeApiUrl('   '), '');
    });
  });

  group('请求体构造', () {
    AIAnswerProvider provider({
      String model = 'qwen3.8-flash',
      bool disableThinking = true,
    }) =>
        AIAnswerProvider(
          apiUrl: 'https://a.com/v1',
          apiKey: 'sk-test',
          model: model,
          disableThinking: disableThinking,
        );

    test('思考型模型应注入 enable_thinking=false', () {
      final body = provider().buildRequestBody('题干', const []);
      expect(body['enable_thinking'], false);
      expect(body['stream'], false);
      expect(body['max_tokens'], isA<int>());
    });

    test('非思考型模型不应带 enable_thinking', () {
      final body = provider(model: 'gpt-4o-mini').buildRequestBody('题干', const []);
      expect(body.containsKey('enable_thinking'), false);
    });

    test('关掉「关闭思考模式」开关后不注入参数', () {
      final body = provider(disableThinking: false).buildRequestBody('题干', const []);
      expect(body.containsKey('enable_thinking'), false);
    });

    test('qvq 开头的模型也算思考型', () {
      expect(provider(model: 'qvq-max').injectThinkingFlag, true);
    });

    test('带图片时应构造多模态 content 数组', () {
      final body = provider().buildRequestBody('题干', const ['data:image/png;base64,AAA']);
      final messages = body['messages'] as List;
      final userContent = messages.last['content'];
      expect(userContent, isA<List>());
      expect((userContent as List).first['type'], 'text');
      expect(userContent.last['type'], 'image_url');
    });

    test('effectiveUrl 应自动补全', () {
      final p = AIAnswerProvider(
        apiUrl: 'https://a.com/compatible-mode/v1',
        apiKey: 'k',
        model: 'm',
      );
      expect(p.effectiveUrl, 'https://a.com/compatible-mode/v1/chat/completions');
    });
  });

  group('错误响应解析', () {
    test('应解析 OpenAI 兼容的错误体', () {
      final info = AnswerSearchApi.parseErrorBody({
        'error': {
          'message': 'Invalid API-key provided.',
          'type': 'invalid_request_error',
          'code': 'invalid_api_key',
        },
      });
      expect(info.code, 'invalid_api_key');
      expect(info.message, 'Invalid API-key provided.');
      expect(info.text, contains('invalid_api_key'));
    });

    test('应解析顶层 code/message', () {
      final info = AnswerSearchApi.parseErrorBody({
        'code': 'Throttling',
        'message': 'Requests throttled',
      });
      expect(info.code, 'Throttling');
      expect(info.message, 'Requests throttled');
    });

    test('空响应体应返回空结果', () {
      expect(AnswerSearchApi.parseErrorBody(null).isEmpty, true);
    });

    test('404 的错误文案应提示补 /chat/completions', () {
      final text = AnswerSearchApi.formatHttpError(404, null);
      expect(text, contains('404'));
      expect(text, contains('/chat/completions'));
    });

    test('401 的错误文案应提到地域不匹配', () {
      final text = AnswerSearchApi.formatHttpError(
        401,
        const ServerErrorInfo(code: 'invalid_api_key', message: 'bad key'),
      );
      expect(text, contains('401'));
      expect(text, contains('invalid_api_key'));
    });
  });

  group('回复清洗 stripCodeFence', () {
    test('应剥离 ```json 围栏', () {
      const raw = '```json\n{"answer":"A"}\n```';
      expect(AnswerSearchApi.stripCodeFence(raw), '{"answer":"A"}');
    });

    test('应剥离无语言标记的围栏', () {
      const raw = '```\n{"answer":"A"}\n```';
      expect(AnswerSearchApi.stripCodeFence(raw), '{"answer":"A"}');
    });

    test('没有围栏时原样返回', () {
      const raw = '{"answer":"A"}';
      expect(AnswerSearchApi.stripCodeFence(raw), raw);
    });
  });

  group('答案回填 matchOptionKeys', () {
    final options = [
      StandardizedOption(key: 'A', value: '甲'),
      StandardizedOption(key: 'B', value: '乙'),
      StandardizedOption(key: 'C', value: '丙'),
    ];

    AnswerSearchResult result({
      String answer = '',
      List<String> keys = const [],
    }) =>
        AnswerSearchResult(
          answer: answer,
          source: 'test',
          confidence: 0.8,
          sourceType: AnswerSourceType.aiProvider,
          answerKeys: keys,
        );

    test('answerKeys 应直接匹配', () {
      expect(result(answer: 'AC', keys: ['A', 'C']).matchOptionKeys(options),
          ['A', 'C']);
    });

    test('没有 answerKeys 时应从 answer 文本里抠字母', () {
      expect(result(answer: 'AC').matchOptionKeys(options), ['A', 'C']);
      expect(result(answer: 'A、C').matchOptionKeys(options), ['A', 'C']);
      expect(result(answer: '选A和C').matchOptionKeys(options), ['A', 'C']);
    });

    test('单选题只回一个 key', () {
      expect(result(answer: 'B').matchOptionKeys(options), ['B']);
    });

    test('答案与选项对不上时返回空', () {
      final onlyBC = [
        StandardizedOption(key: 'B', value: '乙'),
        StandardizedOption(key: 'C', value: '丙'),
      ];
      expect(result(answer: 'A').matchOptionKeys(onlyBC), isEmpty);
    });

    test('返回顺序应跟随选项原始顺序', () {
      expect(result(answer: 'CA').matchOptionKeys(options), ['A', 'C']);
    });

    test('判断题「对」应映射到值为「对」的选项', () {
      final judgement = [
        StandardizedOption(key: 'A', value: '对'),
        StandardizedOption(key: 'B', value: '错'),
      ];
      expect(result(answer: '对').matchOptionKeys(judgement), ['A']);
      expect(result(answer: '正确').matchOptionKeys(judgement), ['A']);
      expect(result(answer: '错').matchOptionKeys(judgement), ['B']);
      expect(result(answer: '错误').matchOptionKeys(judgement), ['B']);
    });

    test('「不正确」不应被当成「正确」', () {
      final judgement = [
        StandardizedOption(key: 'A', value: '对'),
        StandardizedOption(key: 'B', value: '错'),
      ];
      expect(result(answer: '不正确').matchOptionKeys(judgement), ['B']);
    });

    test('lettersOf 应去重并大写', () {
      expect(AnswerSearchResult.lettersOf('a, a, C'), ['A', 'C']);
      expect(AnswerSearchResult.lettersOf('没有字母'), isEmpty);
    });

    test('选项为空时返回空', () {
      expect(result(answer: 'A').matchOptionKeys(const []), isEmpty);
    });
  });
}
