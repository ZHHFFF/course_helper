// ============================================================================
// 可降采样、且能被滚动主动唤醒的「图层背景捕获」
// ============================================================================
//
// ⚠️ 当前状态：**未被接入**（保留备查 + 作为「方案 B / D」的基础设施）。
//
// 底栏最终走的是「方案 C」——直接换成 `BackdropFilter`（与顶栏同一机制），
// 从根上绕开了「捕获频率跟不上滚动」的问题，因此不再需要这个组件。
// 详见 `miuix_liquid_glass_nav_bar.dart` 的文件头。
//
// 什么时候会再需要它：如果以后要用 `ui.ImageFilter.shader` 把**折射**补回来
// （方案 D：实时模糊 + 折射兼得，但只在 Impeller 下可用），
// 或者要给「跨图层、跨路由」的玻璃提供背景，就还得靠捕获。
// 这份实现比上游 `MiuixLayerBackdropCapture` 多两个能力：
// 可降采样、可被外部唤醒，正好是那时需要的。
//
// ----------------------------------------------------------------------------
//
// 这个组件是 `flutter_miuix` 里 `MiuixLayerBackdropCapture` 的替代品，
// 修的是它的两个硬伤 —— 都在真机（一加 13 / Android 15 / dpr 3.5）上实测确认过。
//
// ── 硬伤 1：捕获只由 `paint()` 驱动 → 滚动时玻璃背景「冻住」 ──────────────
//
// 这是「页面在滚、底栏玻璃里的背景却不跟着动，停一会儿突然跳一帧」的根因。
//
// 原因在 Flutter 框架层：`ListView` 的 `Viewport` 对应的渲染对象
// `RenderViewportBase` **自己就是重绘边界**：
//
//     // packages/flutter/lib/src/rendering/viewport.dart
//     abstract class RenderViewportBase<...> ... {
//       @override
//       bool get isRepaintBoundary => true;   // ← 第 752 行
//     }
//
// 而 `markNeedsPaint()` 只会把「最近的**重绘边界**祖先」标脏。滚动时变的是
// viewport 的 offset，重绘被限制在 viewport 自己的图层内 —— 位于 viewport
// **之上**的捕获节点压根收不到 `paint()`，于是：
//
//     paint() 不被调用 → _scheduleCapture() 不被调用 → 快照停留在旧帧
//
// 只有当**别的原因**让捕获节点重绘时（例如顶栏折叠改变了内容内缩 → 整页重排），
// 快照才会跳着更新一次。表现就是用户描述的
// 「停住 → 突然跳到下一帧 → 再停住」。
//
// 修法：给捕获节点一个外部唤醒口 [MiuixBackdropCaptureController.requestCapture]，
// 由滚动通知在每个滚动帧调用一次。
//
// ⚠️ 为什么可以安全地在滚动通知里 `markNeedsPaint()`：
// `ScrollPosition.setPixels` 里有断言
//   「A scrollable's position should not change during the build, layout, and paint phases」
// 也就是说滚动通知只在 `transientCallbacks` 阶段派发，不在 paint 阶段，标脏合法。
//
// ── 硬伤 2：采样率写死成设备 dpr → 每帧一张整屏位图 ────────────────────────
//
// 上游把 `pixelRatio` 写死为 `MediaQuery.devicePixelRatioOf(context)`。一加 13 是
// 3.5，于是**每帧**都要把整屏内容重新录成一张 1264×2780（≈14MB）的位图；
// 玻璃面板随后还要对它做 blur + 两次 blend，等于每帧 3~4 次 `toImageSync`。
//
// 但这些像素最终都要被模糊掉，高分辨率毫无意义。这里改成
// [captureScale]（相对 dpr 的倍率，默认 0.5），像素量直接降到 1/4。
//
// 为什么降采样**不会**让玻璃里的背景错位：面板侧是用
// `image.width / backdrop.pixelRatio` 反推逻辑尺寸的
// （见 `miuix_glass.dart` 的 `MiuixGlassPanel.prepare()`），
// 只要 `pixelRatio` 与录制时一致，几何就是准的。
// ============================================================================

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart';

/// 捕获节点的外部唤醒口。
///
/// 用途：让「内容在重绘边界内部变化、但捕获节点收不到 `paint()`」的场景
/// （典型的就是 `ListView` 滚动）能主动触发重新录制。见文件头「硬伤 1」。
class MiuixBackdropCaptureController {
  _RenderSampledBackdropCapture? _render;

  /// 请求下一帧重新录制快照。幂等：节点已经脏了再调是空操作。
  void requestCapture() => _render?.markContentDirty();

  /// 当前节点是否已挂载（未挂载时 [requestCapture] 是空操作）。
  bool get isAttached => _render?.attached ?? false;
}

/// 与 [MiuixLayerBackdropCapture] 等价，但支持降采样 + 外部唤醒。
class MiuixSampledBackdropCapture extends SingleChildRenderObjectWidget {
  const MiuixSampledBackdropCapture({
    super.key,
    required this.backdrop,
    required Widget super.child,
    this.captureScale = 0.5,
    this.controller,
  });

  final MiuixLayerBackdrop backdrop;

  /// 录制倍率（相对设备 dpr）。1.0 = 与上游一致；0.5 = 像素量降到 1/4。
  ///
  /// 玻璃面板会把背景模糊掉，采样率降一半在视觉上几乎不可分辨，
  /// 但每帧要传输/模糊的像素少了 75%。
  final double captureScale;

