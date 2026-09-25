import 'package:flutter/material.dart';

import '../utils/app_logger.dart';
import '../utils/storage.dart';

/// 深浅色外观设置
///
/// 用户 2026-09-22 要求「设置页所有按钮重写」，其中「外观设置」这一项原先
/// 只有一个「悬浮底栏」开关 —— 而底栏已拍板改成固定的贴边 Miuix 标准样式，
/// 那个开关随之作废。本文件给它换上真正属于「外观」的内容：**深浅色模式**。
///
/// 写法与 [AutoAnswerSetting] / 旧的 `NavBarSetting` 保持一致：静态
/// `ValueNotifier` 持有当前值，便于 `ValueListenableBuilder` 直接监听；
/// 落盘走 `StorageManager.prefs`。
///
/// ⚠️ `MyApp` 用 `ValueListenableBuilder` 包住 `MaterialApp` 来响应变化 ——
/// `themeMode` 是 `MaterialApp` 的构造参数，不重建它就切不动。
class ThemeSetting {
  ThemeSetting._();

  static const _keyMode = 'theme_mode';
  static const _keyBlurEnabled = 'theme_blur_enabled';
  static const _keyFloatingNavBar = 'theme_floating_nav_bar';
  static const _keyLiquidGlass = 'theme_liquid_glass';
  static const _keyPredictiveBack = 'theme_predictive_back';
  static const _keyUiScale = 'theme_ui_scale';

  /// 当前深浅色模式。默认 `system`（跟随系统）
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.system);

  /// 模糊效果开关。默认开启 (true)
  static final ValueNotifier<bool> blurEnabled =
      ValueNotifier<bool>(true);

  /// 悬浮底栏开关。默认关闭 (false，保持传统 Miuix 底栏)，开启后切换为悬浮胶囊底栏
  static final ValueNotifier<bool> floatingNavBar =
      ValueNotifier<bool>(false);

  /// 液态玻璃效果开关。默认开启 (true)，在悬浮底栏开启时生效
  static final ValueNotifier<bool> liquidGlass =
      ValueNotifier<bool>(true);

  /// 预测性返回手势开关。默认开启 (true)
  static final ValueNotifier<bool> predictiveBack =
      ValueNotifier<bool>(true);

  /// 界面全局缩放比例 (0.8 ~ 1.2)。默认 1.0 (100%)
  static final ValueNotifier<double> uiScale =
      ValueNotifier<double>(1.0);

  static bool _loaded = false;

  /// 读取持久化设置（幂等）
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      mode.value = _decode(StorageManager.prefs.getString(_keyMode));
      blurEnabled.value = StorageManager.prefs.getBool(_keyBlurEnabled) ?? true;
      floatingNavBar.value = StorageManager.prefs.getBool(_keyFloatingNavBar) ?? false;
      liquidGlass.value = StorageManager.prefs.getBool(_keyLiquidGlass) ?? true;
      predictiveBack.value = StorageManager.prefs.getBool(_keyPredictiveBack) ?? true;
      final savedScale = StorageManager.prefs.getDouble(_keyUiScale) ?? 1.0;
      uiScale.value = savedScale.clamp(0.8, 1.2);
      _loaded = true;
    } catch (e) {
      AppLogger.w('外观设置', '读取外观设置失败：$e');
    }
  }

  static Future<void> setMode(ThemeMode value) async {
    mode.value = value;
    try {
      await StorageManager.prefs.setString(_keyMode, value.name);
    } catch (e) {
      AppLogger.w('外观设置', '保存外观设置失败：$e');
    }
  }

  static Future<void> setBlurEnabled(bool value) async {
    blurEnabled.value = value;
    try {
      await StorageManager.prefs.setBool(_keyBlurEnabled, value);
    } catch (e) {
      AppLogger.w('外观设置', '保存模糊设置失败：$e');
    }
  }

  static Future<void> setFloatingNavBar(bool value) async {
    floatingNavBar.value = value;
    try {
      await StorageManager.prefs.setBool(_keyFloatingNavBar, value);
    } catch (e) {
      AppLogger.w('外观设置', '保存悬浮底栏设置失败：$e');
    }
  }

  static Future<void> setLiquidGlass(bool value) async {
    liquidGlass.value = value;
    try {
      await StorageManager.prefs.setBool(_keyLiquidGlass, value);
    } catch (e) {
      AppLogger.w('外观设置', '保存液态玻璃设置失败：$e');
    }
  }

  static Future<void> setPredictiveBack(bool value) async {
    predictiveBack.value = value;
    try {
      await StorageManager.prefs.setBool(_keyPredictiveBack, value);
    } catch (e) {
      AppLogger.w('外观设置', '保存预测性返回设置失败：$e');
    }
  }

  static Future<void> setUiScale(double value) async {
    final clamped = value.clamp(0.8, 1.2);
    uiScale.value = clamped;
    try {
      await StorageManager.prefs.setDouble(_keyUiScale, clamped);
    } catch (e) {
      AppLogger.w('外观设置', '保存界面缩放设置失败：$e');
    }
  }

  /// `ThemeMode.name` ↔ 枚举。存名字而不是 index —— index 会随枚举顺序变化。
  static ThemeMode _decode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }
}
