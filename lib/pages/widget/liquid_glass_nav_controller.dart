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

    // 位置收敛后，若有挂起的 release 就执行（对应上游 release() 的顺序要求）
    _value.controller.addStatusListener(_onValueStatusChanged);

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
  bool _releasePending = false;
  bool _tapAnimating = false;
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

  /// 对应上游 `canDrag`
  bool _canDrag(double x) => x >= 0.0 && x <= barWidth;

  // ── 指针事件（对应上游 inspectDragGestures）────────────────────────────

  void handlePointerDown({required int pointer, required double x}) {
    if (_pointer != null) return;
    _pointer = pointer;
    _resetVelocityTracking();

    _pressedIndex = itemAt(x);
    onPointerStateChanged();

    // 上游 onDragStarted：先 updateValue，再 press()
    updateValue(itemAt(x).toDouble());
    press();
  }

  void handlePointerMove({
    required int pointer,
    required double x,
    required double previousX,
  }) {
    if (_pointer != pointer) return;
    // 上游：当前与上一帧都在栏内才处理
    if (!_canDrag(x) || !_canDrag(previousX)) return;

    final dragAmount = x - previousX;
    if (tabWidth <= 0 || dragAmount == 0) return;

    // 上游 onDrag：只更新位置，**不回调 onSelect**（切页推迟到松手）
    final next = (_targetValue + dragAmount / tabWidth * (rtl ? -1.0 : 1.0))
        .clamp(_valueRangeStart, _valueRangeEnd);
    updateValue(next);

    final item = itemAt(x);
    if (item != _pressedIndex) {
      _pressedIndex = item;
      onPointerStateChanged();
    }
  }

  void handlePointerUp(int pointer) {
    if (_pointer != pointer) return;
    _pointer = null;
    _pressedIndex = -1;
    onPointerStateChanged();

    // 上游 onDragStopped：**这里才**决定切页
    final target = _targetValue.round().clamp(0, itemCount - 1);
    if (_index != target) {
      _index = target;
      onSelect(target);
    }
    updateValue(target.toDouble());
    release();
  }

  void handlePointerCancel(int pointer) {
    if (_pointer != pointer) return;
    _pointer = null;
    _pressedIndex = -1;
    onPointerStateChanged();
    // 上游 onDragCancelled：回到当前选中项
    updateValue(_index.toDouble());
    release();
  }

  // ── 动画控制 ────────────────────────────────────────────────────────────

  /// 按下：三个动画并行推进
  void press() {
    _releasePending = false;
    _resetVelocityTracking();
    _press.animateTo(1.0, LiquidGlassSprings.pressProgress);
    _scaleX.animateTo(_pressedScale, LiquidGlassSprings.scaleX);
    _scaleY.animateTo(_pressedScale, LiquidGlassSprings.scaleY);
  }

  /// 松手：**先等位置收敛**，再收起按压与缩放
  void release() {
    _releasePending = true;
    if (!_value.isAnimating) _performRelease();
  }

  void _onValueStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed && _releasePending) {
      _performRelease();
    }
  }

  void _performRelease() {
    if (!_releasePending) return;
    _releasePending = false;
    _press.animateTo(0.0, LiquidGlassSprings.pressProgress);
    _scaleX.animateTo(_initialScale, LiquidGlassSprings.scaleX);
    _scaleY.animateTo(_initialScale, LiquidGlassSprings.scaleY);
  }

  /// 实时更新位置（对应上游 updateValue）
  void updateValue(double v) {
    _targetValue = v.clamp(_valueRangeStart, _valueRangeEnd);
    if (disabledMotion) {
      _value.snapTo(_targetValue);
      return;
    }
    _value.controller.animateWith(
      SpringSimulation(
        LiquidGlassSprings.position,
        _value.value,
        _targetValue,
        _value.controller.velocity,
      ),
    );
    _updateVelocity();
  }

  /// 点击切页：press → 移动 → 收力（对应上游 animateToValue）
  void animateToValue(double v) {
    final target = v.clamp(_valueRangeStart, _valueRangeEnd);
    _tapAnimating = true;
    _index = target.round().clamp(0, itemCount - 1);
    onSelect(_index);
    press();
    updateValue(target);
    _velocity.snapTo(0.0);
    release();
    Future<void>.delayed(const Duration(milliseconds: 320), () {
      _tapAnimating = false;
    });
  }

  /// 用位置序列喂 VelocityTracker 得平滑速度（对应上游 updateVelocity）
  void _updateVelocity() {
    final span =
        (_valueRangeEnd - _valueRangeStart).clamp(1e-6, double.infinity);
    _velocityTracker.addPosition(
      Duration(milliseconds: _startMark.elapsedMilliseconds),
      Offset(_value.value, 0.0),
    );
    final v = _velocityTracker.getVelocity().pixelsPerSecond.dx / span;
    _velocity.snapTo(v.clamp(-8.0, 8.0));
  }

  /// 外部（页面滑动）驱动位置
  void syncFromPage(double page) {
    final clamped = page.clamp(_valueRangeStart, _valueRangeEnd);
    _targetValue = clamped;
    _value.snapTo(clamped);
  }

  void updateSelectedIndex(int index) => _index = index;
  void cancelTapAnimation() => _tapAnimating = false;

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
    _value.controller.removeStatusListener(_onValueStatusChanged);
    _value.dispose();
    _velocity.dispose();
    _press.dispose();
    _scaleX.dispose();
    _scaleY.dispose();
    _show.dispose();
  }
}
