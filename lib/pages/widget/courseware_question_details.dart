import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../cache/cached_image.dart';
import '../../models/answer_result.dart';
import '../../models/courseware_question_discovery.dart';

/// 仅返回用户是否主动选择跳页，不检索答案、不修改课堂或作答状态。
class CoursewareQuestionDetails extends StatelessWidget {
  const CoursewareQuestionDetails({super.key, required this.discovery});

  final CoursewareQuestionDiscovery discovery;

  static Future<bool?> show(
    BuildContext context,
    CoursewareQuestionDiscovery discovery,
  ) {
    final theme = MiuixTheme.of(context);
    return showDialog<bool>(
      context: context,
      builder: (_) => MiuixTheme(
        data: theme,
        child: CoursewareQuestionDetails(discovery: discovery),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final question = discovery.item.question;
    final colors = MiuixTheme.of(context).colors;
    final imageUrls = question.questionImageUrls
        .where((url) => url.trim().isNotEmpty)
        .toSet();
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: MiuixCard(
          insideMargin: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MiuixText(
                '课件题目详情 · 第 ${discovery.pageNumber} 页',
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              const SizedBox(height: 8),
              MiuixText(question.typeLabel, color: colors.primary),
              const SizedBox(height: 8),
              MiuixText(
                '仅供查看，发现题目不代表老师已发布。',
                fontSize: 12,
                color: colors.onSurfaceVariantSummary,
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (question.hasText)
                        SelectableText(
                          question.effectiveText,
                          style: TextStyle(color: colors.onSurface),
                        )
                      else
                        MiuixText(
                          '未获取到题干文字，图片内容尚未识别，请查看原页。',
                          color: colors.onSurfaceVariantSummary,
                        ),
                      for (final option in question.options) ...[
                        const SizedBox(height: 12),
                        SelectableText(
                          _optionText(option),
                          style: TextStyle(color: colors.onSurface),
                        ),
                      ],
                      if (imageUrls.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const MiuixText('题目相关图片'),
                        for (final url in imageUrls) _image(url),
                      ],
                      const SizedBox(height: 16),
                      const MiuixText('原页预览'),
                      if (discovery.slideImageUrl.isNotEmpty)
                        _image(discovery.slideImageUrl)
                      else
                        const MiuixText('原页预览暂不可用，可跳转到课件页查看。'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  MiuixTextButton(
                    '关闭',
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  MiuixButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: MiuixText('跳转到第 ${discovery.pageNumber} 页'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _optionText(StandardizedOption option) {
    final text = StandardizedQuestion.extractPlainText(option.value);
    final label = text.isEmpty ? '图片选项（见题目相关图片）' : text;
    return '${option.key}. $label';
  }

  Widget _image(String url) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: AspectRatio(
      aspectRatio: 16 / 9,
      child: InteractiveViewer(
        child: Image(
          image: SlideImage(discovery.lessonId, url),
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : const Center(child: CircularProgressIndicator()),
          errorBuilder: (context, error, stackTrace) =>
              const Center(child: MiuixText('图片加载失败，可跳转原页查看。')),
        ),
      ),
    ),
  );
}
