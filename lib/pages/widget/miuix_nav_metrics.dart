// ============================================================================
// Miuix 玻璃底栏的几何契约
// ============================================================================
//
// 底栏本体是 `widget/miuix_glass_navigation_bar.dart`（Miuix 标准底栏 +
// `BackdropFilter` 玻璃），由 `main.dart` 用 `Stack` + `Positioned(bottom: 0)`
// **贴边叠加**在页面之上，**不占** Scaffold 的 `bottomNavigationBar` 槽位。
// 于是「底栏到底占掉多少高度」就成了一个必须跨文件共享的数据 —— 就是本文件。
//
// 依赖它的地方：
//   1. 页面滚动内容底部留白（避免最后一项被盖）        → miuixNavBarClearance
//   2. 页面把占位塞进 `MiuixScaffold.bottomBar`（透明 SizedBox）：
//      脚手架会自动把 `contentPadding.bottom` 与 FAB 抬高一起算好
//                                                      → miuixNavBarOccupied
//   3. 全局 `MediaQuery.padding.bottom` 注入，让 SnackBar / BottomSheet
//      自动抬到底栏之上（main.dart 的 `_GlassNavInsets`）
//                                                      → miuixNavBarOccupiedHeight
//
// 历史：2026-09-22 之前底栏是**悬浮**的（左右 24 / 离底 12+安全区），
// 高度随「悬浮 / 贴边」两态变化，所以这里要读 `NavBarSetting.floating` 分叉。
// 用户已拍板「采用非悬浮的固定布局」，两态合一，分叉与本文件里的
// `miuixNavBarLift` 一并删除。
// ============================================================================

import 'package:flutter/widgets.dart';

/// 底栏**内容区**的高度（不含系统安全区）。
///
/// 实测同为一加 13 上的 LSPosed 管理器（也是一个 Miuix 应用，最权威的参照物），
/// 其底栏胶囊 `[86,2458][1178,2682]` → 高 224px ÷ 3.5 = **64.0dp**。
///
/// 与包里的 `MiuixNavigationBarDefaults.itemHeight = 64` 正好一致 ——
/// 所以现在不需要再往组件里显式传高度，`MiuixNavigationBar` 自己就是这个值。
/// 本常量只用来算「底栏占掉多少高度」，供页面留白使用。
const double miuixNavBarContentHeight = 64;

/// 底栏**自身**占用的高度（不含系统安全区）= 内容高 64。
///
/// 用于给全局 `MediaQuery.padding.bottom` 加值（main.dart 的 `_GlassNavInsets`）。
///
/// ⚠️⚠️ **只加 `padding.bottom`，绝不要同时加 `viewPadding.bottom`**（踩过大坑）。
/// `viewPadding` 既是全局 `SafeArea` 的依据，也是底栏自己算手势区占位高度的依据
/// （`MiuixNavigationBar` 内部读 `MediaQuery.viewPaddingOf(context).bottom`）；
/// 一旦在这里把它撑大，底栏底部会多出一大截空白。历史 bug 就是底栏悬空 104dp。
const double miuixNavBarOccupiedHeight = miuixNavBarContentHeight;

/// 底栏「顶边」距屏幕底边的距离（含系统安全区）= 安全区 16 + 栏高 64 = **80dp**。
///
/// 这是页面留白与 FAB 抬高的唯一基准 —— 只要求出底栏顶边在哪，再往上叠余量即可，
/// 不必去猜组件内部的 padding。
///
/// 几何（一加 13 / Android 15 / density 3.5）：
/// - 安全区 `navigationBars frame=[0,2724][1264,2780]` → 56px = **16dp**
/// - 底栏顶边 = 2780 - 56 - 224 = 2500px → 离屏底 280px = **80dp**
/// - 那 16dp 安全区**由底栏自己的玻璃铺满**（`MiuixNavigationBar` 自带的
///   bottomInset 占位也在它的 `ColoredBox` 之内），不再需要页面补色块。
///
/// ⚠️ 必须用 `viewPaddingOf` 而不是 `MediaQuery.of().padding`：
/// 上层 `_GlassNavInsets` 为了给 SnackBar 让位，已经把 `padding.bottom` 撑大了
/// `miuixNavBarOccupiedHeight`（64dp）。若这里用 `padding`，会**再加一遍 64**，
/// 留白直接虚胖到两倍多 —— 这正是「列表滚到底空一大截」的成因。
/// （教训：验证滚动留白务必**滚到底再截图**，否则看到的是中间状态，会误判成没生效。）
double miuixNavBarOccupied(BuildContext context) {
  final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
  return safeBottom + miuixNavBarContentHeight;
}

/// 页面滚动列表底部需要预留的留白高度（= 底栏占位 + 16dp 呼吸间距）。
///
/// 提示：能塞进 `MiuixScaffold.bottomBar` 的页面优先用 [miuixNavBarOccupied] ——
/// 脚手架会把 `contentPadding.bottom` 与 FAB 抬高一起算好，只有一个数据来源；
/// 本函数是给「不方便用脚手架槽位」的页面兜底（例如自定义 `Stack` 布局）。
double miuixNavBarClearance(BuildContext context) =>
    miuixNavBarOccupied(context) + 16;
