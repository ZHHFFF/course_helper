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

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../cache/cached_image.dart';
import '../../cache/ppt_cache.dart';
import '../../cache/slide_scanner.dart';
import '../../models/presentation.dart';
import '../../utils/app_logger.dart';
import '../../utils/ppt_exporter.dart';
import '../widget/miuix_nav_metrics.dart';

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
  State<CoursewareViewer> createState() => CoursewareViewerState();
}

class CoursewareViewerState extends State<CoursewareViewer> {
  static const String _tag = 'CoursewareViewer';

  final PageController _pageController = PageController();
  int _index = 0;
  bool _exporting = false;
  late Future<Presentation?> _future;
  Presentation? _cachedPresentation;

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

  /// 供外部顶栏 actions 调用的全屏入口
  void openFullscreen() {
    final pres = _cachedPresentation;
    if (pres != null && pres.slides.isNotEmpty) {
      _openFullscreen(pres);
    }
  }

  /// 供外部顶栏 actions 调用的导出入口
  void exportPdfAction() {
    final pres = _cachedPresentation;
    if (pres != null && !_exporting) {
      _exportPdf(pres);
    }
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
        _cachedPresentation = presentation;
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
          child: Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                itemCount: total,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => _buildSlide(context, presentation.slides[i]),
              ),
              // 上一页箭头微件
              if (_index > 0)
                Positioned(
                  left: 10,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Material(
                      color: Colors.black26,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _pageController.previousPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOutCubic,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.chevron_left, color: Colors.white, size: 28),
                        ),
                      ),
                    ),
                  ),
                ),
              // 下一页箭头微件
              if (_index < total - 1)
                Positioned(
                  right: 10,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Material(
                      color: Colors.black26,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _pageController.nextPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOutCubic,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.chevron_right, color: Colors.white, size: 28),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // 底部操作条：必须显式给底部叠加 miuixNavBarOccupied(context)，
        // 彻底解决玻璃底栏遮挡导致的「转换为 PDF 的按钮消失」问题。
        Container(
          padding: EdgeInsets.fromLTRB(
            16,
            10,
            16,
            10 + miuixNavBarOccupied(context),
          ),
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
              MiuixButton(
                onPressed: () => _openFullscreen(presentation),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fullscreen, size: 16),
                    SizedBox(width: 4),
                    MiuixText('全屏横屏'),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              MiuixButton(
                onPressed: _exporting ? null : () => _exportPdf(presentation),
                colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_exporting)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    else
                      const Icon(Icons.picture_as_pdf_outlined, size: 16),
                    const SizedBox(width: 4),
                    MiuixText(_exporting ? '导出中…' : '导出 PDF'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openFullscreen(Presentation presentation) async {
    final result = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (context) => CoursewareFullscreenViewer(
          presentation: presentation,
          lessonId: widget.lessonId,
          title: widget.title,
          initialIndex: _index,
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() => _index = result);
      _pageController.jumpToPage(result);
    }
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
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                MiuixText(
                  '正在读取第 ${slide.index + 1} 页…',
                  fontSize: 13,
                  color: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
                ),
              ],
            ),
          );
        },
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
                  '第 ${slide.index + 1} 页暂未缓存到本地',
                  fontSize: 14,
                  color: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
                ),
                const SizedBox(height: 6),
                MiuixText(
                  '可继续滑动翻看其他页',
                  fontSize: 12,
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

/// 课件全屏横屏沉浸浏览路由
class CoursewareFullscreenViewer extends StatefulWidget {
  const CoursewareFullscreenViewer({
    super.key,
    required this.presentation,
    required this.lessonId,
    required this.title,
    required this.initialIndex,
  });

  final Presentation presentation;
  final String lessonId;
  final String title;
  final int initialIndex;

  @override
  State<CoursewareFullscreenViewer> createState() => _CoursewareFullscreenViewerState();
}

class _CoursewareFullscreenViewerState extends State<CoursewareFullscreenViewer> {
  late final PageController _controller;
  late int _currentIndex;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _startHideTimer();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      _startHideTimer();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  String _urlOf(PresentationSlide slide) =>
      (slide.coverAlt.trim().isNotEmpty ? slide.coverAlt : slide.cover).trim();

  @override
  Widget build(BuildContext context) {
    final slides = widget.presentation.slides;
    final total = slides.length;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        // dispose will safely restore orientations
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _toggleControls,
          behavior: HitTestBehavior.opaque,
          child: Stack(
            children: [
              PageView.builder(
                controller: _controller,
                itemCount: total,
                onPageChanged: (i) {
                  setState(() => _currentIndex = i);
                  _startHideTimer();
                },
                itemBuilder: (context, i) {
                  final slide = slides[i];
                  final url = _urlOf(slide);
                  if (url.isEmpty) {
                    return const Center(
                      child: Text('无图片', style: TextStyle(color: Colors.white70)),
                    );
                  }
                  return InteractiveViewer(
                    maxScale: 5,
                    child: Center(
                      child: Image(
                        image: SlideImage(widget.lessonId, url),
                        fit: BoxFit.contain,
                        errorBuilder: (context, err, stack) => Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
                              const SizedBox(height: 8),
                              Text('第 ${i + 1} 页未缓存到本地', style: const TextStyle(color: Colors.white54)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              // 上一页箭头
              if (_currentIndex > 0)
                Positioned(
                  left: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _showControls ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: IconButton(
                        icon: const Icon(Icons.chevron_left, color: Colors.white, size: 36),
                        style: IconButton.styleFrom(backgroundColor: Colors.black45),
                        onPressed: _showControls
                            ? () {
                                _controller.previousPage(
                                  duration: const Duration(milliseconds: 250),
                                  curve: Curves.easeOutCubic,
                                );
                                _startHideTimer();
                              }
                            : null,
                      ),
                    ),
                  ),
                ),
              // 下一页箭头
              if (_currentIndex < total - 1)
                Positioned(
                  right: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _showControls ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: IconButton(
                        icon: const Icon(Icons.chevron_right, color: Colors.white, size: 36),
                        style: IconButton.styleFrom(backgroundColor: Colors.black45),
                        onPressed: _showControls
                            ? () {
                                _controller.nextPage(
                                  duration: const Duration(milliseconds: 250),
                                  curve: Curves.easeOutCubic,
                                );
                                _startHideTimer();
                              }
                            : null,
                      ),
                    ),
                  ),
                ),
              // 顶栏浮动控件
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(_currentIndex),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.title,
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_currentIndex + 1} / $total',
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(_currentIndex),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

