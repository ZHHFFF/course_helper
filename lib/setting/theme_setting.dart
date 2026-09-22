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

  /// 当前深浅色模式。默认 `system`（跟随系统），与迁移前行为一致。
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.system);

  static bool _loaded = false;

  /// 读取持久化设置（幂等）
  ///
  /// 必须在首帧前调用，否则启动瞬间会先用默认值渲染一帧、读到配置后再跳变
  /// （深色用户会看到一次白闪）。
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      mode.value = _decode(StorageManager.prefs.getString(_keyMode));
      _loaded = true;
    } catch (e) {
      // 用 AppLogger 而不是 debugPrint —— debugPrint 不进日志文件，
      // 用户导出日志排查时完全看不到（这个坑项目里踩过）。
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
