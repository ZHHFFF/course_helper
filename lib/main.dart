import'dart:ui' show PlatformDispatcher;
import'package:flutter/material.dart';
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
// [新增] Miuix 玻璃底栏的几何契约（占位高度 / 页面留白）
import'./pages/widget/miuix_nav_metrics.dart';
// [新增] KernelSU 对齐的玻璃规格（模糊半径 / 色调 / vibrancy / 按压 / 几何）。
// 顶栏与底栏都从这里取值，保证「两栏是同一种玻璃、只是参数不同」。
import'./pages/widget/miuix_glass_spec.dart';
// [新增] 液态玻璃底栏本体。
// 为什么不用包里的 `MiuixGlassNavigationBar`：它的玻璃是「录图层快照 → 喂 shader」，
// 采样由 `paint()` 驱动，而 `ListView` 的 viewport 自己是重绘边界，滚动时上面的
// 捕获节点收不到 `paint()` → 快照冻住（实测只有 ~19 次/秒）→ 表现为「一卡一卡」。
// 本文件改用与顶栏完全相同的 `BackdropFilter` 机制，详见组件文件头。
import'./pages/widget/miuix_liquid_glass_nav_bar.dart';
// [新增] 底栏外观设置（悬浮 / 贴边）
import'./setting/navbar_setting.dart';
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

  // [新增] 底栏外观设置要在首帧前读好，否则启动瞬间会先用默认值渲染一帧、
  // 读到配置后再跳变一次（视觉上会闪一下）。这里提前加载。
  await NavBarSetting.ensureLoaded();

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
    return MaterialApp(
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
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: ThemeMode.system,
      // [改动] 用 MiuixTheme 包裹整棵树。
      //
      // 为什么必须包在最外层：MiuixTheme.of() 在上下文**未被包裹**时不会抛错，
      // 而是**静默回退到浅色默认值**（MiuixThemeData.light()）。深色模式下会
      // 表现为「界面莫名变白」且不报任何异常，极难排查。所以这里必须在
      // MaterialApp 之外就包好，保证所有后代都拿得到正确主题。
      //
      // 注意：MiuixThemeData.of(context) 依赖 MediaQuery 判断明暗，
      // 因此它要在 MaterialApp **内部**才能拿到正确的 platformBrightness，
      // 但又必须包住 materialApp 的所有后代 —— 故放在 builder 里，
      // 与 _GlassNavInsets 同层。
      //
      // 同时给所有页面的 SnackBar / 底部提示注入底栏高度的内边距。
      //
      // 背景：底栏是悬浮的，不占 Scaffold 的 bottomNavigationBar 槽位，
      // 所以各页面自己的 Scaffold 并不知道底下还压着一层底栏。
      // SnackBar 默认贴 Scaffold 底部 → 会被玻璃底栏盖住。
      // 给 MediaQuery 加上底部 padding，框架就会据此把 SnackBar 抬高。
      //
      // ⚠️⚠️ 这段补偿**只能在 `MyHomePage` 里做**，绝不能放在 `builder` 里全局生效。
      // 曾经就是放在这里（MaterialApp.builder 会包住整个 Navigator），
      // 后果是**每一个二级页**（登录页 / 日志页 / 各设置页……）的
      // `MediaQuery.padding.bottom` 都被凭空加了 `miuixNavBarOccupiedHeight`。
      // 而那些页面根本没有底栏（push 出来的路由会盖住它），于是：
      //   - 它们自己的 `SafeArea` 底部会多出 ~76dp 空白
      //   - 它们底部的 SnackBar 会凭空悬高 76dp
      //   - 它们自己铺的底栏（如日志页的操作条）会飘在屏幕中间
      // 所以补偿下沉到 `MyHomePage`，只影响真正有底栏的那一层。
      builder: (context, child) {
        return _MiuixScope(child: child);
      },
      // ⚠️⚠️ 底栏补偿**只能挂在 `home:` 上**，绝不能放进 `builder:` 里全局生效。
      //
      // `_GlassNavInsets` 给 `MediaQuery.padding.bottom` 加
      // `miuixNavBarOccupiedHeight`，目的是让首页 Scaffold 渲染的 SnackBar
      // 不被悬浮玻璃底栏盖住。但 `MaterialApp.builder` 包住的是**整个 Navigator**，
      // 放在那里会连所有 push 出来的二级页（登录页 / 日志页 / 各设置页……）
      // 一起污染。而那些页面根本没有底栏（push 出来的路由会盖住它），于是：
      //   - 它们自己的 `SafeArea` 底部凭空多出 ~76dp 空白
      //   - 它们底部的 SnackBar 凭空悬高 76dp
      //   - 它们自己铺的底栏（如日志页的操作条）会飘在屏幕中间
      //
      // 挂在 `home:` 上则只作用于**首页这一个路由**：push 出来的路由是
      // Navigator overlay 里的**兄弟节点**而非 `home` 的后代，拿不到这层 MediaQuery，
      // 天然免疫。这正是我们要的「只补偿真正有底栏的那一层」。
      home: const _GlassNavInsets(child: MyHomePage()),
      routes: {
        '/accounts': (context) => const AccountsPage(),
        '/login': (context) => const LoginPage(),
      },
    );
  }

  /// 浅色主题：纯白背景 + 紫色主色（seed deepPurple）
  static ThemeData _buildLightTheme() {
    final base = ColorScheme.fromSeed(
      seedColor: Colors.deepPurple,
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
    );
  }

  /// 深色主题：纯黑背景（真黑，非灰黑）
  ///
  /// 注意容器层级：背景是纯黑 `#000000`，各级 surfaceContainer 必须**逐级提亮**
  /// 才能让卡片看出边界。若把 surfaceContainerLow 也设成接近纯黑，
  /// 卡片会和背景糊在一起、层级关系完全丢失。
  static ThemeData _buildDarkTheme() {
    final base = ColorScheme.fromSeed(
      seedColor: Colors.deepPurple,
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
    );
  }
}

