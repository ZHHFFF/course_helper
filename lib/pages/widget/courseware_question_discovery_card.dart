import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../models/courseware_question_discovery.dart';
import 'courseware_question_details.dart';

/// 本地时间线卡片；大量题目默认只显示可展开的汇总。
class CoursewareQuestionDiscoveryCard extends StatefulWidget {
  const CoursewareQuestionDiscoveryCard({
    super.key,
    required this.batch,
    required this.isCurrent,
    required this.onJump,
  });

  final CoursewareQuestionBatch batch;
  final bool isCurrent;
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MiuixCard(
        insideMargin: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MiuixText(
              '${batch.title.isEmpty ? "课堂课件" : batch.title} · ${widget.isCurrent ? "当前课件" : "历史课件"}',
              fontSize: 12,
              color: colors.onSurfaceVariantSummary,
            ),
            if (collapsed)
              Row(
                children: [
                  Expanded(
                    child: MiuixText('发现课件题目 · 共 ${batch.questions.length} 题'),
                  ),
                  MiuixTextButton(
                    _expanded ? '收起题目' : '展开题目',
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                ],
              ),
            if (!collapsed || _expanded)
              for (final discovery in batch.questions)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: MiuixCard(
                    key: ValueKey(discovery.identity),
                    insideMargin: const EdgeInsets.all(12),
                    onPressed: () => _showDetails(discovery),
                    child: MiuixText(
                      '发现课件题目 · 第 ${discovery.pageNumber} 页 · ${discovery.item.typeLabel}',
                      color: colors.primary,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
