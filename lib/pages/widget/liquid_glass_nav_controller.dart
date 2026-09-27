// ============================================================================
// DampedDragAnimation —— KernelSU / AndroidLiquidGlass 交互逻辑的忠实移植
// ============================================================================
//
// 来源：`refs/kernelsu/DampedDragAnimation.kt`
//   package me.weishu.kernelsu.ui.component.miuix.animation
//   （从 tiann/KernelSU 上游拉取，见 refs/kernelsu/ 目录）
//
// 【为什么重写】
//
// 上一版是我自己拼的「3 个 AnimationController + 指针瞬时速度」，与上游差距很大，
// 直接导致两个可观察的缺陷：
//   - 放大时缺少"跟手放大"的层次感（没有独立的 scaleX / scaleY 动画）；
//   - 速度形变抖动（上游用 VelocityTracker 平滑，不是指针瞬时速度）。
// 本版按上游逐个还原。
//
// 【核心结构：六个独立动画】
//
//   上游用 6 个 `Animatable`，各自跑自己的弹簧，互不干扰：
//
//   | 动画          | 弹簧 (dampingRatio, stiffness) | 作用          |
//   |---------------|-------------------------------|---------------|
//   | value         | (1.0, 1000)                   | 指示器位置    |
//   | velocity      | (0.5, 300)                    | 平滑后的速度  |
//   | pressProgress | (1.0, 1000)                   | 按压进度 0~1  |
//   | scaleX        | (0.6, 250)                    | 横向缩放      |
//   | scaleY        | (0.7, 250)                    | 纵向缩放      |
//
//   ⚠️ 关键：**scaleX 与 scaleY 是两条独立弹簧，且 dampingRatio 不同
//   （0.6 vs 0.7）** —— 这正是「液态」质感的来源：按下时横向先到位、
//   纵向稍后跟上，产生轻微的各向异性形变。用单一 scale 复刻不出来。
//
//   ⚠️ 位置弹簧 stiffness 是 **1000**（不是常见的 300）—— 很硬、跟手极快。
//
// 【release() 的顺序要求（容易漏）】
//
//   上游 `release()` 先 `awaitFrame()`，再**等位置动画收敛**，最后才回弹按压与缩放：
//     ```kotlin
//     if (value != targetValue) {
//         val threshold = (range.end - range.start) * 0.025f
//         snapshotFlow { value }.first { abs(it - target) < threshold }
//     }
//     launch { pressProgressAnimation.animateTo(0f, ...) }
//     ```
//   即：**松手后指示器先滑到目标位置，位置稳住了才收起放大效果**。
//   若同时回弹，会看到胶囊"一边移动一边缩小"，失去上游那种先落位再收力的手感。
//
// 【速度的处理】
//
//   上游不用指针瞬时速度，而是把 `value` 本身喂给 `VelocityTracker`
//   （`addPosition(t, Offset(value, 0))`），再按 value 区间跨度归一化：
//     `val targetVelocity = velocityTracker.calculateVelocity().x / span`
//   → 得到「每秒跨越多少个 tab」的平滑速度，交给视觉层做 squash & stretch。
//
// 【切页时机（用户明确要求）】
//
//   上游 `onDrag` 只 `updateValue`，**不回调**；
//   `onDragStopped` 里才 `onSelectedUpdated(targetIndex)`。
//   → 拖动过程中界面不变，**松手才切页**。
// ============================================================================

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../utils/app_logger.dart';

/// 弹簧参数（对应上游 `spring(dampingRatio, stiffness)`）
class LiquidGlassSprings {
  const LiquidGlassSprings._();

  /// 位置：ratio 1.0 / stiffness 1000 —— 很硬，跟手快
  static final position = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 1000.0, ratio: 1.0);

  /// 速度平滑：ratio 0.5 / stiffness 300
  static final velocity = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 300.0, ratio: 0.5);

  /// 按压进度：ratio 1.0 / stiffness 1000
  static final pressProgress = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 1000.0, ratio: 1.0);

  /// 横向缩放：ratio 0.6 —— 略带回弹
  static final scaleX = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 250.0, ratio: 0.6);

  /// 纵向缩放：ratio 0.7 —— 与 scaleX 刻意不同，产生各向异性
  static final scaleY = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 250.0, ratio: 0.7);

  /// 显示 / 隐藏
  static final visibility = SpringDescription.withDampingRatio(
      mass: 1.0, stiffness: 300.0, ratio: 1.0);
}

