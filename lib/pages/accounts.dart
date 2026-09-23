import 'package:flutter/material.dart';
// [新增] Miuix：顶栏 / 脚手架按「所有规范都按 miuix」迁移
import 'package:flutter_miuix/miuix.dart';
import 'dart:async';

import '../session/account.dart';
import '../models/user.dart';
import '../platform.dart';
import '../push/easemob.dart';
import 'widget/avatar.dart';
// [新增] 底栏（Miuix 标准样式）的底部占位高度（几何常量模块）
import 'widget/miuix_nav_metrics.dart';
// [新增] 开发期压测假数据（--dart-define=SEED_TEST_DATA=N 时才有内容）
import '../utils/test_data_seeder.dart';
import 'login.dart';

// [移除] 2026-09-22：账号页右上角**只保留「切换雨课堂 / 学习通」**，
// 其余入口（答案检索设置 / 外观设置 / 运行日志 / 课件缓存 / 前台服务自检 /
// 关于）全部搬到新的「设置」Tab。连带移除的 import：
//   widget/answer_search_settings.dart、settings/appearance.dart、
//   widget/log_viewer.dart、widget/cache_manager.dart、
//   widget/keep_alive_checker.dart、setting/navbar_setting.dart、
//   package_info_plus、url_launcher
// （最后两个原先只服务于「关于」弹窗，那个弹窗也搬去设置页了。）

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

  // ---------------------------------------------------------------------------
  // 顶栏的平台切换菜单（学习通 / 雨课堂）
  //
  // 2026-09-22 起账号页右上角**只保留这一个菜单**。原来还有一个「服务器切换」
  // 按钮（雨课堂专用，四个小圆点）和一个「更多」菜单（答案检索设置 / 外观设置 /
  // 运行日志 / PPT 缓存 / 前台服务自检 / 关于），全部搬到新的「设置」Tab。
  //
  // 从 Material 的 `PopupMenuButton` 换成 Miuix 的 `MiuixOverlayListPopup`。
  // Miuix 的弹窗是**声明式**的：由 `show` 控制显隐，锚点靠 `anchorBounds`
  // 显式给出，所以需要各自一个 `GlobalKey` 去量触发器的位置。
  //
  // ⚠️ 弹窗组件必须**常驻挂载**（用 `show:` 切换，而不是 `if (show)` 增删），
  // 否则关闭时组件已被移除、退场动画播不完，表现为「一点空白处菜单就瞬间消失」。
  // ---------------------------------------------------------------------------

  /// 平台切换菜单触发器的锚点
  final GlobalKey _moreMenuAnchor = GlobalKey();

  bool _showMoreMenu = false;

  /// 「添加账号」底部抽屉。
  ///
  /// 原来这里是 `flutter_speed_dial` 的 `SpeedDial`（Material 紫色 + 三个
  /// 展开式迷你 FAB）。换成 Miuix 的「FAB 点开底部抽屉」范式：
  /// `MiuixFloatingActionButton` + `MiuixOverlayBottomSheet`。
  /// 抽屉和弹窗一样是**声明式**的，必须常驻挂载、用 `show` 切换显隐。
  bool _showAddAccountSheet = false;

  /// Miuix 的 Snackbar 走「host + state」模型，不是 `ScaffoldMessenger`。
  final MiuixSnackbarHostState _snackbarHost = MiuixSnackbarHostState();

  /// 取触发器在**窗口坐标系**下的矩形，作为弹窗锚点。
  ///
  /// `MiuixOverlayListPopup.anchorBounds` 会同时作为定位计算的 `parentBounds`
  /// 与 `anchorBounds` 使用，取的就是全局/窗口坐标，所以这里用 `localToGlobal`。
  Rect _anchorBoundsOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Rect.zero;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// 把 `MiuixDropdownEntriesPopupContent` 的 `(组下标, 项下标)` 回调派发到
  /// 对应项的 `onClick`。
  ///
  /// ⚠️ 必须自己派发：`MiuixDropdownImpl` 内部只有
  /// `GestureDetector(onTap: () => onSelectedIndexChange(index))`，
  /// **不会**调用 `MiuixDropdownItem.onClick`。
  /// 库自带的 `MiuixOverlayDropdownPopup` 是自己代劳了这一层，但我们直接用
  /// `MiuixDropdownEntriesPopupContent`，就得接住这个回调，
  /// 否则表现是「菜单点得动、但什么都没发生，也不关」。
  void _dispatchDropdownTap(
    List<MiuixDropdownEntry> entries,
    int entryIdx,
    int itemIdx,
  ) {
    if (entryIdx < 0 || entryIdx >= entries.length) return;
    final items = entries[entryIdx].items;
    if (itemIdx < 0 || itemIdx >= items.length) return;
    items[itemIdx].onClick?.call();
  }

  /// 平台切换菜单：一组单选（学习通 / 雨课堂）。
  ///
  /// 2026-09-22 起这是账号页顶栏**唯一**的菜单 —— 雨课堂的服务器选择
  /// （雨课堂 / 荷塘 / 长江 / 黄河）搬到了「设置」Tab。
  Widget _buildMoreMenu(BuildContext context) {
    final entries = <MiuixDropdownEntry>[
      MiuixDropdownEntry(
        items: [
          for (final platform in PlatformType.values)
            MiuixDropdownItem(
              text: platform == PlatformType.chaoxing ? '学习通' : '雨课堂',
              icon: Icon(
                platform == PlatformType.chaoxing
                    ? Icons.school_outlined
                    : Icons.dns_outlined,
                size: 20,
              ),
              selected: _selectedPlatform == platform,
              onClick: () async {
                setState(() {
                  _selectedPlatform = platform;
                  _showMoreMenu = false;
                });
                await PlatformManager().setPlatform(platform);
                if (mounted) setState(() {});
              },
            ),
        ],
      ),
    ];
    return MiuixOverlayListPopup(
      show: _showMoreMenu,
      anchorBounds: _anchorBoundsOf(_moreMenuAnchor),
      alignment: MiuixPopupAlign.end,
      onDismissRequest: () => setState(() => _showMoreMenu = false),
      content: MiuixListPopupColumn(
        children: [
          MiuixDropdownEntriesPopupContent(
            entries: entries,
            dropdownColors: MiuixDropdownDefaults.dropdownColors(context),
            onItemClick: (entryIdx, itemIdx) =>
                _dispatchDropdownTap(entries, entryIdx, itemIdx),
          ),
        ],
      ),
    );
  }

  /// 先收起抽屉再执行动作：抽屉若还开着，新页面的入场动画会和抽屉的退场动画打架。
  void _closeAddSheetThen(VoidCallback action) {
    setState(() => _showAddAccountSheet = false);
    action();
  }

  /// 「添加账号」底部抽屉：三种登录方式。
  ///
  /// ⚠️ 必须用 `MiuixWindowBottomSheet`（窗口级），**不能**用
  /// `MiuixOverlayBottomSheet`（页内级）。原因见 `main.dart` 里底栏的挂法：
  /// 玻璃底栏是 `MyHomePage` 的 `body: Stack` 里 `Positioned` 悬浮叠加的，
  /// 画在页面之上；而页内级抽屉走的是本页 `MiuixScaffold` 的 `MiuixPopupHost`，
  /// 层级低于底栏 → 抽屉最后一行会被底栏压住（实测「密码登录」正好被吞掉）。
  /// 窗口级抽屉用 `Overlay.maybeOf(context, rootOverlay: true)` 插到**根 Overlay**，
  /// 位于整个 Navigator 之上，连带底栏一起被遮罩盖住，才是正确的模态观感。
  ///
  /// 用 `MiuixArrowPreference`（= `MiuixBasicComponent` + 末尾右箭头）承载每一行，
  /// 它的默认取色正好是为 `colors.background` 底调的（抽屉默认底色就是
  /// `colors.background`）：标题 `onBackground`、摘要 `onSurfaceVariantSummary`、
  /// 箭头 `onSurfaceVariantActions`，深色下都是浅色文字，不需要手动覆盖。
  ///
  /// 起始图标必须显式给 `tint`：`MiuixIcon` 未指定时取
  /// `MiuixContentColor.of(context)`，而抽屉内部**没有** `MiuixContentColor`
  /// 提供者，会静默回退到黑色 `0xFF000000` —— 在 `#242424` 的深色抽屉上等于隐形。
  Widget _buildAddAccountSheet(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final entries = <(IconData, String, String, VoidCallback)>[
      (Icons.qr_code, '二维码登录', '扫码即可登录，适合在手机端快速添加', _showQRCodeLoginDialog),
      (Icons.sms, '验证码登录', '用手机号 + 短信验证码登录', _navigateToCaptchaLogin),
      (Icons.password, '密码登录', '用手机号 + 密码登录', _navigateToPasswordLogin),
    ];
    return MiuixWindowBottomSheet(
      show: _showAddAccountSheet,
      title: '添加账号',
      // 抽屉自带 24dp 左右内边距，这里收到 12dp，
      // 加上行自己的 16dp 正好 28dp，与本页账号卡片的缩进观感一致。
      insideMargin: const Size(12, 0),
      onDismissRequest: () => setState(() => _showAddAccountSheet = false),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (icon, title, summary, action) in entries)
            MiuixArrowPreference(
              title: title,
              summary: summary,
              startAction: MiuixIcon(icon: icon, size: 22, tint: colors.primary),
              onClick: () => _closeAddSheetThen(action),
            ),
        ],
      ),
    );
  }

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
    _snackbarHost.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    setState(() {
      // 压测用假账号只追加到本页的本地列表，**不写 SharedPreferences**，
      // 因此不会污染用户真实的账号列表（详见 test_data_seeder.dart）。
      _accounts = TestDataSeeder.enabled
          ? <User>[
              ...AccountManager.allAccounts,
              ...TestDataSeeder.buildFakeAccounts(
                TestDataSeeder.count,
                AccountManager.allAccounts,
              ),
            ]
          : AccountManager.allAccounts;
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
      if (mounted) _snackbarHost.showSnackbar('获取二维码失败');
      qrState.dispose();
      return;
    }

    qrState.startPolling((bool success) async {
      if (success && await handleLoginSuccess(context, snackbarHost: _snackbarHost) && mounted) {
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
              child: _wrapDialogPanel(_buildQrDialogPanel(context, qrState)),
            );
          },
        );
      },
    );

    qrState.dispose();
  }

  /// 把面板包成「居中 + 限宽」的弹窗。
  ///
  /// ⚠️ 必须自己包 `Center` + 限宽。这个 Flutter 版本里 `DialogRoute.pageBuilder`
  /// 只做了 `SafeArea(Semantics(child: 你的 widget))` —— **既没有 `Align`
  /// 也没有 `ConstrainedBox`**（见 `flutter/lib/src/material/dialog.dart`）。
  /// 于是路由页会把**整屏的紧约束**直接传给 builder 的返回值：
  /// `Column(mainAxisSize: MainAxisSize.min)` 在紧约束下形同虚设，
  /// 面板会铺满整屏（实测就是整屏 `#242424`，连状态栏下面都被填满）。
  ///
  /// 对照：Material 自己的 `Dialog` 组件内部才做了 `Center` + `ConstrainedBox`
  /// （`minWidth: 280`），所以直接 `showDialog(child: AlertDialog(...))` 没问题 ——
  /// 换成自绘面板就必须自己补上这一层。
  Widget _wrapDialogPanel(Widget panel) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 300),
        child: panel,
      ),
    );
  }

  /// 二维码登录弹窗的面板。
  ///
  /// ⚠️ 这里**不能**用 `MiuixOverlayDialog`。它是页内级弹窗，渲染在本页
  /// `MiuixScaffold` 的 `MiuixPopupHost` 里；而玻璃底栏是 `MyHomePage` 的
  /// `body: Stack` 里 `Positioned` 悬浮叠加的、画在页面之上 —— 于是页内级弹窗
  /// 会落在底栏**下面**：遮罩盖不住底栏，底栏还保持可点（弹窗开着却能切 Tab）。
  /// 账号页是 Tab 页（不是 push 出来的路由），这个问题躲不掉。
  ///
  /// 所以这里用 `showDialog`：它走**根 Navigator 的 Overlay**，层级天然在底栏
  /// 之上，遮罩与拦截语义都正确；面板内容用 `MiuixSurface` 自绘，观感仍是 Miuix。
  /// （对照：日志页 / PPT 缓存页是 push 出来的路由，本身就盖住底栏，
  /// 那边直接用 `MiuixOverlayDialog` 就没有这个问题。）
  Widget _buildQrDialogPanel(BuildContext context, QRCodeLoginState qrState) {
    final colors = MiuixTheme.of(context).colors;
    final textStyles = MiuixTheme.of(context).textStyles;
    return MiuixSurface(
      // 弹窗面板用 `surfaceContainer`（深色 #242424），与 `MiuixOverlayDialog`
      // 的默认底色一致；`MiuixSurface` 自己的默认色是 `surface`（深色纯黑），
      // 在遮罩上会糊成一片、看不出面板边界。
      color: colors.surfaceContainer,
      cornerRadius: 32,
      shadowElevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiuixText(
              '二维码登录',
              fontSize: textStyles.title4.fontSize,
              fontWeight: FontWeight.w600,
            ),
            const SizedBox(height: 20),
            Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                // ⚠️ 这里必须是**白底**，不能跟主题走：
                // 二维码是黑白位图，深色底上扫不出来。
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
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
                          MiuixCircularProgressIndicator(
                            size: 24,
                            strokeWidth: 3,
                          ),
                          SizedBox(height: 8),
                          // 白底上的文字，用固定深色而不是主题色
                          MiuixText(
                            '生成中...',
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ],
                      ),
                    )
                  : const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 48,
                            color: Colors.black38,
                          ),
                          SizedBox(height: 8),
                          MiuixText(
                            '二维码加载失败',
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 20),
            MiuixText(
              PlatformManager().isChaoxing ? '使用学习通APP扫码登录' : '使用微信扫码登录',
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            const SizedBox(height: 8),
            MiuixText(
              '二维码失效时会自动刷新',
              fontSize: 12,
              color: colors.onSurfaceVariantSummary,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: MiuixTextButton(
                '取消',
                onPressed: () {
                  qrState.isLoginActive = false;
                  qrState.dispose();
                  Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    // 底栏已固定为「贴边 Miuix 标准样式」（2026-09-22 取消悬浮），
    // 高度是常量，不再需要按设置重建。
    return _buildScaffold(context);
  }

  Widget _buildScaffold(BuildContext context) {
    return MiuixScaffold(
      // 顶栏换成 Miuix 玻璃顶栏。
      //
      // 理由见 courses/list.dart 的同名注释：玻璃顶栏要「有东西可糊」，
      // 内容就必须能从栏底下滚过去，所以得用 MiuixScaffold（body 铺满整屏、
      // 栏画在其上），而不是 Material 的 `Scaffold.appBar` 槽位。
      //
      // 注：弹出菜单已迁到 Miuix 的声明式弹窗
      // （`MiuixOverlayListPopup` + `MiuixListPopupColumn` +
      // `MiuixDropdownEntriesPopupContent`），触发器就是顶栏里的
      // `MiuixIconButton`，不再需要 Material 的 `PopupMenuButton`。
      topBar: MiuixTopAppBar(
        title: '账号',
        largeTitle: '账号',
        blurred: true,
        scrollBehavior: _topBarBehavior,
        actions: [
          // 注：这里的动作按钮直接用 `MiuixIconButton`（自带手势）。
          // 之前用 `PopupMenuButton(child: 纯视觉触发器)` 时**不能**这么做 ——
          // `MiuixPressable` 与 `PopupMenuButton` 外层的 `InkWell` 会抢手势，
          // 而内层（更深）的识别器先入竞技场并获胜，外层永远收不到 tap。
          // 现在弹窗改成 Miuix 的声明式组件、由按钮自己 setState 开合，
          // 手势只有一个归属，就不存在这个冲突了。
          if (_isMultiSelectMode)
            MiuixIconButton(
              onPressed: _deleteSelectedAccounts,
              child: const Icon(Icons.delete),
            ),
          // 2026-09-22 起这里**只保留**平台切换。原来的「服务器切换」按钮
          // （雨课堂专用的彩色圆点）与「更多」菜单（答案检索设置 / 外观设置 /
          // 运行日志 / PPT 缓存 / 前台服务自检 / 关于）都搬到了「设置」Tab。
          MiuixIconButton(
            key: _moreMenuAnchor,
            onPressed: () => setState(() => _showMoreMenu = !_showMoreMenu),
            child: const Icon(Icons.more_horiz),
          ),
        ],
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
            // 把顶栏折叠行为挂到滚动通知上（只认 depth==0 的竖向滚动体）
            MiuixScrollBehaviorListener(
              behavior: _topBarBehavior,
              child: _accounts.isEmpty
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            MiuixText(
              '暂无账号',
              fontSize: 18,
              color: MiuixTheme.of(context).colors.onSurfaceSecondary,
            ),
            const SizedBox(height: 8),
            MiuixText(
              '点击右下角添加账号',
              color: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
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
            ),
            // 弹出菜单常驻挂载（用 `show` 控制显隐），关闭动画才能播完。
            // `MiuixPopupLayout` 的 build 返回 `SizedBox.shrink()`，不占布局。
            _buildMoreMenu(context),
            // 底部抽屉同理：常驻挂载，靠 `show` 开合，退场动画才播得完。
            _buildAddAccountSheet(context),
          ],
        );
      },
      // 底栏是全局叠加的，不在本页脚手架里。这块透明占位一次解决两件事：
      // 1) contentPadding.bottom = 底栏占位 → 列表末项不会被底栏盖住；
      // 2) 脚手架把 FAB 抬到底栏之上（fabOffsetFromBottom =
      //    bottomBarHeight + fabSize + 12）→ 不再需要手写
      //    floatingActionButtonLocation。
      bottomBar: SizedBox(height: miuixNavBarOccupied(context)),
      floatingActionButton: MiuixFloatingActionButton(
        onPressed: () => setState(() => _showAddAccountSheet = true),
        // 用 `MiuixIcon` 而不是裸 `Icon`：`MiuixFloatingActionButton` 内部会
        // 通过 `MiuixContentColor` 注入 `colors.onSurface`，而裸 `Icon` 不读这个
        // InheritedWidget（只有 `MiuixText` / `MiuixIcon` 读），会掉到环境
        // `IconTheme` 上，深浅色下取色都可能不对。
        child: const MiuixIcon(icon: Icons.add, size: 28),
      ),
    );
  }
}
