// ============================================================================
// Liquid Glass 着色器封装
// ============================================================================
//
// 逐行对应 refs/kyant/Shaders.kt（Kyant0/AndroidLiquidGlass @ 65ab177…，分支 kmp）
//
//   liquid_refract.frag            ← RoundedRectRefractionShaderString
//   liquid_refract_dispersion.frag ← RoundedRectRefractionWithDispersionShaderString
//   liquid_highlight.frag          ← DefaultHighlightShaderString
//
// 【本文件只做三件事】
//   1. 全局缓存 `FragmentProgram`（从 asset 加载有真实开销，只做一次）
//   2. 把 Dart 参数按**上游的 uniform 顺序**写进 shader，产出 `ImageFilter`
//   3. 探测后端能力，不可用时返回 null 让调用方降级
//
// 【为什么 program 全局、shader 实例不全局】
//   - `FragmentProgram.fromAsset()` 开销大 → 全局缓存
//   - `FragmentShader` 持有 **uniform 状态**。若全局共用一个实例，
//     外壳与指示器在同帧用不同参数时会互相覆盖 → 必须各自持有
//   - `program.fragmentShader()` 本身很轻（Flutter 官方 stretch_effect.dart:170
//     就是每次 build 新建 + dispose）
//
// 【uniform 索引 —— 与上游声明顺序严格一致】
//   上游 Shaders.kt 的声明顺序：
//     size, offset, cornerRadii, refractionHeight, refractionAmount,
//     depthEffect, [chromaticAberration]
//   `setFloat(index)` 不计数 sampler，且**第一个 float uniform 起于 index 0**；
//   对 `ImageFilter.shader` 而言 0~1 被引擎自动填入「绑定纹理尺寸」。
//   → 0,1=size | 2,3=offset | 4..7=cornerRadii | 8=refractionHeight
//     9=refractionAmount | 10=depthEffect | 11=chromaticAberration（仅色散版）
//
// 【两处必须与上游一致、极易搞错的语义】
//   ★ `refractionAmount` 写入时**取负**
//     上游 Lens.kt：`setFloatUniform("refractionAmount", -refractionAmount)`
//     → 位移方向朝心（向内收）。传正数会让内容被往外推，方向完全相反。
//   ★ `chromaticAberration` 是**布尔**，不是 0~1 强度
//     上游用它切换**两份不同的 shader**；用色散版时 uniform 固定为 1.0
// ============================================================================

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';

/// 全局着色器库：负责 asset 加载与能力探测
class LiquidGlassShaderLibrary {
  LiquidGlassShaderLibrary._();

  static const String _tag = 'LiquidGlass';

  /// 折射（无版散）—— 对应上游 `RoundedRectRefractionShaderString`
  static const String plainAssetKey = 'shaders/liquid_refract.frag';

  /// 折射 + 7 抽色散 —— 对应上游 `RoundedRectRefractionWithDispersionShaderString`
  static const String dispersionAssetKey = 'shaders/liquid_refract_dispersion.frag';

  /// 方向性高光 —— 对应上游 `DefaultHighlightShaderString`
  static const String highlightAssetKey = 'shaders/liquid_highlight.frag';

  static bool _initCalled = false;
  static ui.FragmentProgram? _plain;
  static ui.FragmentProgram? _dispersion;
  static ui.FragmentProgram? _highlight;
  static Object? _loadError;

  /// program 就绪状态。就绪后置 true，监听方据此重建以切到折射路径。
  ///
  /// ⚠️ 加载是异步的，**调用方必须监听** —— 否则底栏会在 program 就绪后
  /// 依然停在降级路径（实机 A/B 验证曾因此误判为「shader 从未生效」）。
  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  /// 当前渲染后端是否支持 `ImageFilter.shader`（仅 Impeller 为 true）
  static bool get isBackendSupported => ui.ImageFilter.isShaderFilterSupported;

  /// 是否可以真正使用折射效果
  static bool get isAvailable => isBackendSupported && _plain != null;

  /// 高光 shader 是否可用（走 `Paint.shader`，不受 Impeller 限制，但仍需加载完成）
  static bool get isHighlightAvailable => _highlight != null;

  /// 加载失败的原因（用于日志 / 兜底提示），成功时为 null
  static Object? get loadError => _loadError;

