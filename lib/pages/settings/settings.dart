import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../platform.dart';
import '../widget/answer_search_settings.dart';
import '../widget/cache_manager.dart';
import '../widget/keep_alive_checker.dart';
import '../widget/log_viewer.dart';
import '../widget/miuix_nav_metrics.dart';
import 'about.dart';
import 'appearance.dart';

/// 「设置」Tab
///
/// 用户 2026-09-22：
///   「第二个是设置页面，为原右上角的按钮导入至里面」
///   「设置页所有按钮重写，账号那一页右上角只保留切换雨课堂还是学习通」
///
/// 所以本页 = 原先散在账号页右上角「更多」菜单里的全部入口：
///   ① 平台（学习通 / 雨课堂）—— 原「更多」菜单里的单选组
///   ② 雨课堂服务器（雨课堂 / 荷塘 / 长江 / 黄河）—— 原顶栏那个彩色圆点按钮
///   ③ 答案检索设置 / 外观设置 / 课件缓存
///   ④ 运行日志 / 前台服务自检 / 关于
///
/// 布局按 Miuix 设置页范式：`MiuixSmallTitle` 分组标题 + `MiuixCard` 包一组
/// 偏好行。卡片左右各留 16 的边距（`MiuixCard` 自身 `insideMargin` 是
/// `EdgeInsets.zero`，所以内缩全靠这层 Padding，行自己的 insideMargin 不会翻倍）。
///
/// ⚠️ 本页是 Tab 页（不是 push 出来的路由），底栏画在页面之上 ——
/// 所以底部必须用 `miuixNavBarOccupied(context)` 占位，否则最后一个分组
/// 会被玻璃底栏压住。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 顶栏「滚动折叠」的行为对象。必须**只创建一次**（它持有折叠进度，
  /// 在 `build()` 里 new 会导致折叠状态每帧被重置）。详见
  /// `courses/list.dart` 里同名字段的注释。
  late final MiuixExitUntilCollapsedScrollBehavior _topBarBehavior =
      miuixScrollBehavior();

  /// 列表顶部留白（= 顶栏**展开态**高度），只记最大值、不跟随折叠回缩。
  /// 用 `contentPadding.top` 会让内容以两倍速往栏底钻，详见
  /// `courses/list.dart` 里同名字段的注释。
  double _topBarInset = 0;

  PlatformType get _platform => PlatformManager().currentPlatform;
  RainClassroomServerType get _server => PlatformManager().currentServer;

  Future<void> _setPlatform(PlatformType value) async {
    if (_platform == value) return;
    await PlatformManager().setPlatform(value);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _setServer(RainClassroomServerType value) async {
    if (_server == value) return;
    await PlatformManager().setServer(value);
    if (!mounted) return;
    setState(() {});
  }

  void _open(Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;

    return MiuixScaffold(
      // 不传 `blurRadius` / `blurTintAlpha` → 用库默认（24 / 0.55），
      // 与课程页、账号页、底栏是同一套玻璃口径。
      topBar: MiuixTopAppBar(
        title: '设置',
        largeTitle: '设置',
        blurred: true,
        scrollBehavior: _topBarBehavior,
      ),
      // 底栏是全局叠加的，不在本页脚手架里。透明占位一次解决两件事：
      // 1) contentPadding.bottom = 底栏占位 → 最后一个分组不会被底栏盖住
      // 2) 本页没有 FAB，但保留这个槽位让留白只有一个数据来源
      bottomBar: SizedBox(height: miuixNavBarOccupied(context)),
      content: (contentPadding) {
        // 只记最大高度，不跟随折叠回缩 —— 原因见 `_topBarInset` 的注释
        if (contentPadding.top > _topBarInset) {
          _topBarInset = contentPadding.top;
        }
        return MiuixScrollBehaviorListener(
          behavior: _topBarBehavior,
          child: ListView(
            padding: EdgeInsets.only(
              top: _topBarInset,
              bottom: contentPadding.bottom + 16,
            ),
            children: [
              // ── 平台 ──────────────────────────────────────────────────
              const MiuixSmallTitle('平台'),
              _card(
                children: [
                  for (final platform in PlatformType.values)
                    MiuixRadioButtonPreference(
                      title: platform == PlatformType.chaoxing
                          ? '学习通'
                          : '雨课堂',
                      summary: platform == PlatformType.chaoxing
                          ? '超星学习通'
                          : '雨课堂（含荷塘 / 长江 / 黄河）',
                      selected: _platform == platform,
                      // ⚠️ 必须显式给 `tint`：`MiuixIcon` 未指定时取
                      // `MiuixContentColor.of(context)`，虽然卡片内是有这个
                      // 提供者的，但显式给色更稳（踩过「图标在深色下隐形」）。
                      startAction: MiuixIcon(
                        icon: platform == PlatformType.chaoxing
                            ? Icons.school_outlined
                            : Icons.dns_outlined,
                        size: 22,
                        tint: colors.primary,
                      ),
                      onClick: () => _setPlatform(platform),
                    ),
                ],
              ),

              // ── 雨课堂服务器（只在雨课堂下出现）──────────────────────
              //
              // 2026-09-22 起默认值是**长江雨课堂**（`platform.dart` 里的
              // `_currentServer`），但只影响新装 —— 老用户存过
              // `current_server` 就以后者为准，不会被这次改动改掉。
              if (_platform == PlatformType.rainClassroom) ...[
                const MiuixSmallTitle('雨课堂服务器'),
                _card(
                  children: [
                    for (final server in RainClassroomServerType.values)
                      MiuixRadioButtonPreference(
                        title: kRainClassroomServerNames[server]!,
                        selected: _server == server,
                        startAction: Icon(
                          Icons.circle,
                          size: 14,
                          color: kRainClassroomServerColors[server],
                        ),
                        onClick: () => _setServer(server),
                      ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
                  child: MiuixText(
                    '不同学校的雨课堂部署在不同服务器上，选错了会登录不上。'
                    '不确定的话问一下任课老师或同学用的是哪个。',
                    style: MiuixTheme.of(context).textStyles.footnote1,
                  ),
                ),
              ],

              // ── 功能 ──────────────────────────────────────────────────
              const MiuixSmallTitle('功能'),
              _card(
                children: [
                  _entry(
                    context,
                    icon: Icons.search,
                    title: '答案检索设置',
                    summary: '配置题目答案的自动检索与填充',
                    onTap: () => _open(const AnswerSearchSettingsPage()),
                  ),
                  _entry(
                    context,
                    icon: Icons.palette_outlined,
                    title: '主題設定',
                    summary: '深淺色、模糊、懸浮底欄與縮放',
                    onTap: () => _open(const AppearanceSettingsPage()),
                  ),
                  _entry(
                    context,
                    icon: Icons.folder_copy_outlined,
                    title: '课件缓存',
                    summary: '查看占用、清理缓存文件',
                    onTap: () => _open(const CacheManagerPage()),
                  ),
                ],
              ),

              // ── 其它 ──────────────────────────────────────────────────
              const MiuixSmallTitle('其它'),
              _card(
                children: [
                  _entry(
                    context,
                    icon: Icons.receipt_long,
                    title: '运行日志',
                    summary: '查看并导出应用运行日志',
                    onTap: () => _open(const LogViewerPage()),
                  ),
                  _entry(
                    context,
                    icon: Icons.power_settings_new,
                    title: '前台服务自检',
                    summary: '检查保活服务是否正常工作',
                    onTap: () => _open(const KeepAliveCheckerPage()),
                  ),
                  _entry(
                    context,
                    icon: Icons.info_outline,
                    title: '关于',
                    summary: '版本与开发者信息',
                    onTap: () => _open(const AboutPage()),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// 一组偏好行 = 一张 Miuix 卡片。
  ///
  /// `MiuixCard` 只接受单个 `child`（没有 `children`），所以自己套 `Column`。
  Widget _card({required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: MiuixCard(
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  /// 一条「点进去」的入口行。
  Widget _entry(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String summary,
    required VoidCallback onTap,
  }) {
    return MiuixArrowPreference(
      title: title,
      summary: summary,
      startAction: MiuixIcon(
        icon: icon,
        size: 22,
        tint: MiuixTheme.of(context).colors.primary,
      ),
      onClick: onTap,
    );
  }
}
