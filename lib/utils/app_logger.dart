/// 运行日志：内存环形缓冲 + 按天落盘，用于导出给开发者分析
///
/// 设计要点：
/// 1. 内存保留最近 [AppLogger.maxEntries] 条，界面通过 [AppLogger.revision] 实时刷新
/// 2. 同时按天写入 `logs/app-YYYY-MM-DD.log`，单文件超过 [AppLogger.maxFileBytes] 自动分卷
/// 3. 启动时清理 [AppLogger.keepDays] 天前的旧日志
/// 4. 所有内容在落盘 / 展示前都会经过 [AppLogger.redact] 脱敏（API Key、Bearer Token 等）
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 日志级别
enum LogLevel { debug, info, warn, error }

/// ⚠️ **这个 extension 是活的，不要删！**
///
/// 2026-09-24 的马尾辫审查曾把它判为「零引用死代码」并删除 —— **误判**。
/// 原因是扫描器只搜了 extension 的**类名** `LogLevelLabel`，
/// 而调用点写的是**成员名** `level.label` / `level.weight`。
///
/// 实际调用点（还原时已核实）：
///   - `label`：本文件 2 处、`log_viewer.dart:369`、
///     `keep_alive_checker.dart:368`、`test/app_logger_test.dart` 4 处
///   - `weight`：本文件 `matches()`、`test/app_logger_test.dart` 6 处
///
/// 教训：**判定 extension 是否死掉，必须搜它的成员名，不能只搜类名。**
extension LogLevelLabel on LogLevel {
  String get label {
    switch (this) {
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warn:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
    }
  }

  /// 用于筛选的权重，越大越严重
  int get weight {
    switch (this) {
      case LogLevel.debug:
        return 0;
      case LogLevel.info:
        return 1;
      case LogLevel.warn:
        return 2;
      case LogLevel.error:
        return 3;
    }
  }
}

/// 一条日志
class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  const LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String formatTime(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.'
      '${t.millisecond.toString().padLeft(3, '0')}';

  /// 单行文本（导出的每一行）
  String get line => '${formatTime(time)} [${level.label}] [$tag] $message';

  bool matches(LogLevel? minLevel) =>
      minLevel == null || level.weight >= minLevel.weight;
}

/// 全局日志器
class AppLogger {
  AppLogger._();

  /// 内存里最多保留多少条
  static const int maxEntries = 3000;

  /// 单个日志文件大小上限（5MB），超过自动分卷
  static const int maxFileBytes = 5 * 1024 * 1024;

  /// 保留最近多少天的日志
  static const int keepDays = 7;

  /// 单条消息落盘前截断长度
  static const int maxMessageChars = 4000;

  static final Queue<LogEntry> _entries = Queue<LogEntry>();

  /// 每写一条日志自增，界面监听它来刷新
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Directory? _logDir;
  static File? _currentFile;
  static int _currentFileBytes = 0;
  static int _part = 1;
  static bool _initialized = false;

  /// 串行化写文件，避免并发写导致顺序错乱
  static Future<void> _writeQueue = Future<void>.value();

  static bool get isInitialized => _initialized;

  /// 日志目录（未初始化时为 null）
  static String? get logDirectoryPath => _logDir?.path;

  /// 当前正在写的文件路径
  static String? get currentFilePath => _currentFile?.path;

  /// 当前文件已写字节数
  static int get currentFileBytes => _currentFileBytes;

  /// 内存里缓存的条数
  static int get entryCount => _entries.length;

  /// 全部内存日志（从旧到新）
  static List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  /// 按级别筛选后的日志
  static List<LogEntry> filtered(LogLevel? minLevel) =>
      _entries.where((e) => e.matches(minLevel)).toList();

  /// 初始化：建目录、清理旧日志、写会话头
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      _logDir = await _resolveLogDir();
      if (_logDir == null) return;

      if (!await _logDir!.exists()) {
        await _logDir!.create(recursive: true);
      }

      await _cleanupOldFiles();
      await _openTodayFile();

      // 会话头：版本 / 平台 / 时间
      String version = 'unknown';
      try {
        final info = await PackageInfo.fromPlatform();
        version = '${info.version}+${info.buildNumber}';
      } catch (_) {
        // 拿不到就算了
      }

