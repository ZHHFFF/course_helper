/// 幻灯片图片的磁盘缓存 + 后台预取
///
/// 为什么不用 `Image.network` 直接看：
/// 1. Flutter 自带的 `ImageCache` 只在内存里，进程一退就没了；
/// 2. `Image.network` 的 HTTP 缓存受服务器响应头摆布，雨课堂的图不一定带缓存头；
/// 3. 我们要的语义是「**这节课的这份 PPT 我已经整份存下来了**」，
///    按课程隔离、按课程清理 —— 这是 HTTP 缓存给不了的。
///
/// 所以这里做三件事：
/// - [SlideImageStore]：把图片字节落到 `lessons/<lessonId>/ppt/images/<sha1>.bin`
/// - [SlideImage]：一个走上面那份磁盘缓存的 `ImageProvider`，
///   命中磁盘直接解码，没命中就下载并顺手存下来
/// - [SlideImagePrefetcher]：串行地把整份 PPT 的图提前拉下来
///
/// 预取**只下载字节、不解码**。80 页 PPT 一次性解码会直接把内存吃爆，
/// 而且解码出来的位图对「提前存到磁盘」这件事毫无帮助。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

import '../utils/app_logger.dart';
import 'course_cache.dart';

/// 幻灯片图片的磁盘存储
class SlideImageStore {
  SlideImageStore._();

  static const String _tag = 'SlideImageStore';
  static const String _imagesDirName = 'images';

  /// 下载用：只要字节，不要字符串，不要拦截器（避免把鉴权头带到图片域名上）
  static final Dio _dio = Dio(
    BaseOptions(
      responseType: ResponseType.bytes,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
      // 图片挂了不该抛到 UI 上，交给调用方按 null/异常处理
      validateStatus: (status) => status != null && status >= 200 && status < 400,
    ),
  );

  static Future<Directory> imageDir(String lessonId,
      {bool create = true}) async {
    final dir = Directory(
      p.join((await CourseCache.pptDir(lessonId, create: create)).path,
          _imagesDirName),
    );
    if (create && !await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> fileFor(String lessonId, String url) async {
    final dir = await imageDir(lessonId);
    return File(p.join(dir.path, '${_digest(url)}.bin'));
  }

  /// 只查磁盘，命中返回文件
  static Future<File?> existing(String lessonId, String url) async {
    if (url.trim().isEmpty) return null;
    try {
      final file = await fileFor(lessonId, url);
      if (!await file.exists()) return null;
      if (await file.length() == 0) return null;
      return file;
    } catch (e) {
      AppLogger.d(_tag, '查图片缓存失败：$e');
      return null;
    }
  }

  /// 磁盘有就读磁盘，没有就下载（下载后顺手落盘）
  static Future<Uint8List> bytesFor(String lessonId, String url) async {
    final hit = await existing(lessonId, url);
    if (hit != null) return hit.readAsBytes();

    final file = await download(lessonId, url);
    return file.readAsBytes();
  }

  /// 下载并落盘
  ///
  /// 先写 `.tmp` 再 rename：中途失败不会留下半张图，
  /// 下次判断「磁盘里有没有」时不会被半个文件骗到。
  static Future<File> download(String lessonId, String url) async {
    final target = await fileFor(lessonId, url);
    final response = await _dio.get<List<int>>(url);
    final data = response.data;

    if (data == null || data.isEmpty) {
      throw StateError('图片内容为空');
    }

    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(data, flush: true);
    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);
    return target;
  }

  static String _digest(String url) =>
      sha1.convert(utf8.encode(url)).toString();
}

/// 走磁盘缓存的 `ImageProvider`
///
/// 用法：`Image(image: SlideImage(lessonId, cover), ...)`
/// 其余 `loadingBuilder` / `errorBuilder` 行为与 `Image.network` 一致。
class SlideImage extends ImageProvider<SlideImage> {
  /// 哪节课的缓存（决定图片存哪个目录）
  final String lessonId;

  /// 图片地址
  final String url;

  final double scale;

  const SlideImage(this.lessonId, this.url, {this.scale = 1.0});

  @override
  Future<SlideImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<SlideImage>(this);

