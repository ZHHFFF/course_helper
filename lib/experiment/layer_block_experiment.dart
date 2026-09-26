// ============================================================================
// 实验：Flutter 里如何等价复现 AndroidLiquidGlass 的 `layerBlock`
// ============================================================================
//
// 【只验证一个问题】
//   Flutter 的 `Transform.scale` 能否复现上游 `layerBlock` 对
//   **backdrop sampling** 的缩放效果？
//
// 【背景：上游 layerBlock 做了什么】
//   `DrawBackdropModifier.kt` 里 `layerBlock` 被用了**两次**：
//     ① `.then(Modifier.graphicsLayer(layerBlock))`  —— 缩放 node 自己的图层
//     ② 传进 `backdrop.drawBackdrop(..., layerBlock = layerBlock)` —— 影响采样几何
//   所以上游的"内部内容被放大"= **图层缩放**，而不是 shader 里的 zoom。
//
// 【A / B 两个模式】
//   A：`Transform.scale` 包住 `ClipRRect(BackdropFilter)`
//      —— 布局尺寸不变，靠 paint-time 变换放大
//   B：直接改变 lens 的 `width/height`（布局级）
//      —— `BackdropFilter` 按放大后的真实区域采样
//
//   其余一切**完全相同**：同一个折射 shader、同一组 lens 参数、
//   同一个形状、同一段背景。只切换缩放机制这一个变量。
//
// ⚠️ 本文件是**独立实验入口**，不参与正式 App 构建路径。
//    它只 **读取** `LiquidGlassRefraction`（shader 封装），不修改任何正式代码。
// ============================================================================

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../pages/widget/liquid_glass_shader_filter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LiquidGlassShaderLibrary.initialize();
  runApp(const _ExperimentApp());
}

class _ExperimentApp extends StatelessWidget {
  const _ExperimentApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const LayerBlockExperimentPage(),
    );
  }
}

// ─────────────────────────────────────────────────────────────── 可调常量

/// lens 的基础尺寸（未放大时）
const double _baseLensW = 190.0;
const double _baseLensH = 76.0;

/// 与上游 `pressedScale = 78f / 56f` 一致
const double _pressedScale = 78.0 / 56.0;

/// tab 行的中心 y（相对屏幕高度）
const double _tabRowYFactor = 0.62;

// ─────────────────────────────────────────────────────────────── 页面

class LayerBlockExperimentPage extends StatefulWidget {
  const LayerBlockExperimentPage({super.key});

  @override
  State<LayerBlockExperimentPage> createState() =>
      _LayerBlockExperimentPageState();
}

class _LayerBlockExperimentPageState extends State<LayerBlockExperimentPage> {
  /// true = 模式 A（Transform.scale）；false = 模式 B（实际尺寸）
  bool _modeA = true;

  /// 当前缩放倍率（A 用它做 Transform.scale；B 用它改实际尺寸）
  double _scale = 1.0;

  /// lens 中心 x（逻辑像素），拖动改变
  double? _lensCx;

  /// 折射开关（便于对比"有/无折射"两种情况下 backdrop 是否被重新采样）
  bool _refractionOn = true;

  final _lens = LiquidGlassRefraction();

