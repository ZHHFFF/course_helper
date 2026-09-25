// ============================================================================
// 统一底栏宿主（NavigationBarHost）
// ============================================================================
//
// 职责：
// 1. 严格解耦并统一管理两套底栏方案：
//    - 方案 1：传统 Miuix 风格底栏 (MiuixBlurNavigationBar)
//    - 方案 2：Liquid Glass 风格底栏 (MiuixLiquidGlassNavigationBar)
//    - 方案 3：标准 Miuix 悬浮胶囊底栏 (_FloatingMiuixCapsuleBar)
// 2. 响应 [ThemeSetting] 中外观设置的动态切换：
//    - `floatingNavBar`: 是否使用悬浮底栏（false: 传统 Miuix 贴边底栏；true: 悬浮胶囊底栏）
//    - `liquidGlass`: 悬浮底栏下是否启用液态玻璃效果（true: BackdropFilter + 双层采样 + 高光描边 + 弹簧阻尼拖拽；false: 标准 Miuix 悬浮胶囊）
//    - `blurEnabled`: 是否开启模糊（false 时降级为不模糊的半透明/纯色底色）
//    - `uiScale`: 配合全局界面缩放，动态缩放悬浮底栏边距与尺寸
// 3. 提供统一的 Tab 切换接口，联动 PageView 与页面状态。
// ============================================================================

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../setting/theme_setting.dart';
import 'miuix_blur_navigation_bar.dart';
import 'miuix_glass_spec.dart';
import 'miuix_liquid_glass_nav_bar.dart';
import 'miuix_nav_metrics.dart';

/// 导航项数据模型
class NavigationDestinationData {
  const NavigationDestinationData({
    required this.activeIcon,
    required this.inactiveIcon,
    required this.label,
  });

  final IconData activeIcon;
  final IconData inactiveIcon;
  final String label;
}

const List<NavigationDestinationData> kDefaultNavigationDestinations = [
  NavigationDestinationData(
    activeIcon: Icons.school,
    inactiveIcon: Icons.school_outlined,
    label: '课程',
  ),
  NavigationDestinationData(
    activeIcon: Icons.account_circle,
    inactiveIcon: Icons.account_circle_outlined,
    label: '账号',
  ),
  NavigationDestinationData(
    activeIcon: Icons.folder_copy,
    inactiveIcon: Icons.folder_copy_outlined,
    label: '课件',
  ),
  NavigationDestinationData(
    activeIcon: Icons.settings,
    inactiveIcon: Icons.settings_outlined,
    label: '设置',
  ),
];

class NavigationBarHost extends StatelessWidget {
  const NavigationBarHost({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    this.pageController,
    this.destinations = kDefaultNavigationDestinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final PageController? pageController;
  final List<NavigationDestinationData> destinations;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeSetting.floatingNavBar,
      builder: (context, floating, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: ThemeSetting.liquidGlass,
          builder: (context, liquid, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: ThemeSetting.blurEnabled,
              builder: (context, blur, _) {
                return ValueListenableBuilder<double>(
                  valueListenable: ThemeSetting.uiScale,
                  builder: (context, scale, _) {
                    return _buildHost(
                      context,
                      floating: floating,
                      liquidGlass: liquid,
                      blurEnabled: blur,
                      uiScale: scale,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildHost(
    BuildContext context, {
    required bool floating,
    required bool liquidGlass,
    required bool blurEnabled,
    required double uiScale,
  }) {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;

    if (!floating) {
      // ── 方案 1：传统 Miuix 风格底栏（贴边、通栏、直角）────────────────
      return MiuixBlurNavigationBar(
        blurRadius: blurEnabled ? MiuixGlassSpec.barBlurRadius : 0,
        blurTintAlpha: blurEnabled ? MiuixGlassSpec.barTintAlpha : 1.0,
        children: [
          for (var i = 0; i < destinations.length; i++)
            MiuixNavigationBarItem(
              icon: Icon(
                selectedIndex == i
                    ? destinations[i].activeIcon
                    : destinations[i].inactiveIcon,
              ),
              label: destinations[i].label,
              selected: selectedIndex == i,
              onPressed: () => onSelect(i),
            ),
        ],
      );
    }

    // ── 方案 2：悬浮底栏（类 Apple / KernelSU 悬浮胶囊）────────────────
    final sideMargin = (28.0 * uiScale).clamp(16.0, 48.0);
    final bottomMargin = safeBottom > 0 ? safeBottom + 8.0 : 16.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(sideMargin, 0, sideMargin, bottomMargin),
      child: liquidGlass
          ? _buildLiquidGlassBar(context, blurEnabled: blurEnabled)
          : _buildStandardFloatingCapsule(context, blurEnabled: blurEnabled),
    );
  }

  /// 液态玻璃底栏（完整移植 Kyant0/AndroidLiquidGlass 与 KernelSU 交互实现）
  Widget _buildLiquidGlassBar(BuildContext context, {required bool blurEnabled}) {
    return MiuixLiquidGlassNavigationBar(
      items: [
        for (var i = 0; i < destinations.length; i++)
          MiuixLiquidGlassNavItem(
            icon: Icon(
              selectedIndex == i
                  ? destinations[i].activeIcon
                  : destinations[i].inactiveIcon,
            ),
            label: destinations[i].label,
            contentDescription: destinations[i].label,
          ),
      ],
      selectedIndex: selectedIndex,
      onSelect: onSelect,
      height: miuixNavBarContentHeight,
      bottomPadding: 0,
      pageController: pageController,
      blurRadius: blurEnabled ? 20 : 0,
      shape: const MiuixGlassShape(cornerRadius: 999),
      shadow: MiuixGlassShadows.floating,
    );
  }

  /// 标准 Miuix 悬浮胶囊底栏（无液态折射与双层玻璃指示器，纯正 Miuix 质感）
  Widget _buildStandardFloatingCapsule(
    BuildContext context, {
    required bool blurEnabled,
  }) {
    final colors = MiuixTheme.of(context).colors;
    final borderRadius = BorderRadius.circular(999);
    final bg = colors.surface.withValues(
      alpha: blurEnabled ? MiuixGlassSpec.barTintAlpha : 1.0,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: blurEnabled
            ? BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: ColoredBox(
                  color: bg,
                  child: _buildCapsuleContent(context),
                ),
              )
            : ColoredBox(
                color: bg,
                child: _buildCapsuleContent(context),
              ),
      ),
    );
  }

  Widget _buildCapsuleContent(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return SizedBox(
      height: miuixNavBarContentHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            for (var i = 0; i < destinations.length; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        selectedIndex == i
                            ? destinations[i].activeIcon
                            : destinations[i].inactiveIcon,
                        color: selectedIndex == i
                            ? colors.primary
                            : colors.onSurfaceContainer.withValues(alpha: 0.5),
                        size: 24,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        destinations[i].label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: selectedIndex == i
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: selectedIndex == i
                              ? colors.primary
                              : colors.onSurfaceContainer.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
