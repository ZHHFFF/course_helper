import 'package:flutter/material.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';
// [新增] Miuix：顶栏 / 脚手架按「所有规范都按 miuix」迁移
import 'package:flutter_miuix/miuix.dart';
import 'dart:async';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../session/account.dart';
import '../models/user.dart';
import '../platform.dart';
import '../push/easemob.dart';
import 'widget/avatar.dart';
import 'widget/answer_search_settings.dart';
// [新增] Miuix 风格的顶栏动作按钮（纯视觉，不接管手势）
import 'widget/miuix_action_trigger.dart';
// [新增] 外观设置页（底栏悬浮 / 贴边切换）
import 'settings/appearance.dart';
import 'widget/log_viewer.dart';
import 'widget/cache_manager.dart';
import 'widget/keep_alive_checker.dart';
// [新增] 悬浮玻璃底栏的底部留白高度
import 'widget/liquid_glass_nav_bar.dart';
import '../setting/navbar_setting.dart';
import 'login.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> with TickerProviderStateMixin {
  List<User> _accounts = [];
  final Set<String> _selectedAccounts = <String>{};
  bool _isMultiSelectMode = false;
  String? _currentAccountId;
  PlatformType _selectedPlatform = PlatformManager().currentPlatform;
  StreamSubscription? _accountChangeSubscription;

  /// 顶栏「滚动折叠」的行为对象。必须**只创建一次**（它持有折叠进度，
  /// 在 `build()` 里 new 会导致折叠状态每帧被重置）。详见
  /// `courses/list.dart` 里同名字段的注释。
  late final MiuixExitUntilCollapsedScrollBehavior _topBarBehavior =
      miuixScrollBehavior();

  /// 列表顶部留白（= 顶栏**展开态**高度），只记最大值、不跟随折叠回缩。
  /// 用 `contentPadding.top` 会让内容以两倍速往栏底钻，详见
  /// `courses/list.dart` 里同名字段的注释。
  double _topBarInset = 0;

  @override
  void initState() {
    super.initState();
    _loadAccounts();

    // 监听账户变更事件
    _accountChangeSubscription =
        AccountChangeNotifier().accountChanges.listen((_) {
      if (mounted) {
        _loadAccounts();
      }
    });

    // 监听环信连接状态变化
    EasemobIM().setConnectionCallback((connected) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _accountChangeSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    setState(() {
      _accounts = AccountManager.allAccounts;
      _currentAccountId = AccountManager.currentSessionId;
    });
  }

  void _toggleSelection(String userId) {
    setState(() {
      if (_selectedAccounts.contains(userId)) {
        _selectedAccounts.remove(userId);
      } else {
        _selectedAccounts.add(userId);
      }
      if (_selectedAccounts.isEmpty) _isMultiSelectMode = false;
    });
  }

  void _toggleMultiSelect() {
    setState(() {
      _isMultiSelectMode = !_isMultiSelectMode;
      if (!_isMultiSelectMode) _selectedAccounts.clear();
    });
  }

  Future<void> _deleteSelectedAccounts() async {
    if (_selectedAccounts.isNotEmpty) {
      await AccountManager.removeAccounts(_selectedAccounts.toList());
      await _loadAccounts();
      _toggleMultiSelect();
    }
  }

  Future<void> _switchToAccount(User user) async {
    if (user.uid == _currentAccountId) {
      return;
    }
    await AccountManager.setCurrentSession(user.uid);
  }

  Future<void> _navigateToPasswordLogin() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage(initialLoginType: 'password')),
    );
    if (result == true) {
      await _loadAccounts();
    }
  }

  Future<void> _navigateToCaptchaLogin() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage(initialLoginType: 'captcha')),
    );
    if (result == true) {
      await _loadAccounts();
    }
  }

  Future<void> _showQRCodeLoginDialog() async {
    final qrState = QRCodeLoginState();

    if (!await qrState.initialize()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('获取二维码失败')),
        );
      }
      qrState.dispose();
      return;
    }

    qrState.startPolling((bool success) async {
      if (success && await handleLoginSuccess(context) && mounted) {
        Navigator.pop(context, true);
        await _loadAccounts();
      }
      qrState.dispose();
    });

    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            qrState.onRefresh = () {
              setState(() {});
            };
            
            return PopScope(
              canPop: true,
              onPopInvokedWithResult: (bool didPop, Object? result) {
                if (didPop) {
                  qrState.isLoginActive = false;
                  qrState.dispose();
                }
              },
              child: AlertDialog(
                title: const Text('二维码登录'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.withValues(alpha: 0.1),
                            spreadRadius: 2,
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: qrState.qrImageUrl != null
                          ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          qrState.qrImageUrl!,
                          fit: BoxFit.contain,
                        ),
                      )
                          : qrState.isLoading
                          ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 8),
                            Text('生成中...', style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      )
                          : const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.error_outline, size: 48, color: Colors.grey),
                            SizedBox(height: 8),
                            Text('二维码加载失败', style: TextStyle(color: Colors.grey)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      PlatformManager().isChaoxing ?
                      '使用学习通APP扫码登录' : '使用微信扫码登录',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '二维码失效时会自动刷新',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    child: const Text('取消'),
                    onPressed: () {
                      qrState.isLoginActive = false;
                      qrState.dispose();
                      Navigator.pop(context);
                    }
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    qrState.dispose();
  }

  Widget _buildTitle(String name, bool isCurrentAccount) {
    final theme = MiuixTheme.of(context);
    // ⚠️ 这里必须用**当前卡片**的内容色，不能用 `colors.onBackgroundVariant`。
    // 当前账号的卡片底色是 `primaryContainer`（浅色 `#5D9BFF` / 深色 `#338FE4`，
    // 两种模式都是**蓝色**），而 `onPrimaryContainer` 都是白色。若用固定的
    // `onBackgroundVariant`（深灰蓝），角标会变成「蓝底 + 深蓝字」，几乎看不见。
    //
    // 用「内容色 + 透明度」的写法可以同时适配两种模式：
    // 深色 → 白色 22% 底 + 白字；浅色 → 白色 22% 底 + 白字（底色同样是蓝）。
    final onCard = MiuixContentColor.of(context);
    return Row(
      children: [
        Flexible(
          child: MiuixText(
            name,
            fontSize: theme.textStyles.headline1.fontSize,
            fontWeight: FontWeight.w500,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (isCurrentAccount)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            margin: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              color: onCard.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(10),
            ),
            child: MiuixText('当前', fontSize: 12, color: onCard),
          ),
      ],
    );
  }

  Widget _buildListItemContent(
      BuildContext context, User user, bool isSelected, bool isCurrentAccount) {
    final colors = MiuixTheme.of(context).colors;
    final textStyles = MiuixTheme.of(context).textStyles;
    // 当前账号的卡片底色是蓝色，次级文字必须跟着卡片内容色走（见 `_buildTitle`
    // 的注释）；普通卡片则用 Miuix 规定的 summary 色 `onSurfaceVariantSummary`。
    final onCard = MiuixContentColor.of(context);
    final summaryColor = isCurrentAccount
        ? onCard.withValues(alpha: 0.85)
        : colors.onSurfaceVariantSummary;
    // [改动] ListTile → MiuixBasicComponent（Miuix 的「一行一项」标准组件）。
    // 点击 / 长按已上移到外层 MiuixCard，这里只负责排版。
    return MiuixBasicComponent(
      // 原 ListTile 的 contentPadding 是「水平 16 / 垂直 8」，
      // MiuixBasicComponent 默认是 16 四边，这里对齐成水平 16 + 垂直 12
      insideMargin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      startAction: AvatarWidget(
        key: ValueKey(user.avatar),
        imageUrl: user.avatar,
      ),
      // 自定义中心内容：标题行（带「当前」角标）+ 两行摘要
      content: [
        _buildTitle(user.name, isCurrentAccount),
        MiuixText(
          'ID: ${user.uid}\n手机号: ${user.phone}',
          fontSize: textStyles.body2.fontSize,
          color: summaryColor,
        ),
      ],
      endActions: [
        if (!user.status)
          Tooltip(
            message: '账号失效',
            child: Icon(Icons.error_outline, color: colors.error, size: 30),
          ),
        if (isCurrentAccount && PlatformManager().isChaoxing)
          Tooltip(
            message: '消息推送',
            child: MiuixIconButton(
              onPressed: () async {
                if (EasemobIM().isLoggedIn) {
                  await EasemobIM().logout();
                } else {
                  await EasemobIM().loginCurrentAccount();
                }
              },
              child: Icon(
                EasemobIM().isLoggedIn
                    ? Icons.notifications
                    : Icons.notifications_off,
                size: 30,
                // 蓝色卡片上不能用 primary（蓝底蓝图标），同样跟着内容色走
                color: isCurrentAccount
                    ? onCard
                    : (EasemobIM().isLoggedIn
                          ? colors.primary
                          : colors.onSurfaceVariantSummary),
              ),
            ),
          ),
        Visibility(
          visible: _isMultiSelectMode,
          child: MiuixCheckbox(
            value: isSelected,
            onChanged: (bool? value) {
              if (value != null) _toggleSelection(user.uid);
            },
          ),
        ),
      ],
    );
  }

  void _showAboutDialog() async {
    // 先把 context 相关的东西取出来：下面要 await，
    // 之后再碰 context 会被 analyzer 判成 use_build_context_synchronously
    final linkColor = Theme.of(context).colorScheme.primary;

    final packageInfo = await PackageInfo.fromPlatform();
    final appIcon = Image.asset(
      'images/logo.png',
      width: 60,
      height: 60
    );
    
    showAboutDialog(
      context: context,
      applicationName: '课程助手',
      applicationVersion: packageInfo.version,
      applicationIcon: appIcon,
      // applicationLegalese: '',
      children: [
        const Text('一个管理学习通、雨课堂课程的应用。'),
        const Text('支持多账号管理、课程查看、活动签到等功能。'),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('开发者：'),
            GestureDetector(
              onTap: () async {
                final Uri url = Uri.parse('https://github.com/makisekurse');
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.inAppBrowserView);
                }
              },
              child: Text(
                'makisekurse',
                style: TextStyle(color: linkColor),
              ),
            ),
            const Text(' & '),
            GestureDetector(
              onTap: () async {
                final Uri url = Uri.parse('https://github.com/ZHHFFF');
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.inAppBrowserView);
                }
              },
              child: Text(
                'ZHHFFF',
                style: TextStyle(color: linkColor),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // [新增] 监听底栏形态设置：切换后 FAB 位置与列表留白都要跟着变。
    // 底栏本身在 main.dart 里也监听同一个 notifier，两边同步刷新。
    return ValueListenableBuilder<bool>(
      valueListenable: NavBarSetting.floating,
      builder: (context, _, _) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return MiuixScaffold(
      // 顶栏换成 Miuix 玻璃顶栏。
      //
      // 理由见 courses/list.dart 的同名注释：玻璃顶栏要「有东西可糊」，
      // 内容就必须能从栏底下滚过去，所以得用 MiuixScaffold（body 铺满整屏、
      // 栏画在其上），而不是 Material 的 `Scaffold.appBar` 槽位。
      //
      // 注：两个 `PopupMenuButton` 的**弹出内容**仍是 Material（`PopupMenuItem`
      // / `RadioListTile`）。触发器已换成 Miuix 观感（`MiuixActionTrigger`），
      // 内容待后续用 `MiuixOverlayListPopup` + `MiuixListPopupColumn` 迁移。
      topBar: MiuixTopAppBar(
        title: '账号',
        largeTitle: '账号',
        blurred: true,
        scrollBehavior: _topBarBehavior,
        actions: [
          if (_isMultiSelectMode)
            MiuixIconButton(
              onPressed: _deleteSelectedAccounts,
              child: const Icon(Icons.delete),
            ),
          if (_selectedPlatform == PlatformType.rainClassroom)
            StatefulBuilder(
              builder: (context, setState) {
                // 服务器类型与颜色
                const serverColors = {
                  RainClassroomServerType.yuketang: Color(0xFF5096F5),
                  RainClassroomServerType.pro: Color(0xFF7B3BB5),
                  RainClassroomServerType.changjiang: Color(0xFFC21F30),
                  RainClassroomServerType.huanghe: Color(0xFFB57232)
                };
                
                final serverColor = serverColors[PlatformManager().currentServer];
                return PopupMenuButton<RainClassroomServerType>(
                  padding: EdgeInsets.zero,
                  tooltip: '切换服务器',
                  onSelected: (RainClassroomServerType server) async {
                    await PlatformManager().setServer(server);
                  },
                  itemBuilder: (BuildContext context) => [
                PopupMenuItem<RainClassroomServerType>(
                  enabled: true,
                  child: StatefulBuilder(
                    builder: (BuildContext context, StateSetter setPopupState) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          RadioGroup<RainClassroomServerType>(
                            groupValue: PlatformManager().currentServer,
                            onChanged: (RainClassroomServerType? value) async {
                              if (value != null) {
                                await PlatformManager().setServer(value);
                                Navigator.pop(context);
                                // 延迟执行以确保弹窗关闭后再刷新
                                Future.microtask(() => setState(() {}));
                              }
                            },
                            child: Column(
                              children: [
                                RadioListTile<RainClassroomServerType>(
                                  title: const Text('雨课堂'),
                                  value: RainClassroomServerType.yuketang,
                                  dense: true
                                ),
                                RadioListTile<RainClassroomServerType>(
                                  title: const Text('荷塘 · 雨课堂'),
                                  value: RainClassroomServerType.pro,
                                  dense: true
                                ),
                                RadioListTile<RainClassroomServerType>(
                                  title: const Text('长江 · 雨课堂'),
                                  value: RainClassroomServerType.changjiang,
                                  dense: true
                                ),
                                RadioListTile<RainClassroomServerType>(
                                  title: const Text('黄河 · 雨课堂'),
                                  value: RainClassroomServerType.huanghe,
                                  dense: true
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
                  // ⚠️ 用 `child` 而不是 `icon`：传 `icon` 时 PopupMenuButton 会
                  // 自己包一个 Material `IconButton`（48×48 + 水波纹），与 Miuix
                  // 顶栏观感不符。传 `child` 则原样使用我们的 Miuix 触发器，
                  // 外层 InkWell 负责点击，`padding` 归零避免额外 8dp 留白。
                  child: MiuixActionTrigger(
                    icon: Icon(Icons.dns, color: serverColor),
                  ),
                );
              },
            ),
          PopupMenuButton<String>(
            // 同上：触发器换成 Miuix 观感，弹出内容暂留 Material
            padding: EdgeInsets.zero,
            tooltip: '更多',
            onSelected: (String result) {
              if (result == 'about') {
                _showAboutDialog();
              } else if (result == 'answer_search_settings') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AnswerSearchSettingsPage(),
                  ),
                );
              } else if (result == 'appearance_settings') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AppearanceSettingsPage(),
                  ),
                );
              } else if (result == 'runtime_logs') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const LogViewerPage(),
                  ),
                );
              } else if (result == 'ppt_cache') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const CacheManagerPage(),
                  ),
                );
              } else if (result == 'keep_alive_checker') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const KeepAliveCheckerPage(),
                  ),
                );
              }
            },
            itemBuilder: (BuildContext context) => [
              // 平台切换菜单项
              PopupMenuItem<String>(
                enabled: true,
                child: StatefulBuilder(
                  builder: (BuildContext context, StateSetter setState) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        RadioGroup<PlatformType>(
                          groupValue: _selectedPlatform,
                          onChanged: (PlatformType? value) async {
                            if (value != null) {
                              setState(() {
                                _selectedPlatform = value;
                              });
                              Navigator.pop(context);
                              await PlatformManager().setPlatform(value);
                            }
                          },
                          child: Column(
                            children: [
                              RadioListTile<PlatformType>(
                                title: const Text('学习通'),
                                value: PlatformType.chaoxing,
                                dense: true,
                              ),
                              RadioListTile<PlatformType>(
                                title: const Text('雨课堂'),
                                value: PlatformType.rainClassroom,
                                dense: true,
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                      ],
                    );
                  },
                ),
              ),
              // 答案检索设置菜单项
              const PopupMenuItem<String>(
                value: 'answer_search_settings',
                child: Row(children: [
                  Icon(Icons.search, size: 20),
                  SizedBox(width: 8),
                  Text('答案检索设置'),
                ]),
              ),
              // 外观设置菜单项（底栏悬浮 / 贴边切换）
              const PopupMenuItem<String>(
                value: 'appearance_settings',
                child: Row(children: [
                  Icon(Icons.palette_outlined, size: 20),
                  SizedBox(width: 8),
                  Text('外观设置'),
                ]),
              ),
              // 运行日志菜单项
              const PopupMenuItem<String>(
                value: 'runtime_logs',
                child: Row(children: [
                  Icon(Icons.receipt_long, size: 20),
                  SizedBox(width: 8),
                  Text('运行日志'),
                ]),
              ),
              // PPT 缓存菜单项
              const PopupMenuItem<String>(
                value: 'ppt_cache',
                child: Row(children: [
                  Icon(Icons.sd_storage_outlined, size: 20),
                  SizedBox(width: 8),
                  Text('PPT 缓存'),
                ]),
              ),
              // 前台服务自检菜单项
              const PopupMenuItem<String>(
                value: 'keep_alive_checker',
                child: Row(children: [
                  Icon(Icons.power_settings_new, size: 20),
                  SizedBox(width: 8),
                  Text('前台服务自检'),
                ]),
              ),
              // 关于菜单项
              const PopupMenuItem<String>(
                value: 'about',
                child: Row(children: [Text('关于')]),
              ),
            ],
            // 触发器换成 Miuix 观感（理由同服务器菜单）
            child: const MiuixActionTrigger(icon: Icon(Icons.more_horiz)),
          )
        ],
      ),
      content: (contentPadding) {
        // 只记最大高度，不跟随折叠回缩 —— 原因见 `_topBarInset` 的注释
        if (contentPadding.top > _topBarInset) {
          _topBarInset = contentPadding.top;
        }
        // 把顶栏折叠行为挂到滚动通知上（只认 depth==0 的竖向滚动体）
        return MiuixScrollBehaviorListener(
          behavior: _topBarBehavior,
          child: _accounts.isEmpty
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MiuixText(
              '暂无账号',
              fontSize: 18,
              color: MiuixTheme.of(context).colors.onBackgroundVariant,
            ),
            const SizedBox(height: 8),
            MiuixText(
              '点击右下角添加账号',
              color: MiuixTheme.of(context).colors.onBackgroundVariant,
            ),
          ],
        ),
      )
          : ListView.builder(
        itemCount: _accounts.length,
        // 顶部留白吃掉顶栏高度 → 内容从顶栏底下滚过（玻璃顶栏的关键）
        padding: EdgeInsets.only(
          top: _topBarInset,
          bottom: contentPadding.bottom + 16,
        ),
        itemBuilder: (context, index) {
          final user = _accounts[index];
          final isSelected = _selectedAccounts.contains(user.uid);
          final isCurrent = user.uid == _currentAccountId;
          final colors = MiuixTheme.of(context).colors;
          return Padding(
            // MiuixCard 没有 margin 参数，外边距由外面这层 Padding 提供
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: MiuixCard(
              // 当前账号用 Miuix 的 primaryContainer 高亮（原来是 Material 的
              // colorScheme.primaryContainer，跟 Miuix 配色不搭）
              colors: isCurrent
                  ? MiuixCardColors(
                      color: colors.primaryContainer,
                      contentColor: colors.onPrimaryContainer,
                    )
                  : null,
              feedbackType: MiuixPressFeedbackType.sink,
              // 点击 / 长按都交给 MiuixCard，原来 ListTile 的 onTap / onLongPress
              // 已移除
              onPressed: _isMultiSelectMode ? null : () => _switchToAccount(user),
              onLongPress: () {
                _toggleMultiSelect();
                _toggleSelection(user.uid);
              },
              child: Builder(
                // ⚠️ 必须套一层 `Builder`：`MiuixContentColor` 是 `MiuixCard`
                // 在**它的子树里**提供的，而 `_buildListItemContent(context, ...)`
                // 拿到的是 itemBuilder 的 context —— 那个 context 在 MiuixCard
                // **之上**，取不到卡片内容色（会拿到更外层祖先的值）。
                // 用 `Builder` 重新开一个位于卡片内部的 context 才行。
                builder: (context) => _buildListItemContent(
                  context,
                  user,
                  isSelected,
                  isCurrent,
                ),
              ),
            ),
          );
        },
      ),
        );
      },
      // 底栏是全局叠加的，不在本页脚手架里。这块透明占位一次解决两件事：
      // 1) contentPadding.bottom = 底栏占位 → 列表末项不会被底栏盖住；
      // 2) 脚手架把 FAB 抬到底栏之上（fabOffsetFromBottom =
      //    bottomBarHeight + fabSize + 12）→ 不再需要手写
      //    floatingActionButtonLocation。
      bottomBar: SizedBox(height: miuixNavBarOccupied(context)),
      floatingActionButton: SpeedDial(
        icon: Icons.add,
        activeIcon: Icons.close,
        spacing: 5,
        spaceBetweenChildren: 2,
        overlayColor: Colors.transparent,
        overlayOpacity: 0.3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
        children: [
          SpeedDialChild(
            child: const Icon(Icons.qr_code),
            label: '二维码登录',
            onTap: _showQRCodeLoginDialog,
          ),
          SpeedDialChild(
            child: const Icon(Icons.sms),
            label: '验证码登录',
            onTap: _navigateToCaptchaLogin,
          ),
          SpeedDialChild(
            child: const Icon(Icons.password),
            label: '密码登录',
            onTap: _navigateToPasswordLogin,
          ),
        ],
      ),
    );
  }
}
