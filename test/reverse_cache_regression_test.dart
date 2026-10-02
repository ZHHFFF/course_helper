import 'dart:io';
import 'dart:typed_data';

import 'package:course_helper/cache/cached_image.dart';
import 'package:course_helper/cache/answer_cache.dart';
import 'package:course_helper/cache/course_cache.dart';
import 'package:course_helper/cache/ppt_cache.dart';
import 'package:course_helper/models/presentation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'support/cache_test_env.dart';

Future<void> _lockFile(File file) async {
  final process = await Process.start(
    'powershell.exe',
    [
      '-NoProfile',
      '-Command',
      r'$f = [IO.File]::Open($env:COURSEHELPER_LOCK_PATH, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None); [Console]::WriteLine("locked"); [Console]::ReadLine() | Out-Null; $f.Dispose()',
    ],
    environment: {'COURSEHELPER_LOCK_PATH': file.path},
  );
  addTearDown(() async {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 5));
  });
  final ready = await process.stdout.first.timeout(const Duration(seconds: 10));
  expect(String.fromCharCodes(ready), contains('locked'));
}

void main() {
  late CacheTestEnv env;
  setUp(() async => env = await CacheTestEnv.create());
  tearDown(() async => env.dispose());

  test('原生校验仍支持 JPEG、PNG、16 位 PNG、动画 GIF 与 WebP 缓存', () async {
    final tiny = img.Image(width: 2, height: 2);
    final gif = img.Image(width: 2, height: 2)..addFrame(tiny);
    final sixteen = img.Image(width: 2, height: 2, format: img.Format.uint16);
    for (final entry in {
      'jpeg': img.encodeJpg(tiny),
      'png': img.encodePng(tiny),
      'png16': img.encodePng(sixteen),
      'gif': img.encodeGif(gif),
      'webp': img.encodeWebP(tiny),
    }.entries) {
      final url = 'https://img/${entry.key}';
      final file = await SlideImageStore.fileFor('formats', url);
      await file.writeAsBytes(entry.value);
      final hit = await SlideImageStore.existing('formats', url);
      expect(hit?.path, file.path, reason: entry.key);
      expect(await hit!.readAsBytes(), entry.value);
    }
  });

  test('PNG 缺尾或关键块 CRC 错误时不能标记课件完整，完整 PNG 的尾随数据仍可读取', () async {
    final png = img.encodePng(img.Image(width: 40, height: 40));
    final variants = <String, List<int>>{
      'missing_iend': png.take(png.length - 12).toList(),
      'partial_iend': png.take(png.length - 2).toList(),
      'partial_data': png.take(png.length ~/ 2).toList(),
    };
    final data = ByteData.sublistView(png);
    var offset = 8;
    while (offset + 12 <= png.length) {
      final length = data.getUint32(offset);
      final type = data.getUint32(offset + 4);
      if (type == 0x49484452 || type == 0x49444154) {
        final broken = Uint8List.fromList(png);
        broken[offset + 8 + length] ^= 0xff;
        variants['crc_$type'] = broken;
      }
      offset += 12 + length;
    }
    for (final entry in variants.entries) {
      final url = 'https://img/${entry.key}.png';
      await (await SlideImageStore.fileFor(
        'pngprobe',
        url,
      )).writeAsBytes(entry.value);
      final slides = Presentation.fromJson({
        'slides': [
          {'index': 1, 'cover': url},
        ],
      }).slides;
      expect(
        await SlideImageStore.existing('pngprobe', url),
        isNull,
        reason: entry.key,
      );
      expect(
        await SlideImageStore.hasAllSlides('pngprobe', slides),
        isFalse,
        reason: entry.key,
      );
    }
    const trailingUrl = 'https://img/trailing.png';
    await (await SlideImageStore.fileFor(
      'pngprobe',
      trailingUrl,
    )).writeAsBytes([...png, 0, 1, 2, 3]);
    expect(await SlideImageStore.existing('pngprobe', trailingUrl), isNotNull);
  });

  test('校验通过的缓存被改写为半文件后必须重新判为未缓存', () async {
    const url = 'https://img/changed.png';
    final bytes = img.encodePng(img.Image(width: 40, height: 40));
    final file = await SlideImageStore.fileFor('changed', url);
    await file.writeAsBytes(bytes);
    expect(await SlideImageStore.existing('changed', url), isNotNull);
    await file.writeAsBytes(bytes.take(32).toList());
    expect(await SlideImageStore.existing('changed', url), isNull);
    await file.writeAsBytes(bytes);
    expect(await SlideImageStore.existing('changed', url), isNotNull);
  });

  test('一节过期课堂删除失败时仍清理后续可删除课堂', () async {
    await PptCache.save('one', 'ppt', {'slides': []});
    await PptCache.save('two', 'ppt', {'slides': []});
    final lessons = Directory(
      p.join((await CourseCache.root()).path, 'lessons'),
    );
    final dirs = (await lessons.list().toList())
        .whereType<Directory>()
        .toList();
    final secondId = p.basename(dirs.last.path);
    for (final dir in dirs) {
      await File(p.join(dir.path, '.finished')).writeAsString(
        '${DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch}',
      );
    }
    await _lockFile(File(p.join(dirs.first.path, 'ppt', 'ppt.json')));
    final report = await CourseCache.cleanup();
    expect(report.removedLessons, [secondId]);
    expect(await dirs.first.exists(), isTrue);
    expect(await dirs.last.exists(), isFalse);
  }, skip: !Platform.isWindows);

  test('清空单节课堂部分失败时仅作废已删除课件，保留未删除课件', () async {
    await PptCache.save('lesson', 'one', {'title': 'one', 'slides': []});
    await PptCache.save('lesson', 'two', {'title': 'two', 'slides': []});
    await PptCache.save('other', 'keep', {'title': '其他课堂', 'slides': []});
    final dir = await CourseCache.pptDir('lesson');
    final files = (await dir.list().toList()).whereType<File>().toList();
    final firstId = p.basenameWithoutExtension(files.first.path);
    final secondId = p.basenameWithoutExtension(files.last.path);
    await _lockFile(files.last);
    await expectLater(
      CourseCache.clearLesson('lesson'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await files.first.exists(), isFalse);
    expect(await PptCache.load('lesson', firstId), isNull);
    expect((await PptCache.load('lesson', secondId))?.title, secondId);
    expect((await PptCache.load('other', 'keep'))?.title, '其他课堂');
  }, skip: !Platform.isWindows);

  test('清空全部缓存部分失败后不能返回已删除课件的内存副本', () async {
    await PptCache.save('one', 'ppt', {'title': 'one', 'slides': []});
    await PptCache.save('two', 'ppt', {'title': 'two', 'slides': []});
    for (final lesson in ['one', 'two']) {
      await AnswerCache.write(
        lesson,
        'hash',
        CachedAnswer(
          hash: 'hash',
          questionPreview: lesson,
          status: CachedAnswerStatus.ok,
          updatedAt: DateTime.now(),
        ),
      );
    }
    final lessons = Directory(
      p.join((await CourseCache.root()).path, 'lessons'),
    );
    final dirs = (await lessons.list().toList())
        .whereType<Directory>()
        .toList();
    final firstId = p.basename(dirs.first.path);
    final secondId = p.basename(dirs.last.path);
    await _lockFile(File(p.join(dirs.last.path, 'ppt', 'ppt.json')));
    await expectLater(
      CourseCache.clearAll(),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await File(p.join(dirs.first.path, 'ppt', 'ppt.json')).exists(),
      isFalse,
    );
    expect(await PptCache.load(firstId, 'ppt'), isNull);
    expect((await PptCache.load(secondId, 'ppt'))?.title, secondId);
    expect(await AnswerCache.read(firstId, 'hash'), isNull);
    final retainedAnswer = File(
      p.join(dirs.last.path, 'questions', 'hash.json'),
    );
    expect(
      (await AnswerCache.read(secondId, 'hash'))?.questionPreview,
      await retainedAnswer.exists() ? secondId : null,
    );
  }, skip: !Platform.isWindows);
}
