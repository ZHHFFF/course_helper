import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:course_helper/api/rc_crawler.dart';
import 'package:course_helper/cache/cached_image.dart';
import 'package:course_helper/cache/ppt_cache.dart';
import 'package:course_helper/cache/slide_scanner.dart';
import 'package:course_helper/models/presentation.dart';

import 'support/cache_test_env.dart';

Map<String, dynamic> _raw(List<String> urls) => {
  'title': '历史课件',
  'width': 720,
  'height': 540,
  'slides': [
    for (var i = 0; i < urls.length; i++)
      {'id': '$i', 'index': i + 1, 'cover': urls[i], 'shapes': []},
  ],
};

class _RealHttpOverrides extends HttpOverrides {}

Future<T> _withRealHttp<T>(Future<T> Function() body) =>
    HttpOverrides.runWithHttpOverrides(body, _RealHttpOverrides());

void main() {
  late CacheTestEnv env;
  setUp(() async => env = await CacheTestEnv.create());
  tearDown(() async => env.dispose());

  Future<File> putImage(String lessonId, String url) async {
    final file = await SlideImageStore.fileFor(lessonId, url);
    await file.writeAsBytes(
      img.encodePng(img.Image(width: 2, height: 2)),
      flush: true,
    );
    return file;
  }

  Future<(HttpServer, String)> serveImageBytes(List<int> bytes) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = HttpStatus.ok;
      request.response.add(bytes);
      await request.response.close();
    });
    return (server, 'http://127.0.0.1:${server.port}/slide.png');
  }

  for (final payload in ['<html>403</html>', '{"error":"expired"}']) {
    test('HTTP 200 非图片内容不能成为完整课件：$payload', () async {
      final (server, url) = await serveImageBytes(payload.codeUnits);
      addTearDown(() => server.close(force: true));
      final slides = Presentation.fromJson(_raw([url])).slides;

      expect(
        await _withRealHttp(
          () => SlideImageStore.ensureAllSlides('lesson', slides),
        ),
        isFalse,
      );
      expect(await SlideImageStore.existing('lesson', url), isNull);
      expect(
        await (await SlideImageStore.fileFor('lesson', url)).exists(),
        isFalse,
      );
    });
  }

  test('合法 PNG 下载后可通过完整性检查', () async {
    final (server, url) = await serveImageBytes(
      img.encodePng(img.Image(width: 2, height: 2)),
    );
    addTearDown(() => server.close(force: true));
    final slides = Presentation.fromJson(_raw([url])).slides;

    expect(
      await _withRealHttp(
        () => SlideImageStore.ensureAllSlides('lesson', slides),
      ),
      isTrue,
    );
    expect(await SlideImageStore.existing('lesson', url), isNotNull);
  });

  test('旧的非图片缓存视为缺图，重抓时替换为合法图片', () async {
    final (server, url) = await serveImageBytes(
      img.encodePng(img.Image(width: 2, height: 2)),
    );
    addTearDown(() => server.close(force: true));
    final file = await SlideImageStore.fileFor('lesson', url);
    await file.writeAsString('<html>stale error</html>', flush: true);
    expect(await SlideImageStore.existing('lesson', url), isNull);

    final slides = Presentation.fromJson(_raw([url])).slides;
    expect(
      await _withRealHttp(
        () => SlideImageStore.ensureAllSlides('lesson', slides),
      ),
      isTrue,
    );
    expect(await SlideImageStore.existing('lesson', url), isNotNull);
  });

  test('三张图全部落盘后才完整，导出页序列都能映射本地文件', () async {
    final urls = [
      'https://img/a.png',
      'https://img/b.png',
      'https://img/c.png',
    ];
    await PptCache.save('lesson', 'ppt', _raw(urls), verifyDisk: true);
    PptCache.clearMemory();
    final slides = (await PptCache.load('lesson', 'ppt'))!.slides;
    final downloaded = <String>[];

    final complete = await SlideImageStore.ensureAllSlides(
      'lesson',
      slides,
      downloadMissing: (id, url) async {
        downloaded.add(url);
        return putImage(id, url);
      },
    );

    expect(complete, isTrue);
    expect(downloaded.length, urls.length);
    expect(downloaded.toSet(), urls.toSet());
    for (final url in SlideScanner.exportPageUrlsOf(slides)) {
      expect(await SlideImageStore.existing('lesson', url), isNotNull);
    }
  });

  test('crawler 命中完整 metadata 和图片时直接返回整份课件', () async {
    final urls = ['https://img/a.png', 'https://img/b.png'];
    await PptCache.save('lesson', 'ppt', _raw(urls), verifyDisk: true);
    for (final url in urls) {
      await putImage('lesson', url);
    }
    PptCache.clearMemory();

    final result = await RCCrawler.crawlLessonPresentation(
      lessonId: 'lesson',
      courseId: 'course',
      courseName: '历史课',
      presentationId: 'ppt',
    );
    expect(result?.slides.length, 2);
  });

  test('一张图失败时未完整，已下载文件与 metadata 保留', () async {
    final urls = [
      'https://img/a.png',
      'https://img/b.png',
      'https://img/c.png',
    ];
    await PptCache.save('lesson', 'ppt', _raw(urls), verifyDisk: true);
    final slides = (await PptCache.load('lesson', 'ppt'))!.slides;

    final complete = await SlideImageStore.ensureAllSlides(
      'lesson',
      slides,
      downloadMissing: (id, url) async {
        if (url == urls.last) throw const SocketException('offline');
        return putImage(id, url);
      },
    );

    expect(complete, isFalse);
    PptCache.clearMemory();
    expect(await PptCache.load('lesson', 'ppt'), isNotNull);
    expect(await SlideImageStore.existing('lesson', urls[0]), isNotNull);
    expect(await SlideImageStore.existing('lesson', urls[1]), isNotNull);
    expect(await SlideImageStore.existing('lesson', urls[2]), isNull);
  });

  test('metadata 命中仍判缺图，再抓只补缺失资源', () async {
    final urls = [
      'https://img/a.png',
      'https://img/b.png',
      'https://img/c.png',
    ];
    await PptCache.save('lesson', 'ppt', _raw(urls), verifyDisk: true);
    await putImage('lesson', urls[0]);
    await putImage('lesson', urls[1]);
    final slides = (await PptCache.load('lesson', 'ppt'))!.slides;
    expect(await SlideImageStore.hasAllSlides('lesson', slides), isFalse);
    final downloaded = <String>[];

    expect(
      await SlideImageStore.ensureAllSlides(
        'lesson',
        slides,
        downloadMissing: (id, url) async {
          downloaded.add(url);
          return putImage(id, url);
        },
      ),
      isTrue,
    );
    expect(downloaded, [urls[2]]);
    expect(await SlideImageStore.hasAllSlides('lesson', slides), isTrue);
  });

  test('重复图片只下载一份，但每个 slide 仍须有本地图片', () async {
    final urls = ['https://img/a.png?token=one', 'https://img/a.png?token=two'];
    final slides = Presentation.fromJson(_raw(urls)).slides;
    final downloaded = <String>[];

    expect(
      await SlideImageStore.ensureAllSlides(
        'lesson',
        slides,
        downloadMissing: (id, url) async {
          downloaded.add(url);
          return putImage(id, url);
        },
      ),
      isTrue,
    );
    expect(downloaded, [urls.first]);
    expect(SlideScanner.exportPageUrlsOf(slides), urls);
    for (final url in urls) {
      expect(await SlideImageStore.existing('lesson', url), isNotNull);
    }
  });

  test('slide 缺少图片地址不能判完整', () async {
    final slides = Presentation.fromJson(
      _raw(['https://img/a.png', '']),
    ).slides;
    await putImage('lesson', 'https://img/a.png');
    expect(await SlideImageStore.hasAllSlides('lesson', slides), isFalse);
    expect(await SlideImageStore.ensureAllSlides('lesson', slides), isFalse);
  });
}
