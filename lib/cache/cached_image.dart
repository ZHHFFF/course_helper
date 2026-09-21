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
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

import '../utils/app_logger.dart';
import '../utils/image_cache_key.dart';
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

  /// 同一张图的并发下载只跑一次
  ///
  /// 界面上的 [SlideImage] 和后台的 [SlideImagePrefetcher] 完全可能同时要同一张图。
  /// 不共享的话两边会往同一个临时文件上写，然后互相把对方 rename 掉，
  /// 结果其中一个报「文件不存在」→ 页面显示一个莫名其妙的错误图标。
  static final Map<String, Future<File>> _inFlight = {};

  /// 下载并落盘
  static Future<File> download(String lessonId, String url) {
    // ⚠️ key 必须和落盘文件名用**同一个身份**。
    //
    // 落盘名走 _digest()，而它只看 URL 的路径部分（丢掉签名 query）——
    // 因为 token 每次进课堂都重签，带 query 做 key 会导致缓存永远命中不了。
    //
    // 所以这里也必须是 _digest(url) 而不是完整的 url：
    // 同一张源图被多页以不同 query 引用时（比如 imageView2 的 w/1280 和 w/640），
    // 完整 URL 不同、落盘文件却是同一个。用完整 URL 当 key 就漏了这种情况，
    // 两个请求会同时写同一个目标文件、互相 delete + rename ——
    // 正是下面这段注释要防的事。
    final key = '${CourseCache.safeName(lessonId)}|${_digest(url)}';
    final pending = _inFlight[key];
    if (pending != null) return pending;

    final completer = Completer<File>();
    _inFlight[key] = completer.future;

    _downloadOnce(lessonId, url).then(
      (file) {
        _inFlight.remove(key);
        if (!completer.isCompleted) completer.complete(file);
      },
      onError: (Object error, StackTrace stack) {
        _inFlight.remove(key);
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );

    return completer.future;
  }

  static int _tmpSeq = 0;

  static Future<File> _downloadOnce(String lessonId, String url) async {
    final target = await fileFor(lessonId, url);
    final response = await _dio.get<List<int>>(url);
    final data = response.data;

    if (data == null || data.isEmpty) {
      throw StateError('图片内容为空');
    }

    // 临时文件名带自增序号：就算磁盘上有上次残留的 .tmp 也不会互相踩
    final tmp = File('${target.path}.${++_tmpSeq}.tmp');
    try {
      await tmp.writeAsBytes(data, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    } catch (e) {
      // 别把半个文件留在磁盘上，下次「磁盘里有没有」会被它骗到
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 清理失败无所谓，主流程的异常更重要
      }
      rethrow;
    }
    return target;
  }

  /// 缓存键统一由 `utils/image_cache_key.dart` 推导。
  ///
  /// 落盘文件名、并发去重键、队列去重键**三者必须是同一个身份**。
  /// 这套规则已经踩过两次坑（缓存键带签名 query 导致永不命中；
  /// 去重键与落盘键不一致导致两个 worker 抢写同一文件），
  /// 所以抽成纯函数 + 单测钉住，见那个文件顶部的说明。
  static String _digest(String url) => imageCacheDigest(url);
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

  bool get isNotEmpty => total > 0;

  /// 整份 PPT 是否已经**完整**落盘（可以安全导出 PDF）
  ///
  /// 注意必须 `failed == 0`：只要有一页没拿到，导出的 PDF 就是残缺的。
  bool get isComplete => total > 0 && finished >= total && failed == 0;

  /// 还差几页
  int get remaining => (total - finished).clamp(0, total);

  /// 「已就绪 X/Y」这类文案用
  String get label => '$finished/$total';
}

/// 预取整份 PPT 的图片
///
/// 有限并发（[maxConcurrent]）而不是串行：
/// 串行下 42 页要 20 多秒，用户进课堂后没等缓存完就点导出 PDF 就会拿到残缺文件。
/// 并发 4 是折中 —— 再高容易触发服务端限速，也会和正在播放的 PPT 抢带宽。
class SlideImagePrefetcher {
  SlideImagePrefetcher._();

  static const String _tag = 'SlideImagePrefetcher';

  /// 同时在飞的下载数
  static const int maxConcurrent = 4;

  static final List<String> _queue = [];
  static String? _lessonId;
  static bool _running = false;

  static int _total = 0;
  static int _downloaded = 0;
  static int _skipped = 0;
  static int _failed = 0;

  /// App 退到后台时置 true，预取循环会在原地等
  static bool paused = false;

  static final ValueNotifier<SlidePrefetchProgress> progress =
      ValueNotifier<SlidePrefetchProgress>(
    const SlidePrefetchProgress.idle(),
  );

  /// 整份 PPT 是否已经完整缓存（PDF 导出的前置条件）
  static bool get isComplete => progress.value.isComplete;

  /// 用新的列表替换待预取队列（旧队列立即作废）
  static void start(String lessonId, Iterable<String> urls) {
    _lessonId = lessonId;

    // 按**落盘身份**（_digest，只看 URL 路径）去重，而不是按完整 URL。
    //
    // 同一张源图可能被多页以不同 query 引用（不同尺寸参数 / 不同签名），
    // 完整 URL 不同但落盘文件名相同。按完整 URL 去重会把它们排两遍 →
    // 两个 worker 抢写同一个目标文件。这里保留**第一次出现**的那个
    // （文件名唯一，最终只可能留一份，取首次出现才是确定的）。
    final seen = <String>{};
    final unique = <String>[];
    for (final raw in urls) {
      final u = raw.trim();
      if (u.isEmpty) continue;
      if (seen.add(imageCacheDigest(u))) unique.add(u);
    }

    _queue
      ..clear()
      ..addAll(unique);
    _total = _queue.length;
    _downloaded = 0;
    _skipped = 0;
    _failed = 0;
    _emit();
    AppLogger.i(_tag, '开始预取：共 $_total 张，并发 $maxConcurrent');
    // 不 await：预取是后台行为，调用方不需要等它
    unawaited(_pump());
  }

  /// 只暂停，**不丢弃队列**
  ///
  /// 退出课堂时用这个而不是 [cancel] —— 下次进来还能接着下没下完的，
  /// 已经下好的页也不会被判定成「没缓存」。
  static void pause() {
    paused = true;
  }

  static void resume() {
    paused = false;
  }

  /// 彻底丢弃队列（切到另一份 PPT 时才用）
  static void cancel() {
    _queue.clear();
    _lessonId = null;
    _total = 0;
    _downloaded = 0;
    _skipped = 0;
    _failed = 0;
    _emit();
  }

  static Future<void> _pump() async {
    if (_running) return;
    _running = true;

    try {
      // 起 N 个 worker 抢同一个队列
      await Future.wait(
        List.generate(maxConcurrent, (_) => _worker()),
      );
    } finally {
      _running = false;
      _emit();
      AppLogger.i(
        _tag,
        '预取结束：新下载 $_downloaded，已缓存 $_skipped，失败 $_failed'
            '（$_total 张，${isComplete ? "完整" : "未完整"}）',
      );
    }
  }

  static Future<void> _worker() async {
    while (true) {
      // 后台就原地等，回前台再继续
      while (paused && _queue.isNotEmpty) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (_queue.isEmpty) return;

      final url = _queue.removeAt(0);
      final lessonId = _lessonId;
      if (lessonId == null) return;

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
  }

  static void _emit() {
    progress.value = SlidePrefetchProgress(
      downloaded: _downloaded,
      skipped: _skipped,
      failed: _failed,
      total: _total,
    );
  }
}