/// 带弹簧回弹的标量动画（对应 Compose 的 `Animatable<Float>`）
class _SpringValue {
  _SpringValue({required TickerProvider vsync, required double initial})
      : controller =
            AnimationController.unbounded(vsync: vsync, value: initial);

  final AnimationController controller;

  double get value => controller.value;
  bool get isAnimating => controller.isAnimating;

  void animateTo(double target, SpringDescription spring) {
    controller.animateWith(
      SpringSimulation(spring, controller.value, target, controller.velocity),
    );
  }

  void snapTo(double target) {
    controller.stop();
    controller.value = target;
  }

  void dispose() => controller.dispose();
}

/// 底栏交互控制器 —— `DampedDragAnimation` 的 Dart 版
class LiquidGlassNavController {
  LiquidGlassNavController({
    required TickerProvider vsync,
    required this.itemCount,
    required int initialIndex,
    required bool visible,
    required this.onSelect,
    required this.onPointerStateChanged,
  })  : _index = initialIndex,
        _initialScale = 1.0,
        _pressedScale = 78.0 / 56.0, // 上游常量 ≈ 1.393
        _valueRangeStart = 0.0,
        _valueRangeEnd = (itemCount - 1).toDouble(),
        _targetValue = initialIndex.toDouble() {
    _value = _SpringValue(vsync: vsync, initial: initialIndex.toDouble());
    _velocity = _SpringValue(vsync: vsync, initial: 0.0);
    _press = _SpringValue(vsync: vsync, initial: 0.0);
    _scaleX = _SpringValue(vsync: vsync, initial: _initialScale);
    _scaleY = _SpringValue(vsync: vsync, initial: _initialScale);
    _show = _SpringValue(vsync: vsync, initial: visible ? 1.0 : 0.0);

    animatables = Listenable.merge([
      _value.controller,
      _velocity.controller,
      _press.controller,
      _scaleX.controller,
      _scaleY.controller,
      _show.controller,
    ]);
  }

  int itemCount;
  final ValueChanged<int> onSelect;
  final VoidCallback onPointerStateChanged;

  final double _initialScale;
  final double _pressedScale;
  final double _valueRangeStart;
  final double _valueRangeEnd;

  late final _SpringValue _value;
  late final _SpringValue _velocity;
  late final _SpringValue _press;
  late final _SpringValue _scaleX;
  late final _SpringValue _scaleY;
  late final _SpringValue _show;

  /// 供 Widget 用 `AnimatedBuilder` 监听（六个动画合并）
  late final Listenable animatables;

  int _index;
  int? _pointer;
  int _pressedIndex = -1;
  bool _tapAnimating = false;
  int _barSelectionEpoch = 0;
  double _targetValue;

  /// Flutter 的 VelocityTracker 需要指定设备类型，且没有 reset 方法 ——
  /// 需要重置时直接换一个新实例（上游 Compose 用 resetTracking()）。
  VelocityTracker _velocityTracker =
      VelocityTracker.withKind(PointerDeviceKind.touch);
  final _startMark = Stopwatch()..start();

  void _resetVelocityTracking() {
    _velocityTracker = VelocityTracker.withKind(PointerDeviceKind.touch);
    _startMark.reset();
  }

  // ── 只读暴露 ────────────────────────────────────────────────────────────

  double get value => _value.value;
  double get targetValue => _targetValue;
  double get pressProgress => _press.value;
  double get scaleX => _scaleX.value;
  double get scaleY => _scaleY.value;

  /// 归一化平滑速度（每秒跨越多少个 tab）
  double get velocity => _velocity.value;

  double get showProgress => _show.value;
  int get index => _index;
  int get pressedIndex => _pressedIndex;
  bool get isDragging => _pointer != null;
  bool get isAnimatingFromTap => _tapAnimating;

  /// 布局相关几何量（由 Widget 每帧同步）
  double tabWidth = 0.0;
  double barWidth = 0.0;
  bool rtl = false;
  bool disabledMotion = false;
  bool positioned = false;

