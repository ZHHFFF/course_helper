/// 答案检索设置页
/// 配置 AI 检索源的 API 地址、密钥和模型名称，并支持一键连通测试
///
/// 关键设计：
/// 1. 地址只填到 base_url 也能用 —— 页面会实时显示「实际请求地址」，避免再出现少一段路径
/// 2. 思考模式可关（qwen3.8-flash 等混合思考模型默认开思考，慢约 3 倍）
/// 3. 测试连接会展示服务端原始报错，方便定位是 Key、地址还是模型的问题
library;
import 'package:flutter/material.dart';
// [新增] Miuix：整页按「所有规范都按 miuix」迁移
import 'package:flutter_miuix/miuix.dart';

import '../../api/answer_search.dart';
import '../../setting/auto_answer_setting.dart';

class AnswerSearchSettingsPage extends StatefulWidget {
  const AnswerSearchSettingsPage({super.key});

  @override
  State<AnswerSearchSettingsPage> createState() =>
      _AnswerSearchSettingsPageState();
}

class _AnswerSearchSettingsPageState extends State<AnswerSearchSettingsPage> {
  bool _enabled = false;
  final _apiUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();
  final _timeoutController = TextEditingController();
  bool _isLoading = true;

  /// 是否正在做连通测试
  bool _isTesting = false;

  /// 是否显示 API Key 明文
  bool _showApiKey = false;

  /// 关闭思考模式（默认开）
  bool _disableThinking = AnswerSearchApi.defaultDisableThinking;

  /// 当前选中的预设名（仅用于高亮按钮，不持久化）
  String _selectedPreset = '';

  /// 顶栏滚动折叠行为。必须**只创建一次**（它持有折叠进度，
  /// 在 `build()` 里 new 会导致折叠状态每帧被重置）。
  late final MiuixExitUntilCollapsedScrollBehavior _topBarBehavior =
      miuixScrollBehavior();

  /// 列表顶部留白（= 顶栏**展开态**高度），只记最大值、不跟随折叠回缩。
  double _topBarInset = 0;

  /// Miuix 的 Snackbar 走「host + state」模型，不是 `ScaffoldMessenger`。
  final MiuixSnackbarHostState _snackbarHost = MiuixSnackbarHostState();

  /// 连通测试结果弹窗。Miuix 对话框是**声明式**的（由 `show` 控制显隐），
  /// 所以不能用 `showDialog()` 命令式弹，必须常驻挂载 + 用状态驱动。
  AIConnectionTestResult? _testResult;
  bool _showTestDialog = false;

  @override
  void initState() {
    super.initState();
    // 地址变化时刷新「实际请求地址」预览
    _apiUrlController.addListener(_onUrlChanged);
    _loadConfig();
  }

  @override
  void dispose() {
    _apiUrlController.removeListener(_onUrlChanged);
    _apiUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _timeoutController.dispose();
    _snackbarHost.dispose();
    super.dispose();
  }

