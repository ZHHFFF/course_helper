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
// [新增] 液态玻璃底栏（方案 A：悬浮胶囊 + 真实模糊）
import'./pages/widget/liquid_glass_nav_bar.dart';
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
      // 这里统一给 MediaQuery 加上底部 padding，框架会据此把 SnackBar 抬高。
      builder: (context, child) {
        return _MiuixScope(
          child: _GlassNavInsets(child: child),
        );
      },
      home: const MyHomePage(),
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
      child: child!,
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
class _GlassNavInsets extends StatelessWidget {
  const _GlassNavInsets({required this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        padding: mq.padding.copyWith(
          bottom: mq.padding.bottom + glassNavBarOccupiedHeight,
        ),
        viewPadding: mq.viewPadding.copyWith(
          bottom: mq.viewPadding.bottom + glassNavBarOccupiedHeight,
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
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      // 底栏改为悬浮玻璃样式，由 Stack 叠加（不再用 Scaffold 的 bottomNavigationBar）
      body: Stack(
        children: [
          Positioned.fill(
            child: IndexedStack(
              index: _selectedIndex,
              children: [
                CoursesPage(key: coursesPageKey),
                const AccountsPage(),
              ],
            ),
          ),
          // 悬浮液态玻璃底栏（方案 A）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: GlassNavBar(
              currentIndex: _selectedIndex,
              onTap: (index) {
                setState(() {
                  _selectedIndex = index;
                });
                (coursesPageKey.currentState as dynamic)
                    ?.onVisibilityChanged(index == 0);
              },
              items: const <GlassNavItem>[
                GlassNavItem(
                  icon: Icons.school_outlined,
                  activeIcon: Icons.school,
                  label: '课程',
                ),
                GlassNavItem(
                  icon: Icons.account_circle_outlined,
                  activeIcon: Icons.account_circle,
                  label: '账号',
                ),
              ],
              mode: GlassNavMode.floatingBlur,
              isDark: isDark,
              colorScheme: cs,
            ),
          ),
        ],
      ),
    );
  }
}