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
