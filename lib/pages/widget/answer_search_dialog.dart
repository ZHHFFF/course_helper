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

  @override
  void initState() {
    super.initState();
    _performSearch();
  }

  Future<void> _performSearch() async {
    setState(() {
      _isSearching = true;
      _errorMessage = null;
      _results.clear();
    });

    try {
      final results = await AnswerSearchApi.search(widget.question);
      if (mounted) {
        setState(() {
          _results = results;
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
                : _results.isEmpty
                    ? const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.search_off, size: 48, color: Colors.grey),
                          SizedBox(height: 8),
                          Text('未找到相关答案'),
                          SizedBox(height: 4),
                          Text(
                            '可尝试在设置中配置AI检索源',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 题干预览
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(8),
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              widget.question.questionText,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                          ),
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

