import 'dart:io';
import 'dart:convert';

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

int _pdfPageCount(List<int> bytes) =>
    RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes, allowInvalid: true)).length;

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

  test('同一路径被两页引用时写出两页', () async {
    final p = _fakeSlide(dir, 0, png: false);
    final result = await PptExporter.build([p, p]);

    expect(result.ok, isTrue, reason: result.error);
    expect(result.total, 2);
    expect(result.written, 2);
    expect(_pdfPageCount(result.bytes!), 2);
  });

  test('混合重复路径仍按输入顺序写出四页', () async {
    final a = _fakeSlide(dir, 0, png: false);
    final b = _fakeSlide(dir, 1, png: true);
    final result = await PptExporter.build([a, a, b, a]);

    expect(result.ok, isTrue, reason: result.error);
    expect(result.total, 4);
    expect(result.written, 4);
    expect(result.skipped, isEmpty);
    expect(_pdfPageCount(result.bytes!), 4);
  });

  test('有坏文件时拒绝导出，避免课件缺页', () async {
    final bad = File('${dir.path}/broken.jpg')..writeAsBytesSync([1, 2, 3, 4]);
    final good = _fakeSlide(dir, 0, png: false);

    final result = await PptExporter.build([bad.path, good]);

    expect(result.ok, isFalse);
    expect(result.bytes, isNull);
    expect(result.total, 2);
    expect(result.written, 1);
    expect(result.skipped.length, 1);
  });

  test('空列表 → 明确报错而不是崩', () async {
    final result = await PptExporter.build([]);
    expect(result.ok, isFalse);
    expect(result.error, isNotNull);
  });

  test('保留 JPEG 文件头的截断图片仍须拒绝整份导出', () async {
    final image = img.Image(width: 160, height: 90);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgb(x, y, x % 256, y % 256, (x * y) % 256);
      }
    }
    final jpeg = img.encodeJpg(image);
    final good = _fakeSlide(dir, 0, png: true);
    for (final badBytes in [
      jpeg.take(jpeg.length - 2).toList(),
      jpeg.take(jpeg.length ~/ 2).toList(),
      // APP 段里允许有缩略图 EOI；它不能掩盖主图缺失的结束块。
      [...jpeg.take(2), 0xff, 0xe1, 0, 5, 0xff, 0xd9, 0,
        ...jpeg.skip(2).take(jpeg.length - 4)],
    ]) {
      final bad = File('${dir.path}/truncated.jpg');
      await bad.writeAsBytes(badBytes);
      final result = await PptExporter.build([good, bad.path]);
      expect(result.ok, isFalse);
      expect(result.bytes, isNull);
      expect(result.written, 1);
      expect(result.skipped, [bad.path]);
    }
  });

  test('完整 JPEG 带尾随数据或嵌入缩略图结束标记仍可导出', () async {
    final jpeg = img.encodeJpg(img.Image(width: 160, height: 90));
    for (final bytes in [
      [...jpeg, 0, 1, 2, 3],
      [...jpeg.take(2), 0xff, 0xe1, 0, 5, 0xff, 0xd9, 0, ...jpeg.skip(2)],
    ]) {
      final file = File('${dir.path}/complete.jpg');
      await file.writeAsBytes(bytes);
      final result = await PptExporter.build([file.path]);
      expect(result.ok, isTrue, reason: result.error);
      expect(_pdfPageCount(result.bytes!), 1);
    }
  });

  test('多扫描的渐进 JPEG 仍可导出，最后一段扫描截断时拒绝导出', () async {
    // 本地 Pillow 生成的 16x16 渐进 JPEG，独立于被测 JPEG 解析器。
    final progressive = base64Decode(
      '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERET'
      'FhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4e'
      'Hh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/wgARCAAQABADASIAAhEBAxEB/8QA'
      'FQABAQAAAAAAAAAAAAAAAAAABQf/xAAVAQEBAAAAAAAAAAAAAAAAAAABAv/aAAwDAQACEAMQAAABnrzD'
      '1n//xAAWEAADAAAAAAAAAAAAAAAAAAAAAwT/2gAIAQEAAQUCRMImETCJj//EABcRAQADAAAAAAAAAAAA'
      'AAAAAAUAITH/2gAIAQMBAT8BKWy5/8QAFhEAAwAAAAAAAAAAAAAAAAAAAAID/9oACAECAQE/AZOf/8QA'
      'FRABAQAAAAAAAAAAAAAAAAAAADH/2gAIAQEABj8CiIj/xAAVEAEBAAAAAAAAAAAAAAAAAAAAMf/aAAgB'
      'AQABPyGJEiRP/9oADAMBAAIAAwAAABD3/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPxBH/8QA'
      'FBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPxAf/8QAFRABAQAAAAAAAAAAAAAAAAAAAPH/2gAIAQEA'
      'AT8QgJCQgP/Z',
    );
    final file = File('${dir.path}/progressive.jpg');
    await file.writeAsBytes(progressive);
    final valid = await PptExporter.build([file.path]);
    expect(valid.ok, isTrue, reason: valid.error);
    expect(_pdfPageCount(valid.bytes!), 1);
    await file.writeAsBytes(progressive.take(progressive.length - 3).toList());
    final truncated = await PptExporter.build([file.path]);
    expect(truncated.ok, isFalse);
    expect(truncated.bytes, isNull);
  });
}