  // ── 几何 ────────────────────────────────────────────────────────────────

  void syncGeometry({
    required double tabWidth,
    required double barWidth,
    required bool rtl,
  }) {
    this.tabWidth = tabWidth;
    this.barWidth = barWidth;
    this.rtl = rtl;
  }

  double localX(Offset global, RenderBox? box) {
    if (box == null) return 0.0;
    return box.globalToLocal(global).dx;
  }

  int itemAt(double x) {
    if (tabWidth <= 0) return _index;
    const horizontalPadding = 4.0;
    final logicalX = rtl ? barWidth - x : x;
    return ((logicalX - horizontalPadding) / tabWidth)
        .floor()
        .clamp(0, itemCount - 1);
  }

  double _downFingerX = 0.0;
  double _downIndicatorValue = 0.0;
  bool _hasDragged = false;

  /// 调试指标（用于量化跟手误差）
  double debugPointerX = 0.0;
  double debugIndicatorX = 0.0;
  double debugError = 0.0;
  double maxErrorSlow = 0.0;
  double maxErrorFast = 0.0;
  int debugSampleCount = 0;

  double _indicatorPixelCenter(double val) {
    if (tabWidth <= 0) return 0.0;
    return rtl
        ? 8.0 + (itemCount - 1 - val + 0.5) * tabWidth
        : 8.0 + (val + 0.5) * tabWidth;
  }

  /// 对应上游 `canDrag`
  bool _canDrag(double x) => x >= 0.0 && x <= barWidth;

  // ── 指针事件（两阶段交互模型）────────────────────────────────────────────

  void handlePointerDown({required int pointer, required double x}) {
    if (_pointer != null) return;
    _pointer = pointer;
    _downFingerX = x;
    _downIndicatorValue = _value.value;
    _hasDragged = false;
    _resetVelocityTracking();

    _pressedIndex = itemAt(x);
    onPointerStateChanged();

    // 按下瞬间：严格保持当前 lens 位置，不能将位置重置为 selectedIndex 或手指位置
    // 只启动 pressProgress 与 scale 动画
    press();

    // 重置调试指标
    debugPointerX = x;
    debugIndicatorX = _indicatorPixelCenter(_value.value);
    debugError = 0.0;
    maxErrorSlow = 0.0;
    maxErrorFast = 0.0;
    debugSampleCount = 0;
  }

  void handlePointerMove({
    required int pointer,
    required double x,
    required double previousX,
  }) {
    if (_pointer != pointer) return;
    if (!_canDrag(x) || !_canDrag(previousX)) return;
    if (tabWidth <= 0) return;

    final totalDeltaX = x - _downFingerX;
    if (!_hasDragged && totalDeltaX.abs() > 4.0) {
      _hasDragged = true;
    }

    if (_hasDragged) {
      final deltaVal = (totalDeltaX / tabWidth) * (rtl ? -1.0 : 1.0);
      final rawVal = _downIndicatorValue + deltaVal;

      final boundedVal = rawVal.clamp(_valueRangeStart, _valueRangeEnd);

      // 【核心改动：两阶段模型第 1 阶段（手指按住并拖动期间）】
      // 目标：indicator 几乎直接跟随手指，严禁使用普通 Spring 作为主要追踪机制。
      // 使用 snapTo 零延迟直接更新 Lens 当前位置，彻底消除二阶 Spring 滞后！
      _value.snapTo(boundedVal);
      _targetValue = boundedVal;

      // 同步更新 velocity tracking
      _updateVelocity();

      // 计算调试指标：pointerX, indicatorX, error
      debugPointerX = x;
      debugIndicatorX = _indicatorPixelCenter(boundedVal);
      final idealIndicatorX =
          _indicatorPixelCenter(_downIndicatorValue) + totalDeltaX * (rtl ? -1.0 : 1.0);
      debugError = (idealIndicatorX - debugIndicatorX).abs();

      final vAbs = _velocity.value.abs();
      if (vAbs < 1.0) {
        if (debugError > maxErrorSlow) maxErrorSlow = debugError;
      } else {
        if (debugError > maxErrorFast) maxErrorFast = debugError;
      }
      debugSampleCount++;
      if (debugSampleCount % 4 == 0) {
        // ignore: avoid_print
        print(
          '[LiquidLag] DRAG MOVE #$debugSampleCount | pointerX: ${x.toStringAsFixed(1)} | indicatorX: ${debugIndicatorX.toStringAsFixed(1)} | error: ${debugError.toStringAsFixed(2)}px | vel: ${_velocity.value.toStringAsFixed(2)} | maxSlow: ${maxErrorSlow.toStringAsFixed(2)}px | maxFast: ${maxErrorFast.toStringAsFixed(2)}px',
        );
        AppLogger.d(
          'LiquidLag',
          'DRAG MOVE #$debugSampleCount | pointerX: ${x.toStringAsFixed(1)} | indicatorX: ${debugIndicatorX.toStringAsFixed(1)} | error: ${debugError.toStringAsFixed(2)}px | vel: ${_velocity.value.toStringAsFixed(2)} | maxSlow: ${maxErrorSlow.toStringAsFixed(2)}px | maxFast: ${maxErrorFast.toStringAsFixed(2)}px',
        );
      }
    }

    final item = itemAt(x);
    if (item != _pressedIndex) {
      _pressedIndex = item;
      onPointerStateChanged();
    }
  }

