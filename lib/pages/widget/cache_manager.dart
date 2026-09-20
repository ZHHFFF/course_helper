/// PPT 缓存管理页
///
/// 展示缓存占用，并提供手动清理入口。
///
/// 自动清理策略本来就在跑（进课堂时清一遍）：
/// 1. 课程目录里有「已结束」标记且过了 24 小时 → 删
/// 2. 课程目录超过 7 天没有任何写入 → 删
///
/// 这一页只是让用户能主动看一眼、主动清一次，不是必需品。
library;

import 'package:flutter/material.dart';

import '../../cache/answer_cache.dart';
import '../../cache/ppt_cache.dart';
import '../../cache/course_cache.dart';

class CacheManagerPage extends StatefulWidget {
  const CacheManagerPage({super.key});

  @override
  State<CacheManagerPage> createState() => _CacheManagerPageState();
}

class _CacheManagerPageState extends State<CacheManagerPage> {
  bool _isLoading = true;
  bool _isBusy = false;

  int _bytes = 0;
  int _lessons = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _isLoading = true);
    final stats = await CourseCache.stats();
    if (!mounted) return;
    setState(() {
      _bytes = stats.bytes;
      _lessons = stats.lessons;
      _isLoading = false;
    });
  }

  Future<void> _runCleanup() async {
    setState(() => _isBusy = true);
    final report = await CourseCache.cleanup();
    if (!mounted) return;
    setState(() => _isBusy = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(report.isEmpty ? '没有需要清理的缓存' : '已清理：$report'),
      ),
    );
    await _refresh();
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空全部缓存'),
        content: const Text(
          '会删掉所有课程已缓存的 PPT 元数据、课件图片和题目答案。\n\n'
          '下次进课堂会重新下载和重新检索，不影响账号和设置。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              '清空',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isBusy = true);
    final bytes = await CourseCache.clearAll();
    // 内存里那层也要一起丢掉，否则界面还在展示已经删掉的答案
    PptCache.clearMemory();
    AnswerCache.clearMemory();
    if (!mounted) return;
    setState(() => _isBusy = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已释放 ${_formatBytes(bytes)}')),
    );
    await _refresh();
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PPT 缓存'),
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isBusy ? null : _refresh,
            tooltip: '刷新',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildOverviewCard(context),
                const SizedBox(height: 16),
                _buildPolicyCard(context),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: _isBusy ? null : _runCleanup,
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('清理过期缓存'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isBusy || _lessons == 0 ? null : _clearAll,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('清空全部缓存'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.error,
                  ),
                ),
                if (_isBusy) ...[
                  const SizedBox(height: 24),
                  const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildOverviewCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前占用',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            _formatBytes(_bytes),
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _lessons == 0 ? '还没有缓存任何课程' : '共 $_lessons 门课的缓存',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildPolicyCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                '自动清理规则',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildRule(
            context,
            '课程结束后 ${CourseCache.finishGrace.inHours} 小时',
            '离开课堂会打上结束标记，再留一段时间防止下课还想回去翻两眼',
          ),
          const SizedBox(height: 8),
          _buildRule(
            context,
            '${CourseCache.idleKeep.inDays} 天没有使用',
            '按目录内最后一次写入时间算',
          ),
          const SizedBox(height: 8),
          _buildRule(
            context,
            '按课程隔离',
            '每节课一个目录，互不影响；清理时整门课一起清',
          ),
        ],
      ),
    );
  }

  Widget _buildRule(BuildContext context, String title, String detail) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(fontSize: 13, color: scheme.onSurface),
              ),
              Text(
                detail,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