  final MiuixBackdropCaptureController? controller;

  @override
  RenderObject createRenderObject(BuildContext context) {
    // 位置参数顺序与 _RenderSampledBackdropCapture 构造函数一致
    final render = _RenderSampledBackdropCapture(
      backdrop,
      MediaQuery.devicePixelRatioOf(context),
      captureScale,
      controller,
    );
    controller?._render = render;
    return render;
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderSampledBackdropCapture)
      ..backdrop = backdrop
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..captureScale = captureScale
      ..controller = controller;
  }

  @override
  void didUnmountRenderObject(RenderObject renderObject) {
    final render = renderObject as _RenderSampledBackdropCapture;
    if (identical(controller?._render, render)) controller?._render = null;
    super.didUnmountRenderObject(renderObject);
  }
}

class _RenderSampledBackdropCapture extends RenderProxyBox {
  /// 位置参数 + 初始化形参：Dart 不允许**命名**参数以下划线开头，
  /// 而这里几个字段都是私有的，所以只能走位置式。
  /// 调用点见 [MiuixSampledBackdropCapture.createRenderObject]，顺序一致。
  _RenderSampledBackdropCapture(
    this._backdrop,
    this._devicePixelRatio,
    this._captureScale,
    this._controller,
  );

  MiuixLayerBackdrop _backdrop;
  MiuixLayerBackdrop get backdrop => _backdrop;
  set backdrop(MiuixLayerBackdrop value) {
    if (identical(_backdrop, value)) return;
    _backdrop.unregisterCapture(this);
    _backdrop = value;
    if (attached) _backdrop.registerCapture(this);
    markNeedsPaint();
  }

  double _devicePixelRatio;
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  double _captureScale;
  double get captureScale => _captureScale;
  set captureScale(double value) {
    if (_captureScale == value) return;
    _captureScale = value;
    markNeedsPaint();
  }

  MiuixBackdropCaptureController? _controller;
  MiuixBackdropCaptureController? get controller => _controller;
  set controller(MiuixBackdropCaptureController? value) {
    if (identical(_controller, value)) return;
    if (identical(value?._render, this)) value?._render = null;
    _controller = value;
  }

  // 独立重绘边界：Flutter 会为本节点分配一个 OffsetLayer，
  // 直接对该真实图层做 toImageSync 快照，避免重录子树导致的图层重入。
  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _backdrop.registerCapture(this);
  }

  @override
  void detach() {
    _backdrop.unregisterCapture(this);
    super.detach();
  }

  /// 外部唤醒：让本节点（重绘边界）在下一帧重新 paint，从而重新录制快照。
  void markContentDirty() {
    if (!attached) return;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _scheduleCapture();
  }

  bool _captureScheduled = false;

  void _scheduleCapture() {
    if (_captureScheduled || !hasSize || size.isEmpty) return;
    _captureScheduled = true;
    // 帧结束后再快照，避免在 paint 阶段改状态触发同帧重入。
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _captureScheduled = false;
      if (!attached || !hasSize || size.isEmpty) return;
      _capture();
    });
  }

  /// 实际录制时用的采样倍率。
  ///
  /// `pixelRatio` 直接决定这张位图多大；`toImageSync` 是按这个倍率出图的，
  /// 所以降采样就落在这里。
  double get _capturePixelRatio {
    final ratio = _devicePixelRatio * _captureScale;
    // 兜底：倍率必须为正且有限，否则 toImageSync 会抛
    if (!ratio.isFinite || ratio <= 0) return 1;
    return ratio;
  }

  void _capture() {
    final offsetLayer = layer;
    if (offsetLayer is! OffsetLayer) return;
    final dpr = _capturePixelRatio;
    final ui.Image image = offsetLayer.toImageSync(
      Offset.zero & size,
      pixelRatio: dpr,
    );
    final global = localToGlobal(Offset.zero);
    // 注意：这里上报的是**实际录制倍率**，面板据此把位图尺寸换算回逻辑尺寸，
    // 所以降采样不会影响玻璃里背景的位置与缩放。
    _backdrop.updateSnapshot(image, global, dpr);
    BackdropCaptureStats.record(image.width, image.height);
  }
}

/// 捕获频率 / 位图尺寸的统计，只用于诊断，正常路径开销可忽略。
///
/// 读法（滚动时）：
///   adb logcat -s MiuixBackdrop
///
/// 期望：滚动中每秒约等于屏幕刷新率（60Hz → ≈60 次）。
/// 若每秒只有 0~3 次，说明捕获没跟上滚动 —— 即文件头「硬伤 1」的复现。
class BackdropCaptureStats {
  BackdropCaptureStats._();

  static int _count = 0;
  static int _lastReportMs = 0;
  static int _lastW = 0, _lastH = 0;

  static void record(int width, int height) {
    _count++;
    _lastW = width;
    _lastH = height;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastReportMs == 0) {
      _lastReportMs = now;
      return;
    }
    if (now - _lastReportMs < 1000) return;
    debugPrint(
      '[MiuixBackdrop] 每秒捕获 $_count 次，位图 ${_lastW}x$_lastH',
    );
    _count = 0;
    _lastReportMs = now;
  }
}