  void _onUrlChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadConfig() async {
    await AnswerSearchApi.initialize();
    await AutoAnswerSetting.ensureLoaded();
    final config = AnswerSearchApi.getAIConfig();

    // 先写输入框（会触发地址预览的 setState），再统一刷新状态
    _apiUrlController.text = config['apiUrl'] as String;
    _apiKeyController.text = config['apiKey'] as String;
    _modelController.text = config['model'] as String;
    _timeoutController.text = '${config['timeoutSeconds']}';

    // 反推当前配置命中了哪个预设，让芯片高亮跟上。
    //
    // 原来 `_selectedPreset` 只在 `_applyPreset()` 里赋值，进页面时恒为空串，
    // 表现是「5 个芯片全都不高亮」，看不出当前用的是哪一套。
    // 这里按**归一化后的地址**比对（预设里存的是简写地址，用户存的可能已带
    // /chat/completions），两边都归一化才能可靠命中。
    final currentUrl = AnswerSearchApi.normalizeApiUrl(
      config['apiUrl'] as String,
    );
    var matchedPreset = '';
    if (currentUrl.isNotEmpty) {
      for (final preset in AnswerSearchApi.presets) {
        if (preset.apiUrl.isEmpty) continue; // 「自定义」没有地址，不参与匹配
        if (AnswerSearchApi.normalizeApiUrl(preset.apiUrl) == currentUrl) {
          matchedPreset = preset.name;
          break;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _enabled = config['enabled'] as bool;
      _disableThinking = config['disableThinking'] as bool;
      _selectedPreset = matchedPreset;
      _isLoading = false;
    });
  }

  int get _timeoutSeconds {
    final value = int.tryParse(_timeoutController.text.trim()) ?? 0;
    if (value <= 0) return AnswerSearchApi.defaultTimeoutSeconds;
    if (value > 600) return 600;
    return value;
  }

  Future<void> _saveConfig() async {
    await AnswerSearchApi.saveAIConfig(
      enabled: _enabled,
      apiUrl: _apiUrlController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim(),
      disableThinking: _disableThinking,
      timeoutSeconds: _timeoutSeconds,
    );

    if (mounted) _snackbarHost.showSnackbar('设置已保存');
  }

  /// 应用服务商预设
  void _applyPreset(AIProviderPreset preset) {
    setState(() {
      _selectedPreset = preset.name;
      if (preset.apiUrl.isNotEmpty) {
        _apiUrlController.text = preset.apiUrl;
      }
      if (preset.model.isNotEmpty) {
        _modelController.text = preset.model;
      }
    });
  }

  /// 连通测试：用当前输入框里的内容直接发一条最小请求
  Future<void> _testConnection() async {
    if (_isTesting) return;

    setState(() => _isTesting = true);

    var result = const AIConnectionTestResult(
      success: false,
      message: '测试未完成',
    );
    try {
      result = await AnswerSearchApi.testConnection(
        apiUrl: _apiUrlController.text,
        apiKey: _apiKeyController.text,
        model: _modelController.text,
        disableThinking: _disableThinking,
        timeoutSeconds: _timeoutSeconds,
      );
    } catch (e) {
      result = AIConnectionTestResult(
        success: false,
        message: '测试异常：$e',
      );
    }

    if (!mounted) return;
    setState(() {
      _isTesting = false;
      _testResult = result;
      _showTestDialog = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;

    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: '答案检索设置',
        largeTitle: '答案检索设置',
        blurred: true,
        // 不传 `blurRadius` / `blurTintAlpha` → 用库默认（24 / 0.55），
        // 与底栏是同一套玻璃口径（见 miuix_glass_spec.dart）。
        scrollBehavior: _topBarBehavior,
        // ⚠️ `MiuixTopAppBar` **没有** `onBack`，返回键要用 `navigationIcon`
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Icon(Icons.arrow_back_ios_new, size: 20),
        ),
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
        return Stack(
          children: [
            _isLoading
                ? const Center(child: MiuixCircularProgressIndicator())
                : MiuixScrollBehaviorListener(
                    behavior: _topBarBehavior,
                    child: ListView(
                      padding: EdgeInsets.only(
                        top: _topBarInset,
                        left: 16,
                        right: 16,
                        bottom: contentPadding.bottom + 16,
                      ),
                      children: [
                        _buildIntroCard(context, colors),
                        const SizedBox(height: 12),
                        _buildEnableCard(context),
                        const SizedBox(height: 12),
                        _buildAutoAnswerCard(context),
                        const SizedBox(height: 12),
                        if (_enabled) ...[
                          _buildApiConfigCard(context, colors),
                          const SizedBox(height: 12),
                        ],
                        _buildSaveButton(context),
                      ],
                    ),
                  ),
            // 结果弹窗常驻挂载（用 `show` 控制显隐），退场动画才能播完
            _buildTestResultDialog(context, colors),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------

  Widget _buildIntroCard(BuildContext context, MiuixColors colors) {
    return MiuixCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: colors.primary),
              const SizedBox(width: 8),
              MiuixText('答案检索说明', fontSize: 16, fontWeight: FontWeight.bold),
            ],
          ),
          const SizedBox(height: 12),
          MiuixText(
            '1. 学习通题目：服务器直接返回正确答案标记，无需配置AI即可自动获取\n'
            '2. 雨课堂题目：服务器不返回答案，需配置AI检索源\n'
            '3. 检索结果仅供参考，不保证正确\n'
            '4. AI检索结果仅展示当前题目，不会缓存到本地\n'
            '5. 题目只写在PPT上时，会自动把课件图片发给多模态模型识别\n'
            '6. 检索到答案后可一键填入选项，但不会自动提交，需你核对',
            fontSize: 13,
            color: colors.onSurfaceVariantSummary,
          ),
        ],
      ),
    );
  }

  Widget _buildEnableCard(BuildContext context) {
    // ⚠️ 卡片 `insideMargin` 归零，让 preference 自己的内边距生效，
    // 否则会出现「卡片 16 + 行 16 = 32」的双重缩进
    return MiuixCard(
      insideMargin: EdgeInsets.zero,
      child: MiuixSwitchPreference(
        title: '启用AI答案检索',
        summary: '为无法从服务器获取答案的题目提供AI检索',
        value: _enabled,
        onChanged: (value) => setState(() => _enabled = value),
      ),
    );
  }

  Widget _buildAutoAnswerCard(BuildContext context) {
    return MiuixCard(
      insideMargin: EdgeInsets.zero,
      child: Column(
        children: [
          MiuixSwitchPreference(
            title: '自动检索答案',
            summary: '进课堂后把整份 PPT 的题提前丢给 AI 检索（后台跑，不影响看课件）',
            value: AutoAnswerSetting.autoSearch.value,
            onChanged: (v) {
              AutoAnswerSetting.setAutoSearch(v);
              setState(() {});
            },
          ),
          const MiuixHorizontalDivider(),
          MiuixSwitchPreference(
            title: '自动预选答案',
            summary: '答案到手就填进作答区（只填不交，你能看到选了什么）',
            value: AutoAnswerSetting.autoSelect.value,
            onChanged: (v) {
              AutoAnswerSetting.setAutoSelect(v);
              setState(() {});
            },
          ),
          const MiuixHorizontalDivider(),
          MiuixSwitchPreference(
            title: '自动提交',
            summary: '老师发布题目后自动交卷。提交前有随机延迟，避免「秒交」特征',
            value: AutoAnswerSetting.autoSubmit.value,
            onChanged: (v) {
              AutoAnswerSetting.setAutoSubmit(v);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  /// 单个服务商预设芯片。
  ///
  /// Miuix 没有独立的 Chip 组件，用 `MiuixButton` 收窄几何 + 胶囊圆角复刻：
  /// - `minWidth: 0` / `minHeight: 32` —— 摆脱按钮默认的 58×40，改为**贴内容定宽**，
  ///   否则短名字（如「自定义」）会被撑成 58dp，长名字反而更挤
  /// - `insideMargin` 收到 14/6 —— 比按钮默认的 16/13 紧凑一档，接近 Chip 观感
  /// - 选中态用 `buttonColorsPrimary`（主色蓝底），未选中用 `buttonColors`（次级底），
  ///   文字色由 `MiuixButton` 内部注入的 `MiuixContentColor` 自动跟随，
  ///   所以 `MiuixText` 不用显式给 `color`
  Widget _buildPresetChip(BuildContext context, AIProviderPreset preset) {
    final selected = preset.name == _selectedPreset;
    return MiuixButton(
      onPressed: () => _applyPreset(preset),
      minWidth: 0,
      minHeight: 32,
      cornerRadius: 16,
      insideMargin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      colors: selected
          ? MiuixButtonDefaults.buttonColorsPrimary(context)
          : MiuixButtonDefaults.buttonColors(context),
      child: MiuixText(preset.name, fontSize: 13),
    );
  }

  Widget _buildApiConfigCard(BuildContext context, MiuixColors colors) {
    final textStyles = MiuixTheme.of(context).textStyles;
    final previewUrl = AnswerSearchApi.normalizeApiUrl(_apiUrlController.text);
    final rawUrl = _apiUrlController.text.trim();
    final urlChanged = rawUrl.isNotEmpty && previewUrl != rawUrl;

    return MiuixCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MiuixText('AI API 配置', fontSize: 16, fontWeight: FontWeight.bold),
              const Spacer(),
              if (_isTesting)
                const MiuixCircularProgressIndicator(size: 16, strokeWidth: 2),
            ],
          ),
          const SizedBox(height: 8),
          MiuixText(
            '支持 OpenAI 兼容的 Chat Completions API\n'
            '（阿里云百炼 / DeepSeek / OpenAI / Moonshot / 本地Ollama 等）',
            fontSize: 12,
            color: colors.onSurfaceVariantSummary,
          ),
          const SizedBox(height: 14),

          // 服务商预设。原来是 `ChoiceChip` 的 Wrap。
          //
          // ⚠️ 这里**不能**用 `MiuixTabRow`。它是「短标签等宽分段控件」：
          // 内部 `_calculateTabWidth` 先把可用宽按标签数均分（297/5 ≈ 52dp），
          // 小于 `minWidth`(76) 时取 76，再减掉 `itemHorizontalPadding`(12×2)，
          // 文字区只剩 52dp —— 5 个汉字直接被 ellipsis 截成「阿里...」；
          // 且总宽 76×5+36 = 416 > 297，第 5 个被推到屏外只能横滑看到。
          // 预设名长短不一（3~7 字），本就该用「按内容定宽 + 自动换行」的芯片。
          MiuixText('快速预设', fontSize: 13, fontWeight: FontWeight.w600),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in AnswerSearchApi.presets)
                _buildPresetChip(context, preset),
            ],
          ),
          // 预设提示
          if (_selectedPresetHint.isNotEmpty) ...[
            const SizedBox(height: 8),
            MiuixText(
              _selectedPresetHint,
              fontSize: 11,
              color: colors.onSurfaceVariantSummary,
            ),
          ],
          const SizedBox(height: 16),

          MiuixTextField(
            controller: _apiUrlController,
            label: 'API 地址',
            leadingIcon: const Icon(Icons.link),
            keyboardType: TextInputType.url,
            singleLine: true,
          ),
          const SizedBox(height: 6),
          MiuixText(
            '只填到 /v1 或 /compatible-mode/v1 即可，会自动补 /chat/completions',
            fontSize: 11,
            color: colors.onSurfaceVariantSummary,
          ),

          // 实际请求地址实时预览
          if (previewUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildUrlPreview(context, colors, previewUrl, urlChanged),
          ],
          const SizedBox(height: 14),

          MiuixTextField(
            controller: _apiKeyController,
            label: 'API Key',
            leadingIcon: const Icon(Icons.key),
            obscureText: !_showApiKey,
            singleLine: true,
            // ⚠️ `MiuixTextField.trailingIcon` 只是被放进 Row 的普通 Widget，
            // 不接管手势。这里放 `MiuixIconButton`（自带 MiuixPressable），
            // 它与输入框是**兄弟**关系、且绘制在更上层，命中测试时先入
            // 手势竞技场 → 点击能正常落到按钮上。
            trailingIcon: MiuixIconButton(
              onPressed: () => setState(() => _showApiKey = !_showApiKey),
              child: Icon(
                _showApiKey ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
          const SizedBox(height: 6),
          MiuixText(
            'Key 分地域，北京账号的 Key 只能用于北京的地址',
            fontSize: 11,
            color: colors.onSurfaceVariantSummary,
          ),
          const SizedBox(height: 14),

          MiuixTextField(
            controller: _modelController,
            label: '模型名称',
            leadingIcon: const Icon(Icons.model_training),
            singleLine: true,
          ),
          const SizedBox(height: 14),

          MiuixTextField(
            controller: _timeoutController,
            label: '接收超时（秒）',
            leadingIcon: const Icon(Icons.timer_outlined),
            keyboardType: TextInputType.number,
            singleLine: true,
          ),
          const SizedBox(height: 6),
          MiuixText(
            '思考型模型建议 180 秒以上',
            fontSize: 11,
            color: colors.onSurfaceVariantSummary,
          ),
          const SizedBox(height: 8),

          MiuixSwitchPreference(
            insideMargin: EdgeInsets.zero,
            title: '关闭思考模式',
            summary: 'qwen3.8 系列等混合思考模型默认开思考，耗时约为关闭后的 3 倍\n'
                '（仅对 qwen3 / qvq 开头的模型生效，其他模型不受影响）',
            value: _disableThinking,
            onChanged: (value) => setState(() => _disableThinking = value),
          ),
          const SizedBox(height: 8),

          // 连通测试按钮
          SizedBox(
            width: double.infinity,
            child: MiuixButton(
              onPressed: _isTesting ? null : _testConnection,
              colors: MiuixButtonDefaults.buttonColors(context),
              insideMargin: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isTesting)
                    const MiuixCircularProgressIndicator(
                      size: 16,
                      strokeWidth: 2,
                    )
                  else
                    const Icon(Icons.wifi_tethering, size: 18),
                  const SizedBox(width: 8),
                  MiuixText(
                    _isTesting ? '正在测试连接...' : '测试连接',
                    style: textStyles.button,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 当前预设的提示文案（没选预设或预设没写 hint 时返回空串）
  String get _selectedPresetHint {
    final matched = AnswerSearchApi.presets
        .where((p) => p.name == _selectedPreset)
        .toList();
    if (matched.isEmpty) return '';
    return matched.first.hint;
  }

  Widget _buildUrlPreview(
    BuildContext context,
    MiuixColors colors,
    String previewUrl,
    bool urlChanged,
  ) {
    // 「已自动补全」用绿色强调；没补全就是普通信息条
    final accent = urlChanged ? Colors.green.shade400 : colors.onSurfaceVariantSummary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: urlChanged
            ? Colors.green.withValues(alpha: 0.08)
            : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: urlChanged
            ? Border.all(color: Colors.green.withValues(alpha: 0.3))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.send, size: 14, color: accent),
              const SizedBox(width: 6),
              MiuixText(
                urlChanged ? '实际请求地址（已自动补全）' : '实际请求地址',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 地址要能长按选中复制 —— 保留 Material 的 `SelectableText`
          SelectableText(previewUrl, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildSaveButton(BuildContext context) {
    final textStyles = MiuixTheme.of(context).textStyles;
    return SizedBox(
      width: double.infinity,
      child: MiuixButton(
        onPressed: _saveConfig,
        colors: MiuixButtonDefaults.buttonColorsPrimary(context),
        insideMargin: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: MiuixText('保存设置', fontSize: 16, style: textStyles.button),
      ),
    );
  }

  Widget _buildTestResultDialog(BuildContext context, MiuixColors colors) {
    final result = _testResult;
    final success = result?.success ?? false;
    final accent = success ? Colors.green : colors.error;

    return MiuixOverlayDialog(
      show: _showTestDialog,
      onDismissRequest: () => setState(() => _showTestDialog = false),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  success ? Icons.check_circle : Icons.error_outline,
                  color: accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: MiuixText(
                    success ? '连接成功' : '连接失败',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            MiuixText(
              result?.message ?? '',
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
            if (result != null && result.latencyText.isNotEmpty) ...[
              const SizedBox(height: 6),
              MiuixText(
                '耗时：${result.latencyText}',
                fontSize: 12,
                color: colors.onSurfaceVariantSummary,
              ),
            ],
            if (result?.detail != null && result!.detail!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  result.detail!,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
            if (!success && result != null) ...[
              const SizedBox(height: 12),
              MiuixText(
                '排查建议：\n'
                '· 地址只填到 /compatible-mode/v1 也可以，App 会自动补 /chat/completions\n'
                '· 401：Key 无效，或 Key 与接口地域不匹配（北京的 Key 只能打北京的地址）\n'
                '· 404：地址写错了，或接口路径不对\n'
                '· 400：模型名称不存在，或该模型不支持当前参数\n'
                '· 超时：把超时调大，或打开「关闭思考模式」\n'
                '· 确认手机网络可以访问该服务（部分服务需代理）',
                fontSize: 12,
                color: colors.onSurfaceVariantSummary,
              ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                MiuixTextButton(
                  '确定',
                  onPressed: () => setState(() => _showTestDialog = false),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
