// ============================================================================
// Miuix 底部导航栏 Tab 点击液态微弹交互组件
// ============================================================================
//
// 复原之前版本点击时的轻微缩放 + 弹性回弹（Spring Simulation）物理触感：
// - 点击时轻微下沉（scale 0.92）并迅速随弹性曲线回弹至 1.0；
// - 纯局部微动效，不引入卡顿的全屏滑动手势页面切换；
// - 完美契合 Miuix 贴边固定模糊底栏。
// ============================================================================

import 'package:flutter/material.dart';

class MiuixTabBounce extends StatefulWidget {
  final Widget child;
  final bool selected;

  const MiuixTabBounce({
    super.key,
    required this.child,
    required this.selected,
  });

  @override
  State<MiuixTabBounce> createState() => _MiuixTabBounceState();
}

class _MiuixTabBounceState extends State<MiuixTabBounce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.92)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.92, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 65,
      ),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(covariant MiuixTabBounce oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从未选中变为选中时触发弹簧微动
    if (!oldWidget.selected && widget.selected) {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: widget.child,
    );
  }
}
