import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:course_helper/utils/ppt_exporter.dart';

/// 造一张纯色假幻灯片
String _fakeSlide(Directory dir, int index, {required bool png}) {
  final im = img.Image(width: 160, height: 90);
  img.fill(im, color: img.ColorRgb8(30 + index * 40, 80, 200));
  final bytes = png ? img.encodePng(im) : img.encodeJpg(im);
  final path = '${dir.path}/slide_$index.${png ? 'png' : 'jpg'}';
  File(path).writeAsBytesSync(bytes);
  return path;
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ppt_exporter_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('把多张图片合成 PDF（含 PNG → JPEG 转码）', () async {
    final paths = [
      _fakeSlide(dir, 0, png: true),
      _fakeSlide(dir, 1, png: false),
      _fakeSlide(dir, 2, png: true),
    ];

    final result = await PptExporter.build(paths);

    expect(result.ok, isTrue, reason: result.error);
    expect(result.total, 3);
    expect(result.written, 3);
    expect(result.skipped, isEmpty);
    expect(result.bytes, isNotNull);
    expect(result.bytes!.length, greaterThan(1000));

    // PDF 魔数
    expect(String.fromCharCodes(result.bytes!.take(5)), '%PDF-');
  });

  test('去重：同一张图重复传只写一页', () async {
    final p = _fakeSlide(dir, 0, png: false);
    final result = await PptExporter.build([p, p, p]);

    expect(result.ok, isTrue, reason: result.error);
    expect(result.total, 1);
    expect(result.written, 1);
  });

  test('坏文件被跳过，不影响其它页', () async {
    final bad = File('${dir.path}/broken.jpg')..writeAsBytesSync([1, 2, 3, 4]);
    final good = _fakeSlide(dir, 0, png: false);

    final result = await PptExporter.build([bad.path, good]);

    expect(result.ok, isTrue, reason: result.error);
    expect(result.total, 2);
    expect(result.written, 1);
    expect(result.skipped.length, 1);
  });

  test('空列表 → 明确报错而不是崩', () async {
    final result = await PptExporter.build([]);
    expect(result.ok, isFalse);
    expect(result.error, isNotNull);
  });
}
