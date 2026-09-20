/// 答案检索结果展示弹窗
/// 在题目页面中点击"搜索答案"后弹出，展示检索结果
///
/// 选择某条结果后可通过「填入答案」按钮回传给调用页（`Navigator.pop(context, result)`），
/// 由调用页决定怎么写入作答状态；关闭（× / 关闭按钮）返回 null，不修改任何作答。
library;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// 最近一次请求的诊断信息
  AIRequestInfo? _requestInfo;

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
      _requestInfo = null;
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
          _requestInfo = AnswerSearchApi.lastRequestInfo;
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

  /// 把结果里的答案映射到当前题目的选项 key
  List<String> _matchedKeys(AnswerSearchResult result) =>
      result.matchOptionKeys(widget.question.options);

  /// 「填入」按钮能否点
  bool _canApply(AnswerSearchResult result) {
    if (widget.question.isChoice) return _matchedKeys(result).isNotEmpty;
    return result.answer.trim().isNotEmpty;
  }

  /// 「填入」按钮文案
  String _applyLabel(AnswerSearchResult result) {
    if (widget.question.isChoice) {
      final keys = _matchedKeys(result);
      if (keys.isEmpty) return '无法匹配选项';
      return '填入 ${keys.join('、')}';
    }
    return '填入答案文本';
  }

  Future<void> _copyAnswer(AnswerSearchResult result) async {
    await Clipboard.setData(ClipboardData(text: result.answer));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('答案已复制')),
    );
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
                  SizedBox(height: 8),
                  Text(
                    '思考型模型可能需要十几秒到几分钟',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
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
    final info = _requestInfo;

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
        // 请求诊断：出问题时能一眼看出地址 / 模型 / HTTP 码
        if (info != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: SelectableText(
              info.summary,
              style: const TextStyle(fontSize: 10),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildResultCard(AnswerSearchResult result) {
    final isBuiltin = result.sourceType == AnswerSourceType.builtin;
    final isLowConfidence = result.confidence < 0.8 && !isBuiltin;
    final canApply = _canApply(result);

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
            // 题型与答案不匹配时的提醒
            if (widget.question.isMultipleChoice &&
                _matchedKeys(result).length == 1) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: Colors.amber.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '本题是多选题，AI 只给出了 1 个选项，请自行核对',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.amber.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copyAnswer(result),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制答案'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        canApply ? () => Navigator.of(context).pop(result) : null,
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: Text(
                      _applyLabel(result),
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
            if (widget.question.isChoice && !canApply) ...[
              const SizedBox(height: 6),
              Text(
                'AI 给的答案与当前选项对不上，请手动选择或复制答案',
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
