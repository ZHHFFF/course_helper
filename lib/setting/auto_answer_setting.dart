import 'package:flutter/foundation.dart';

import '../utils/storage.dart';

/// 学习通（超星）自动答题设置
///
/// 学习通和雨课堂机制不同：活动页 HTML 里直接嵌了 `quizList`，
/// 而且 `answer[].isanswer == true` 就是服务器给的正确答案
/// （`_autoFillAnswers()` 已经在用它填了）。
///
/// 所以这里只解决两件事：
/// 1. **补差**：服务器没给答案的题，用 AI 检索补上（只填，不交）
/// 2. **自动提交**（可选，默认关）：全部填好后自动交卷
///
/// 雨课堂那边由 `lib/cache/*` 负责，不归这里管。
class AutoAnswerSetting {
  AutoAnswerSetting._();

  static const _keyPreSearch = 'chaoxing_presearch';
  static const _keyAutoSubmit = 'chaoxing_autosubmit';
  static const _keyDelayMin = 'chaoxing_delay_min_ms';
  static const _keyDelayMax = 'chaoxing_delay_max_ms';

  /// 题目加载后，把服务器没给答案的题用 AI 补上
  ///
  /// 默认开：这一步**只填不交**，和雨课堂那边的自动识题行为一致。
  static final ValueNotifier<bool> preSearch = ValueNotifier<bool>(true);

  /// 全部填好后自动提交
  ///
  /// **默认开**（产品明确要求）。
  ///
  /// ⚠️ 风险提示：雨课堂那边同学的实现是「只给建议，永不自动提交」，
  /// 两边策略不一致。秒交的脚本特征很明显，容易被风控盯上。
  /// 提交前有 1.2~3.5 秒随机延迟做拟人化，但**不能完全消除风险**。
  /// 想保守一点就把这个开关关掉（只预搜、手动交）。
  static final ValueNotifier<bool> autoSubmit = ValueNotifier<bool>(true);

  /// 拟人化延迟区间（毫秒）——只在开了自动提交时生效
  static final ValueNotifier<int> delayMinMs = ValueNotifier<int>(1200);
  static final ValueNotifier<int> delayMaxMs = ValueNotifier<int>(3500);

  static bool _loaded = false;

  /// 读取持久化设置（幂等）
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final p = StorageManager.prefs;
      preSearch.value = p.getBool(_keyPreSearch) ?? true;
      autoSubmit.value = p.getBool(_keyAutoSubmit) ?? true;
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
