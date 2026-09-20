/// 答案检索结果展示弹窗
/// 在题目页面中点击"搜索答案"后弹出，展示检索结果
import 'package:flutter/material.dart';

import '../../api/answer_search.dart';
import '../../models/answer_result.dart';

class AnswerSearchDialog extends StatefulWidget {
  final StandardizedQuestion question;

  const AnswerSearchDialog({
    super.key,
    required this.question,
  });

  @override
  State<AnswerSearchDialog> createState() => _AnswerSearchDialogState();
}

class _AnswerSearchDialogState extends State<AnswerSearchDialog> {
  bool _isSearching = true;
  List<AnswerSearchResult> _results = [];
  String? _errorMessage;

  /// AI 检索失败的原因（用于给出更具体的提示）
  String? _aiErrorHint;

  @override
  void initState() {
    super.initState();
    _performSearch();
  }

  Future<void> _performSearch() async {
    setState(() {
      _isSearching = true;
      _errorMessage = null;
      _aiErrorHint = null;
      _results.clear();
    });

    // 题目内容都没拿到，直接提示，不用发请求
    if (!widget.question.isUsable) {
      setState(() {
        _isSearching = false;
        _errorMessage = '未能获取到题目内容\n（题干为空，且当前课件页没有可识别的图片）';
      });
      return;
    }

    try {
      final results = await AnswerSearchApi.search(widget.question);
      if (mounted) {
        setState(() {
          _results = results;
          _aiErrorHint = AnswerSearchApi.lastAIError;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '检索失败: $e';
          _isSearching = false;
        });
      }
    }
  }

  Color _getConfidenceColor(double confidence) {
    if (confidence >= 0.8) return Colors.green;
    if (confidence >= 0.5) return Colors.orange;
    return Colors.red;
  }

  String _getConfidenceLabel(double confidence) {
    if (confidence >= 1.0) return '确定';
    if (confidence >= 0.8) return '高';
    if (confidence >= 0.5) return '中';
    return '低';
  }

  /// 题目来源描述
  String get _questionSourceText {
    final q = widget.question;
    if (q.hasText && q.hasImage) return '题干 + 课件图片';
    if (q.hasText) return q.questionText.trim().isNotEmpty ? '题干' : '课件文本';
    if (q.hasImage) return '课件图片（AI 识图）';
    return '未获取到';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.search, size: 20),
          const SizedBox(width: 8),
          const Text('答案检索'),
          const Spacer(),
          if (!_isSearching)
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _performSearch,
              tooltip: '重新搜索',
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: _isSearching
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在检索答案...'),
                ],
              )
            : _errorMessage != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline,
                          color: Theme.of(context).colorScheme.error, size: 48),
                      const SizedBox(height: 8),
                      Text(_errorMessage!, textAlign: TextAlign.center),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildQuestionPreview(),
                      const SizedBox(height: 8),
                      if (_results.isEmpty)
                        _buildEmptyResult()
                      else
                        Flexible(
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: _results.length,
                            itemBuilder: (context, index) =>
                                _buildResultCard(_results[index]),
                          ),
                        ),
                    ],
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// 题干预览 + 题型 + 来源
  Widget _buildQuestionPreview() {
    final theme = Theme.of(context);
    final q = widget.question;
    final previewText = q.hasText ? q.effectiveText : '（题目来自课件图片）';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 题型标签
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  q.typeLabel,
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 来源标签
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: q.hasImage
                      ? Colors.purple.withValues(alpha: 0.15)
                      : theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _questionSourceText,
                  style: TextStyle(
                    fontSize: 10,
                    color: q.hasImage
                        ? Colors.purple.shade700
                        : theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              if (q.options.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  '${q.options.length} 个选项',
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            previewText,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyResult() {
    final theme = Theme.of(context);
    final hint = _aiErrorHint;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.search_off, size: 48, color: Colors.grey),
        const SizedBox(height: 8),
        const Text('未找到相关答案'),
        const SizedBox(height: 6),
        if (hint != null)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: Text(
              'AI 检索失败：$hint',
              style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
            ),
          )
        else
          Text(
            '可尝试在设置中配置AI检索源',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  Widget _buildResultCard(AnswerSearchResult result) {
    final isBuiltin = result.sourceType == AnswerSourceType.builtin;
    final isLowConfidence =
        result.confidence < 0.8 && !isBuiltin;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildSourceBadge(result),
                const Spacer(),
                _buildConfidenceBadge(result),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isBuiltin
                    ? Colors.green.withValues(alpha: 0.08)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
                border: isBuiltin
                    ? Border.all(color: Colors.green.withValues(alpha: 0.3))
                    : null,
              ),
              child: SelectableText(
                result.answer,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (result.explanation != null &&
                result.explanation!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                result.explanation!,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (isLowConfidence) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber,
                        size: 16, color: Colors.orange.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '此结果置信度较低，仅供参考，不保证正确',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSourceBadge(AnswerSearchResult result) {
    Color bgColor;
    Color textColor;

    switch (result.sourceType) {
      case AnswerSourceType.builtin:
        bgColor = Colors.green.withValues(alpha: 0.15);
        textColor = Colors.green.shade700;
        break;
      case AnswerSourceType.aiProvider:
        bgColor = Colors.purple.withValues(alpha: 0.15);
        textColor = Colors.purple.shade700;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        result.source,
        style: TextStyle(fontSize: 11, color: textColor),
      ),
    );
  }

  Widget _buildConfidenceBadge(AnswerSearchResult result) {
    final color = _getConfidenceColor(result.confidence);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '匹配度: ${_getConfidenceLabel(result.confidence)}'
        ' (${(result.confidence * 100).toInt()}%)',
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
