// ============================================================================
// 课件离线浏览
// ============================================================================
//
// 「离线」的含义：图片全部走 `SlideImageStore` 的磁盘缓存
// （`lessons/<lessonId>/ppt/images/<digest>.bin`），**不建 WebSocket、不连雨课堂**。
// 所以断网也能翻页 —— 这正是它与课堂内 `PresentationPage` 的根本区别
// （后者是实时跟随老师进度 + 收题答题的）。
//
// ⚠️ 它**不是**一个路由，而是 `CoursewarePage` 内部的第三层（由 `_stage` 切）。
// 为什么不用 `Navigator.push`：push 出来的路由会盖住玻璃底栏，而用户明确要求
// 「课件如果打开了，就要保活，切回去还是那个页面」—— 底栏被盖住就没法切 Tab 了。
// 代价是全屏看课件时底栏仍在（可用高度少 ~80dp），用户已确认接受。
// ============================================================================

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../cache/cached_image.dart';
import '../../cache/ppt_cache.dart';
import '../../cache/slide_scanner.dart';
import '../../models/presentation.dart';
import '../../utils/app_logger.dart';
import '../../utils/ppt_exporter.dart';

/// 离线浏览一份已缓存的课件。
class CoursewareViewer extends StatefulWidget {
  const CoursewareViewer({
    super.key,
    required this.lessonId,
    required this.presentationId,
    required this.title,
  });

  /// 缓存目录身份（`lessons/<lessonId>/`）
  final String lessonId;

  final String presentationId;

  /// 导出 PDF 时的文件名主体
  final String title;

  @override
  State<CoursewareViewer> createState() => _CoursewareViewerState();
}

class _CoursewareViewerState extends State<CoursewareViewer> {
  static const String _tag = 'CoursewareViewer';

  final PageController _pageController = PageController();
  int _index = 0;
  bool _exporting = false;
  late Future<Presentation?> _future;

  @override
  void initState() {
    super.initState();
    // 只读本地缓存，不联网 —— 这是「离线浏览」的核心语义。
    // 若这份课件还没缓存过，`load` 返回 null，界面给出对应提示。
    _future = PptCache.load(widget.lessonId, widget.presentationId);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 一页对应的图片地址（优先 `coverAlt`，与 `PresentationPage` 一致）
  String _urlOf(PresentationSlide slide) =>
      (slide.coverAlt.trim().isNotEmpty ? slide.coverAlt : slide.cover).trim();

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Presentation?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final presentation = snapshot.data;
        if (presentation == null || presentation.slides.isEmpty) {
          return _buildEmpty(context);
        }
        return _buildViewer(context, presentation);
      },
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiuixIcon(
              icon: Icons.cloud_off_outlined,
              size: 44,
              tint: colors.onSurfaceVariantSummary,
            ),
            const SizedBox(height: 12),
            MiuixText(
              '这份课件没有本地缓存',
              fontSize: 16,
              color: colors.onSurfaceSecondary,
            ),
            const SizedBox(height: 6),
            MiuixText(
              '进课堂时它会自动缓存，也可以从课件列表里删掉这条记录',
              fontSize: 13,
              color: colors.onSurfaceVariantSummary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildViewer(BuildContext context, Presentation presentation) {
    final colors = MiuixTheme.of(context).colors;
    final total = presentation.slides.length;

    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: total,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => _buildSlide(context, presentation.slides[i]),
          ),
        ),
        // 底部操作条。它在 `CoursewarePage` 的 `bottomBar` 占位**之上**，
        // 所以不会被玻璃底栏压住。
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            border: Border(top: BorderSide(color: colors.dividerLine, width: .5)),
          ),
          child: Row(
            children: [
              MiuixText(
                '${_index + 1} / $total',
                fontSize: 14,
                color: colors.onSurfaceVariantSummary,
              ),
              const Spacer(),
              MiuixTextButton(
                _exporting ? '导出中…' : '导出 PDF',
                onPressed: _exporting
                    ? null
                    : () => _exportPdf(presentation),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSlide(BuildContext context, PresentationSlide slide) {
    final url = _urlOf(slide);
    if (url.isEmpty) {
      return Center(
        child: MiuixText(
          '第 ${slide.index + 1} 页没有图片',
          color: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
        ),
      );
    }

    return InteractiveViewer(
      maxScale: 4,
      child: Image(
        // `SlideImage` 是走磁盘缓存的 ImageProvider：命中磁盘直接解码，
        // 没命中才下载。离线时没缓存会走 errorBuilder，不会白屏。
        image: SlideImage(widget.lessonId, url),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MiuixIcon(
                  icon: Icons.broken_image_outlined,
                  size: 40,
                  tint: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
                ),
                const SizedBox(height: 10),
                MiuixText(
                  '这一页没有缓存到本地',
                  fontSize: 14,
                  color: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 把整份课件合成 PDF 并调起系统分享。
  ///
  /// 与 `PresentationPage._exportPresentationPdf` 同源，但**拒绝缺页**这一条
  /// 在这里更关键：离线浏览时图片可能只缓存了一部分，缺页导出会得到一个
  /// 页码错乱的文件，用户拿到才发现 —— 不如当场说清楚。
  Future<void> _exportPdf(Presentation presentation) async {
    if (_exporting) return;
    setState(() => _exporting = true);

    try {
      final urls = SlideScanner.imageUrlsOf(presentation.slides);
      if (urls.isEmpty) throw Exception('这份课件没有任何图片');

      // 只读盘、不下载（离线语义）
      final paths = <String>[];
      for (final url in urls) {
        final file = await SlideImageStore.existing(widget.lessonId, url);
        if (file != null) paths.add(file.path);
      }

      if (paths.length != urls.length) {
        AppLogger.w(_tag, '拒绝导出：只有 ${paths.length}/${urls.length} 页有缓存');
        _toast('还有 ${urls.length - paths.length} 页没缓存，导出会缺页。'
            '请先进课堂把这节课的课件缓存完整');
        return;
      }

      final result = await PptExporter.build(paths);
      if (!result.ok || result.bytes == null) {
        throw Exception(result.error ?? '生成 PDF 失败');
      }

      final dir = await getApplicationDocumentsDirectory();
      final raw =
          '课件_${widget.title}_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final safe = raw.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
      final out = File('${dir.path}/$safe');
      await out.writeAsBytes(result.bytes!);

      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final origin =
          box != null ? box.localToGlobal(Offset.zero) & box.size : null;

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(out.path, mimeType: 'application/pdf')],
          subject: '${widget.title} 课件',
          text: '共 ${result.written} 页',
          sharePositionOrigin: origin,
        ),
      );
      AppLogger.i(_tag, '已导出 ${result.written}/${result.total} 页 → ${out.path}');
    } catch (e) {
      AppLogger.e(_tag, '导出失败：$e');
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
}
