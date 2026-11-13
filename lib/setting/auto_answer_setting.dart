import 'package:flutter/foundation.dart';

import '../utils/storage.dart';

/// 自动答题设置
///
/// 三个开关是**递进**的，可以单独开：
/// - [autoSearch]：进课堂后自动把整份 PPT 的题都丢给 AI 检索（后台跑，不影响看课件）
/// - [autoSelect]：答案到手就自动填进作答区（不提交，你能看到填了什么）
/// - [autoSubmit]：老师发布题目后自动交卷
///
/// 只开 [autoSearch] = 纯预搜，答案摆在那儿等你点；
/// 三个全开 = 完整自动化。
class AutoAnswerSetting {
  AutoAnswerSetting._();

  static const _keyAutoSearch = 'aa_auto_search';
  static const _keyAutoSelect = 'aa_auto_select';
  static const _keyAutoSubmit = 'aa_auto_submit';

  /// Fixed default also applies to upgrades with legacy delay values saved.
  static const defaultSubmitDelayMs = 2000;

  /// 进课堂后自动检索整份 PPT 的题目
  ///
  /// 默认开。这一步只是「提前把答案准备好」，不碰作答区、不提交。
  static final ValueNotifier<bool> autoSearch = ValueNotifier<bool>(true);

  /// 答案到手后自动填进作答区
  ///
  /// 默认开。填完你还能看到选了哪个，[autoSubmit] 关着的话可以自己核对。
  static final ValueNotifier<bool> autoSelect = ValueNotifier<bool>(true);

  /// 老师发布题目后自动提交
  ///
  /// 默认开。答案准备好后等待固定 2 秒，再提交。
  static final ValueNotifier<bool> autoSubmit = ValueNotifier<bool>(true);

  /// 提交等待时间（毫秒）。上下限一致，默认固定为 2 秒。
  static final ValueNotifier<int> delayMinMs = ValueNotifier<int>(
    defaultSubmitDelayMs,
  );
  static final ValueNotifier<int> delayMaxMs = ValueNotifier<int>(
    defaultSubmitDelayMs,
  );

  static bool _loaded = false;

  /// 读取持久化设置（幂等）
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final p = StorageManager.prefs;
      autoSearch.value = p.getBool(_keyAutoSearch) ?? true;
      autoSelect.value = p.getBool(_keyAutoSelect) ?? true;
      autoSubmit.value = p.getBool(_keyAutoSubmit) ?? true;
      // No delay editor exists. Ignore legacy persisted ranges so an existing
      // installation also adopts the requested fixed two-second delay.
      delayMinMs.value = defaultSubmitDelayMs;
      delayMaxMs.value = defaultSubmitDelayMs;
      _loaded = true;
    } catch (e) {
      debugPrint('读取自动答题设置失败：$e');
    }
  }

  static Future<void> setAutoSearch(bool v) async {
    autoSearch.value = v;
    await _safe(() => StorageManager.prefs.setBool(_keyAutoSearch, v));
  }

  static Future<void> setAutoSelect(bool v) async {
    autoSelect.value = v;
    await _safe(() => StorageManager.prefs.setBool(_keyAutoSelect, v));
  }

  static Future<void> setAutoSubmit(bool v) async {
    autoSubmit.value = v;
    await _safe(() => StorageManager.prefs.setBool(_keyAutoSubmit, v));
  }

  /// 生成设置范围内的延迟；默认上下限相同，固定返回 2 秒。
  static Duration randomDelay() {
    final lo = delayMinMs.value;
    final hi = delayMaxMs.value;
    if (hi <= lo) return Duration(milliseconds: lo);
    final span = hi - lo;
    final r = DateTime.now().microsecondsSinceEpoch % span;
    return Duration(milliseconds: lo + r);
  }

  static Future<void> _safe(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      debugPrint('保存自动答题设置失败：$e');
    }
  }
}
