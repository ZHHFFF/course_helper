/// 答案检索设置页
/// 配置 AI 检索源的 API 地址、密钥和模型名称
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
                          '4. AI检索结果仅展示当前题目，不会缓存到本地',
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
                          const Text(
                            'AI API 配置',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
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
                            decoration: const InputDecoration(
                              labelText: 'API Key',
                              hintText: 'sk-...',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.key),
                            ),
                            obscureText: true,
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

