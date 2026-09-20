/// 运行日志模块单元测试
///
/// 重点覆盖脱敏（正则必须是合法 Dart RegExp，否则运行时会直接抛 FormatException）
/// 与文本截断、级别筛选这些纯函数逻辑。
library;

import 'package:course_helper/utils/app_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('日志脱敏 redact', () {
    test('应打码 sk- 开头的 Key', () {
      final masked = AppLogger.redact('Authorization: sk-abcdef1234567890xyz');
      expect(masked.contains('sk-abcdef1234567890xyz'), isFalse);
      expect(masked.contains('****'), isTrue);
      // 保留前 6 后 4，便于确认用的是哪把 Key
      expect(masked.contains('sk-abc'), isTrue);
      expect(masked.contains('0xyz'), isTrue);
    });

    test('应打码 Bearer Token', () {
      final masked = AppLogger.redact('Bearer sk-1234567890abcdef');
      expect(masked.contains('1234567890abcdef'), isFalse);
      expect(masked.contains('Bearer'), isTrue);
    });

    test('应打码 bearer（小写）Token', () {
      final masked = AppLogger.redact('bearer abcdefghijklmnop');
      expect(masked.contains('abcdefghijklmnop'), isFalse);
      expect(masked.contains('****'), isTrue);
    });

    test('应打码 JSON 里的 api_key 字段', () {
      final masked =
          AppLogger.redact('{"api_key":"abcdef1234567890","model":"qwen"}');
      expect(masked.contains('abcdef1234567890'), isFalse);
      expect(masked.contains('api_key'), isTrue);
      expect(masked.contains('qwen'), isTrue);
    });

    test('应打码 camelCase 的 apiKey 与 password 字段', () {
      final masked = AppLogger.redact('apiKey=abcdef1234567890&password=hunter22');
      expect(masked.contains('abcdef1234567890'), isFalse);
      expect(masked.contains('hunter22'), isFalse);
    });

    test('普通文本不应被改动', () {
      const raw = '请求地址 https://dashscope.aliyuncs.com/compatible-mode/v1';
      expect(AppLogger.redact(raw), raw);
    });

    test('空字符串应原样返回', () {
      expect(AppLogger.redact(''), '');
    });

    test('短于 10 位的值整体打码，不泄露片段', () {
      final masked = AppLogger.redact('api_key=abc123');
      expect(masked.contains('abc123'), isFalse);
      expect(masked.contains('****'), isTrue);
    });
  });

  group('文本截断 truncate', () {
    test('未超长时原样返回', () {
      expect(AppLogger.truncate('hello'), 'hello');
    });

    test('超长时截断并标注原长度', () {
      final text = 'a' * 100;
      final result = AppLogger.truncate(text, 10);
      expect(result.startsWith('a' * 10), isTrue);
      expect(result.contains('100'), isTrue);
      expect(result.contains('已截断'), isTrue);
    });

    test('刚好等于上限时不截断', () {
      final text = 'a' * 10;
      expect(AppLogger.truncate(text, 10), text);
    });
  });

  group('日志级别', () {
    test('权重应递增，便于「警告及以上」筛选', () {
      expect(LogLevel.debug.weight < LogLevel.info.weight, isTrue);
      expect(LogLevel.info.weight < LogLevel.warn.weight, isTrue);
      expect(LogLevel.warn.weight < LogLevel.error.weight, isTrue);
    });

    test('标签文本应正确', () {
      expect(LogLevel.debug.label, 'DEBUG');
      expect(LogLevel.info.label, 'INFO');
      expect(LogLevel.warn.label, 'WARN');
      expect(LogLevel.error.label, 'ERROR');
    });
  });

  group('日志条目 LogEntry', () {
    final entry = LogEntry(
      time: DateTime(2026, 9, 20, 16, 5, 3, 7),
      level: LogLevel.warn,
      tag: 'AI请求',
      message: 'HTTP 404',
    );

    test('formatTime 应补零到毫秒', () {
      expect(LogEntry.formatTime(entry.time), '2026-09-20 16:05:03.007');
    });

    test('line 应包含时间、级别、标签、消息', () {
      expect(
        entry.line,
        '2026-09-20 16:05:03.007 [WARN] [AI请求] HTTP 404',
      );
    });

    test('matches(null) 表示不筛选，全部命中', () {
      expect(entry.matches(null), isTrue);
      expect(entry.matches(LogLevel.debug), isTrue);
      expect(entry.matches(LogLevel.warn), isTrue);
      expect(entry.matches(LogLevel.error), isFalse);
    });
  });
}
