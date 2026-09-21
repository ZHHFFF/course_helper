/// 前台服务自检页
///
/// **为什么需要这一页**：前台服务原本只在 `PresentationPage.initState` 里启动，
/// 也就是说「没有正在上课的课程」时根本进不去课堂页、没法验证它。
/// 这一页把启动/停止/状态查询都暴露出来，随时能验。
///
/// 正常使用不需要它 —— 进课堂时服务会自己起、离开课堂会自己停。
///
/// 顺带说明验证方法：光看这一页不够，最好再配合命令行
/// `adb shell dumpsys activity services com.anerycoft.coursehelper`
/// 确认系统那边真的认了。
library;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../../utils/app_logger.dart';
import '../../utils/keep_alive_service.dart';

class KeepAliveCheckerPage extends StatefulWidget {
  const KeepAliveCheckerPage({super.key});

  @override
  State<KeepAliveCheckerPage> createState() => _KeepAliveCheckerPageState();
}

class _KeepAliveCheckerPageState extends State<KeepAliveCheckerPage> {
  bool _loading = true;
  bool _busy = false;

  bool _running = false;
  NotificationPermission? _notification;
  bool _ignoringBattery = false;

  @override
  void initState() {
    super.initState();
    KeepAliveService.lastResult.addListener(_onResultChanged);
    _refresh();
  }

  @override
  void dispose() {
    KeepAliveService.lastResult.removeListener(_onResultChanged);
    super.dispose();
  }

  void _onResultChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final running = await KeepAliveService.isRunning();
    final permission = await KeepAliveService.notificationPermission();
    final ignoring = await KeepAliveService.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _running = running;
      _notification = permission;
      _ignoringBattery = ignoring;
      _loading = false;
    });
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    await action();
    if (!mounted) return;
    setState(() => _busy = false);
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('前台服务自检'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _busy || _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _statusCard(),
                const SizedBox(height: 16),
                _actions(),
                const SizedBox(height: 16),
                _helpCard(),
                const SizedBox(height: 16),
                _logCard(),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------------

  Widget _statusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '当前状态',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _row(
              '前台服务',
              _running ? '运行中' : '未运行',
              ok: _running,
            ),
            _row(
              '通知权限',
              switch (_notification) {
                NotificationPermission.granted => '已授权',
                NotificationPermission.denied => '未授权（通知不会显示）',
                NotificationPermission.permanently_denied => '已被永久拒绝',
                null => '未知',
              },
              ok: _notification == NotificationPermission.granted,
            ),
            _row(
              '电池优化',
              _ignoringBattery ? '已豁免' : '未豁免（国产 ROM 上容易被杀）',
              ok: _ignoringBattery,
            ),
            const Divider(height: 24),
            _row('最近一次操作', KeepAliveService.lastResult.value, ok: null),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {required bool? ok}) {
    final color = ok == null
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : (ok ? Colors.green : Colors.orange);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: const TextStyle(color: Colors.grey)),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }

  Widget _actions() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(KeepAliveService.start, '已请求启动，看通知栏'),
                icon: const Icon(Icons.play_arrow),
                label: const Text('启动服务'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(KeepAliveService.stop, '已请求停止'),
                icon: const Icon(Icons.stop),
                label: const Text('停止服务'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _busy || _ignoringBattery
                ? null
                : () => _run(
                      KeepAliveService.requestBatteryOptimizationExemption,
                      '已打开电池优化设置',
                    ),
            icon: const Icon(Icons.battery_saver),
            label: const Text('申请电池优化豁免'),
          ),
        ),
      ],
    );
  }

  Widget _helpCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '这一页在验什么',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '前台服务的作用是：App 切后台或锁屏后，进程不被系统冻结/杀掉，'
              'WebSocket 还能继续收签到提醒和课堂题目。\n\n'
              '正常使用时它由课堂页自动管理（进课堂启动、离开停止），'
              '这里只是手动触发，方便没有课的时候也能验证。\n\n'
              '启动后拉下通知栏，应该能看到一条「课堂助手 / 正在保持 WebSocket 连接...」。'
              '没有通知不代表服务没跑（Android 13+ 未授权通知时通知会被隐藏），'
              '所以以「通知权限」那一行和下面的日志为准。',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            const Divider(height: 24),
            const Text(
              '命令行验证（更可靠）',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            SelectableText(
              'adb shell dumpsys activity services '
              'com.anerycoft.coursehelper',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logCard() {
    final logs = AppLogger.entries
        .where((e) => e.tag == KeepAliveService.tag)
        .toList();
    final tail = logs.length > 20 ? logs.sublist(logs.length - 20) : logs;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '前台服务日志（最近 ${tail.length} 条）',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (tail.isEmpty)
              const Text(
                '暂无。启动一次服务就会有了。',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              )
            else
              ...tail.reversed.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: SelectableText(
                    '${LogEntry.formatTime(e.time).substring(11)} '
                    '[${e.level.label}] ${e.message}',
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              '完整日志在「运行日志」页，搜 ForegroundService。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