      write(LogLevel.info, 'App',
          '======== 会话开始 ========  版本 $version  ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}');
      write(LogLevel.info, 'App', '日志目录：${_logDir!.path}');
    } catch (e) {
      debugPrint('AppLogger 初始化失败：$e');
    }
  }

  static Future<Directory?> _resolveLogDir() async {
    try {
      if (Platform.isAndroid) {
        final external = await getExternalStorageDirectory();
        if (external != null) {
          return Directory('${external.path}/logs');
        }
      }
    } catch (_) {
      // 忽略，回落到内部目录
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      return Directory('${docs.path}/logs');
    } catch (e) {
      debugPrint('无法获取日志目录：$e');
      return null;
    }
  }

  /// 清理过期日志文件
  static Future<void> _cleanupOldFiles() async {
    final dir = _logDir;
    if (dir == null) return;

    final deadline = DateTime.now().subtract(const Duration(days: keepDays));
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('app-') || !name.endsWith('.log')) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(deadline)) {
            await entity.delete();
          }
        } catch (_) {
          // 单个文件删不掉不影响其他
        }
      }
    } catch (e) {
      debugPrint('清理旧日志失败：$e');
    }
  }

  static String _dateStamp(DateTime t) {
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '${t.year}-$m-$d';
  }

  static String _fileNameFor(DateTime t, int part) {
    final base = 'app-${_dateStamp(t)}';
    return part <= 1 ? '$base.log' : '$base-part$part.log';
  }

  /// 打开（或切换到）今天的日志文件
  static Future<void> _openTodayFile() async {
    final dir = _logDir;
    if (dir == null) return;

    final now = DateTime.now();
    final expectedName = _fileNameFor(now, _part);

    if (_currentFile != null &&
        _currentFile!.uri.pathSegments.last == expectedName) {
      return;
    }

    _part = 1;
    var file = File('${dir.path}/${_fileNameFor(now, 1)}');

    // 找到今天最后一个还没超限的分卷
    while (await file.exists()) {
      final size = await file.length();
      if (size < maxFileBytes) break;
      _part += 1;
      file = File('${dir.path}/${_fileNameFor(now, _part)}');
    }

    _currentFile = file;
    try {
      _currentFileBytes = await file.exists() ? await file.length() : 0;
    } catch (_) {
      _currentFileBytes = 0;
    }
  }

  /// 落盘一行（异步排队，不阻塞调用方）
  static void _appendToFile(String line) {
    final dir = _logDir;
    if (dir == null) return;

    _writeQueue = _writeQueue.then((_) async {
      try {
        await _openTodayFile();
        final file = _currentFile;
        if (file == null) return;

        final data = '$line\n';
        final bytes = data.length;
        if (_currentFileBytes + bytes > maxFileBytes) {
          // 分卷
          _part += 1;
          _currentFile = File('${dir.path}/${_fileNameFor(DateTime.now(), _part)}');
          _currentFileBytes = 0;
        }

        await _currentFile!.writeAsString(data, mode: FileMode.append, flush: false);
        _currentFileBytes += bytes;
      } catch (e) {
        debugPrint('写日志失败：$e');
      }
    });
  }

  /// 记录一条日志
  static void write(LogLevel level, String tag, String message) {
    final safeMessage = redact(message);
    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: safeMessage.length > maxMessageChars
          ? '${safeMessage.substring(0, maxMessageChars)}…（已截断）'
          : safeMessage,
    );

    _entries.addLast(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    revision.value++;

    _appendToFile(entry.line);
  }

  static void d(String tag, String message) => write(LogLevel.debug, tag, message);
  static void i(String tag, String message) => write(LogLevel.info, tag, message);
  static void w(String tag, String message) => write(LogLevel.warn, tag, message);
  static void e(String tag, String message) => write(LogLevel.error, tag, message);

  /// 导出全部内存日志为文本
  static String exportText({LogLevel? minLevel}) {
    final buffer = StringBuffer();
    buffer.writeln('# 课程助手运行日志');
    buffer.writeln('# 导出时间：${LogEntry.formatTime(DateTime.now())}');
    buffer.writeln('# 条数：${_entries.length}'
        '${minLevel == null ? '' : '（筛选：${minLevel.label} 及以上）'}');
    buffer.writeln('# 日志文件：${_currentFile?.path ?? '（未落盘）'}');
    buffer.writeln('#' * 60);
    for (final entry in _entries) {
      if (!entry.matches(minLevel)) continue;
      buffer.writeln(entry.line);
    }
    return buffer.toString();
  }

  /// 确保落盘队列已刷完（导出文件前调用）
  static Future<void> flush() async {
    try {
      await _writeQueue;
    } catch (_) {
      // 忽略
    }
  }

  /// 导出为文件，返回文件路径
  static Future<File?> exportFile() async {
    final dir = _logDir;
    if (dir == null) return null;

    await flush();
    try {
      final name = 'course_helper_log_'
          '${DateTime.now().millisecondsSinceEpoch}.txt';
      final file = File('${dir.path}/$name');
      await file.writeAsString(exportText(), flush: true);
      return file;
    } catch (e) {
      debugPrint('导出日志失败：$e');
      return null;
    }
  }

  /// 清空内存与磁盘日志
  static Future<void> clear() async {
    _entries.clear();
    revision.value++;

    final dir = _logDir;
    if (dir == null) return;
    try {
      await _writeQueue;
      await for (final entity in dir.list()) {
        if (entity is File) {
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('app-') || name.startsWith('course_helper_log_')) {
            try {
              await entity.delete();
            } catch (_) {
              // 忽略单个文件
            }
          }
        }
      }
      _part = 1;
      _currentFile = null;
      _currentFileBytes = 0;
      await _openTodayFile();
      write(LogLevel.info, 'App', '日志已清空');
    } catch (e) {
      debugPrint('清空日志失败：$e');
    }
  }

  // ==================== 脱敏 ====================

  // 注意：Dart 的 RegExp 不支持内联 (?i) 标志，必须用 caseSensitive: false
  static final RegExp _skPattern =
      RegExp(r'sk-[A-Za-z0-9_\-]{6,}', caseSensitive: false);
  static final RegExp _bearerPattern =
      RegExp(r'(bearer\s+)([A-Za-z0-9_\-\.]{6,})', caseSensitive: false);
  static final RegExp _fieldPattern = RegExp(
    r'("?(?:api[-_]?key|apikey|access[-_]?token|password|secret|token)"?\s*[:=]\s*"?)([A-Za-z0-9_\-\.]{6,})',
    caseSensitive: false,
  );

  /// 把 Key / Token 打码，只保留前 6 后 4
  static String redact(String input) {
    if (input.isEmpty) return input;

    var text = input;
    text = text.replaceAllMapped(_skPattern, (m) => _mask(m.group(0)!));
    text = text.replaceAllMapped(
        _bearerPattern, (m) => '${m.group(1)}${_mask(m.group(2)!)}');
    text = text.replaceAllMapped(
        _fieldPattern, (m) => '${m.group(1)}${_mask(m.group(2)!)}');
    return text;
  }

  static String _mask(String value) {
    if (value.length <= 10) return '****';
    return '${value.substring(0, 6)}****${value.substring(value.length - 4)}';
  }

  /// 长文本截断（请求体 / 响应体用）
  static String truncate(String text, [int max = 4000]) =>
      text.length <= max ? text : '${text.substring(0, max)}…（共 ${text.length} 字符，已截断）';
}

