// ============================================================================
// Miuix 玻璃底栏的几何契约
// ============================================================================
//
// 底栏本体是 `widget/miuix_liquid_glass_nav_bar.dart`
// （`BackdropFilter` 版液态玻璃底栏，v4.8.6 起；之前是包里的
// `MiuixGlassNavigationBar` + `MiuixLayerBackdropCapture` 那套快照采样），
// 由 `main.dart` 用 `Stack` + `Positioned` **悬浮叠加**在页面之上，
// **不占** Scaffold 的 `bottomNavigationBar` 槽位。
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
// 历史：这些常量原先住在 `widget/liquid_glass_nav_bar.dart` 里，与自研玻璃底栏
// （`GlassNavBar` / 4 方案预览页 / `shaders/liquid_glass.frag`）混在一个 1378 行的
// 文件里。那套自研组件整体删除后，只剩这几个仍被引用的几何常量，抽出来单独成文件。
// ============================================================================

import 'package:flutter/widgets.dart';

import '../../setting/navbar_setting.dart';

/// 底栏**内容区**的高度（不含底部抬起与系统安全区）。
///
/// 实测同为一加 13 上的 LSPosed 管理器（也是一个 Miuix 应用，最权威的参照物），
/// 其底栏胶囊 `[86,2458][1178,2682]` → 高 224px ÷ 3.5 = **64.0dp**。
///
/// ⚠️ `main.dart` 以 `_kNavBarHeight` 把它传给
/// `MiuixLiquidGlassNavigationBar(height:)`。Miuix 库里对应的默认值是 `54.0`
/// （不一致，故显式传），**两处必须同步改**，否则「底栏实际高度」与「页面留白」
/// 会各说各话。
const double miuixNavBarContentHeight = 64;

/// 底栏离「手势条安全区上沿」的额外抬起距离（不含系统安全区）。
///
/// 参照物底栏胶囊离屏底 98px = 28dp，其中 56px = 16dp 是手势条安全区，
/// 故额外抬起 = 28 - 16 = **12dp**。`main.dart` 里对应 `_kNavBottomGap`。
const double miuixNavBarLift = 12;

/// 悬浮底栏**自身**占用的高度（不含系统安全区）：抬起 12 + 内容高 64 = **76**。
///
/// 用于给全局 `MediaQuery.padding.bottom` 加值（main.dart 的 `_GlassNavInsets`）。
///
/// ⚠️⚠️ **只加 `padding.bottom`，绝不要同时加 `viewPadding.bottom`**（踩过大坑）。
/// `viewPadding` 既是全局 `SafeArea` 的依据，也是 `main.dart` 算「底栏离屏底距离」
/// 的依据；一旦在这里把它撑大，底栏会被整体顶高 —— 历史 bug 就是底栏悬空 104dp。
const double miuixNavBarOccupiedHeight =
    miuixNavBarLift + miuixNavBarContentHeight;

/// 底栏「顶边」距屏幕底边的距离（含系统安全区）。
///
/// 这是页面留白与 FAB 抬高的唯一基准 —— 只要求出底栏顶边在哪，再往上叠余量即可，
/// 不必去猜组件内部的 padding。
///
/// 几何（一加 13 / Android 15 / density 3.5）：
/// - 安全区 `navigationBars frame=[0,2724][1264,2780]` → 56px = **16dp**
/// - 悬浮：安全区 16 + 抬起 12 + 栏高 64 = **92dp**
/// - 贴边：安全区 16 + 栏高 64 = **80dp**
///   （栏下那 16dp 安全区由 `main.dart` 用 surface 纯色补上，不留透明缝）
///
/// 悬浮 / 贴边两态高度不同，所以这里读全局 [NavBarSetting.floating]，
/// 与底栏渲染用同一个来源，保证「底栏换了形态但页面留白没跟上」不会发生。
///
/// ⚠️ 必须用 `viewPaddingOf` 而不是 `MediaQuery.of().padding`：
/// 上层 `_GlassNavInsets` 为了给 SnackBar 让位，已经把 `padding.bottom` 撑大了
/// `miuixNavBarOccupiedHeight`（76dp）。若这里用 `padding`，会**再加一遍 76**，
/// 留白直接虚胖到两倍多 —— 这正是「列表滚到底空一大截」的成因。
/// （教训：验证滚动留白务必**滚到底再截图**，否则看到的是中间状态，会误判成没生效。）
double miuixNavBarOccupied(BuildContext context) {
  final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
  return NavBarSetting.floating.value
      ? safeBottom + miuixNavBarLift + miuixNavBarContentHeight
      : safeBottom + miuixNavBarContentHeight;
}

/// 页面滚动列表底部需要预留的留白高度（= 底栏占位 + 16dp 呼吸间距）。
///
/// 提示：能塞进 `MiuixScaffold.bottomBar` 的页面优先用 [miuixNavBarOccupied] ——
/// 脚手架会把 `contentPadding.bottom` 与 FAB 抬高一起算好，只有一个数据来源；
/// 本函数是给「不方便用脚手架槽位」的页面兜底（例如自定义 `Stack` 布局）。
double miuixNavBarClearance(BuildContext context) =>
    miuixNavBarOccupied(context) + 16;
