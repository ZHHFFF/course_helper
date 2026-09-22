import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// 「关于」页
///
/// 入口：设置 Tab → 关于。
///
/// 【历史】原先它是账号页右上角「更多」菜单里的一项，形态是 `showDialog` +
/// `MiuixSurface` 自绘面板（之所以不用 `MiuixOverlayDialog`，是因为账号页是
/// Tab 页、玻璃底栏画在页面之上，页内级弹窗会被底栏压住 —— 见
/// `accounts.dart` 里 `_buildQrDialogPanel` 的注释）。
///
/// 2026-09-22 菜单入口整体搬到「设置」Tab 后，本页改成 **push 出来的独立路由**：
/// 它天然盖住底栏，上面那个层级问题不复存在，也就用不着自绘弹窗了。
/// 形态改成 Miuix 的常规页面（`MiuixScaffold` + 卡片），与设置页其它入口一致。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  /// 两位开发者（点名字跳 GitHub）
  static const List<(String, String)> _developers = [
    ('makisekurse', 'https://github.com/makisekurse'),
    ('ZHHFFF', 'https://github.com/ZHHFFF'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final textStyles = MiuixTheme.of(context).textStyles;

    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: '关于',
        blurred: true,
        // ⚠️ `MiuixTopAppBar` 没有 `onBack`，返回键要自己塞 `navigationIcon`
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Icon(Icons.arrow_back_ios_new, size: 20),
        ),
      ),
      content: (contentPadding) => ListView(
        padding: contentPadding,
        children: [
          const SizedBox(height: 28),
          Center(child: Image.asset('images/logo.png', width: 72, height: 72)),
          const SizedBox(height: 14),
          Center(
            child: MiuixText(
              '课程助手',
              fontSize: textStyles.title4.fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          // 版本号要 `await`，所以用 `FutureBuilder` 而不是在 build 里 await
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final version = snapshot.data?.version;
              return Center(
                child: MiuixText(
                  version == null ? '版本读取中…' : '版本 $version',
                  fontSize: 13,
                  color: colors.onSurfaceVariantSummary,
                ),
              );
            },
          ),
          const SizedBox(height: 28),
          const MiuixSmallTitle('开发者'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: MiuixCard(
              child: Column(
                children: [
                  for (final (name, url) in _developers)
                    MiuixArrowPreference(
                      title: name,
                      summary: 'GitHub',
                      endActions: [
                        MiuixIcon(
                          icon: Icons.open_in_new,
                          size: 16,
                          tint: colors.onSurfaceVariantActions,
                        ),
                      ],
                      onClick: () => _openLink(url),
                    ),
                ],
              ),
            ),
          ),
          const MiuixSmallTitle('简介'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: MiuixCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MiuixText('一个管理学习通、雨课堂课程的应用。', fontSize: 14),
                    const SizedBox(height: 6),
                    MiuixText(
                      '支持多账号管理、课程查看、活动签到、PPT 缓存与离线浏览等功能。',
                      fontSize: 14,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  /// `MiuixText` 没有 `onTap`（Miuix 里可点文本就是套一层按压组件），
  /// 所以整行走 `MiuixArrowPreference.onClick`，点名字即跳转。
  static Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    }
  }
}