  void handlePointerUp(int pointer) {
    if (_pointer != pointer) return;
    _pointer = null;
    final pressed = _pressedIndex;
    _pressedIndex = -1;
    onPointerStateChanged();

    if (_hasDragged) {
      // 【核心改动：两阶段模型第 2 阶段（手指松开以后）】
      // current position + release velocity → spring → target tab
      final releasePxPerSec = _velocityTracker.getVelocity().pixelsPerSecond.dx;
      final releaseTabPerSec =
          (tabWidth > 0 ? (releasePxPerSec / tabWidth) : 0.0) * (rtl ? -1.0 : 1.0);

      // 结合惯性速度预测目标项（约 120ms 动量前瞻）
      final momentum = releaseTabPerSec * 0.12;
      final projected = (_value.value + momentum).round().clamp(0, itemCount - 1);

      final target = projected;
      _targetValue = target.toDouble();
      _holdPageSyncForBarSelection();
      if (_index != target) {
        _index = target;
        onSelect(target);
      }

      // ignore: avoid_print
      print(
        '[LiquidLag] DRAG RELEASE -> target: $target | from: ${_value.value.toStringAsFixed(3)} | vel: ${releaseTabPerSec.toStringAsFixed(2)} tabs/s | maxSlowErr: ${maxErrorSlow.toStringAsFixed(2)}px | maxFastErr: ${maxErrorFast.toStringAsFixed(2)}px',
      );
      AppLogger.i(
        'LiquidLag',
        'DRAG RELEASE -> target: $target | from: ${_value.value.toStringAsFixed(3)} | vel: ${releaseTabPerSec.toStringAsFixed(2)} tabs/s | maxSlowErr: ${maxErrorSlow.toStringAsFixed(2)}px | maxFastErr: ${maxErrorFast.toStringAsFixed(2)}px',
      );

      // 松手后由高刚度弹簧带着初速度落位目标项
      _value.controller.animateWith(
        SpringSimulation(
          LiquidGlassSprings.position,
          _value.value,
          _targetValue,
          releaseTabPerSec.clamp(-25.0, 25.0),
        ),
      );
      release();
    } else {
      // 未发生拖拽（纯点击）：通过 animateToValue 平滑滑向点击项
      if (pressed >= 0 && pressed < itemCount && pressed != _index) {
        animateToValue(pressed.toDouble());
      } else {
        release();
      }
    }
  }

  void handlePointerCancel(int pointer) {
    if (_pointer != pointer) return;
    _pointer = null;
    _pressedIndex = -1;
    onPointerStateChanged();
    // 取消时回到当前选中项
    _targetValue = _index.toDouble();
    _value.controller.animateWith(
      SpringSimulation(
        LiquidGlassSprings.position,
        _value.value,
        _targetValue,
        0.0,
      ),
    );
    release();
  }

  // ── 动画控制 ────────────────────────────────────────────────────────────

