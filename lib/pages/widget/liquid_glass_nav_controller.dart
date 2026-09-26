// ============================================================================
// Liquid Glass 底栏的交互控制器
// ============================================================================
//
// 移植自 Kyant0/AndroidLiquidGlass 的 `DampedDragAnimation` 与
// KernelSU `FloatingBottomBar.kt` 的手势部分，并把它们从 Widget 里**抽离**出来。
//
// 【为什么单独成文件】
//
// 原实现把「几何计算 / 手势跟踪 / 弹簧动画 / 选中回调」全塞在
// `_MiuixLiquidGlassNavigationBarState` 里（1000+ 行）。职责混在一起导致：
//   - 想调手势参数得先读懂布局代码；
//   - 想改视觉又会碰到手势逻辑。
// 这里按**职责**切开：本文件只管「指示器在哪个位置、按得多深、手在哪」，
// 视觉与布局留在 Widget 里。
//
// 【三条核心行为（都与 Kyant0 对齐）】
//
// 1. **零延迟跟手**：`onPointerMove` 直接写 `position.value`，不经过任何补间动画。
//    这是「不许出现手指已移动、玻璃才慢半拍」那条要求的实现方式 ——
//    任何 `animateTo` 都会引入滞后。
//
// 2. **速度驱动的形变**：把相邻两次 move 的位移除以时间得到 `velocity`，
//    交给视觉层做 squash & stretch（横向拉伸、纵向微缩）。
//    速度做了**上限钳制**，避免甩动时形变夸张。
//
// 3. **松手回弹**：用 `SpringSimulation` 而不是 `CurvedAnimation`。
//    弹簧带 `velocity` 初值，所以快速甩动后会有真实的惯性过冲，
//    而不是从静止开始的匀减速。
//
// 【与 Widget 的边界】
//
//   控制器负责：指针跟踪、位置/按压的弹簧动画、选中索引的收敛
//   Widget 负责：宽度与 tab 宽度（来自 LayoutBuilder）、视觉绘制、RTL 方向
//   → 所以 `tabWidth` / `rtl` 由 Widget 在每帧通过 [syncGeometry] 告知。
// ============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// 弹簧参数（Kyant0 量级）
class LiquidGlassSprings {
  const LiquidGlassSprings._();

  /// 指示器位置回弹：偏软，允许轻微过冲
  static const position = SpringDescription(
    mass: 1.0,
    stiffness: 300.0,
    damping: 24.0,
  );

  /// 按下：更硬更快，给"立刻响应"的手感
  static const pressEnter = SpringDescription(
    mass: 1.0,
    stiffness: 420.0,
    damping: 28.0,
  );

  /// 抬起：略软，让液态感更自然
  static const pressExit = SpringDescription(
    mass: 1.0,
    stiffness: 280.0,
    damping: 22.0,
  );

  /// 显示 / 隐藏
  static const visibility = SpringDescription(
    mass: 1.0,
    stiffness: 300.0,
    damping: 24.0,
  );
}

/// 底栏交互控制器
///
/// 生命周期：由 Widget 的 `State` 创建并 `dispose`。
class LiquidGlassNavController {
  LiquidGlassNavController({
    required TickerProvider vsync,
    required this.itemCount,
    required int initialIndex,
    required bool visible,
    required this.onSelect,
    required this.onPointerStateChanged,
  })  : _index = initialIndex,
        position = AnimationController.unbounded(
          vsync: vsync,
          value: initialIndex.toDouble(),
        ),
        press = AnimationController.unbounded(vsync: vsync, value: 0.0),
        show = AnimationController.unbounded(
          vsync: vsync,
          value: visible ? 1.0 : 0.0,
        );

  /// 导航项数量
  int itemCount;

  /// 指示器的物理浮点位置（0.0 ~ itemCount-1.0）
  final AnimationController position;

  /// 按压进度（0.0 静止 ~ 1.0 完全按下）
  final AnimationController press;

  /// 显示进度（0.0 隐藏 ~ 1.0 显示）
  final AnimationController show;

  /// 选中项变化时回调（Widget 据此通知外部）
  final ValueChanged<int> onSelect;

  /// 指针按下 / 抬起时回调 —— Widget 用它触发 `setState` 重绘视觉层
  final VoidCallback onPointerStateChanged;

  int _index;
  int? _pointer;
  int _pressedIndex = -1;
  double _dragVelocity = 0.0;
  double _lastX = 0.0;
  int _lastTime = 0;

  /// 当前选中的索引
  int get index => _index;

  /// 当前被按住的项（-1 表示没有）
  int get pressedIndex => _pressedIndex;

  /// 当前拖动速度（已钳制），供视觉层做形变
  double get dragVelocity => _dragVelocity;

  /// 是否有手指按在底栏上
  bool get isDragging => _pointer != null;

  /// 布局相关的几何量，由 Widget 每帧同步
  double tabWidth = 0.0;
  bool rtl = false;

  /// 无动画（系统「移除动画」开启）时直接跳变
  bool disabledMotion = false;

  /// 指示器是否已按初始选中项就位（首帧后置位）
  bool positioned = false;

  Timer? _tapAnimTimer;
  bool _isAnimatingFromTap = false;

  /// 供 Widget 在页面滑动时判断是否要打断
  bool get isAnimatingFromTap => _isAnimatingFromTap;

  /// 用户在页面滑动时打断「点击底栏触发的动画」
  void cancelTapAnimation() {
    _tapAnimTimer?.cancel();
    _isAnimatingFromTap = false;
  }

