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
import'./pages/widget/miuix_nav_metrics.dart';
// [新增] 贴边玻璃底栏本体（Miuix 标准底栏 + BackdropFilter）。
// 2026-09-22 用户拍板：取消液态玻璃与悬浮底栏，改用 Miuix 标准样式的固定底栏，
// 但顶栏底栏都要保留模糊。所以这里只是「包里的 MiuixNavigationBar + 一层玻璃」，
// 几何/字号/按压反馈/动画时长全部由库定义，不自造。
import'./pages/widget/miuix_blur_navigation_bar.dart';
// [新增] 深浅色外观设置（原「悬浮底栏」开关作废，见 setting/theme_setting.dart）
import'./setting/theme_setting.dart';
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
      builder: (context, themeMode, _) => MaterialApp(
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
      themeMode: themeMode,
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
      ),
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
    final brightness = MediaQuery.platformBrightnessOf(context);
    return MiuixTheme(
      data: MiuixThemeData.of(brightness),
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
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _overlayStyleOf(brightness),
        child: Material(type: MaterialType.transparency, child: child!),
      ),
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
    return Scaffold(
      // 底栏由 Stack 叠加（弃用 Scaffold.bottomNavigationBar）：
      // 玻璃靠 `BackdropFilter` 采「**已经画好的**内容」，一旦挪进槽位，
      // body 会被顶到栏上方、栏底下没有内容可糊 —— 糊了个寂寞。
      body: Stack(
        children: [
          // ── Tab 内容 ─────────────────────────────────────────────────
          //
          // 保活策略（用户要求「课件如果打开了，就要保活，切回去还是那个页面」）：
          //   课程页 / 课件页 → `Offstage` 常驻，切 Tab 不销毁 State
          //   账号页 / 设置页 → `if` 条件挂载，切走即释放
          //
          // 为什么课程页也要保活：它有个 3 秒轮询在跑「正在上课」状态，
          // 重建会打断轮询；滚动位置也不该被重置。
          //
          // ⚠️ `Offstage` 必须包在 `Positioned.fill` 里：`RenderOffstage` 在
          // offstage 时 `size = constraints.smallest`，而 `Stack` 给非定位子节点
          // 的是 **loose** 约束（min 为 0）→ 直接放进去会塌成 0×0。
          // 用 `Positioned.fill` 给 tight 约束后 `smallest` 才是满屏。
          Positioned.fill(
            child: Offstage(
              offstage: _selectedIndex != 0,
              child: CoursesPage(key: coursesPageKey),
            ),
          ),
          Positioned.fill(
            child: Offstage(
              offstage: _selectedIndex != 2,
              child: const CoursewarePage(),
            ),
          ),
          if (_selectedIndex == 1) const AccountsPage(),
          if (_selectedIndex == 3) const SettingsPage(),

          // ── 玻璃底栏（贴边叠加）──────────────────────────────────────
          //
          // 2026-09-22 用户拍板：取消液态玻璃与悬浮底栏，改用 Miuix 标准样式的
          // 固定底栏，但**顶栏底栏都要保留模糊**。所以这里 = 包里的
          // `MiuixNavigationBar`（几何 / 字号 / 按压 / 动画全由库定义）
          // + 一层 `BackdropFilter` 玻璃，见
          // `widget/miuix_blur_navigation_bar.dart`。
          //
          // 玻璃铺满整条含手势区 → 历史 bug「小白条区域显示为黑块」不复存在
          // （那个黑块来自旧代码用 `ColoredBox(colors.surface)` 补手势区，
          //  而深色下 surface 是纯黑 `#000000`，与上面的玻璃之间出现硬边）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildNavBar(context),
          ),
        ],
      ),
    );
  }

  /// 贴边玻璃底栏（4 个 Tab：课程 / 账号 / 课件 / 设置）。
  ///
  /// 几何、字号、按压反馈、选中动画时长全部由包里的
  /// `MiuixNavigationBarDefaults` 定义（item 高 64 / 图标 26 / 字号 12 /
  /// 动画 300ms），我们只补一层玻璃。
  Widget _buildNavBar(BuildContext context) {
    // 图标：选中态用实心，未选中用描边（Miuix 底栏的常规做法）
    const items = <(IconData, IconData, String)>[
      (Icons.school, Icons.school_outlined, '课程'),
      (Icons.account_circle, Icons.account_circle_outlined, '账号'),
      (Icons.folder_copy, Icons.folder_copy_outlined, '课件'),
      (Icons.settings, Icons.settings_outlined, '设置'),
    ];

    return MiuixBlurNavigationBar(
      children: [
        for (var i = 0; i < items.length; i++)
          MiuixNavigationBarItem(
            selected: _selectedIndex == i,
            onPressed: () => _onNavTap(i),
            // 裸 `Icon` 即可：`MiuixNavigationBarItem` 内部用 `IconTheme.merge`
            // 注入尺寸与状态色（选中 `onSurfaceContainer`，未选中同色 @ 40%），
            // 不需要自己算颜色。
            icon: Icon(_selectedIndex == i ? items[i].$1 : items[i].$2),
            label: items[i].$3,
          ),
      ],
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