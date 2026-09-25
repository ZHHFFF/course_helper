import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../setting/theme_setting.dart';

/// 「主題設定」頁
///
/// 1:1 对齐用户参考视觉与功能设计：
/// 1. 主題：選擇應用程式的主題模式（跟隨系統 / 淺色 / 深色）
/// 2. 模糊：啟用頂欄和底欄的模糊效果
/// 3. 懸浮底欄：使用類 Apple 風格的懸浮底欄
/// 4. 液態玻璃：啟用懸浮底欄的液態玻璃效果
/// 5. 預測性返回手勢：啟用對預測性返回手勢的支援
/// 6. 介面縮放：調整全域顯示比例 (80% ~ 120%)
class AppearanceSettingsPage extends StatefulWidget {
  const AppearanceSettingsPage({super.key});

  @override
  State<AppearanceSettingsPage> createState() => _AppearanceSettingsPageState();
}

class _AppearanceSettingsPageState extends State<AppearanceSettingsPage> {
  late final MiuixExitUntilCollapsedScrollBehavior _topBarBehavior =
      miuixScrollBehavior();
  double _topBarInset = 0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeSetting.blurEnabled,
      builder: (context, blurEnabled, _) {
        return MiuixScaffold(
          topBar: MiuixTopAppBar(
            title: '主題設定',
            largeTitle: '主題設定',
            blurred: blurEnabled,
            scrollBehavior: _topBarBehavior,
            navigationIcon: MiuixIconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Icon(Icons.arrow_back_ios_new, size: 20),
            ),
          ),
          content: (contentPadding) {
            if (contentPadding.top > _topBarInset) {
              _topBarInset = contentPadding.top;
            }
            return MiuixScrollBehaviorListener(
              behavior: _topBarBehavior,
              child: ListView(
                padding: EdgeInsets.only(
                  top: _topBarInset,
                  bottom: contentPadding.bottom + 24,
                ),
                children: [
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: MiuixCard(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 1. 主題
                          ValueListenableBuilder<ThemeMode>(
                            valueListenable: ThemeSetting.mode,
                            builder: (context, mode, _) {
                              final selectedIndex = switch (mode) {
                                ThemeMode.system => 0,
                                ThemeMode.light => 1,
                                ThemeMode.dark => 2,
                              };
                              return MiuixOverlayDropdownPreference(
                                title: '主題',
                                summary: '選擇應用程式的主題模式',
                                items: const ['跟隨系統', '淺色', '深色'],
                                selectedIndex: selectedIndex,
                                onSelectedIndexChange: (index) {
                                  final newMode = [
                                    ThemeMode.system,
                                    ThemeMode.light,
                                    ThemeMode.dark,
                                  ][index];
                                  ThemeSetting.setMode(newMode);
                                },
                              );
                            },
                          ),

                          // 2. 模糊
                          MiuixSwitchPreference(
                            title: '模糊',
                            summary: '啟用頂欄和底欄的模糊效果',
                            value: blurEnabled,
                            onChanged: (v) => ThemeSetting.setBlurEnabled(v),
                          ),

                          // 3. 懸浮底欄
                          ValueListenableBuilder<bool>(
                            valueListenable: ThemeSetting.floatingNavBar,
                            builder: (context, floating, _) =>
                                MiuixSwitchPreference(
                              title: '懸浮底欄',
                              summary: '使用類 Apple 風格的懸浮底欄',
                              value: floating,
                              onChanged: (v) =>
                                  ThemeSetting.setFloatingNavBar(v),
                            ),
                          ),

                          // 4. 液態玻璃
                          ValueListenableBuilder<bool>(
                            valueListenable: ThemeSetting.floatingNavBar,
                            builder: (context, floating, _) {
                              return ValueListenableBuilder<bool>(
                                valueListenable: ThemeSetting.liquidGlass,
                                builder: (context, liquidGlass, _) =>
                                    MiuixSwitchPreference(
                                  title: '液態玻璃',
                                  summary: '啟用懸浮底欄的液態玻璃效果',
                                  value: liquidGlass,
                                  enabled: floating,
                                  onChanged: (v) =>
                                      ThemeSetting.setLiquidGlass(v),
                                ),
                              );
                            },
                          ),

                          // 5. 預測性返回手勢
                          ValueListenableBuilder<bool>(
                            valueListenable: ThemeSetting.predictiveBack,
                            builder: (context, predictive, _) =>
                                MiuixSwitchPreference(
                              title: '預測性返回手勢',
                              summary: '啟用對預測性返回手勢的支援',
                              value: predictive,
                              onChanged: (v) =>
                                  ThemeSetting.setPredictiveBack(v),
                            ),
                          ),

                          // 6. 介面縮放
                          ValueListenableBuilder<double>(
                            valueListenable: ThemeSetting.uiScale,
                            builder: (context, scale, _) =>
                                MiuixSliderPreference(
                              title: '介面縮放',
                              summary: '調整全域顯示比例',
                              value: scale,
                              min: 0.8,
                              max: 1.2,
                              steps: 4,
                              showKeyPoints: true,
                              keyPoints: const [0.8, 0.9, 1.0, 1.1, 1.2],
                              valueText: '${(scale * 100).round()}%',
                              onClick: () {},
                              onValueChange: (v) {
                                final snapped =
                                    (v * 10).round() / 10.0;
                                ThemeSetting.setUiScale(snapped);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
