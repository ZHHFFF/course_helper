import 'package:flutter/foundation.dart';

import '../utils/storage.dart';

/// 底栏外观设置
///
/// 用户需求原文：「底栏加个按钮选择是否为悬浮底栏」。
///
/// Miuix 提供了两种底部导航栏形态，这里就是在这两者之间切换：
/// - 悬浮（[floating] = true）→ `MiuixFloatingNavigationBar`
///   胶囊圆角（cornerRadius 默认 50）+ 阴影，离屏幕底边有一段距离。
/// - 贴边（[floating] = false）→ `MiuixNavigationBar`
///   通栏贴底，自带底部安全区内边距，顶部有一条分隔线。
///
/// 写法与 [AutoAnswerSetting] 保持一致：静态 `ValueNotifier` 持有当前值，
/// 便于 `ValueListenableBuilder` 直接监听；落盘走 `StorageManager.prefs`。
class NavBarSetting {
  NavBarSetting._();

  static const _keyFloating = 'navbar_floating';

  /// 是否使用悬浮底栏。默认 `true`，与迁移前自研悬浮底栏的观感一致。
  static final ValueNotifier<bool> floating = ValueNotifier<bool>(true);

  static bool _loaded = false;

  /// 读取持久化设置（幂等）
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      floating.value = StorageManager.prefs.getBool(_keyFloating) ?? true;
      _loaded = true;
    } catch (e) {
      debugPrint('读取底栏设置失败：$e');
    }
  }

  static Future<void> setFloating(bool v) async {
    floating.value = v;
    await _safe(() => StorageManager.prefs.setBool(_keyFloating, v));
  }

  static Future<void> _safe(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      debugPrint('保存底栏设置失败：$e');
    }
  }
}
