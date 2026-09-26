import'dart:ui' show PlatformDispatcher;
import'package:flutter/material.dart';
import'package:flutter/services.dart';
import'package:flutter_localizations/flutter_localizations.dart';
// [移除] dynamic_color：已取消 Material You 动态取色，改为固定主题色 + 纯白/纯黑背景
// [新增] flutter_miuix：HyperOS 设计语言（Miuix）组件库。
// 用户已拍板「所有规范都按 miuix」，后续底栏与各页面逐步迁移到 Miuix 组件。
import'package:flutter_miuix/miuix.dart';
import'package:package_info_plus/package_info_plus.dart';
import'package:url_launcher/url_launcher.dart';
import'package:dio/dio.dart';

import'./pages/accounts.dart';
import'./pages/courses/list.dart';
import'./pages/login.dart';
// [新增] 「课件」Tab（全部课程 → 该课课件列表 → 离线浏览）
import'./pages/courseware/list.dart';
// [新增] 「设置」Tab（原账号页右上角菜单里的全部入口）
import'./pages/settings/settings.dart';
// [新增] 玻璃底栏的几何契约（占位高度 / 页面留白）
import './pages/widget/miuix_nav_metrics.dart';
// [新增] 统一底栏宿主（NavigationBarHost：传统 Miuix / Liquid Glass 动态切换）
import './pages/widget/navigation_bar_host.dart';
// [新增] Liquid Glass 折射着色器库（启动时预加载，见 main() 内说明）
import './pages/widget/liquid_glass_shader_filter.dart';
// [新增] 深浅色外观设置（见 setting/theme_setting.dart）
import './setting/theme_setting.dart';
import'./api/api_service.dart';
import'./session/cookie.dart';
import'./session/account.dart';
import'./platform.dart';
import './utils/storage.dart';
// [新增] 运行日志
import './utils/app_logger.dart';
// [/新增]
import 'push/easemob.dart';


// 全局Navigator Key,用于在无context时显示dialog
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // [新增] 沉浸式系统栏：内容铺到状态栏 / 手势导航区底下。
  //
  // 为什么必须开：玻璃底栏要一路铺到屏幕**最底边**（含 16dp 手势区），
  // 否则「小白条」那一条会出现与底栏割裂的色块（历史 bug 就是一条纯黑）。
  // `MiuixNavigationBar` 自带的 bottomInset 占位在它的 `ColoredBox` 之内，
  // 只要内容能铺到最底，玻璃就自然覆盖过去。
  //
  // 另一半是 `systemNavigationBarContrastEnforced: false`（在 `_MiuixScope`
  // 里按明暗设置）：系统默认会给导航栏加一层半透明黑遮罩，那层遮罩正好压在
  // 玻璃上，看起来就是「底栏下面有一条灰边」。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // [新增] 日志系统：越早初始化越好，后面的初始化过程也会被记下来
  await AppLogger.init();
  _installGlobalErrorHandlers();
  AppLogger.i('App', '应用启动');
  // [/新增]

  await StorageManager.initialize();

  await ApiService.initialize();

  await PlatformManager().initialize();

  await AccountManager.initialize();

  await CookieManager.initialize();

  await EasemobIM().initialize();

  // [新增] 外观设置要在首帧前读好，否则启动瞬间会先用默认值渲染一帧、
  // 读到配置后再跳变一次（深色用户会看到一次白闪）。这里提前加载。
  //
  // （原先这里是 `NavBarSetting.ensureLoaded()` —— 那个「悬浮 / 贴边」开关
  //  已随悬浮底栏一起删除，见 setting/theme_setting.dart 的说明。）
  await ThemeSetting.ensureLoaded();

  // [新增] 预加载 Liquid Glass 折射着色器。
  //
  // 不 await —— `FragmentProgram.fromAsset` 是异步的，等它会拖慢冷启动；
  // 底栏在 program 就绪前会走降级模糊（Skia 路径），就绪后下一帧自动切到折射。
  // 这里只是把加载**提前**到启动阶段，让底栏首次出现时就大概率已就绪。
  LiquidGlassShaderLibrary.initialize();
  AppLogger.i(
    'App',
    'Liquid Glass 着色器：后端支持=${LiquidGlassShaderLibrary.isBackendSupported}',
  );

  AppLogger.i('App', '初始化完成，进入主界面');

  runApp(const MyApp());
}

