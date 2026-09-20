/// 运行日志查看页
///
/// 能力：
/// - 实时查看内存里的运行日志（级别筛选：全部 / 警告及以上 / 仅错误）
/// - 长按单条复制
/// - 一键导出：调起系统分享（可直接发微信 / QQ / 邮件，或存到文件）
/// - 复制全部到剪贴板（分享不可用时的兜底）
/// - 清空日志
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../utils/app_logger.dart';

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  /// null = 全部
  LogLevel? _minLevel;

  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    AppLogger.revision.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    AppLogger.revision.removeListener(_onLogChanged);
    super.dispose();
  }

  void _onLogChanged() {
    if (mounted) setState(() {});
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  Color _levelColor(LogLevel level, ColorScheme scheme) {
    switch (level) {
      case LogLevel.debug:
        return scheme.onSurfaceVariant;
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.warn:
        return Colors.orange;
      case LogLevel.error:
        return scheme.error;
    }
  }

  Future<void> _copyLine(LogEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.line));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('该条日志已复制'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _copyAll() async {
    final text = AppLogger.exportText(minLevel: _minLevel);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('全部日志已复制到剪贴板')),
    );
  }

  Future<void> _export() async {
    if (_exporting) return;

    // 先取好分享锚点，避免 await 之后再用 context
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _exporting = true);
    try {
      final file = await AppLogger.exportFile();
      if (file == null) {
        if (!mounted) return;
        setState(() => _exporting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导出文件失败，可改用「复制全部」')),
        );
        return;
      }

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/plain')],
          subject: '课程助手运行日志',
          text: '课程助手运行日志（${AppLogger.entryCount} 条）',
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      AppLogger.e('日志页', '导出失败：$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e，可改用「复制全部」')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('将删除内存与磁盘上的全部日志，确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await AppLogger.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日志已清空')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = AppLogger.filtered(_minLevel);

    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空日志',
            onPressed: _confirmClear,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildInfoCard(theme),
          _buildFilters(theme),
          const Divider(height: 1),
          Expanded(
            child: list.isEmpty
                ? const Center(
                    child: Text('暂无日志', style: TextStyle(color: Colors.grey)),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      // reverse: true → index 0 在最底部，所以从末尾取
                      final entry = list[list.length - 1 - index];
                      return _buildRow(entry, theme);
                    },
                  ),
          ),
          _buildBottomBar(theme),
        ],
      ),
    );
  }

  Widget _buildInfoCard(ThemeData theme) {
    final path = AppLogger.currentFilePath ?? '（未落盘）';

    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_long, size: 16,
                  color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                '内存 ${AppLogger.entryCount} 条 · '
                '当前文件 ${_formatBytes(AppLogger.currentFileBytes)}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            path,
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '最多保留 ${AppLogger.maxEntries} 条 / 单文件 '
            '${_formatBytes(AppLogger.maxFileBytes)} / 保留 ${AppLogger.keepDays} 天'
            ' · API Key 已自动脱敏',
            style: TextStyle(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters(ThemeData theme) {
    final options = <(String, LogLevel?)>[
      ('全部', null),
      ('警告及以上', LogLevel.warn),
      ('仅错误', LogLevel.error),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: options.map((option) {
          final selected = _minLevel == option.$2;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(option.$1),
              selected: selected,
              onSelected: (_) => setState(() => _minLevel = option.$2),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildRow(LogEntry entry, ThemeData theme) {
    final color = _levelColor(entry.level, theme.colorScheme);

    return InkWell(
      onLongPress: () => _copyLine(entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 3,
              height: 30,
              margin: const EdgeInsets.only(right: 8, top: 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        LogEntry.formatTime(entry.time).substring(11),
                        style: TextStyle(
                          fontSize: 10,
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        entry.level.label,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          entry.tag,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    entry.message,
                    style: const TextStyle(fontSize: 11.5, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _copyAll,
                icon: const Icon(Icons.copy_all, size: 18),
                label: const Text('复制全部'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: _exporting ? null : _export,
                icon: _exporting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share, size: 18),
                label: Text(_exporting ? '正在导出...' : '导出日志（分享/发送）'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