/// Dio 日志拦截器：把每次请求 / 响应 / 报错都记进 [AppLogger]
class LoggingInterceptor extends Interceptor {
  /// 标签，例如 'AI' / 'AI图片'
  final String tag;

  /// 是否记录响应体
  final bool logResponseBody;

  const LoggingInterceptor({this.tag = 'HTTP', this.logResponseBody = true});

  static const String _startKey = '_app_logger_start';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startKey] = DateTime.now().millisecondsSinceEpoch;

    AppLogger.d(tag, '→ ${options.method} ${options.uri}');
    if (options.headers.isNotEmpty) {
      AppLogger.d(tag, '  请求头: ${AppLogger.redact(options.headers.toString())}');
    }
    final data = options.data;
    if (data != null) {
      AppLogger.d(tag, '  请求体: ${AppLogger.truncate(AppLogger.redact(data.toString()))}');
    }
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    final start = response.requestOptions.extra[_startKey];
    final cost = start is int
        ? '${DateTime.now().millisecondsSinceEpoch - start}ms'
        : '?ms';

    AppLogger.i(tag,
        '← ${response.statusCode} ${response.requestOptions.uri} ($cost)');

    if (logResponseBody && response.data != null) {
      AppLogger.d(tag,
          '  响应体: ${AppLogger.truncate(AppLogger.redact(response.data.toString()))}');
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final start = err.requestOptions.extra[_startKey];
    final cost = start is int
        ? '${DateTime.now().millisecondsSinceEpoch - start}ms'
        : '?ms';

    AppLogger.e(
      tag,
      '✗ ${err.type.name} ${err.requestOptions.method} '
      '${err.requestOptions.uri} ($cost) → ${err.message}',
    );

    final data = err.response?.data;
    if (data != null) {
      AppLogger.e(tag, '  响应体: ${AppLogger.truncate(AppLogger.redact(data.toString()))}');
    }
    handler.next(err);
  }
}
