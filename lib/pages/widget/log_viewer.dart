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
// [新增] Miuix：整页按「所有规范都按 miuix」迁移
import 'package:flutter_miuix/miuix.dart';

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

  /// 顶栏滚动折叠行为。必须**只创建一次**（它持有折叠进度，
  /// 在 `build()` 里 new 会导致折叠状态每帧被重置）。
  late final MiuixExitUntilCollapsedScrollBehavior _topBarBehavior =
      miuixScrollBehavior();

  /// 列表顶部留白（= 顶栏**展开态**高度），只记最大值、不跟随折叠回缩。
  double _topBarInset = 0;

  /// Miuix 的 Snackbar 走「host + state」模型，不是 `ScaffoldMessenger`。
  final MiuixSnackbarHostState _snackbarHost = MiuixSnackbarHostState();

  /// 「清空日志」确认框（Miuix 对话框是声明式的，必须常驻挂载）。
  bool _showClearDialog = false;

  @override
  void initState() {
    super.initState();
    AppLogger.revision.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    AppLogger.revision.removeListener(_onLogChanged);
    _snackbarHost.dispose();
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

  Color _levelColor(LogLevel level, MiuixColors colors) {
    switch (level) {
      case LogLevel.debug:
        return colors.onSurfaceVariantSummary;
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.warn:
        return Colors.orange;
      case LogLevel.error:
        return colors.error;
    }
  }

  Future<void> _copyLine(LogEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.line));
    if (!mounted) return;
    _snackbarHost.showSnackbar('该条日志已复制');
  }

  Future<void> _copyAll() async {
    final text = AppLogger.exportText(minLevel: _minLevel);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _snackbarHost.showSnackbar('全部日志已复制到剪贴板');
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
        _snackbarHost.showSnackbar('导出文件失败，可改用「复制全部」');
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
      _snackbarHost.showSnackbar('导出失败：$e，可改用「复制全部」');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 真正执行清空（由确认框的「清空」按钮调用）。
  Future<void> _doClear() async {
    setState(() => _showClearDialog = false);
    await AppLogger.clear();
    if (!mounted) return;
    _snackbarHost.showSnackbar('日志已清空');
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final list = AppLogger.filtered(_minLevel);

    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: '运行日志',
        largeTitle: '运行日志',
        blurred: true,
        // 不传 `blurRadius` / `blurTintAlpha` → 用库默认（24 / 0.55），
        // 与底栏是同一套玻璃口径（见 miuix_glass_spec.dart）。
        scrollBehavior: _topBarBehavior,
        // ⚠️ `MiuixTopAppBar` **没有** `onBack`，返回键要用 `navigationIcon`
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Icon(Icons.arrow_back_ios_new, size: 20),
        ),
        actions: [
          MiuixIconButton(
            onPressed: () => setState(() => _showClearDialog = true),
            child: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      // 底部操作条交给脚手架，contentPadding.bottom 会自动让开它
      bottomBar: _buildBottomBar(context, colors),
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
        return Stack(
          children: [
            Padding(
              // 顶部让开顶栏、底部让开操作条。两者都由脚手架算好。
              padding: EdgeInsets.only(
                top: _topBarInset,
                bottom: contentPadding.bottom,
              ),
              child: Column(
                children: [
                  _buildInfoCard(context, colors),
                  _buildFilters(context),
                  const MiuixHorizontalDivider(),
                  Expanded(
                    child: list.isEmpty
                        ? Center(
                            child: MiuixText(
                              '暂无日志',
                              color: colors.onSurfaceVariantSummary,
                            ),
                          )
                        : MiuixScrollBehaviorListener(
                            behavior: _topBarBehavior,
                            child: ListView.builder(
                              reverse: true,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: list.length,
                              itemBuilder: (context, index) {
                                // reverse: true → index 0 在最底部，所以从末尾取
                                final entry = list[list.length - 1 - index];
                                return _buildRow(entry, colors);
                              },
                            ),
                          ),
                  ),
                ],
              ),
            ),
            // 确认框常驻挂载（用 `show` 控制显隐），退场动画才能播完
            _buildClearDialog(context, colors),
          ],
        );
      },
    );
  }

  Widget _buildClearDialog(BuildContext context, MiuixColors colors) {
    final textStyles = MiuixTheme.of(context).textStyles;

    return MiuixOverlayDialog(
      show: _showClearDialog,
      title: '清空日志',
      summary: '将删除内存与磁盘上的全部日志，确定吗？',
      onDismissRequest: () => setState(() => _showClearDialog = false),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              MiuixTextButton(
                '取消',
                onPressed: () => setState(() => _showClearDialog = false),
              ),
              const SizedBox(width: 12),
              MiuixButton(
                onPressed: _doClear,
                colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                child: MiuixText('清空', style: textStyles.button),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context, MiuixColors colors) {
    final path = AppLogger.currentFilePath ?? '（未落盘）';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: MiuixCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.receipt_long,
                  size: 16,
                  color: colors.onSurfaceVariantSummary,
                ),
                const SizedBox(width: 6),
                MiuixText(
                  '内存 ${AppLogger.entryCount} 条 · '
                  '当前文件 ${_formatBytes(AppLogger.currentFileBytes)}',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 路径要能长按选中复制 —— Miuix 没有可选中文本组件，
            // 这里保留 Material 的 `SelectableText`（靠 main.dart 补的
            // 那层透明 `Material` 正常渲染，不需要额外 Material 祖先）
            SelectableText(
              path,
              style: TextStyle(
                fontSize: 10,
                color: colors.onSurfaceVariantSummary,
              ),
            ),
            const SizedBox(height: 4),
            MiuixText(
              '最多保留 ${AppLogger.maxEntries} 条 / 单文件 '
              '${_formatBytes(AppLogger.maxFileBytes)} / 保留 ${AppLogger.keepDays} 天'
              ' · API Key 已自动脱敏',
              fontSize: 10,
              color: colors.onSurfaceVariantSummary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilters(BuildContext context) {
    final options = <(String, LogLevel?)>[
      ('全部', null),
      ('警告及以上', LogLevel.warn),
      ('仅错误', LogLevel.error),
    ];
    final selectedIndex = options.indexWhere((o) => o.$2 == _minLevel);

    // 原来是三个 `ChoiceChip`，换成 Miuix 的标签栏 `MiuixTabRow`
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: MiuixTabRow(
        tabs: [for (final option in options) option.$1],
        selectedTabIndex: selectedIndex < 0 ? 0 : selectedIndex,
        onTabSelected: (index) => setState(() => _minLevel = options[index].$2),
      ),
    );
  }

  Widget _buildRow(LogEntry entry, MiuixColors colors) {
    final color = _levelColor(entry.level, colors);

    // ⚠️ 原来这里是 `InkWell(onLongPress:)`。Miuix 的 `MiuixPressable` 才是
    // 本体系的按压组件，但它的 `onLongPress` 被 `enabled` 把关，而
    // `enabled` 又要求 `onPressed != null` —— 所以这里给一个空 `onPressed`
    // 把开关打开，只把长按接出去（短按无行为，与原来一致）。
    return MiuixPressable(
      onPressed: () {},
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
                          color: colors.onSurfaceVariantSummary,
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
                            color: colors.onSurfaceVariantSummary,
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

  Widget _buildBottomBar(BuildContext context, MiuixColors colors) {
    final textStyles = MiuixTheme.of(context).textStyles;

    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        // 让开手势条：这里必须用 `viewPaddingOf`（真实安全区）。
        // 用 `paddingOf` 会被键盘等 `viewInsets` 干扰，且历史上还被
        // main.dart 全局的底栏补偿污染过（现已下沉到首页路由）。
        8 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.dividerLine)),
      ),
      child: Row(
        children: [
          Expanded(
            child: MiuixButton(
              onPressed: _copyAll,
              colors: MiuixButtonDefaults.buttonColors(context),
              insideMargin: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.copy_all, size: 18),
                  const SizedBox(width: 8),
                  MiuixText('复制全部', style: textStyles.button),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: MiuixButton(
              onPressed: _exporting ? null : _export,
              colors: MiuixButtonDefaults.buttonColorsPrimary(context),
              insideMargin: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_exporting)
                    const MiuixCircularProgressIndicator(
                      size: 16,
                      strokeWidth: 2,
                    )
                  else
                    const Icon(Icons.ios_share, size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: MiuixText(
                      // 标签必须短。实测该按钮内容区约 195dp，减去图标 18 + 间距 8
                      // 只剩约 169dp 给文字，而「导出日志（分享/发送）」11 个汉字
                      // 需要约 169dp —— 刚好差一点，会被 ellipsis 吃成
                      // 「导出日志（分享/发...」。分享语义已由 ios_share 图标表达，
                      // 标签收到 4 个字，留足余量。
                      _exporting ? '正在导出...' : '导出日志',
                      style: textStyles.button,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
