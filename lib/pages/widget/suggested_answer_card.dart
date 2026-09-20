/// 题目面板里的「建议答案」卡片
///
/// 只做展示 + 把用户的选择回传，**绝不自动提交**。
/// 三种状态：
/// - 检索中（还没结果）
/// - 有建议答案（显示答案 + 置信度 + 来源，可一键填入）
/// - 没答案 / 失败（显示原因 + 重试）
library;

import 'package:flutter/material.dart';

import '../../cache/answer_cache.dart';
import '../../models/answer_result.dart';

class SuggestedAnswerCard extends StatelessWidget {
  /// 缓存里的结果（没有则为 null）
  final CachedAnswer? cached;

  /// 是否正在检索（排队中或请求中）
  final bool isSearching;

  /// 这题题干/选项都为空、只有图，需要视觉识别才能读题
  final bool needsVision;

  /// 当前题目的选项（用来把答案映射成选项 key）
  final List<StandardizedOption> options;

  /// 一键填入
  final VoidCallback? onApply;

  /// 查看详情（打开检索弹窗）
  final VoidCallback? onDetails;

  /// 重新检索（忽略缓存）
  final VoidCallback? onRetry;

  const SuggestedAnswerCard({
    super.key,
    required this.cached,
    required this.isSearching,
    required this.options,
    this.needsVision = false,
    this.onApply,
    this.onDetails,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 既没有缓存也没在检索 → 不占位（AI 没配置时就是这种状态）
    if (cached == null && !isSearching) return const SizedBox.shrink();

    final answer = cached;
    final usable = answer?.usable ?? false;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: usable ? scheme.primary : scheme.outlineVariant,
            width: 3,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context, answer, usable),
          if (usable) ...[
            const SizedBox(height: 8),
            _buildAnswerBody(context, answer!),
          ],
          if (isSearching && !usable) ...[
            const SizedBox(height: 8),
            _buildSearching(context),
          ],
          if (!isSearching && !usable && answer != null) ...[
            const SizedBox(height: 6),
            _buildEmptyOrError(context, answer),
          ],
          const SizedBox(height: 4),
          _buildActions(context, answer, usable),
        ],
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    CachedAnswer? answer,
    bool usable,
  ) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Icon(
          usable ? Icons.auto_awesome : Icons.auto_awesome_outlined,
          size: 16,
          color: usable ? scheme.primary : scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text(
          '建议答案',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: usable ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        if (needsVision)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '需识图',
              style: TextStyle(
                fontSize: 10,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        const Spacer(),
        if (usable) _confidenceChip(context, answer!.best!.confidence),
      ],
    );
  }

  Widget _confidenceChip(BuildContext context, double confidence) {
    final scheme = Theme.of(context).colorScheme;
    final color = confidence >= 0.8
        ? scheme.primary
        : (confidence >= 0.5 ? Colors.orange : scheme.error);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '置信度 ${_confidenceLabel(confidence)}',
        style: TextStyle(fontSize: 10, color: color),
      ),
    );
  }

  Widget _buildAnswerBody(BuildContext context, CachedAnswer answer) {
    final scheme = Theme.of(context).colorScheme;
    final best = answer.best!;
    final keys = best.matchOptionKeys(options);
    final isChoice = options.isNotEmpty;

    // 选择题显示映射后的选项字母；非选择题直接显示答案文本
    final display = isChoice && keys.isNotEmpty
        ? keys.join('、')
        : best.answer.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          display.isEmpty ? '（模型未给出答案）' : display,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          best.source.isEmpty ? best.sourceType.label : best.source,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        if ((best.explanation ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            best.explanation!.trim(),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
        if (answer.questionPreview.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '匹配题目：${answer.questionPreview}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSearching(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          needsVision ? '题目只画在图上，点「搜索答案」手动识别' : '正在检索建议答案…',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildEmptyOrError(BuildContext context, CachedAnswer answer) {
    final scheme = Theme.of(context).colorScheme;
    final failed = answer.status == CachedAnswerStatus.failed;

    final text = failed
        ? '检索失败：${answer.error ?? '未知原因'}'
        : '未检索到答案';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          failed ? Icons.error_outline : Icons.search_off,
          size: 14,
          color: failed ? scheme.error : scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: failed ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActions(
    BuildContext context,
    CachedAnswer? answer,
    bool usable,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final keys = usable ? answer!.best!.matchOptionKeys(options) : const <String>[];
    final canApply = usable &&
        (options.isEmpty ? answer!.best!.answer.trim().isNotEmpty : keys.isNotEmpty);

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (usable)
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: scheme.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('重新检索', style: TextStyle(fontSize: 12)),
          ),
        TextButton(
          onPressed: onDetails,
          style: TextButton.styleFrom(
            foregroundColor: scheme.onSurfaceVariant,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('详情', style: TextStyle(fontSize: 12)),
        ),
        if (canApply)
          TextButton(
            onPressed: onApply,
            style: TextButton.styleFrom(
              foregroundColor: scheme.primary,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              options.isEmpty ? '填入文本' : '填入 ${keys.join('、')}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
      ],
    );
  }

  static String _confidenceLabel(double confidence) {
    if (confidence >= 1.0) return '确定';
    if (confidence >= 0.8) return '高';
    if (confidence >= 0.5) return '中';
    return '低';
  }
}