/// 把 Miuix 主题注入整棵子树。
///
/// 放在 `MaterialApp.builder` 里，好处是能拿到已由 `MaterialApp` 建立好的
/// `MediaQuery`（含正确的 `platformBrightness`），从而让浅色/深色自动跟随系统。
///
/// ⚠️ 签名注意：`MiuixThemeData.of()` 的第一个参数是 `Brightness`（不是
/// `BuildContext`），与 Flutter 里 `Theme.of(context)` 的习惯不同，别写错。
///
/// ⚠️ 关键坑：`MiuixTheme.of()` 在未包裹时**不报错**，而是静默返回
/// `MiuixThemeData.light()`。若这里忘记包裹，深色模式下界面会莫名变浅色，
/// 且没有任何异常提示。所以这个 wrapper 不允许被移除。
class _MiuixScope extends StatelessWidget {
  const _MiuixScope({required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (child == null) return const SizedBox.shrink();
    return MiuixTheme(
      data: MiuixThemeData.of(MediaQuery.platformBrightnessOf(context)),
      // [新增] 全局补一层透明 `Material`。
      //
      // 为什么需要：Miuix 的 `MiuixScaffold` / `MiuixSurface` **不提供
      // `DefaultTextStyle`**（它是纯 Miuix 组件，不走 Material 那套）。于是
      // Miuix 页面里的 `Text` 找不到 `DefaultTextStyle` 祖先，会退回到
      // `DefaultTextStyle.fallback()` —— 表现是**每行文字都带一条黄色双下划线**。
      //
      // 实测：外观设置页（MiuixScaffold）标题、小标题、开关行标题全是黄下划线。
      // 这里在 Navigator 之上补一层 `MaterialType.transparency`（不画任何背景），
      // 所有路由就都有 `DefaultTextStyle` 了。
      //
      // 对原有 Material 页面无影响：`Scaffold` 自己也会套一层 `Material`，
      // 且用的是同一套主题文字样式。
      child: Material(type: MaterialType.transparency, child: child!),
    );
  }
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
  int _selectedIndex = 0;

  // ── 底栏几何常量 ────────────────────────────────────────────────────────
  //
  // 全部来自对同一台机器（一加 13 / Android 15 / density 3.5）上 **LSPosed 管理器**
  // 的 uiautomator 实测 —— 那也是一个 Miuix 应用，是最权威的「参照物」。
  // 原始像素与 dp 换算（÷3.5）：
  //   胶囊本体   [86,2458][1178,2682] → 高 224px = 64.0dp，左右边距各 86px = 24.6dp
  //   单个 item  [100,2472][366,2668] → 高 196px = 56.0dp，宽 266px = 76.0dp
  //   胶囊离屏底 2780 - 2682 = 98px = 28.0dp
  //   其中手势条安全区 56px = 16.0dp → 额外留 12.0dp
  //
  // ⚠️ 注意库默认 `MiuixGlassNavigationBarDefaults.height = 54.0`，
  // 与参照物的 64dp 不一致。这里按用户「你看看他的底栏高度」的要求对齐到 64。

  /// 悬浮底栏左右边距（实测 24.6dp，取整 24）
  static const double _kNavSideMargin = 24;

  /// 悬浮底栏离「手势条安全区上沿」的额外间距（实测 28 - 16 = 12）
  static const double _kNavBottomGap = 12;

  /// 底栏内容高度（实测参照物 64dp，与 KernelSU `FloatingBottomBar` 的
  /// `height(64.dp)` 一致 → 见 [MiuixGlassSpec.navShellHeight]）
  static const double _kNavBarHeight = MiuixGlassSpec.navShellHeight;

  /// 底栏玻璃的模糊半径（dp）。
  ///
  /// 2026-09-22 起按 KernelSU 的 `FloatingBottomBar` 取
  /// [MiuixGlassSpec.navBlurRadius] = 14 → sigma 6.3，约顶栏（25 → 11.25）的一半
  /// —— KernelSU 的悬浮胶囊是「轻霜」而不是重磨砂。
  /// （改之前是 20 → sigma 9.0，与 Miuix 玻璃材质 `puredThinGlass` 一致。）
  static const double _kNavBlurRadius = MiuixGlassSpec.navBlurRadius;

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
      final response = await dio.get('https://api.github.com/repos/makisekurse/course_helper/releases/latest');
      final data = response.data;
      final latestVersion = data['tag_name']?.toString().replaceAll('v', '') ?? '';

      if (_isNewerVersion(latestVersion, currentVersion)) {
        _showUpdateDialog(
          latestVersion: latestVersion,
          releaseNotes: data['body'] ?? '暂无更新说明',
          downloadUrl: data['html_url'] ?? 'https://github.com/makisekurse/course_helper/releases/latest',
        );
      }
    } catch (e) {
      // 忽略更新检查错误
    }
  }

  bool _isNewerVersion(String latest, String current) {
    try {
      final latestParts = latest.split('.').map(int.parse).toList();
      final currentParts = current.split('.').map(int.parse).toList();
      
      for (int i = 0; i < 3; i++) {
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
    // 底栏离屏幕底的距离依据：实测同为一加 13 上的 LSPosed（也是 Miuix 应用），
    // 其底栏胶囊底边距屏幕底 28dp，其中 16dp 是手势条安全区 → 额外留 12dp。
    //
    // ⚠️ 必须用 `viewPaddingOf` 而不是 `MediaQuery.of().padding`：
    // 上层 `_GlassNavInsets` 为了给 SnackBar 让位已经把 `padding.bottom`
    // 撑大了，用它算间距会把底栏顶得极高（这正是之前悬空 104dp 的成因）。
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;

    return Scaffold(
      // 底栏由 Stack 叠加（弃用 Scaffold.bottomNavigationBar，因为它无法悬浮）
      body: Stack(
        children: [
          // 内容层：直接铺满即可。
          //
          // 为什么不再需要「捕获组件包住内容层」：底栏已改用 `BackdropFilter`
          // （与顶栏同一机制），它在合成时**实时**读正下方像素，
          // 不需要预先录制任何快照。旧的 `MiuixSampledBackdropCapture` +
          // 滚动唤醒那套已随方案 B 一并移除（组件文件保留备查）。
          Positioned.fill(
            child: IndexedStack(
              index: _selectedIndex,
              children: [CoursesPage(key: coursesPageKey), const AccountsPage()],
            ),
          ),
          // [改动 v4.8.6] 底栏换成自研的 `MiuixLiquidGlassNavigationBar`。
          //
          // 为什么不直接用包里的 `MiuixGlassNavigationBar`：它的玻璃是
          // 「录图层快照 → 喂 shader」，采样由 `paint()` 驱动；而 `ListView` 的
          // `Viewport` 自己就是重绘边界（`viewport.dart:752`），滚动时重绘被限制在
          // viewport 自己的图层里，**位于它之上的捕获节点收不到 `paint()`**，
          // 快照就冻在旧帧 —— 真机实测滚动期间只有 ~19 次/秒（60Hz 屏），
          // 表现为「停住 → 跳一下 → 再停住」。
          //
          // 新组件改用与顶栏**完全相同**的 `BackdropFilter` + `ImageFilter.blur`：
          // 合成时实时取正下方像素，永远与当前帧同步，且只有一次 GPU blur pass。
          // 代价是暂时没有折射（用户已确认可接受）。
          //
          // 几何参数（左右 24 / 离底 12+安全区）来自对同一台机器上 LSPosed 管理器
          // （也是 Miuix 应用）的 uiautomator 实测：
          //   胶囊 [86,2458][1178,2682] → 高 64dp，左右边距 24.6dp，离屏底 28dp
          //   离屏底 28dp 中有 16dp 是手势条安全区 → 额外留 12dp
          //
          // ⚠️ 外面套 ValueListenableBuilder 而不是把它塞进 Positioned：
          // 因为「悬浮 / 贴边」两态的 left/right/bottom 都不同，必须让
          // **Positioned 本身**参与重建。`Positioned` 是 ParentDataWidget，
          // 中间隔一层 StatefulWidget 不影响它向上找到 RenderStack（合法）。
          ValueListenableBuilder<bool>(
            valueListenable: NavBarSetting.floating,
            builder: (context, floating, _) => Positioned(
              left: floating ? _kNavSideMargin : 0,
              right: floating ? _kNavSideMargin : 0,
              bottom: floating ? safeBottom + _kNavBottomGap : 0,
              child: _buildMiuixNavBar(
                context,
                floating: floating,
                safeBottom: safeBottom,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 按当前设置构建液态玻璃底栏（悬浮 / 贴边二选一），两态都是**真模糊**。
  ///
  /// ⚠️ 用的是 `MiuixLiquidGlassNavigationBar`（`BackdropFilter` 版），
  /// 不是包里的 `MiuixNavigationBar` / `MiuixFloatingNavigationBar` —— 后两者是
  /// 纯色版本，**没有任何模糊能力**（第一版就是错在这里，做出来一个实心块，
  /// 用户直接问「我的玻璃呢？」）。
  ///
  /// ⚠️ 也不是包里的 `MiuixGlassNavigationBar`：它的玻璃靠图层快照采样，
  /// 滚动时会冻住（详见 `build()` 里的注释）。
  Widget _buildMiuixNavBar(
    BuildContext context, {
    required bool floating,
    required double safeBottom,
  }) {
    // 图标按选中态切换实心/描边
    final icons = <Widget>[
      Icon(_selectedIndex == 0 ? Icons.school : Icons.school_outlined),
      Icon(
        _selectedIndex == 1
            ? Icons.account_circle
            : Icons.account_circle_outlined,
      ),
    ];
    const labels = <String>['课程', '账号'];

    final bar = MiuixLiquidGlassNavigationBar(
      items: [
        for (var i = 0; i < labels.length; i++)
          MiuixLiquidGlassNavItem(
            icon: icons[i],
            label: labels[i],
            contentDescription: labels[i],
          ),
      ],
      selectedIndex: _selectedIndex,
      onSelect: _onNavTap,
      height: _kNavBarHeight,
      blurRadius: _kNavBlurRadius,
      // 悬浮态：胶囊形（默认 cornerRadius 999）+ KernelSU 口径的外阴影
      //         （`dropShadow(radius = 10, Black @ .1/.2)`，传 null 即用默认值）
      // 贴边态：直角 + 去掉阴影，通栏贴底
      shape: floating ? null : const MiuixGlassShape(cornerRadius: 0),
      shadow: floating
          ? null
          : const MiuixGlassShadow(radius: 0, color: Color(0x00000000)),
    );

    if (floating) return bar;

    // 贴边态：玻璃条本身只有 _kNavBarHeight 高，直接 bottom:0 会把手势条
    // 那 16dp 安全区留成一条透明缝（能看见底下内容穿过去）。所以把玻璃条
    // 上抬 safeBottom，缝里用 surface 纯色补上。
    return ColoredBox(
      color: MiuixTheme.of(context).colors.surface,
      child: Padding(
        padding: EdgeInsets.only(bottom: safeBottom),
        child: bar,
      ),
    );
  }

  /// 底栏点击统一入口（切页 + 通知课程页可见性变化）
  void _onNavTap(int index) {
    if (index == _selectedIndex) return;
    setState(() {
      _selectedIndex = index;
    });
    (coursesPageKey.currentState as dynamic)?.onVisibilityChanged(index == 0);
  }
}