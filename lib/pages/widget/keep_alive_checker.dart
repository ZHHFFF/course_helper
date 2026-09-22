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
// [新增] Miuix：整页按「所有规范都按 miuix」迁移
import 'package:flutter_miuix/miuix.dart';

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

  /// 顶栏滚动折叠行为。必须**只创建一次**（它持有折叠进度，
  /// 在 `build()` 里 new 会导致折叠状态每帧被重置）。
  late final MiuixExitUntilCollapsedScrollBehavior _topBarBehavior =
      miuixScrollBehavior();

  /// 列表顶部留白（= 顶栏**展开态**高度），只记最大值、不跟随折叠回缩。
  double _topBarInset = 0;

  /// Miuix 的 Snackbar 走「host + state」模型，不是 `ScaffoldMessenger`。
  final MiuixSnackbarHostState _snackbarHost = MiuixSnackbarHostState();

  @override
  void initState() {
    super.initState();
    KeepAliveService.lastResult.addListener(_onResultChanged);
    _refresh();
  }

  @override
  void dispose() {
    KeepAliveService.lastResult.removeListener(_onResultChanged);
    _snackbarHost.dispose();
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
    _snackbarHost.showSnackbar(done);
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;

    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: '前台服务自检',
        largeTitle: '前台服务自检',
        blurred: true,
        scrollBehavior: _topBarBehavior,
        // ⚠️ `MiuixTopAppBar` **没有** `onBack`，返回键要用 `navigationIcon`
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Icon(Icons.arrow_back_ios_new, size: 20),
        ),
        actions: [
          MiuixIconButton(
            onPressed: _busy || _loading ? null : _refresh,
            child: const Icon(Icons.refresh),
          ),
        ],
      ),
      snackbarHost: MiuixSnackbarHost(
        state: _snackbarHost,
        blurSigma: 30,
        blurBackgroundAlpha: 0.55,
      ),
      content: (contentPadding) {
        // 只记最大高度，不跟随折叠回缩 —— 原因见 `_topBarInset` 的注释
        if (contentPadding.top > _topBarInset) {
          _topBarInset = contentPadding.top;
        }
        if (_loading) {
          return const Center(child: MiuixCircularProgressIndicator());
        }
        return MiuixScrollBehaviorListener(
          behavior: _topBarBehavior,
          child: ListView(
            padding: EdgeInsets.only(
              top: _topBarInset,
              left: 16,
              right: 16,
              bottom: contentPadding.bottom + 16,
            ),
            children: [
              _statusCard(context, colors),
              const SizedBox(height: 16),
              _actions(context),
              const SizedBox(height: 16),
              _helpCard(context, colors),
              const SizedBox(height: 16),
              _logCard(context, colors),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------

  Widget _statusCard(BuildContext context, MiuixColors colors) {
    // MiuixCard 自带 16dp 内边距（`insideMargin`），不需要再套 Padding
    return MiuixCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiuixText('当前状态', fontSize: 16, fontWeight: FontWeight.bold),
          const SizedBox(height: 12),
          _row(context, '前台服务', _running ? '运行中' : '未运行', ok: _running),
          _row(
            context,
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
            context,
            '电池优化',
            _ignoringBattery ? '已豁免' : '未豁免（国产 ROM 上容易被杀）',
            ok: _ignoringBattery,
          ),
          const MiuixHorizontalDivider(),
          const SizedBox(height: 12),
          _row(context, '最近一次操作', KeepAliveService.lastResult.value,
              ok: null),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value,
      {required bool? ok}) {
    final colors = MiuixTheme.of(context).colors;
    final color = ok == null
        ? colors.onSurfaceVariantSummary
        : (ok ? Colors.green : Colors.orange);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: MiuixText(
              label,
              color: colors.onSurfaceVariantSummary,
            ),
          ),
          Expanded(child: MiuixText(value, color: color)),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _button(
                context,
                icon: Icons.play_arrow,
                label: '启动服务',
                primary: true,
                onPressed: _busy
                    ? null
                    : () => _run(KeepAliveService.start, '已请求启动，看通知栏'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _button(
                context,
                icon: Icons.stop,
                label: '停止服务',
                onPressed: _busy ? null : () => _run(KeepAliveService.stop, '已请求停止'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: _button(
            context,
            icon: Icons.battery_saver,
            label: '申请电池优化豁免',
            onPressed: _busy || _ignoringBattery
                ? null
                : () => _run(
                      KeepAliveService.requestBatteryOptimizationExemption,
                      '已打开电池优化设置',
                    ),
          ),
        ),
      ],
    );
  }

  /// Miuix 按钮。默认贴内容尺寸（内部 `Center(widthFactor: 1)`），
  /// 放进 `Expanded` / `SizedBox(width: double.infinity)` 才会整宽。
  Widget _button(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool primary = false,
  }) {
    final textStyles = MiuixTheme.of(context).textStyles;
    return MiuixButton(
      onPressed: onPressed,
      colors: primary
          ? MiuixButtonDefaults.buttonColorsPrimary(context)
          : MiuixButtonDefaults.buttonColors(context),
      insideMargin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: MiuixText(
              label,
              style: textStyles.button,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _helpCard(BuildContext context, MiuixColors colors) {
    return MiuixCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiuixText('这一页在验什么', fontSize: 16, fontWeight: FontWeight.bold),
          const SizedBox(height: 8),
          MiuixText(
            '前台服务的作用是：App 切后台或锁屏后，进程不被系统冻结/杀掉，'
            'WebSocket 还能继续收签到提醒和课堂题目。\n\n'
            '正常使用时它由课堂页自动管理（进课堂启动、离开停止），'
            '这里只是手动触发，方便没有课的时候也能验证。\n\n'
            '启动后拉下通知栏，应该能看到一条「课堂助手 / 正在保持 WebSocket 连接...」。'
            '没有通知不代表服务没跑（Android 13+ 未授权通知时通知会被隐藏），'
            '所以以「通知权限」那一行和下面的日志为准。',
            fontSize: 13,
            // ⚠️ 行高要用 `height` 参数，别塞进 `style:`：
            // `style` 会整个替换掉基础样式（`MiuixTheme.textStyles.main`）
            height: 1.5,
          ),
          const MiuixHorizontalDivider(),
          const SizedBox(height: 12),
          MiuixText('命令行验证（更可靠）', fontWeight: FontWeight.bold),
          const SizedBox(height: 6),
          // 命令要能长按选中复制 —— Miuix 没有可选中文本组件，
          // 保留 Material 的 `SelectableText`
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
    );
  }

  Widget _logCard(BuildContext context, MiuixColors colors) {
    final logs =
        AppLogger.entries.where((e) => e.tag == KeepAliveService.tag).toList();
    final tail = logs.length > 20 ? logs.sublist(logs.length - 20) : logs;

    return MiuixCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiuixText(
            '前台服务日志（最近 ${tail.length} 条）',
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
          const SizedBox(height: 8),
          if (tail.isEmpty)
            MiuixText(
              '暂无。启动一次服务就会有了。',
              fontSize: 13,
              color: colors.onSurfaceVariantSummary,
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
          MiuixText(
            '完整日志在「运行日志」页，搜 ForegroundService。',
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
        ],
      ),
    );
  }
}