  /// 预加载全部着色器（幂等，可在 `main()` 里提前调用）
  static void initialize() {
    if (_initCalled) return;
    _initCalled = true;

    // 高光走 Paint.shader，任何后端都能用，先加载它
    _load(highlightAssetKey, (p) => _highlight = p);

    // Skia 下 `ImageFilter.shader` 必然抛异常，折射两份不必加载
    if (!isBackendSupported) {
      AppLogger.w(_tag, '后端不支持 ImageFilter.shader（非 Impeller），折射已禁用');
      return;
    }

    _load(dispersionAssetKey, (p) => _dispersion = p);
    _load(plainAssetKey, (p) {
      _plain = p;
      AppLogger.i(_tag, '折射着色器加载完成，已启用');
      ready.value = true;
    });
  }

  static void _load(String key, void Function(ui.FragmentProgram) onOk) {
    ui.FragmentProgram.fromAsset(key).then(
      (ui.FragmentProgram program) {
        onOk(program);
        _loadError = null;
      },
      onError: (Object error, StackTrace stack) {
        _loadError = error;
        AppLogger.e(_tag, '着色器加载失败（$key）：$error\n$stack');
      },
    );
  }

  /// 供 [LiquidGlassRefraction] 取用；外部不应直接调用
  static ui.FragmentShader? newRefractionShader({required bool dispersion}) =>
      (dispersion ? _dispersion : _plain)?.fragmentShader();

  /// 供高光绘制取用；外部不应直接调用
  static ui.FragmentShader? newHighlightShader() => _highlight?.fragmentShader();
}

/// 一次折射渲染所需的参数（也是复用缓存的键）
///
/// 字段与上游 `Lens.kt` 的 `lens(...)` 入参一一对应。
class LiquidGlassRefractionParams {
  const LiquidGlassRefractionParams({
    required this.refractionHeight,
    required this.refractionAmount,
    required this.cornerRadii,
    this.depthEffect = false,
    this.chromaticAberration = false,
    this.offset = ui.Offset.zero,
  });

  /// 折射带宽度（**物理像素**）：距边缘这个距离内的像素才参与折射
  ///
  /// 上游 `lens(refractionHeight)`。传 0 或负 → 上游会直接不加效果。
  final double refractionHeight;

  /// 最大折射位移（**物理像素**，传正数）
  ///
  /// 上游 `lens(refractionAmount)`，内部取负后写入 uniform。
  final double refractionAmount;

  /// 四角圆角半径，顺序 **TL, TR, BR, BL**（与上游 `cornerRadii` 一致）
  final List<double> cornerRadii;

  /// 是否叠加朝心的深度分量（上游 `depthEffect: Boolean = false`）
  final bool depthEffect;

  /// 是否使用色散版 shader（上游 `chromaticAberration: Boolean = false`）
  ///
  /// ⚠️ 这是**布尔开关**，不是强度。true 时改用
  /// `liquid_refract_dispersion.frag`，并把 uniform 固定为 1.0。
  final bool chromaticAberration;

  /// 与 SDF 中心的偏移（上游 `offset`，默认由 `-padding` 得到；此处默认 0）
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

    // 上游：`if (refractionHeight <= 0 || refractionAmount <= 0) return`
    // —— 参数为 0 就不加效果（指示器静止时正是这种情况）
    if (params.refractionHeight <= 0 || params.refractionAmount <= 0) {
      _release();
      return null;
    }

    final cached = _cached;
    if (cached != null && cached._sameAs(params) && _filter != null) {
      return _filter;
    }

    final shader = LiquidGlassShaderLibrary.newRefractionShader(
      dispersion: params.chromaticAberration,
    );
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

  /// 写入 uniform。索引与上游声明顺序严格一致，见文件头说明。
  static void _writeUniforms(
    ui.FragmentShader shader,
    LiquidGlassRefractionParams p,
  ) {
    // 0,1 = size —— 由引擎自动填入绑定纹理尺寸，**不要**自己设

    // 2,3 = offset
    shader.setFloat(2, p.offset.dx);
    shader.setFloat(3, p.offset.dy);

    // 4..7 = cornerRadii（TL, TR, BR, BL）—— 不足 4 个时补 0
    for (var i = 0; i < 4; i++) {
      shader.setFloat(4 + i, i < p.cornerRadii.length ? p.cornerRadii[i] : 0.0);
    }

    // 8 = refractionHeight
    shader.setFloat(8, p.refractionHeight);

    // 9 = refractionAmount —— ★ 上游取负，位移朝心
    shader.setFloat(9, -p.refractionAmount);

    // 10 = depthEffect
    shader.setFloat(10, p.depthEffect ? 1.0 : 0.0);

    // 11 = chromaticAberration —— 仅色散版有；上游固定传 1f
    if (p.chromaticAberration) {
      shader.setFloat(11, 1.0);
    }
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