  // ── 几何 ────────────────────────────────────────────────────────────────

  /// 由 Widget 在 `LayoutBuilder` 里同步
  void syncGeometry({required double tabWidth, required bool rtl}) {
    this.tabWidth = tabWidth;
    this.rtl = rtl;
  }

  /// 把全局坐标换算成底栏局部 x
  double localX(Offset global, RenderBox? box) {
    if (box == null) return 0.0;
    return box.globalToLocal(global).dx;
  }

  /// 局部 x 落在第几项
  int itemAt(double x) {
    if (tabWidth <= 0) return _index;
    final raw = ((x - 8) / tabWidth).floor().clamp(0, itemCount - 1);
    return rtl ? itemCount - 1 - raw : raw;
  }

  // ── 指针事件 ────────────────────────────────────────────────────────────

  void handlePointerDown({required int pointer, required double x}) {
    if (_pointer != null) return;
    _pointer = pointer;
    _lastX = x;
    _lastTime = DateTime.now().millisecondsSinceEpoch;
    _dragVelocity = 0.0;

    final item = itemAt(x);
    _pressedIndex = item;
    onPointerStateChanged();
    _animatePressTo(1.0);
    select(item);
  }

  void handlePointerMove({required int pointer, required double x}) {
    if (_pointer != pointer) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final dt = (now - _lastTime) / 1000.0;
    if (dt > 0.003) {
      // 除以 360 是经验系数：把 px/s 压到 -2.5~2.5 的可用于形变的区间
      _dragVelocity = ((x - _lastX) / dt / 360.0).clamp(-2.5, 2.5);
    }
    _lastTime = now;
    _lastX = x;

    if (tabWidth <= 0) return;

    // ★ 零延迟跟手：直接写 value，不做任何补间
    final logicalX = rtl ? _barWidth - 8 - x : x - 8;
    final floatTarget = (logicalX - tabWidth / 2) / tabWidth;
    position.value = floatTarget.clamp(-0.4, (itemCount - 1) + 0.4);

    final item = itemAt(x);
    if (item != _pressedIndex) {
      _pressedIndex = item;
      onPointerStateChanged();
      onSelect(item);
    }
  }

  void handlePointerUp(int pointer) {
    if (_pointer != pointer) return;
    _release();
  }

  /// 底栏总宽度（跟手换算需要）——由 Widget 同步
  double _barWidth = 0.0;
  set barWidth(double v) => _barWidth = v;

  // ── 选中 ────────────────────────────────────────────────────────────────

  /// 点击底栏（或外部要求切换）时调用
  void select(int index, {bool animate = true}) {
    _tapAnimTimer?.cancel();
    _isAnimatingFromTap = true;
    _tapAnimTimer = Timer(const Duration(milliseconds: 320), () {
      _isAnimatingFromTap = false;
    });
    if (animate) {
      _animatePositionTo(index.toDouble());
    } else {
      position.value = index.toDouble();
    }
    _index = index;
    onSelect(index);
  }

  /// 外部（页面滑动）驱动的位置更新 —— 直接跟，不做弹簧
  void syncFromPage(double page) {
    final clamped = page.clamp(0.0, (itemCount - 1).toDouble());
    position.value = clamped;
  }

  /// 外部选中项变化（非用户点击）时同步
  void updateSelectedIndex(int index) {
    _index = index;
  }

  void _release() {
    if (_pointer == null && _pressedIndex == -1) return;
    final targetIndex = position.value.round().clamp(0, itemCount - 1);
    _pointer = null;
    _pressedIndex = -1;
    _dragVelocity = 0.0;
    onPointerStateChanged();

    _animatePressTo(0.0);
    _animatePositionTo(targetIndex.toDouble());
    if (targetIndex != _index) {
      _index = targetIndex;
      onSelect(targetIndex);
    }
  }

  // ── 弹簧动画 ────────────────────────────────────────────────────────────

  /// 外部驱动的位置动画（如选中项被外部改变）
  void animatePositionTo(double target) => _animatePositionTo(target);

  void _animatePositionTo(double target) {
    if (disabledMotion) {
      position.value = target;
      return;
    }
    position.animateWith(
      SpringSimulation(
        LiquidGlassSprings.position,
        position.value,
        target,
        position.velocity,
      ),
    );
  }

  void _animatePressTo(double target) {
    if (disabledMotion) {
      press.value = target;
      return;
    }
    press.animateWith(
      SpringSimulation(
        target > 0.5
            ? LiquidGlassSprings.pressEnter
            : LiquidGlassSprings.pressExit,
        press.value,
        target,
        press.velocity,
      ),
    );
  }

  /// 显示 / 隐藏
  void setVisible(bool visible) {
    if (disabledMotion) {
      show.value = visible ? 1.0 : 0.0;
    } else {
      show.animateWith(
        SpringSimulation(
          LiquidGlassSprings.visibility,
          show.value,
          visible ? 1.0 : 0.0,
          show.velocity,
        ),
      );
    }
    if (!visible) {
      _pointer = null;
      _pressedIndex = -1;
      _dragVelocity = 0.0;
    }
  }

  /// 项数变化时重置手势状态
  void resetForItemCountChange() {
    positioned = false;
    _pointer = null;
    _pressedIndex = -1;
  }

  void dispose() {
    _tapAnimTimer?.cancel();
    position.dispose();
    press.dispose();
    show.dispose();
  }
}
