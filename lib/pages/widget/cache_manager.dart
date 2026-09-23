/// 课件缓存管理页
///
/// 展示缓存占用，并提供手动清理入口。
///
/// ⚠️ 2026-09-22 用户拍板「取消自动删除 ppt」：原先进课堂时会自动跑一遍
/// `CourseCache.cleanup()`（结束标记超 24h 删 / 7 天无写入删），那行已从
/// `presentation.dart` 里删除。现在**只有两种删除途径**：
///   1. 底栏「课件」Tab 里逐份删除（精确到某一份课件）
///   2. 本页的「立即清理」（按下面的规则批量清）与「清空全部」
///
/// `CourseCache.cleanup()` 本身保留 —— 它就是「立即清理」按钮的实现，
/// 只是不再自动触发。
///
/// [改名] 页标题从「PPT 缓存」改成「课件缓存」，与底栏的「课件」Tab 统一用词。
library;

import 'package:flutter/material.dart';
// [新增] Miuix：整页按「所有规范都按 miuix」迁移
import 'package:flutter_miuix/miuix.dart';

import '../../cache/answer_cache.dart';
import '../../cache/ppt_cache.dart';
import '../../cache/course_cache.dart';
// [新增] 卡片内容的标准内边距（MiuixCard 默认是 0，裸用会贴边）
import 'miuix_card_metrics.dart';

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

  /// 顶栏滚动折叠行为。必须**只创建一次**（它持有折叠进度，
  /// 在 `build()` 里 new 会导致折叠状态每帧被重置）。
  late final MiuixExitUntilCollapsedScrollBehavior _topBarBehavior =
      miuixScrollBehavior();

  /// 列表顶部留白（= 顶栏**展开态**高度），只记最大值、不跟随折叠回缩。
  /// 详见 `courses/list.dart` 里同名字段的注释（否则内容会「双重滚动」）。
  double _topBarInset = 0;

  /// Miuix 的 Snackbar 不是 `ScaffoldMessenger` 那一套，
  /// 而是「`MiuixSnackbarHostState` 持有队列 + `MiuixSnackbarHost` 负责渲染」。
  final MiuixSnackbarHostState _snackbarHost = MiuixSnackbarHostState();

  /// 「清空全部缓存」确认框。
  /// Miuix 的对话框是**声明式**的（由 `show` 控制显隐），
  /// 所以必须常驻挂载、不能用 `showDialog()` 命令式弹。
  bool _showClearDialog = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _snackbarHost.dispose();
    super.dispose();
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

    _snackbarHost.showSnackbar(report.isEmpty ? '没有需要清理的缓存' : '已清理：$report');
    await _refresh();
  }

  /// 真正执行清空（由确认框的「清空」按钮调用）。
  Future<void> _doClearAll() async {
    setState(() {
      _showClearDialog = false;
      _isBusy = true;
    });

    final bytes = await CourseCache.clearAll();
    // 内存里那层也要一起丢掉，否则界面还在展示已经删掉的答案
    PptCache.clearMemory();
    AnswerCache.clearMemory();
    if (!mounted) return;
    setState(() => _isBusy = false);

    _snackbarHost.showSnackbar('已释放 ${_formatBytes(bytes)}');
    await _refresh();
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;

    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        // [改名] 「PPT 缓存」→「课件缓存」：与底栏的「课件」Tab 用同一个词。
        // 用户原话「不叫 ppt 缓存了」—— 他面对的是「这门课的课件」，
        // 缓存只是实现细节；而且本页也确实是管理缓存用的，两者不冲突。
        title: '课件缓存',
        largeTitle: '课件缓存',
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
            // 传 null 即为禁用态（`effectiveEnabled = enabled && onPressed != null`）
            onPressed: _isBusy ? null : _refresh,
            child: const Icon(Icons.refresh),
          ),
        ],
      ),
      // 玻璃质感的 Snackbar（blurSigma 需要背景有内容才看得出来）
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
            MiuixScrollBehaviorListener(
              behavior: _topBarBehavior,
              child: _isLoading
                  ? const Center(child: MiuixCircularProgressIndicator())
                  : ListView(
                      padding: EdgeInsets.only(
                        top: _topBarInset,
                        left: 16,
                        right: 16,
                        bottom: contentPadding.bottom + 16,
                      ),
                      children: [
                        _buildOverviewCard(context),
                        const SizedBox(height: 12),
                        _buildPolicyCard(context),
                        const SizedBox(height: 24),
                        _buildActionButton(
                          context,
                          icon: Icons.cleaning_services_outlined,
                          label: '清理过期缓存',
                          onPressed: _isBusy ? null : _runCleanup,
                        ),
                        const SizedBox(height: 12),
                        _buildActionButton(
                          context,
                          icon: Icons.delete_outline,
                          label: '清空全部缓存',
                          // 清空后缓存没了，再点也没意义 → 禁用
                          onPressed: _isBusy || _lessons == 0
                              ? null
                              : () => setState(() => _showClearDialog = true),
                          // 危险操作用 Miuix 的 error 色文字
                          contentColor: colors.error,
                        ),
                        if (_isBusy) ...[
                          const SizedBox(height: 24),
                          const Center(
                            child: MiuixCircularProgressIndicator(size: 20),
                          ),
                        ],
                      ],
                    ),
            ),
            // 确认框常驻挂载（用 `show` 控制显隐），退场动画才能播完
            _buildClearDialog(context),
          ],
        );
      },
    );
  }

  /// 整宽按钮。`MiuixButton` 默认贴内容尺寸（内部是
  /// `Center(widthFactor: 1)`），要整宽就得外面给一个紧宽度约束。
  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    Color? contentColor,
  }) {
    final colors = MiuixTheme.of(context).colors;
    final textStyles = MiuixTheme.of(context).textStyles;
    final effectiveColor =
        contentColor ?? MiuixButtonDefaults.buttonColors(context).contentColor;

    return SizedBox(
      width: double.infinity,
      child: MiuixButton(
        onPressed: onPressed,
        colors: MiuixButtonColors(
          color: colors.secondaryVariant,
          disabledColor: colors.disabledSecondaryVariant,
          contentColor: effectiveColor,
          disabledContentColor: colors.disabledOnSecondaryVariant,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            MiuixText(label, style: textStyles.button),
          ],
        ),
      ),
    );
  }

  Widget _buildClearDialog(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final textStyles = MiuixTheme.of(context).textStyles;

    return MiuixOverlayDialog(
      show: _showClearDialog,
      title: '清空全部缓存',
      summary: '会删掉所有课程已缓存的 PPT 元数据、课件图片和题目答案。',
      onDismissRequest: () => setState(() => _showClearDialog = false),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          MiuixText(
            '下次进课堂会重新下载和重新检索，不影响账号和设置。',
            style: textStyles.body1,
          ),
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
                onPressed: _doClearAll,
                // 破坏性主按钮用 error 底 + onError 字
                colors: MiuixButtonColors(
                  color: colors.error,
                  disabledColor: colors.disabledSecondary,
                  contentColor: colors.onError,
                  disabledContentColor: colors.disabledOnSecondary,
                ),
                child: MiuixText('清空', style: textStyles.button),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewCard(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;

    return MiuixCard(
      // MiuixCard 默认无内边距（= 0），不显式给会让「当前占用」贴到卡片边缘
      insideMargin: kMiuixCardInsideMargin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiuixText(
            '当前占用',
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
          const SizedBox(height: 6),
          MiuixText(
            _formatBytes(_bytes),
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
          const SizedBox(height: 4),
          MiuixText(
            _lessons == 0 ? '还没有缓存任何课程' : '共 $_lessons 门课的缓存',
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
        ],
      ),
    );
  }

  Widget _buildPolicyCard(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final textStyles = MiuixTheme.of(context).textStyles;

    return MiuixCard(
      // 同上：裸 MiuixCard 默认无内边距
      insideMargin: kMiuixCardInsideMargin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: colors.onSurfaceVariantSummary,
              ),
              const SizedBox(width: 6),
              MiuixText(
                '手动清理规则',
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ],
          ),
          const SizedBox(height: 6),
          MiuixText(
            '2026-09-22 起已取消自动删除：下面这些规则只在点「立即清理」时才生效，'
            '平时不会自动删掉任何课件。想精确删某一份，去底栏「课件」Tab。',
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
          const SizedBox(height: 10),
          _buildRule(
            context,
            '课程结束后 ${CourseCache.finishGrace.inHours} 小时',
            '离开课堂会打上结束标记，再留一段时间防止下课还想回去翻两眼',
            textStyles,
            colors,
          ),
          const SizedBox(height: 8),
          _buildRule(
            context,
            '${CourseCache.idleKeep.inDays} 天没有使用',
            '按目录内最后一次写入时间算',
            textStyles,
            colors,
          ),
          const SizedBox(height: 8),
          _buildRule(
            context,
            '按课程隔离',
            '每节课一个目录，互不影响；清理时整门课一起清',
            textStyles,
            colors,
          ),
        ],
      ),
    );
  }

  Widget _buildRule(
    BuildContext context,
    String title,
    String detail,
    MiuixTextStyles textStyles,
    MiuixColors colors,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: colors.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MiuixText(title, fontSize: 13),
              MiuixText(
                detail,
                fontSize: 11,
                color: colors.onSurfaceVariantSummary,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
