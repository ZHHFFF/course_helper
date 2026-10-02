import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:course_helper/cache/cached_image.dart';
import 'package:course_helper/cache/course_cache.dart';
import 'package:course_helper/cache/ppt_cache.dart';
import 'package:course_helper/models/presentation.dart';
import 'package:course_helper/utils/ppt_exporter.dart';

import 'support/cache_test_env.dart';

class _RealHttpOverrides extends HttpOverrides {}

Future<Process> _lockFile(File file) async {
  final process = await Process.start('powershell.exe', [
    '-NoProfile', '-Command',
    r'$f = [IO.File]::Open($env:COURSEHELPER_LOCK_PATH, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None); [Console]::WriteLine("locked"); [Console]::ReadLine() | Out-Null; $f.Dispose()',
  ], environment: {'COURSEHELPER_LOCK_PATH': file.path});
  addTearDown(() async {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 5));
  });
  final ready = await process.stdout.first.timeout(const Duration(seconds: 10));
  expect(String.fromCharCodes(ready), contains('locked'));
  return process;
}

void main() {
  late CacheTestEnv env;
  setUp(() async => env = await CacheTestEnv.create());
  tearDown(() async => env.dispose());

  test('删除另一份课件时保留历史格式引用的共享图片', () async {
    const url = 'https://img/shared.png';
    for (final raw in <Map<String, dynamic>>[
      {'Slides': [{'Index': 1, 'Cover': url}]},
      {'presentation': {'slides': [{'index': 1, 'cover_alt': url}]}},
      {'slide_list': [{'index': 1, 'cover_url': url}]},
    ]) {
      await PptCache.save('lesson', 'keep', raw);
      await PptCache.save('lesson', 'remove', {'slides': []});
      final file = await SlideImageStore.fileFor('lesson', url);
      await file.writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
      await CourseCache.deletePresentation('lesson', 'remove');
      expect(await file.exists(), isTrue, reason: '$raw');
    }
  });

  test('截断 PNG 不能命中图片缓存或被判为完整课件', () async {
    const url = 'https://img/truncated.png';
    final bytes = img.encodePng(img.Image(width: 2, height: 2));
    final file = await SlideImageStore.fileFor('lesson', url);
    await file.writeAsBytes(bytes.take(32).toList());
    final slides = Presentation.fromJson({
      'slides': [{'index': 1, 'cover': url}],
    }).slides;
    expect(await SlideImageStore.existing('lesson', url), isNull);
    expect(await SlideImageStore.hasAllSlides('lesson', slides), isFalse);
  });

  test('PDF 有一页无法解码时不能报告成功或返回残缺文件', () async {
    final good = File(p.join(env.root.path, 'good.png'));
    await good.writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
    final bad = File(p.join(env.root.path, 'bad.png'));
    await bad.writeAsBytes([1, 2, 3]);
    final result = await PptExporter.build([good.path, bad.path]);
    expect(result.ok, isFalse);
    expect(result.bytes, isNull);
    expect(result.skipped, [bad.path]);
    expect(result.error, contains('1'));
  });

  test('数值字符串不能让历史课件整份失败或静默掉页', () {
    final presentation = Presentation.fromJson({
      'width': '720', 'height': '540',
      'slides': [
        {'index': '1', 'cover': 'https://img/1.png'},
        {'index': 2, 'cover': 'https://img/2.png'},
      ],
    });
    expect(presentation.width, 720);
    expect(presentation.height, 540);
    expect(presentation.slides.map((s) => s.index), [1, 2]);
  });

  test('JSON 写入失败必须向调用者报告失败', () async {
    final target = Directory(p.join(env.root.path, 'blocked.json'));
    await target.create();
    await expectLater(
      CourseCache.writeJson(File(target.path), {'new': true}),
      throwsA(isA<FileSystemException>()),
    );
  });

  for (final action in ['lesson', 'all', 'presentation']) {
    test('删除 $action 时文件被占用，不能报告成功或作废内存', () async {
      await PptCache.save('lesson', 'ppt', {'title': '课件', 'slides': []});
      final file = File(p.join((await CourseCache.pptDir('lesson')).path, 'ppt.json'));
      await _lockFile(file);
      final operation = switch (action) {
        'lesson' => CourseCache.clearLesson('lesson'),
        'all' => CourseCache.clearAll(),
        _ => CourseCache.deletePresentation('lesson', 'ppt'),
      };
      await expectLater(operation, throwsA(isA<FileSystemException>()));
      expect(await file.exists(), isTrue);
      expect(await PptCache.load('lesson', 'ppt'), isNotNull);
    }, skip: !Platform.isWindows);
  }

  test('独占图片删除失败时不能把它计入已释放字节数', () async {
    const url = 'https://img/locked.png';
    await PptCache.save('lesson', 'ppt', {'slides': [{'index': 1, 'cover': url}]});
    final json = File(p.join((await CourseCache.pptDir('lesson')).path, 'ppt.json'));
    final jsonBytes = await json.length();
    final image = await SlideImageStore.fileFor('lesson', url);
    await image.writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
    await _lockFile(image);
    expect(await CourseCache.deletePresentation('lesson', 'ppt'), jsonBytes);
    expect(await image.exists(), isTrue);
  }, skip: !Platform.isWindows);

  test('预取 A 切到 B 后，A 完成不能提前把 B 标记完整', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String, HttpRequest>{};
    final arrived = <String, Completer<void>>{
      '/a.png': Completer<void>(), '/b.png': Completer<void>(),
    };
    server.listen((request) {
      requests[request.uri.path] = request;
      arrived[request.uri.path]!.complete();
    });
    addTearDown(() => server.close(force: true));
    final png = img.encodePng(img.Image(width: 2, height: 2));
    Future<void> finish(String path) async {
      final request = requests[path]!;
      request.response.add(png);
      await request.response.close();
    }
    Future<void> waitFor(bool Function() predicate) async {
      for (var i = 0; i < 200 && !predicate(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(predicate(), isTrue);
    }
    await HttpOverrides.runWithHttpOverrides(() async {
      SlideImagePrefetcher.cancel();
      SlideImagePrefetcher.resume();
      final base = 'http://127.0.0.1:${server.port}';
      SlideImagePrefetcher.start('A', ['$base/a.png']);
      await arrived['/a.png']!.future;
      SlideImagePrefetcher.start('B', ['$base/b.png']);
      await finish('/a.png');
      await arrived['/b.png']!.future;
      final premature = SlideImagePrefetcher.progress.value;
      await finish('/b.png');
      await waitFor(() => SlideImagePrefetcher.progress.value.finished >= 1);
      // Drain both workers before teardown, including the original buggy worker.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(premature.isComplete, isFalse);
      expect(premature.finished, 0);
      expect(SlideImagePrefetcher.progress.value.finished, 1);
      SlideImagePrefetcher.cancel();
    }, _RealHttpOverrides());
  });
}