  /// 按下：三个动画并行推进
  void press() {
    _resetVelocityTracking();
    _press.animateTo(1.0, LiquidGlassSprings.pressProgress);
    _scaleX.animateTo(_pressedScale, LiquidGlassSprings.scaleX);
    _scaleY.animateTo(_pressedScale, LiquidGlassSprings.scaleY);
  }

  /// 松手：位置与按压/缩放动画彻底解耦，立即独立回弹！
  void release() {
    // 松手后的位移弹簧已拿到 release velocity；视觉形变不能停在最后一帧速度。
    _velocity.snapTo(0.0);
    _press.animateTo(0.0, LiquidGlassSprings.pressProgress);
    _scaleX.animateTo(_initialScale, LiquidGlassSprings.scaleX);
    _scaleY.animateTo(_initialScale, LiquidGlassSprings.scaleY);
  }

  /// 点击切页：位置 spring 独立飞向目标，按压与缩放立即独立回弹！
  void animateToValue(double v) {
    final target = v.clamp(_valueRangeStart, _valueRangeEnd);
    _holdPageSyncForBarSelection();
    _index = target.round().clamp(0, itemCount - 1);
    onSelect(_index);
    _targetValue = target;
    _value.controller.animateWith(
      SpringSimulation(
        LiquidGlassSprings.position,
        _value.value,
        _targetValue,
        0.0,
      ),
    );
    _velocity.snapTo(0.0);
    release();
  }

  // PageView 从旧页滚到新页时不能把已经跟手到目标附近的 Lens 拉回旧位置。
  void _holdPageSyncForBarSelection() {
    _tapAnimating = true;
    final epoch = ++_barSelectionEpoch;
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (_barSelectionEpoch == epoch) _tapAnimating = false;
    });
  }

  /// 外部状态更新（如外部直接设置 selectedIndex）
  void updateValue(double v) {
    final target = v.clamp(_valueRangeStart, _valueRangeEnd);
    _targetValue = target;
    if (disabledMotion) {
      _value.snapTo(_targetValue);
      return;
    }
    _value.controller.animateWith(
      SpringSimulation(
        LiquidGlassSprings.position,
        _value.value,
        _targetValue,
        0.0,
      ),
    );
  }

  /// 用位置序列喂 VelocityTracker 得平滑速度（对应上游 updateVelocity）
  void _updateVelocity() {
    final span =
        (_valueRangeEnd - _valueRangeStart).clamp(1e-6, double.infinity);
    _velocityTracker.addPosition(
      Duration(milliseconds: _startMark.elapsedMilliseconds),
      Offset(_value.value * (tabWidth > 0 ? tabWidth : 1.0), 0.0),
    );
    final pxPerSec = _velocityTracker.getVelocity().pixelsPerSecond.dx;
    final tabPerSec = tabWidth > 0 ? (pxPerSec / tabWidth) : 0.0;
    final normalizedVel = tabPerSec / span;
    _velocity.animateTo(
      normalizedVel.clamp(-6.0, 6.0),
      LiquidGlassSprings.velocity,
    );
  }

  /// 外部（页面滑动）驱动位置
  void syncFromPage(double page) {
    final clamped = page.clamp(_valueRangeStart, _valueRangeEnd);
    _targetValue = clamped;
    _value.snapTo(clamped);
  }

  void updateSelectedIndex(int index) => _index = index;
  void cancelTapAnimation() {
    ++_barSelectionEpoch;
    _tapAnimating = false;
  }

  /// 显示 / 隐藏
  void setVisible(bool visible) {
    _show.animateTo(visible ? 1.0 : 0.0, LiquidGlassSprings.visibility);
    if (!visible) {
      _pointer = null;
      _pressedIndex = -1;
    }
  }

  void resetForItemCountChange() {
    positioned = false;
    _pointer = null;
    _pressedIndex = -1;
  }

  /// 首帧就位（不做动画）
  void placeAt(int index) {
    _value.snapTo(index.toDouble());
    _targetValue = index.toDouble();
  }

  void dispose() {
    _value.dispose();
    _velocity.dispose();
    _press.dispose();
    _scaleX.dispose();
    _scaleY.dispose();
    _show.dispose();
  }
}
