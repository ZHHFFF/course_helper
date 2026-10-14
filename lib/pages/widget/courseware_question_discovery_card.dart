import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../models/courseware_question_discovery.dart';
import 'classroom_timeline_card.dart';
import 'courseware_question_details.dart';

/// 本地时间线卡片；大量题目默认只显示可展开的汇总。
class CoursewareQuestionDiscoveryCard extends StatefulWidget {
  const CoursewareQuestionDiscoveryCard({
    super.key,
    required this.batch,
    required this.isCurrent,
    required this.timeLabel,
    required this.onJump,
  });

  final CoursewareQuestionBatch batch;
  final bool isCurrent;
  final String timeLabel;
  final Future<void> Function(CoursewareQuestionDiscovery) onJump;

  @override
  State<CoursewareQuestionDiscoveryCard> createState() =>
      _CoursewareQuestionDiscoveryCardState();
}

class _CoursewareQuestionDiscoveryCardState
    extends State<CoursewareQuestionDiscoveryCard> {
  bool _expanded = false;

  Future<void> _showDetails(CoursewareQuestionDiscovery discovery) async {
    // 教师切换课件可能重建/移除卡片；详情快照和页面级回调仍有效。
    final onJump = widget.onJump;
    final jump = await CoursewareQuestionDetails.show(context, discovery);
    if (jump == true) await onJump(discovery);
  }

  @override
  Widget build(BuildContext context) {
    final batch = widget.batch;
    if (batch.questions.isEmpty) return const SizedBox.shrink();
    final colors = MiuixTheme.of(context).colors;
    final collapsed = batch.questions.length > 3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (collapsed)
          ClassroomTimelineCard(
            icon: Icons.quiz_outlined,
            color: colors.primary,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(context),
                const SizedBox(height: 12),
                MiuixText(
                  '共 ${batch.questions.length} 题',
                  color: colors.onSurfaceVariantSummary,
                ),
                _historyLabel(context),
                const SizedBox(height: 4),
                MiuixTextButton(
                  _expanded ? '收起题目' : '展开题目',
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ),
          ),
        if (!collapsed || _expanded)
          for (final discovery in batch.questions)
            ClassroomTimelineCard(
              key: ValueKey(discovery.identity),
              icon: Icons.quiz_outlined,
              color: colors.primary,
              onPressed: () => _showDetails(discovery),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(context),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: MiuixText(
                          '第 ${discovery.pageNumber} 页',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                        ),
                      ),
                      MiuixText(discovery.item.typeLabel, fontSize: 15),
                    ],
                  ),
                  _historyLabel(context),
                  const SizedBox(height: 12),
                  MiuixText(
                    discovery.item.question.hasText
                        ? discovery.item.question.effectiveText
                        : '图片内容尚未识别，请查看原页。',
                    fontSize: 15,
                    height: 1.5,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    color: colors.onSurfaceVariantSummary,
                  ),
                  Divider(height: 28, color: colors.dividerLine),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 36),
                    child: Row(
                      children: [
                        Expanded(
                          child: MiuixText(
                            '查看题目详情',
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.chevron_right,
                          size: 24,
                          color: colors.primary,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _historyLabel(BuildContext context) => widget.isCurrent
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: MiuixText(
            '历史课件 · ${widget.batch.title.isEmpty ? "课堂课件" : widget.batch.title}',
            fontSize: 12,
            color: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
          ),
        );

  Widget _header(BuildContext context) {
    final time = MiuixText(
      widget.timeLabel,
      fontSize: 12,
      color: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
    );
    const title = MiuixText(
      '发现课件题目',
      fontSize: 18,
      fontWeight: FontWeight.bold,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 210 ||
            MediaQuery.textScalerOf(context).scale(18) > 24) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 4), time],
          );
        }
        return Row(
          children: [
            const Expanded(child: title),
            const SizedBox(width: 8),
            time,
          ],
        );
      },
    );
  }
}
