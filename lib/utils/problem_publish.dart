/// 判断「当前页的题是不是老师已发布的」
///
/// 抽成纯函数是为了能单测 —— 这段逻辑最容易出错，因为它要处理
/// **两套 ID 命名空间**：
/// - 发题消息（unlockproblem）给的是 `prob`
/// - PPT 里题目的字段是 `problemId`
///
/// 原来的代码拿一边的值去 contains 另一边的集合，万一两个值不一样，
/// 「提交」按钮就永远不出现。现在统一在这里判断。
///
/// 不依赖 Flutter，`flutter test` 里能直接跑。
library;

/// 当前页的题是否已发布
///
/// 判据（任一成立即算已发布）：
/// 1. [currentSlideIndex] 在 [publishedSlideOf] 里
///    —— 最可靠：这是收到发题消息时把 `prob` 解析成页号存下来的映射，
///    不依赖任何 ID 字符串比对
/// 2. 当前页题目的 [currentProblemId] 直接在 [publishedProbs] 里
///    —— 对应 `prob == problemId` 的情况
/// 3. [timelineProblemId] 在 [publishedProbs] 里
///    —— 用户从时间轴点进来的场景
bool isCurrentProblemPublished({
  required int currentSlideIndex,
  required Map<int, String> publishedSlideOf,
  required String? currentProblemId,
  required Set<String> publishedProbs,
  required String? timelineProblemId,
}) {
  // 判据 1：页号映射（最可靠）
  if (publishedSlideOf.containsKey(currentSlideIndex)) return true;

  // 判据 2：当前页的 problemId 在已发布集合里
  if (currentProblemId != null &&
      currentProblemId.isNotEmpty &&
      publishedProbs.contains(currentProblemId)) {
    return true;
  }

  // 判据 3：时间轴点开的那道题已发布
  if (timelineProblemId != null &&
      timelineProblemId.isNotEmpty &&
      publishedProbs.contains(timelineProblemId)) {
    return true;
  }

  return false;
}

/// 重连补查的结果
typedef ResyncDecision = ({String? problemId, String reason});

/// 从 timeline 里挑出「值得补一次自动提交」的那道题
///
/// **为什么需要**：`unlockproblem` 是**推送**。如果连接正好在老师发题那一刻
/// 断着（后台被系统回收、网络切换、socket 空闲被丢弃……），这条消息就永久丢了
/// —— 把连接重连回来也补不回事件，这道题再也不会自动提交。
/// 重连后服务端会回一份完整 timeline（`hello` 的响应），从里面把最新那道题捞出来。
///
/// 三道闸门，**宁可漏补也不能交错**：
/// 1. 只看 `problem` 事件里的**最新一条**
/// 2. `dt` 距今必须在 [window] 内 —— 太久远的是历史题，不能复活
/// 3. `si` 必须等于老师**当前**所在页（1-based）—— 说明这就是「现在这道」
///
/// [reason] 是给人看的原因，直接写进日志，方便真机排查。
/// `problemId == null` 表示不用补。
ResyncDecision pickResyncProblemId({
  required List timeline,
  required DateTime now,
  required int? currentLessonSlideIndex,
  required Set<String> alreadySubmitted,
  Duration window = const Duration(minutes: 3),
}) {
  Map<dynamic, dynamic>? latest;
  for (final event in timeline.reversed) {
    if (event is Map && event['type'] == 'problem' && event['prob'] != null) {
      latest = event;
      break;
    }
  }
  if (latest == null) {
    return (problemId: null, reason: 'timeline 里没有 problem 事件');
  }

  final problemId = latest['prob'].toString();
  if (problemId.isEmpty) {
    return (problemId: null, reason: 'problem 事件的 prob 为空');
  }
  if (alreadySubmitted.contains(problemId)) {
    return (problemId: null, reason: '题目 $problemId 已经提交过，不重复补');
  }

  // 闸门 2：时间
  final dt = latest['dt'];
  if (dt is num) {
    final publishedAt = DateTime.fromMillisecondsSinceEpoch(dt.toInt());
    final age = now.difference(publishedAt);
    if (age.isNegative || age > window) {
      return (
        problemId: null,
        reason: '题目 $problemId 发布于 ${age.inMinutes} 分钟前，超出补交窗口'
            '（${window.inMinutes} 分钟），跳过',
      );
    }
  }

  // 闸门 3：位置
  final si = latest['si'];
  if (si is num && si.toInt() > 0 && currentLessonSlideIndex != null) {
    if (si.toInt() - 1 != currentLessonSlideIndex) {
      return (
        problemId: null,
        reason: '题目 $problemId 在第 ${si.toInt()} 页，老师当前在第 '
            '${currentLessonSlideIndex + 1} 页，不是当前题，跳过',
      );
    }
  }

  return (
    problemId: problemId,
    reason: '发现断线期间可能漏掉的题目 $problemId（老师当前就在这一页），补一次自动提交',
  );
}