  @override
  void dispose() {
    _lens.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final size = MediaQuery.sizeOf(context);
    final cx = _lensCx ?? size.width / 2;
    final cy = size.height * _tabRowYFactor;

    // 上游指示器 lens 参数：10dp*progress / 14dp*progress / CA=true
    // 实验中 progress 由「折射开关」控制 —— 这样能分别观察
    // 「纯模糊」与「模糊+折射」两种情况下 backdrop 是否被重新采样
    final progress = _refractionOn ? 1.0 : 0.0;
    final radius = _baseLensH / 2;
    final filter = _lens.resolve(
      LiquidGlassRefractionParams(
        refractionHeight: 10.0 * dpr * progress,
        refractionAmount: 14.0 * dpr * progress,
        cornerRadii: [radius, radius, radius, radius],
        depthEffect: false,
        chromaticAberration: true,
      ),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: Stack(
        children: [
          // ── ① 高对比度测试背景（细线 + 棋盘格）─────────────────
          Positioned.fill(child: CustomPaint(painter: _TestBackgroundPainter())),
          // ── ② 大号 / 小号文字 ───────────────────────────────────
          const Positioned.fill(child: TestTextLayer()),
          // ── ③ 模拟 tab 行（用于"拖过其它 icon"）─────────────────
          Positioned(
            left: 0,
            right: 0,
            top: cy - 40,
            child: const _TabRow(),
          ),
          // ── ④ 拖动层：左右拖动移动 lens ─────────────────────────
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerMove: (e) {
                setState(() => _lensCx = e.position.dx);
              },
            ),
          ),
          // ── ⑤ lens ──────────────────────────────────────────────
          _buildLens(cx: cx, cy: cy, filter: filter, dpr: dpr),
          // ── ⑥ 顶部控制区（必须在最上层，否则点不到）──────────────
          _buildControls(size, dpr),
        ],
      ),
    );
  }

  // ── lens ───────────────────────────────────────────────────────────────

  Widget _buildLens({
    required double cx,
    required double cy,
    required ui.ImageFilter? filter,
    required double dpr,
  }) {
    final effectiveFilter = filter ??
        ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8); // 降级：纯模糊

    final borderRadius = BorderRadius.circular(999);

    if (_modeA) {
      // ── 模式 A：布局尺寸不变，Transform.scale 放大 ──────────────
      return Positioned(
        left: cx - _baseLensW / 2,
        top: cy - _baseLensH / 2,
        width: _baseLensW,
        height: _baseLensH,
        child: Transform.scale(
          scale: _scale,
          child: ClipRRect(
            borderRadius: borderRadius,
            child: BackdropFilter(
              filter: effectiveFilter,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
    }

    // ── 模式 B：实际尺寸按 scale 放大，BackdropFilter 按新区域采样 ──
    final w = _baseLensW * _scale;
    final h = _baseLensH * _scale;
    return Positioned(
      left: cx - w / 2,
      top: cy - h / 2,
      width: w,
      height: h,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(h / 2),
        child: BackdropFilter(
          filter: effectiveFilter,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  // ── 控制区 ─────────────────────────────────────────────────────────────

  Widget _buildControls(Size size, double dpr) {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: SafeArea(
        bottom: false,
        child: Container(
          color: const Color(0xCC000000),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _chip('A: Transform.scale', _modeA, () {
                    setState(() => _modeA = true);
                  }),
                  const SizedBox(width: 8),
                  _chip('B: 实际尺寸', !_modeA, () {
                    setState(() => _modeA = false);
                  }),
                  const SizedBox(width: 12),
                  Text(
                    'mode=${_modeA ? "A" : "B"}  scale=${_scale.toStringAsFixed(3)}',
                    style: const TextStyle(
                      color: Colors.amber,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  // 其中 _pressedScale 就是上游的 78/56，便于直接对照
                  for (final s in [1.0, 1.2, _pressedScale, 1.5])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _chip('×${s.toStringAsFixed(3)}',
                          (_scale - s).abs() < 1e-6, () {
                        setState(() => _scale = s);
                      }),
                    ),
                  const SizedBox(width: 6),
                  _chip('折射开关', _refractionOn, () {
                    setState(() => _refractionOn = !_refractionOn);
                  }),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '拖动屏幕任意处左右移动 lens',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.amber : const Color(0xFF2A2A30),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.black : Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────── 模拟 tab 行（4 个 icon）

class _TabRow extends StatelessWidget {
  const _TabRow();

  static const _labels = ['课程', '账号', '课件', '设置'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: Row(
        children: [
          for (var i = 0; i < _labels.length; i++)
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 几何图形 —— 便于观察是否被放大/折射
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: CustomPaint(painter: _IconShapePainter(i)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _labels[i],
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 四个不同的几何图形（方形/圆/三角/十字）
class _IconShapePainter extends CustomPainter {
  const _IconShapePainter(this.index);
  final int index;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.white;
    final r = Offset.zero & size;
    switch (index) {
      case 0:
        canvas.drawRect(r.deflate(6), p);
      case 1:
        canvas.drawCircle(r.center, size.width / 2 - 5, p);
      case 2:
        final path = Path()
          ..moveTo(size.width / 2, 4)
          ..lineTo(size.width - 4, size.height - 4)
          ..lineTo(4, size.height - 4)
          ..close();
        canvas.drawPath(path, p);
      default:
        canvas.drawRect(
            Rect.fromCenter(
                center: r.center, width: size.width - 8, height: 5),
            p);
        canvas.drawRect(
            Rect.fromCenter(
                center: r.center, width: 5, height: size.height - 8),
            p);
    }
  }

  @override
  bool shouldRepaint(_IconShapePainter old) => old.index != index;
}

// ─────────────────────────────────────────────────────── 高对比度测试背景

class _TestBackgroundPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 底色
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF101014),
    );

    // ① 细水平线（每 9px 一条，1px 粗）
    final hLine = Paint()
      ..color = const Color(0xFF3AF0FF)
      ..strokeWidth = 1.0;
    for (double y = 0; y < size.height; y += 9) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), hLine);
    }

    // ② 细垂直线（每 13px 一条，1px 粗）
    final vLine = Paint()
      ..color = const Color(0xFFFF4FD8)
      ..strokeWidth = 1.0;
    for (double x = 0; x < size.width; x += 13) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), vLine);
    }

    // ③ 棋盘格块（便于观察是否只是被拉伸）
    final cb = Paint()..color = const Color(0xFF1B6B3A);
    const cell = 11.0;
    for (double y = size.height * 0.74; y < size.height * 0.74 + 90; y += cell) {
      for (double x = 20; x < 20 + 220; x += cell) {
        if (((x / cell).floor() + (y / cell).floor()) % 2 == 0) {
          canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), cb);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_TestBackgroundPainter old) => false;
}

// ───────────────────────────────────────────────────── 文字层（大小号文字）

/// 叠在背景上的文字（用 widget 而非 CustomPainter，省去 TextPainter 样板）
class TestTextLayer extends StatelessWidget {
  const TestTextLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 200),
          // ④ 大号文字
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'LIQUID GLASS 12345',
              style: TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 10),
          // ⑤ 小号文字
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'abcdefghijklmnopqrstuvwxyz 0123456789 '
              'abcdefghijklmnopqrstuvwxyz 0123456789',
              style: TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Hamburgefonstiv HAMBURGEFONSTIV',
              style: TextStyle(
                color: Colors.amber,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
