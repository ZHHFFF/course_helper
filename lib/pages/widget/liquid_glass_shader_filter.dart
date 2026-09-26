// ============================================================================
// Liquid Glass 折射滤镜（`ImageFilter.shader` 封装）
// ============================================================================
//
// 对应着色器：`shaders/liquid_refract.frag`（移植自 Kyant0/AndroidLiquidGlass
// 的 Lens.kt，经 KernelSU refs/kernelsu/Lens.kt 中转）。
//
// 【职责】
//   1. 全局缓存 `FragmentProgram`（从 asset 加载，有真实开销，只做一次）
//   2. 把 Dart 侧参数写进 shader 的 uniform，产出一个 `ImageFilter`
//   3. 探测后端能力，不可用时返回 null 让调用方降级
//
// 【为什么 program 全局、shader 实例不全局】
//
//   - `FragmentProgram.fromAsset()` 要读 asset + 走编译产物，**开销大** → 全局缓存。
//   - `FragmentShader` 持有 **uniform 状态**。若全局共用一个实例，
//     底栏外壳与选中指示器在同帧用不同参数时**会互相覆盖** → 必须各自持有。
//   - `program.fragmentShader()` 本身很轻（Flutter 官方的 overscroll 拉伸效果
//     就是每次 build 新建 + dispose，见 packages/flutter/lib/src/widgets/
//     stretch_effect.dart:170）。所以策略是：
//       **program 全局一份；FragmentShader 由调用方按角色持有并复用。**
//
// 【uniform 索引约定（踩过的坑）】
//
//   `setFloat(index, value)` 的 index **不计数 sampler**，且
//   **index 0~1 被 `u_size` 占用**（引擎自动填绑定纹理尺寸，不要自己设）。
//   → 自定义 float 从 **index 2** 开始。
//   这与 Flutter 官方 stretch_effect 的用法一致（它也从 2 开始）。
//
// 【后端限制（硬性）】
//
//   `ImageFilter.shader` **仅 Impeller 可用**，Skia 下构造会直接抛
//   `UnsupportedError`（见 sky_engine/lib/ui/painting.dart:4461）。
//   所以调用前必须过 `isAvailable`。Skia 下本类返回 null，
//   调用方降级为普通 `BackdropFilter` + `ImageFilter.blur`（无折射）。
// ============================================================================

import 'dart:ui' as ui;

/// 全局 shader 库：负责 asset 加载与能力探测
class LiquidGlassShaderLibrary {
  LiquidGlassShaderLibrary._();

  /// 必须与 `pubspec.yaml` 的 `flutter: shaders:` 条目一致
  static const String assetKey = 'shaders/liquid_refract.frag';

  static bool _initCalled = false;
  static ui.FragmentProgram? _program;
  static Object? _loadError;

  /// 当前渲染后端是否支持 `ImageFilter.shader`（仅 Impeller 为 true）
  static bool get isBackendSupported => ui.ImageFilter.isShaderFilterSupported;

  /// program 是否已加载完成（异步，首帧可能还没好）
  static bool get isProgramLoaded => _program != null;

  /// 是否可以真正使用折射效果
  static bool get isAvailable => isBackendSupported && _program != null;

  /// 加载失败的原因（用于日志 / 兜底提示），成功时为 null
  static Object? get loadError => _loadError;

  /// 预加载 shader program（幂等，可在 `main()` 里提前调用）
  ///
  /// ⚠️ 是异步的：调用后 `isAvailable` 不会立刻变 true。
  /// 底栏在 program 就绪前会走降级路径，就绪后下一帧自动切换 —— 这是刻意的，
  /// 避免为了等 shader 而阻塞首帧。
  static void initialize() {
    if (_initCalled) return;
    _initCalled = true;

    // Skia 下 `ImageFilter.shader` 必然抛异常，连加载都不必做
    if (!isBackendSupported) return;

    ui.FragmentProgram.fromAsset(assetKey).then(
      (ui.FragmentProgram program) {
        _program = program;
        _loadError = null;
      },
      onError: (Object error, StackTrace _) {
        _loadError = error;
      },
    );
  }

  /// 供 [LiquidGlassRefraction] 取用；外部不应直接调用
  static ui.FragmentShader? newShader() => _program?.fragmentShader();
}

