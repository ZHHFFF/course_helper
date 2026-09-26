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

import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';

/// 全局 shader 库：负责 asset 加载与能力探测
///
/// ⚠️ **加载是异步的**，所以本类暴露 [ready] 这个 `ValueListenable`。
/// 调用方**必须监听它**并在变化时重建 —— 否则底栏会在 program 就绪后
/// 依然停在降级路径（这正是第一版实机验证暴露出的缺陷：
/// A/B 对比像素完全一致，说明 shader 从未被应用）。
class LiquidGlassShaderLibrary {
  LiquidGlassShaderLibrary._();

  static const String _tag = 'LiquidGlass';

  /// 必须与 `pubspec.yaml` 的 `flutter: shaders:` 条目一致
  static const String assetKey = 'shaders/liquid_refract.frag';

  static bool _initCalled = false;
  static ui.FragmentProgram? _program;
  static Object? _loadError;

  /// program 就绪状态。就绪后置 true，监听方据此重建以切到折射路径。
  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  /// 当前渲染后端是否支持 `ImageFilter.shader`（仅 Impeller 为 true）
  static bool get isBackendSupported => ui.ImageFilter.isShaderFilterSupported;

  /// program 是否已加载完成
  static bool get isProgramLoaded => _program != null;

  /// 是否可以真正使用折射效果
  static bool get isAvailable => isBackendSupported && _program != null;

  /// 加载失败的原因（用于日志 / 兜底提示），成功时为 null
  static Object? get loadError => _loadError;

  /// 预加载 shader program（幂等，可在 `main()` 里提前调用）
  ///
  /// ⚠️ 异步：调用后 [isAvailable] 不会立刻变 true。
  /// 底栏在就绪前走降级模糊，就绪后由 [ready] 通知重建切到折射 ——
  /// 这样既不阻塞首帧，又不会永远停在降级路径。
  static void initialize() {
    if (_initCalled) return;
    _initCalled = true;

    // Skia 下 `ImageFilter.shader` 必然抛异常，连加载都不必做
    if (!isBackendSupported) {
      AppLogger.w(_tag, '后端不支持 ImageFilter.shader（非 Impeller），折射已禁用');
      return;
    }

    AppLogger.i(_tag, '开始加载折射着色器：$assetKey');
    ui.FragmentProgram.fromAsset(assetKey).then(
      (ui.FragmentProgram program) {
        _program = program;
        _loadError = null;
        AppLogger.i(_tag, '折射着色器加载完成，已启用');
        ready.value = true;
      },
      onError: (Object error, StackTrace stack) {
        _loadError = error;
        AppLogger.e(_tag, '折射着色器加载失败：$error\n$stack');
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
    this.zoom = 1.0,
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

  /// 采样放大倍率（1.0 = 不放大）。
  ///
  /// 对应 Compose 的 `layerBlock { scaleX/scaleY }` —— 在**采样层**缩放，
  /// 所以放大后的内容仍会被折射，而不是把已渲染的结果拉大。
  final double zoom;

  bool _sameAs(LiquidGlassRefractionParams o) {
    if (refractionHeight != o.refractionHeight ||
        refractionAmount != o.refractionAmount ||
        depthEffect != o.depthEffect ||
        chromaticAberration != o.chromaticAberration ||
        offset != o.offset ||
        zoom != o.zoom ||
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

    // float zoom
    shader.setFloat(12, p.zoom);
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
