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
  // 延迟的键名带 _v2：旧版把 800/2000 存进过用户手机，
  // 沿用旧键的话新默认值永远不生效（ensureLoaded 会读回旧值）。
  // 延迟没有 UI，用户不可能手动改过，所以直接换键是安全的。
  static const _keyDelayMin = 'aa_delay_min_ms_v2';
  static const _keyDelayMax = 'aa_delay_max_ms_v2';

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
  /// 默认开。提交前有 [delayMinMs]~[delayMaxMs] 的随机延迟，
  /// 避免「老师刚发就秒交」这种明显的脚本特征。
  static final ValueNotifier<bool> autoSubmit = ValueNotifier<bool>(true);

  /// 拟人化延迟区间（毫秒）
  ///
  /// 用户明确要求「延迟要低」—— 老师发题到交卷之间只留 0.3~0.8 秒。
  /// 再低就接近「零延迟秒交」了，那个特征反而更明显。
  static final ValueNotifier<int> delayMinMs = ValueNotifier<int>(300);
  static final ValueNotifier<int> delayMaxMs = ValueNotifier<int>(800);

  static bool _loaded = false;

  /// 读取持久化设置（幂等）
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final p = StorageManager.prefs;
      autoSearch.value = p.getBool(_keyAutoSearch) ?? true;
      autoSelect.value = p.getBool(_keyAutoSelect) ?? true;
      autoSubmit.value = p.getBool(_keyAutoSubmit) ?? true;
      delayMinMs.value = p.getInt(_keyDelayMin) ?? 300;
      delayMaxMs.value = p.getInt(_keyDelayMax) ?? 800;
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
