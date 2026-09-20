/// 答案检索设置页
/// 配置 AI 检索源的 API 地址、密钥和模型名称，并支持一键连通测试
import 'package:flutter/material.dart';

import '../../api/answer_search.dart';

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
  bool _isLoading = true;

  /// 是否正在做连通测试
  bool _isTesting = false;

  /// 是否显示 API Key 明文
  bool _showApiKey = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    await AnswerSearchApi.initialize();
    final config = AnswerSearchApi.getAIConfig();
    setState(() {
      _enabled = config['enabled'] as bool;
      _apiUrlController.text = config['apiUrl'] as String;
      _apiKeyController.text = config['apiKey'] as String;
      _modelController.text = config['model'] as String;
      _isLoading = false;
    });
  }

  Future<void> _saveConfig() async {
    await AnswerSearchApi.saveAIConfig(
      enabled: _enabled,
      apiUrl: _apiUrlController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim(),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存')),
      );
    }
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
                  '· 确认 API 地址填的是完整的 chat/completions 接口\n'
                  '· 确认 API Key 没有多余空格或引号\n'
                  '· 确认模型名称在该服务商下真实存在\n'
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('答案检索设置'),
        backgroundColor: Theme.of(context).colorScheme.primary,
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
                                color: Theme.of(context).colorScheme.primary),
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
                          '   （需使用支持识图的模型，如 gpt-4o / qwen-vl-max / glm-4v）',
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
                            '（OpenAI / DeepSeek / 通义千问 / Moonshot / 本地Ollama 等）',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _apiUrlController,
                            decoration: const InputDecoration(
                              labelText: 'API 地址',
                              hintText: 'https://api.openai.com/v1/chat/completions',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.link),
                            ),
                            keyboardType: TextInputType.url,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _apiKeyController,
                            obscureText: !_showApiKey,
                            decoration: InputDecoration(
                              labelText: 'API Key',
                              hintText: 'sk-...',
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
                              hintText: 'gpt-3.5-turbo / deepseek-chat / qwen-plus',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.model_training),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // [新增] 连通测试按钮
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
                          // [/新增]
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
