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
// [新增] Miuix：整页按「所有规范都按 miuix」迁移
import 'package:flutter_miuix/miuix.dart';
import 'miuix_glass_spec.dart';

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
        title: 'PPT 缓存',
        largeTitle: 'PPT 缓存',
        blurred: true,
        // KernelSU `BlurredBar` 口径（见 miuix_glass_spec.dart）：
        // blurRadius 25 → sigma 11.25、色调 surface @ .87 —— 磨砂到几乎实心，
        // 只透出一点点底纹（HyperOS 顶栏就是这个观感）。
        blurRadius: MiuixGlassSpec.topBarBlurRadius,
        blurTintAlpha: MiuixGlassSpec.topBarTintAlpha,
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
                '自动清理规则',
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ],
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