  @override
  ImageStreamCompleter loadImage(SlideImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
      debugLabel: key.url,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<String>('图片地址', key.url),
        DiagnosticsProperty<String>('课程', key.lessonId),
      ],
    );
  }

  Future<ui.Codec> _load(SlideImage key, ImageDecoderCallback decode) async {
    final bytes = await SlideImageStore.bytesFor(key.lessonId, key.url);
    if (bytes.isEmpty) {
      throw StateError('图片内容为空：${key.url}');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is SlideImage &&
      other.lessonId == lessonId &&
      other.url == url &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(lessonId, url, scale);

  @override
  String toString() => 'SlideImage("$url", scale: $scale)';
}

/// 预取进度
@immutable
class SlidePrefetchProgress {
  /// 新下载成功的数量
  final int downloaded;

  /// 磁盘已有、直接跳过的数量
  final int skipped;

  /// 下载失败的数量
  final int failed;

  /// 本次计划总数
  final int total;

  const SlidePrefetchProgress({
    required this.downloaded,
    required this.skipped,
    required this.failed,
    required this.total,
  });

  const SlidePrefetchProgress.idle()
      : downloaded = 0,
        skipped = 0,
        failed = 0,
        total = 0;

  int get finished => downloaded + skipped + failed;

  bool get isRunning => total > 0 && finished < total;

  bool get isEmpty => total == 0;
}

/// 串行预取整份 PPT 的图片
///
/// 串行而不是并发，是因为同时打 80 个请求既容易被服务端限速，
/// 也会和正在播放的 PPT 抢带宽 —— 用户翻到某页时反而更卡。
class SlideImagePrefetcher {
  SlideImagePrefetcher._();

  static const String _tag = 'SlideImagePrefetcher';

  static final List<String> _queue = [];
  static String? _lessonId;
  static bool _running = false;

  static int _downloaded = 0;
  static int _skipped = 0;
  static int _failed = 0;

  /// App 退到后台时置 true，预取循环会在原地等
  static bool paused = false;

  static final ValueNotifier<SlidePrefetchProgress> progress =
      ValueNotifier<SlidePrefetchProgress>(
    const SlidePrefetchProgress.idle(),
  );

  /// 用新的列表替换待预取队列（旧队列立即作废）
  static void start(String lessonId, Iterable<String> urls) {
    _lessonId = lessonId;
    _queue
      ..clear()
      ..addAll(
        urls
            .map((u) => u.trim())
            .where((u) => u.isNotEmpty)
            .toSet(), // 去重：同一张图可能被多页引用
      );
    _downloaded = 0;
    _skipped = 0;
    _failed = 0;
    _emit();
    // 不 await：预取是后台行为，调用方不需要等它
    unawaited(_pump());
  }

  /// 停止预取并清空队列（退出课堂时调用）
  static void cancel() {
    _queue.clear();
    _lessonId = null;
    _downloaded = 0;
    _skipped = 0;
    _failed = 0;
    _emit();
  }

  static Future<void> _pump() async {
    if (_running) return;
    _running = true;

    try {
      while (_queue.isNotEmpty) {
        // 后台就原地等，回前台再继续
        while (paused && _queue.isNotEmpty) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (_queue.isEmpty) break;

        final url = _queue.removeAt(0);
        final lessonId = _lessonId;
        if (lessonId == null) break;

        try {
          final hit = await SlideImageStore.existing(lessonId, url);
          if (hit != null) {
            _skipped++;
          } else {
            await SlideImageStore.download(lessonId, url);
            _downloaded++;
          }
        } catch (e) {
          _failed++;
          AppLogger.d(_tag, '预取失败（$url）：$e');
        }

        _emit();
        // 让出一次事件循环，避免长时间占着同一帧
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _running = false;
      _emit();
      AppLogger.i(
        _tag,
        '预取结束：新下载 $_downloaded，已缓存 $_skipped，失败 $_failed',
      );
    }
  }

  static void _emit() {
    progress.value = SlidePrefetchProgress(
      downloaded: _downloaded,
      skipped: _skipped,
      failed: _failed,
      total: _downloaded + _skipped + _failed + _queue.length,
    );
  }
}
