import 'package:flutter/material.dart';

/// Miuix 顶栏动作按钮的「纯视觉」版本。
///
/// ## 为什么不能用 `MiuixIconButton`
///
/// `MiuixIconButton` 内部是 `MiuixPressable`，**自带手势识别器**。
/// 把它塞进 `PopupMenuButton(child: ...)` 时会出现手势竞技场争抢：
///
/// * `PopupMenuButton` 在 `child` 外又包了一层 `InkWell`（见 Flutter 源码
///   `material/popup_menu.dart` 的 `buildChild`）；
/// * Flutter 的手势竞技场在 sweep 时，**选择最先被加入的成员**；
/// * 而 `addPointer` 的调用顺序 = 命中测试顺序 = **由内向外**。
///
/// 于是内层的 `MiuixPressable` 先入竞技场并获胜，`MiuixIconButton.onPressed`
/// 会照常触发，而外层 `InkWell` 永远收不到 tap —— **菜单弹不出来**。
///
/// 结论：当动作按钮的点击要交给外层（如 `PopupMenuButton`）时，只能用这个
/// 只复刻外观、不接管手势的版本。
///
/// ## 尺寸口径
///
/// 与 `MiuixIconButton` 保持一致：最小 40×40 + 内容居中。
/// `Center` 必须带 `widthFactor/heightFactor = 1`，否则在有界宽松约束下会
/// 撑满可用宽度，把顶栏的 actions 测量层算成整屏宽（Miuix 源码里专门为
/// 这个坑写了注释）。
class MiuixActionTrigger extends StatelessWidget {
  const MiuixActionTrigger({super.key, required this.icon});

  /// 图标本身（尺寸 / 颜色由调用方决定，默认吃环境 `IconTheme`）。
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      child: Center(widthFactor: 1, heightFactor: 1, child: icon),
    );
  }
}
