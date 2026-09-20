import 'package:flutter/foundation.dart';

import '../utils/storage.dart';

/// 自动答题 / 预取 相关设置
///
/// 与「AI 检索配置」分开存放，避免互相覆盖：
/// - AI 检索配置（地址/Key/模型）在 `AnswerSearchApi` 里
/// - 行为开关（预搜、自动提交、拟人延迟、PPT 预取）在这里
class AutoAnswerSetting {
  AutoAnswerSetting._();

  static const _keyPreSearch = 'auto_answer_presearch';
  static const _keyAutoSubmit = 'auto_answer_autosubmit';
  static const _keyDelayMin = 'auto_answer_delay_min_ms';
  static const _keyDelayMax = 'auto_answer_delay_max_ms';
  static const _keyPrefetch = 'ppt_prefetch_enabled';

  /// 进课堂后立刻把所有题目的答案搜好（不等老师发布）
  static final ValueNotifier<bool> preSearch = ValueNotifier<bool>(false);

  /// 老师发布题目后自动提交（不需要手动点「提交」）
  static final ValueNotifier<bool> autoSubmit = ValueNotifier<bool>(false);

  /// 进课堂后把整份 PPT 的图片预取到本地缓存（翻页秒开）
  static final ValueNotifier<bool> prefetch = ValueNotifier<bool>(true);

  /// 拟人化延迟区间（毫秒）——避免「秒交」被风控
  static final ValueNotifier<int> delayMinMs = ValueNotifier<int>(1200);
  static final ValueNotifier<int> delayMaxMs = ValueNotifier<int>(3500);

  static bool _loaded = false;

  /// 读取持久化设置（幂等，可重复调用）
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final p = StorageManager.prefs;
      preSearch.value = p.getBool(_keyPreSearch) ?? false;
      autoSubmit.value = p.getBool(_keyAutoSubmit) ?? false;
      prefetch.value = p.getBool(_keyPrefetch) ?? true;
      delayMinMs.value = p.getInt(_keyDelayMin) ?? 1200;
      delayMaxMs.value = p.getInt(_keyDelayMax) ?? 3500;
      _loaded = true;
    } catch (e) {
      debugPrint('读取自动答题设置失败：$e');
    }
  }

  static Future<void> setPreSearch(bool value) async {
    preSearch.value = value;
    await _safe(() => StorageManager.prefs.setBool(_keyPreSearch, value));
  }

  static Future<void> setAutoSubmit(bool value) async {
    autoSubmit.value = value;
    await _safe(() => StorageManager.prefs.setBool(_keyAutoSubmit, value));
  }

  static Future<void> setPrefetch(bool value) async {
    prefetch.value = value;
    await _safe(() => StorageManager.prefs.setBool(_keyPrefetch, value));
  }

  static Future<void> setDelayRange(int minMs, int maxMs) async {
    final lo = minMs.clamp(0, 60000);
    final hi = maxMs.clamp(lo, 60000);
    delayMinMs.value = lo;
    delayMaxMs.value = hi;
    await _safe(() => StorageManager.prefs.setInt(_keyDelayMin, lo));
    await _safe(() => StorageManager.prefs.setInt(_keyDelayMax, hi));
  }

  /// 生成一个落在区间内的随机延迟
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
