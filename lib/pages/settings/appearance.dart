import 'package:flutter/material.dart';

import '../../setting/navbar_setting.dart';

/// 「外观设置」页
///
/// 用户要求「底栏加个按钮选择是否为悬浮底栏」，故把开关独立成一页，
/// 从账号页右上角菜单（`/accounts` 页的 `more_horiz`）进入。
///
/// 之所以不直接做成菜单里的一项：菜单项点一下就关，而用户切换后需要能
/// **立刻看到底栏变化**，留在页面上才方便反复对比两种形态。
class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('外观设置'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '底栏样式',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          // 用 ValueListenableBuilder 直接监听全局设置，
          // 这样切换后底栏立刻重绘（底栏本身也监听了同一个 notifier）
          ValueListenableBuilder<bool>(
            valueListenable: NavBarSetting.floating,
            builder: (context, floating, _) {
              return SwitchListTile(
                value: floating,
                onChanged: (v) => NavBarSetting.setFloating(v),
                title: const Text('悬浮底栏'),
                subtitle: Text(
                  floating
                      ? '胶囊圆角 + 阴影，与屏幕底边留有间距'
                      : '通栏贴底，顶部带分隔线',
                ),
                secondary: Icon(
                  floating ? Icons.rounded_corner : Icons.crop_16_9,
                ),
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              '关闭后底栏会贴住屏幕底边，视觉上更紧凑；'
              '开启则更接近悬浮胶囊的观感。切换即时生效，无需重启。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
