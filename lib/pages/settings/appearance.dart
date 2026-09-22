import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../setting/theme_setting.dart';

/// 「外观设置」页
///
/// 入口：设置 Tab → 外观设置。
///
/// 【历史】
/// 本页原先只有一个「悬浮底栏」开关（`NavBarSetting.floating`）。2026-09-22
/// 用户拍板「底部导航栏改为 miuix 标准样式，采用非悬浮的固定布局，删除现有的
/// 悬浮底栏实现」—— 那个开关随之作废，`setting/navbar_setting.dart` 已整体删除。
///
/// 现在换成真正属于「外观」的内容：**深浅色模式**（跟随系统 / 浅色 / 深色）。
/// 三态单选而不是一个开关 —— 因为「跟随系统」必须能选回来，
/// 二元开关表达不了三态。
class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: '外观设置',
        // ⚠️ `MiuixTopAppBar` **没有** `onBack` 参数（踩过：写 `onBack:` 直接编译不过）。
        // 返回键要自己塞进 `navigationIcon`。
        //
        // 不传 `blurRadius` / `blurTintAlpha` → 用库默认（24 / 0.55），
        // 与顶栏、底栏是同一套玻璃口径（见 `widget/miuix_glass_spec.dart`）。
        blurred: true,
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
          const MiuixSmallTitle('深浅色'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: MiuixCard(
              child: ValueListenableBuilder<ThemeMode>(
                valueListenable: ThemeSetting.mode,
                builder: (context, current, _) => Column(
                  children: [
                    for (final mode in ThemeMode.values)
                      MiuixRadioButtonPreference(
                        title: _labelOf(mode),
                        summary: _summaryOf(mode),
                        selected: current == mode,
                        onClick: () => ThemeSetting.setMode(mode),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
            child: MiuixText(
              '「跟随系统」会随手机的深色模式自动切换；选「浅色」或「深色」'
              '则固定不变。切换即时生效，无需重启。',
              style: MiuixTheme.of(context).textStyles.footnote1,
            ),
          ),
        ],
      ),
    );
  }

  static String _labelOf(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '跟随系统';
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
    }
  }

  static String _summaryOf(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '与手机的深色模式保持一致';
      case ThemeMode.light:
        return '始终使用浅色外观';
      case ThemeMode.dark:
        return '始终使用深色外观';
    }
  }
}