/// 一次折射渲染所需的参数（也是复用缓存的键）
class LiquidGlassRefractionParams {
  const LiquidGlassRefractionParams({
    required this.refractionHeight,
    required this.refractionAmount,
    required this.cornerRadii,
    this.depthEffect = 1.0,
    this.chromaticAberration = 0.0,
    this.offset = ui.Offset.zero,
  });

  /// 折射带宽度（px）：距边缘这个距离内的像素才参与折射
  final double refractionHeight;

  /// 最大折射位移（px）
  final double refractionAmount;

  /// 四角圆角半径，顺序 TL, TR, BR, BL
  final List<double> cornerRadii;

  /// 0/1，是否叠加朝心的深度分量（玻璃厚度感）
  final double depthEffect;

  /// 色散强度。**0 = 走无版散快路径**（省 6 次纹理采样）
  final double chromaticAberration;

  /// 与 SDF 中心的偏移
  final ui.Offset offset;

  bool _sameAs(LiquidGlassRefractionParams o) {
    if (refractionHeight != o.refractionHeight ||
        refractionAmount != o.refractionAmount ||
        depthEffect != o.depthEffect ||
        chromaticAberration != o.chromaticAberration ||
        offset != o.offset ||
        cornerRadii.length != o.cornerRadii.length) {
      return false;
    }
    for (var i = 0; i < cornerRadii.length; i++) {
      if (cornerRadii[i] != o.cornerRadii[i]) return false;
    }
    return true;
  }
}

/// 折射滤镜持有者：参数不变时复用同一个 `ImageFilter`，避免每帧重建
///
/// 用法（在 `State` 里持有一个实例，`dispose()` 里释放）：
/// ```dart
/// final _refraction = LiquidGlassRefraction();
///
/// ui.ImageFilter? get _glassFilter => _refraction.resolve(
///       const LiquidGlassRefractionParams(
///         refractionHeight: 18,
///         refractionAmount: 9,
///         cornerRadii: [32, 32, 32, 32],
///         chromaticAberration: 0.35,
///       ),
///     );
/// ```
class LiquidGlassRefraction {
  ui.FragmentShader? _shader;
  ui.ImageFilter? _filter;
  LiquidGlassRefractionParams? _cached;

  /// 取（或按需重建）滤镜。**后端不可用时返回 null**，调用方必须降级。
  ui.ImageFilter? resolve(LiquidGlassRefractionParams params) {
    if (!LiquidGlassShaderLibrary.isAvailable) {
      _release();
      return null;
    }

    // 参数没变 → 直接复用，避免每帧分配
    final cached = _cached;
    if (cached != null && cached._sameAs(params) && _filter != null) {
      return _filter;
    }

    final shader = LiquidGlassShaderLibrary.newShader();
    if (shader == null) {
      _release();
      return null;
    }

    _writeUniforms(shader, params);

    // 旧实例先释放：上一帧已绘制完成，这里释放是安全的
    _shader?.dispose();
    _shader = shader;
    _filter = ui.ImageFilter.shader(shader);
    _cached = params;
    return _filter;
  }

  /// 写入 uniform。索引见文件头说明：0~1 是引擎占用的 `u_size`。
  static void _writeUniforms(
    ui.FragmentShader shader,
    LiquidGlassRefractionParams p,
  ) {
    shader.setFloat(2, p.refractionHeight);
    shader.setFloat(3, p.refractionAmount);
    shader.setFloat(4, p.depthEffect);
    shader.setFloat(5, p.chromaticAberration);

    // vec4 cornerRadii（TL, TR, BR, BL）—— 不足 4 个时补 0
    for (var i = 0; i < 4; i++) {
      shader.setFloat(6 + i, i < p.cornerRadii.length ? p.cornerRadii[i] : 0.0);
    }

    // vec2 offset
    shader.setFloat(10, p.offset.dx);
    shader.setFloat(11, p.offset.dy);
  }

  void _release() {
    _shader?.dispose();
    _shader = null;
    _filter = null;
    _cached = null;
  }

  /// 必须在 `State.dispose()` 里调用
  void dispose() => _release();
}
