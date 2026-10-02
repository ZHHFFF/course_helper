import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// PPT 导出为 PDF
///
/// 设计要点：
/// 1. 图片统一转成 JPEG 再嵌入 —— `pdf` 的 `MemoryImage` 对 JPEG 支持最稳，
///    遇到 PNG/WebP 先解码再编码，避免个别页整页丢失
/// 2. 整份合成放在后台 isolate（`compute`）里做，页面不卡
/// 3. 任一页失败时拒绝导出，避免分享缺页的课件
class PptExporter {
  PptExporter._();

  /// A4 横向（16:9 的 PPT 铺满宽度时留白最少）
  static const PdfPageFormat defaultPageFormat = PdfPageFormat.a4;

  /// 合成 PDF。入参是逐页的本地图片路径，重复路径仍代表不同页。
  ///
  /// 这是一个**顶层函数**，可直接丢给 `compute()`。
  static Future<PptPdfResult> build(List<String> imagePaths) {
    return compute(_buildInIsolate, imagePaths);
  }
}

/// 导出结果
class PptPdfResult {
  final Uint8List? bytes;

  /// 总页数（调用方传入的页面数，允许重复图片）
  final int total;

  /// 实际写入 PDF 的页数
  final int written;

  /// 跳过的图片（读取或解码失败）
  final List<String> skipped;

  /// 整体失败原因（bytes 为 null 时有值）
  final String? error;

  const PptPdfResult({
    required this.bytes,
    required this.total,
    required this.written,
    required this.skipped,
    this.error,
  });

  bool get ok => bytes != null && written > 0 && written == total && skipped.isEmpty;
}

Future<PptPdfResult> _buildInIsolate(List<String> imagePaths) async {
  if (imagePaths.isEmpty) {
    return const PptPdfResult(
      bytes: null,
      total: 0,
      written: 0,
      skipped: [],
      error: '没有可导出的 PPT 图片',
    );
  }

  final doc = pw.Document();
  final skipped = <String>[];
  var written = 0;

  for (final path in imagePaths) {
    try {
      final raw = await File(path).readAsBytes();
      final jpeg = _normalizeToJpeg(raw);
      final image = pw.MemoryImage(jpeg);

      doc.addPage(
        pw.Page(
          pageFormat: PptExporter.defaultPageFormat,
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.Center(
            child: pw.Image(image, fit: pw.BoxFit.contain),
          ),
        ),
      );
      written++;
    } catch (e) {
      skipped.add(path);
      debugPrint('导出 PDF：跳过 $path（$e）');
    }
  }

  if (skipped.isNotEmpty) {
    return PptPdfResult(
      bytes: null,
      total: imagePaths.length,
      written: written,
      skipped: skipped,
      error: '${skipped.length}/${imagePaths.length} 页无法读取或解码，导出失败',
    );
  }

  try {
    final bytes = await doc.save();
    return PptPdfResult(
      bytes: bytes,
      total: imagePaths.length,
      written: written,
      skipped: skipped,
    );
  } catch (e) {
    return PptPdfResult(
      bytes: null,
      total: imagePaths.length,
      written: written,
      skipped: skipped,
      error: '生成 PDF 失败：$e',
    );
  }
}

/// 保证交给 `pw.MemoryImage` 的一定是 JPEG 字节
Uint8List _normalizeToJpeg(Uint8List raw) {
  // 已经是 JPEG（FF D8 开头）直接用，省一次解码
  if (raw.length > 3 && raw[0] == 0xFF && raw[1] == 0xD8) return raw;

  final decoded = img.decodeImage(raw);
  if (decoded == null) {
    throw const FormatException('无法解码图片');
  }
  return Uint8List.fromList(img.encodeJpg(decoded, quality: 88));
}
