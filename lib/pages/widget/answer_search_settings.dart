/// 答案检索设置页
/// 配置 AI 检索源的 API 地址、密钥和模型名称，并支持一键连通测试
///
/// 关键设计：
/// 1. 地址只填到 base_url 也能用 —— 页面会实时显示「实际请求地址」，避免再出现少一段路径
/// 2. 思考模式可关（qwen3.8-flash 等混合思考模型默认开思考，慢约 3 倍）
/// 3. 测试连接会展示服务端原始报错，方便定位是 Key、地址还是模型的问题
library;
import 'package:flutter/material.dart';

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

    if (!mounted) return;
    setState(() {
      _enabled = config['enabled'] as bool;
      _disableThinking = config['disableThinking'] as bool;
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

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存')),
      );
    }
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
    setState(() => _isTesting = false);
    _showTestResult(result);
  }

  void _showTestResult(AIConnectionTestResult result) {
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(
              result.success ? Icons.check_circle : Icons.error_outline,
              color: result.success ? Colors.green : theme.colorScheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                result.success ? '连接成功' : '连接失败',
                style: TextStyle(
                  color: result.success
                      ? Colors.green
                      : theme.colorScheme.error,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                result.message,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
              if (result.latencyText.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '耗时：${result.latencyText}',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
              if (result.detail != null && result.detail!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    result.detail!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
              if (!result.success) ...[
                const SizedBox(height: 12),
                Text(
                  '排查建议：\n'
                  '· 地址只填到 /compatible-mode/v1 也可以，App 会自动补 /chat/completions\n'
                  '· 401：Key 无效，或 Key 与接口地域不匹配（北京的 Key 只能打北京的地址）\n'
                  '· 404：地址写错了，或接口路径不对\n'
                  '· 400：模型名称不存在，或该模型不支持当前参数\n'
                  '· 超时：把超时调大，或打开「关闭思考模式」\n'
                  '· 确认手机网络可以访问该服务（部分服务需代理）',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final previewUrl = AnswerSearchApi.normalizeApiUrl(_apiUrlController.text);
    final rawUrl = _apiUrlController.text.trim();
    final urlChanged = rawUrl.isNotEmpty && previewUrl != rawUrl;

    return Scaffold(
      appBar: AppBar(
        title: const Text('答案检索设置'),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 说明卡片
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.info_outline,
                                color: theme.colorScheme.primary),
                            const SizedBox(width: 8),
                            const Text(
                              '答案检索说明',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '1. 学习通题目：服务器直接返回正确答案标记，无需配置AI即可自动获取\n'
                          '2. 雨课堂题目：服务器不返回答案，需配置AI检索源\n'
                          '3. 检索结果仅供参考，不保证正确\n'
                          '4. AI检索结果仅展示当前题目，不会缓存到本地\n'
                          '5. 题目只写在PPT上时，会自动把课件图片发给多模态模型识别\n'
                          '6. 检索到答案后可一键填入选项，但不会自动提交，需你核对',
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 启用开关
                Card(
                  child: SwitchListTile(
                    title: const Text('启用AI答案检索'),
                    subtitle: const Text('为无法从服务器获取答案的题目提供AI检索'),
                    value: _enabled,
                    onChanged: (value) {
                      setState(() {
                        _enabled = value;
                      });
                    },
                  ),
                ),
                  const SizedBox(height: 16),

                  // [新增] 自动答题（雨课堂）
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text('自动检索答案'),
                          subtitle: const Text(
                              '进课堂后把整份 PPT 的题提前丢给 AI 检索（后台跑，不影响看课件）'),
                          value: AutoAnswerSetting.autoSearch.value,
                          onChanged: (v) {
                            AutoAnswerSetting.setAutoSearch(v);
                            setState(() {});
                          },
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          title: const Text('自动预选答案'),
                          subtitle: const Text(
                              '答案到手就填进作答区（只填不交，你能看到选了什么）'),
                          value: AutoAnswerSetting.autoSelect.value,
                          onChanged: (v) {
                            AutoAnswerSetting.setAutoSelect(v);
                            setState(() {});
                          },
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          title: const Text('自动提交'),
                          subtitle: const Text(
                              '老师发布题目后自动交卷。提交前有随机延迟，避免「秒交」特征'),
                          value: AutoAnswerSetting.autoSubmit.value,
                          onChanged: (v) {
                            AutoAnswerSetting.setAutoSubmit(v);
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // API 配置
                  if (_enabled) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'AI API 配置',
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                              const Spacer(),
                              if (_isTesting)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '支持 OpenAI 兼容的 Chat Completions API\n'
                            '（阿里云百炼 / DeepSeek / OpenAI / Moonshot / 本地Ollama 等）',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 14),

                          // [新增] 服务商预设
                          const Text(
                            '快速预设',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: AnswerSearchApi.presets.map((preset) {
                              final selected = _selectedPreset == preset.name;
                              return ChoiceChip(
                                label: Text(preset.name),
                                selected: selected,
                                onSelected: (_) => _applyPreset(preset),
                              );
                            }).toList(),
                          ),
                          // 预设提示
                          Builder(builder: (context) {
                            final matched = AnswerSearchApi.presets
                                .where((p) => p.name == _selectedPreset)
                                .toList();
                            if (matched.isEmpty ||
                                matched.first.hint.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                matched.first.hint,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            );
                          }),
                          const SizedBox(height: 16),

                          TextField(
                            controller: _apiUrlController,
                            decoration: const InputDecoration(
                              labelText: 'API 地址',
                              hintText:
                                  'https://xxx.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
                              helperText: '只填到 /v1 或 /compatible-mode/v1 即可，会自动补 /chat/completions',
                              helperMaxLines: 2,
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.link),
                            ),
                            keyboardType: TextInputType.url,
                          ),

                          // [新增] 实际请求地址实时预览
                          if (previewUrl.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: urlChanged
                                    ? Colors.green.withValues(alpha: 0.08)
                                    : theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(6),
                                border: urlChanged
                                    ? Border.all(
                                        color: Colors.green.withValues(alpha: 0.3))
                                    : null,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.send,
                                          size: 14,
                                          color: urlChanged
                                              ? Colors.green.shade700
                                              : theme.colorScheme.onSurfaceVariant),
                                      const SizedBox(width: 6),
                                      Text(
                                        urlChanged
                                            ? '实际请求地址（已自动补全）'
                                            : '实际请求地址',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: urlChanged
                                              ? Colors.green.shade700
                                              : theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  SelectableText(
                                    previewUrl,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),

                          TextField(
                            controller: _apiKeyController,
                            obscureText: !_showApiKey,
                            decoration: InputDecoration(
                              labelText: 'API Key',
                              hintText: 'sk-...',
                              helperText: 'Key 分地域，北京账号的 Key 只能用于北京的地址',
                              helperMaxLines: 2,
                              border: const OutlineInputBorder(),
                              prefixIcon: const Icon(Icons.key),
                              suffixIcon: IconButton(
                                icon: Icon(_showApiKey
                                    ? Icons.visibility_off
                                    : Icons.visibility),
                                onPressed: () {
                                  setState(() => _showApiKey = !_showApiKey);
                                },
                                tooltip: _showApiKey ? '隐藏' : '显示',
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),

                          TextField(
                            controller: _modelController,
                            decoration: const InputDecoration(
                              labelText: '模型名称',
                              hintText: 'qwen3.8-flash / deepseek-chat / gpt-4o-mini',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.model_training),
                            ),
                          ),
                          const SizedBox(height: 12),

                          // [新增] 超时设置
                          TextField(
                            controller: _timeoutController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '接收超时（秒）',
                              hintText: '180',
                              helperText: '思考型模型建议 180 秒以上',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.timer_outlined),
                            ),
                          ),

                          // [新增] 关闭思考模式
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('关闭思考模式'),
                            subtitle: const Text(
                              'qwen3.8 系列等混合思考模型默认开思考，耗时约为关闭后的 3 倍\n'
                              '（仅对 qwen3 / qvq 开头的模型生效，其他模型不受影响）',
                            ),
                            value: _disableThinking,
                            onChanged: (value) {
                              setState(() => _disableThinking = value);
                            },
                          ),
                          const SizedBox(height: 8),

                          // 连通测试按钮
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _isTesting ? null : _testConnection,
                              icon: _isTesting
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.wifi_tethering, size: 18),
                              label: Text(_isTesting ? '正在测试连接...' : '测试连接'),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // 保存按钮
                FilledButton(
                  onPressed: _saveConfig,
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text('保存设置', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ),
    );
  }
}
