import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import '../widget/miuix_glass_spec.dart';

import '../../setting/navbar_setting.dart';

/// 「外观设置」页
///
/// 用户要求「底栏加个按钮选择是否为悬浮底栏」，故把开关独立成一页，
/// 从账号页右上角菜单（`/accounts` 页的 `more_horiz`）进入。
///
/// 之所以不直接做成菜单里的一项：菜单项点一下就关，而用户切换后需要能
/// **立刻看到底栏变化**，留在页面上才方便反复对比两种形态。
///
/// [改动] 本页为 Miuix 迁移试点：整页改用 Miuix 组件
/// （`MiuixScaffold` + `MiuixSmallTitle` + `MiuixCard` + `MiuixSwitchPreference`），
/// 验证迁移模式后再推广到其余页面。
class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: '外观设置',
        // ⚠️ `MiuixTopAppBar` **没有** `onBack` 参数（踩过：写 `onBack:` 直接编译不过）。
        // 返回键要自己塞进 `navigationIcon`。
        blurred: true,
        // KernelSU `BlurredBar` 口径（见 ../widget/miuix_glass_spec.dart）：
        // blurRadius 25 → sigma 11.25、色调 surface @ .87 —— 磨砂到几乎实心，
        // 只透出一点点底纹（HyperOS 顶栏就是这个观感）。
        blurRadius: MiuixGlassSpec.topBarBlurRadius,
        blurTintAlpha: MiuixGlassSpec.topBarTintAlpha,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Icon(Icons.arrow_back_ios_new, size: 20),
        ),
      ),
      // ⚠️ `content` 是 `Widget Function(EdgeInsets)` 而**不是** `Widget`
      // （踩过：直接传 ListView 报 `argument_type_not_assignable`）。
      // 脚手架把算好的内边距交给你，由内容自行贴到根部。
      content: (contentPadding) => ListView(
        padding: contentPadding,
        children: [
          const MiuixSmallTitle('底栏样式'),
          // 用 ValueListenableBuilder 直接监听全局设置：
          // 切换后底栏立刻重绘（底栏本身也监听了同一个 notifier）
          ValueListenableBuilder<bool>(
            valueListenable: NavBarSetting.floating,
            builder: (context, floating, _) {
              return MiuixSwitchPreference(
                value: floating,
                onChanged: (v) => NavBarSetting.setFloating(v),
                title: '悬浮底栏',
                summary: floating
                    ? '胶囊圆角 + 阴影，与屏幕底边留有间距'
                    : '通栏贴底，顶部带分隔线',
                startAction: Icon(
                  floating ? Icons.rounded_corner : Icons.crop_16_9,
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
            child: MiuixText(
              '关闭后底栏会贴住屏幕底边，视觉上更紧凑；'
              '开启则更接近悬浮胶囊的观感。切换即时生效，无需重启。',
              style: MiuixTheme.of(context).textStyles.footnote1,
            ),
          ),
        ],
      ),
    );
  }
}