/// [新增] 把未捕获异常也写进运行日志，方便导出排查
void _installGlobalErrorHandlers() {
  final previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    AppLogger.e(
      'Flutter',
      '未捕获异常：${details.exceptionAsString()}\n${details.stack ?? ''}',
    );
    if (previous != null) {
      previous(details);
    } else {
      FlutterError.presentError(details);
    }
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    AppLogger.e('Platform', '未捕获异常：$error\n$stack');
    return true;
  };
}
// [/新增]

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // [新增] 深浅色模式由「设置 → 外观设置」控制，所以 `MaterialApp` 必须跟着
    // `ThemeSetting.mode` 重建 —— `themeMode` 是构造参数，不重建切不动。
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeSetting.mode,
      builder: (context, themeMode, _) => ValueListenableBuilder<bool>(
        valueListenable: ThemeSetting.predictiveBack,
        builder: (context, predictiveBack, _) => MaterialApp(
          navigatorKey: navigatorKey,
          title: '课程助手',
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en', 'US')
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate
          ],
          // [改动] 取消 Material You 动态取色（不再跟随壁纸），改为固定主题色 + 纯白/纯黑背景
          // 原来的 DynamicColorBuilder 已移除，因此 dynamic_color 依赖不再需要
          theme: _buildLightTheme(predictiveBack: predictiveBack),
          darkTheme: _buildDarkTheme(predictiveBack: predictiveBack),
          themeMode: themeMode,
          builder: (context, child) {
            return _MiuixScope(child: child);
          },
          home: const _GlassNavInsets(child: MyHomePage()),
          routes: {
            '/accounts': (context) => const AccountsPage(),
            '/login': (context) => const LoginPage(),
          },
        ),
      ),
    );
  }

  /// 浅色主题：纯白背景 + Miuix 蓝色主色（seed 0xFF3482FF）
  static ThemeData _buildLightTheme({bool predictiveBack = true}) {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3482FF),
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: base.copyWith(
        surface: Colors.white,
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: Colors.white,
        surfaceContainer: const Color(0xFFF7F7F9),
        surfaceContainerHigh: const Color(0xFFF2F2F5),
        surfaceContainerHighest: const Color(0xFFECECF0),
        onSurface: const Color(0xFF1A1A1F),
        onSurfaceVariant: const Color(0xFF6A6A78),
        outlineVariant: const Color(0xFFE4E4EA),
      ),
      scaffoldBackgroundColor: Colors.white,
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          TargetPlatform.android: predictiveBack
              ? const PredictiveBackPageTransitionsBuilder()
              : const ZoomPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// 深色主题：纯黑背景（真黑，非灰黑）
  static ThemeData _buildDarkTheme({bool predictiveBack = true}) {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3482FF),
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: base.copyWith(
        // 真黑背景
        surface: Colors.black,
        surfaceContainerLowest: Colors.black,
        // 卡片层级：从 #101014 起，逐级提亮，保证在纯黑上可分辨
        surfaceContainerLow: const Color(0xFF101014),
        surfaceContainer: const Color(0xFF16161B),
        surfaceContainerHigh: const Color(0xFF1E1E24),
        surfaceContainerHighest: const Color(0xFF27272E),
        onSurface: const Color(0xFFF2F2F5),
        onSurfaceVariant: const Color(0xFF9A9AA8),
        outlineVariant: const Color(0xFF33333C),
      ),
      scaffoldBackgroundColor: Colors.black,
      // Card 默认用 surfaceContainerLow，显式再指定一次避免主题推导差异
      cardTheme: CardThemeData(
        color: const Color(0xFF101014),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          TargetPlatform.android: predictiveBack
              ? const PredictiveBackPageTransitionsBuilder()
              : const ZoomPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// 把 Miuix 主题注入整棵子树。
class _MiuixScope extends StatelessWidget {
  const _MiuixScope({required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (child == null) return const SizedBox.shrink();
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeSetting.mode,
      builder: (context, mode, _) {
        final brightness = switch (mode) {
          ThemeMode.light => Brightness.light,
          ThemeMode.dark => Brightness.dark,
          ThemeMode.system => MediaQuery.platformBrightnessOf(context),
        };
        return ValueListenableBuilder<double>(
          valueListenable: ThemeSetting.uiScale,
          builder: (context, scale, _) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(scale),
              ),
              child: MiuixTheme(
                data: MiuixThemeData.of(brightness),
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  value: _overlayStyleOf(brightness),
                  child: Material(type: MaterialType.transparency, child: child!),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 沉浸式系统栏的样式。
  ///
  /// 为什么要自己设：`MiuixTopAppBar` 不是 Material 的 `AppBar`，不会通过
  /// `AppBarTheme.systemOverlayStyle` 帮我们设；而 edge-to-edge 下状态栏图标
  /// 颜色必须跟着明暗走，否则浅色主题下白色图标直接看不见。
  ///
  /// `systemNavigationBarContrastEnforced: false` 是关键的一条：系统默认会给
  /// 手势导航区叠一层半透明黑，那层正好压在玻璃底栏上，看起来像「底栏下缘
  /// 多了一条灰边」。关掉它，玻璃才能一路干净地铺到屏幕最底。
  static SystemUiOverlayStyle _overlayStyleOf(Brightness brightness) =>
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      );
}

/// 给全局注入「底栏占位」的底部内边距。
///
/// 为什么需要：玻璃底栏是 `Stack` + `Positioned` 悬浮叠加的，**不占**
/// `Scaffold.bottomNavigationBar` 槽位，因此各页面自己的 `Scaffold` 完全不知道
/// 底下还压着一层底栏。后果是 SnackBar 等贴着 Scaffold 底部的元素会被底栏盖住
/// （本项目有 170+ 处 SnackBar，逐个改不现实）。
///
/// 做法：在 `MaterialApp.builder` 里调大 `MediaQuery` 的底部 padding，
/// 框架会据此把 SnackBar、BottomSheet 等抬高到底栏之上。
/// 只影响 `padding.bottom`，不改变 `size`，避免影响正常布局计算。
///
/// ⚠️⚠️ **绝对不要同时修改 `viewPadding`**（踩过大坑，务必记住）
///
/// v4.6.1 时这里把 `viewPadding.bottom` 也一起加了 `miuixNavBarOccupiedHeight`，
/// 当时看起来无害。但 `MiuixFloatingNavigationBar` 恰恰是**读 `viewPadding`
/// 来算自己离屏幕底的距离**的：
///
/// ```dart
/// final navigationInset = MediaQuery.viewPaddingOf(context).bottom;
/// final bottomPadding = navigationInset != 0 ? 26 + navigationInset : 36.0;
/// ```
///
/// 于是真实 16dp 被这里撑成 76dp，Miuix 再算出 `26 + 76 = 102dp` ——
/// 真机实测底栏悬空 **104dp**，与计算值几乎完全吻合。**间距被算了两遍。**
///
/// 副作用还不止于此：`viewPadding` 是 `SafeArea` 的依据，撑大它会让全局
/// 所有 `SafeArea` 都多出一截底部留白。
///
/// 结论：SnackBar 需要的是 `padding`，改 `padding` 就够，`viewPadding` 必须保持原值。
///
/// v4.7 补充：底栏已换成 `MiuixGlassNavigationBar`（v4.8.6 起进一步换成自研的
/// `MiuixLiquidGlassNavigationBar`），它自己**不读** `viewPadding`
/// （改用 `LayoutBuilder` 拿外部约束，间距由 `main.dart` 的 `Positioned` 控制），
/// 所以上面那个「间距算两遍」的具体路径已经不存在了。但这条规则**依然成立**：
/// `main.dart` 里算底栏离屏底距离用的就是 `viewPaddingOf(context).bottom`，
/// 一旦这里污染了它，底栏会被整体顶高。
class _GlassNavInsets extends StatelessWidget {
  const _GlassNavInsets({required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        padding: mq.padding.copyWith(
          bottom: mq.padding.bottom + miuixNavBarOccupiedHeight,
        ),
      ),
      child: child ?? const SizedBox.shrink(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  Widget build(BuildContext context) {
    return const MainPage();
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  /// 当前选中的 Tab。顺序 = 底栏从左到右：
  /// 0 课程 / 1 账号 / 2 课件 / 3 设置
  int _selectedIndex = 0;

  late final PageController _pageController =
      PageController(initialPage: _selectedIndex);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // [移除] 底栏几何常量（_kNavSideMargin / _kNavBottomGap / _kNavBarHeight /
  // _kNavBlurRadius）。
  //
  // 2026-09-22 用户拍板「底部导航栏改为 miuix 标准样式，采用非悬浮的固定布局」，
  // 左右边距与「离底抬起」两个常量随之作废；高度与模糊半径改由
  // `MiuixNavigationBarDefaults`（库定义）和 `MiuixGlassSpec`（玻璃口径）提供，
  // 不再需要在本文件里存一份。
  //
  // 页面留白仍走 `miuixNavBarOccupied(context)`（widget/miuix_nav_metrics.dart），
  // 那是「底栏顶边离屏底多远」的单一事实来源。

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      (coursesPageKey.currentState as dynamic)?.onVisibilityChanged(true);
      _checkUpdate();
      // 赞赏弹窗已按要求关闭并删除（整个 _showSponsorDialog 都删了）。
      //
      // 为什么删：它 barrierDismissible:false —— 点外面关不掉，必须点
      // 「我已赞助」或「去赞助」；而每次重装 App 数据都会重置，
      // 于是每装一次新包就被强制弹一次。而且赞赏码是原作者的收款码。
      //
      // 要恢复的话从 git history 里把 _showSponsorDialog /
      // _saveImageAndSponsor / _hasSponsoredKey 拿回来即可。
    });
  }

  Future<void> _checkUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final dio = Dio();
      // ⚠️ 不能用 `/releases/latest`：这个接口**不返回 prerelease**，
      // 而本项目的测试包全部是 prerelease → 实测它直接返回 404，
      // 异常又被下面的 catch 吞掉 → 更新检查永远是死的（真机上从不提示更新）。
      // 改成拉列表，自己挑第一个非 draft 的。
      final response = await dio.get(
        'https://api.github.com/repos/makisekurse/course_helper/releases',
        queryParameters: {'per_page': 10},
      );

      final list = response.data;
      if (list is! List || list.isEmpty) {
        AppLogger.i('更新检查', '线上没有可用的 release');
        return;
      }
      final data = list.firstWhere(
        (r) => r is Map && r['draft'] != true,
        orElse: () => null,
      );
      if (data is! Map) {
        AppLogger.i('更新检查', '线上没有非 draft 的 release');
        return;
      }

      // tag 可能长成 `v1.2.24` / `test-apk-1.2.3-r5`，不能直接 int.parse，
      // 统一先抠出第一段 `数字.数字`。
      final tag = (data['tag_name'] ?? '').toString();
      final latestVersion = _versionOf(tag);
      final mine = _versionOf(currentVersion);
      if (latestVersion == null || mine == null) {
        AppLogger.w('更新检查', '解析不出版本号（tag「$tag」/ 当前「$currentVersion」），跳过');
        return;
      }

      if (_isNewerVersion(latestVersion, mine)) {
        _showUpdateDialog(
          latestVersion: latestVersion,
          releaseNotes: (data['body'] ?? '暂无更新说明').toString(),
          downloadUrl: (data['html_url'] ??
                  'https://github.com/makisekurse/course_helper/releases')
              .toString(),
        );
      } else {
        AppLogger.i('更新检查', '已是最新（当前 $currentVersion，线上 $tag）');
      }
    } catch (e) {
      // 更新检查失败不该影响启动，但**要留下痕迹** ——
      // 以前这里静默吞异常，导致「更新检查坏了」一直没人发现。
      AppLogger.w('更新检查', '检查更新失败：$e');
    }
  }

  /// 从任意 tag / versionName 里抠出第一段版本号。
  ///
  /// `v1.2.24` → `1.2.24`；`test-apk-1.2.3-r5` → `1.2.3`；`1.2.3-test43` → `1.2.3`
  static final RegExp _versionPattern = RegExp(r'\d+(?:\.\d+)*');

  static String? _versionOf(String raw) =>
      _versionPattern.firstMatch(raw)?.group(0);

  bool _isNewerVersion(String latest, String current) {
    try {
      final latestParts = latest.split('.').map(int.parse).toList();
      final currentParts = current.split('.').map(int.parse).toList();
      
      // 不写死 3 段：`1.2` 与 `1.2.3.1` 都要能比
      final len = latestParts.length > currentParts.length
          ? latestParts.length
          : currentParts.length;
      for (int i = 0; i < len; i++) {
        final latestNum = i < latestParts.length ? latestParts[i] : 0;
        final currentNum = i < currentParts.length ? currentParts[i] : 0;
        
        if (latestNum > currentNum) return true;
        if (latestNum < currentNum) return false;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  void _showUpdateDialog({
    required String latestVersion,
    required String releaseNotes,
    required String downloadUrl,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('发现新版本'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '最新版本: v$latestVersion',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '更新内容:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(releaseNotes),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              launchUrl(Uri.parse(downloadUrl));
            },
            child: const Text('前往下载'),
          ),
        ],
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 底栏由 Stack 叠加（弃用 Scaffold.bottomNavigationBar）：
      // 玻璃靠 `BackdropFilter` 采「**已经画好的**内容」，一旦挪进槽位，
      // body 会被顶到栏上方、栏底下没有内容可糊 —— 糊了个寂寞。
      body: Stack(
        children: [
          // ── Tab 内容 ─────────────────────────────────────────────────
          //
          // 滑动切换 + 保活策略：
          //   使用 PageView 承载 4 个 Tab（课程 / 账号 / 课件 / 设置），
          //   配合 BouncingScrollPhysics 实现极其细腻的左右滑动手感。
          //   每个 Tab 通过 _KeepAliveTab (AutomaticKeepAliveClientMixin)
          //   永久保活，切页不销毁 State，各列表位置与输入状态完美保留。
          Positioned.fill(
            child: PageView(
              controller: _pageController,
              physics: const BouncingScrollPhysics(),
              onPageChanged: _onPageChanged,
              children: [
                _KeepAliveTab(child: CoursesPage(key: coursesPageKey)),
                const _KeepAliveTab(child: AccountsPage()),
                const _KeepAliveTab(child: CoursewarePage()),
                const _KeepAliveTab(child: SettingsPage()),
              ],
            ),
          ),

          // ── 统一底栏宿主（由 NavigationBarHost 动态切换传统 Miuix / Liquid Glass）──
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: NavigationBarHost(
              selectedIndex: _selectedIndex,
              onSelect: _onNavTap,
              pageController: _pageController,
            ),
          ),
        ],
      ),
    );
  }

  int? _targetNavIndex;

  void _onPageChanged(int index) {
    if (_targetNavIndex != null) {
      if (index == _targetNavIndex) {
        _targetNavIndex = null;
      } else {
        // 正在通过点击底栏进行长距离跨页平滑滚动，忽略中间过渡页的触发，防止底栏图标与指示器在过渡期来回抽搐抖动
        return;
      }
    }
    if (_selectedIndex != index) {
      setState(() {
        _selectedIndex = index;
      });
      (coursesPageKey.currentState as dynamic)?.onVisibilityChanged(index == 0);
    }
  }

  /// 底栏点击统一入口（切页 + 动画平滑滚动 PageView + 通知课程页可见性变化）
  void _onNavTap(int index) {
    if (index == _selectedIndex) return;
    _targetNavIndex = index;
    setState(() {
      _selectedIndex = index;
    });
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      ).then((_) {
        if (_targetNavIndex == index) {
          _targetNavIndex = null;
        }
      });
    }
    (coursesPageKey.currentState as dynamic)?.onVisibilityChanged(index == 0);
  }
}

/// 保持 Tab 页面状态不销毁的保活包装器
class _KeepAliveTab extends StatefulWidget {
  const _KeepAliveTab({required this.child});
  final Widget child;

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}