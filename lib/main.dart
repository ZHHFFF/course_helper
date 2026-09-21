import'dart:ui' show PlatformDispatcher;
import'package:flutter/material.dart';
import'package:flutter_localizations/flutter_localizations.dart';
// [移除] dynamic_color：已取消 Material You 动态取色，改为固定主题色 + 纯白/纯黑背景
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
  static ThemeData _buildDarkTheme() {
    final base = ColorScheme.fromSeed(
      seedColor: Colors.deepPurple,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: base.copyWith(
        surface: Colors.black,
        surfaceContainerLowest: Colors.black,
        surfaceContainerLow: const Color(0xFF0A0A0C),
        surfaceContainer: const Color(0xFF121214),
        surfaceContainerHigh: const Color(0xFF1A1A1D),
        surfaceContainerHighest: const Color(0xFF232327),
        onSurface: const Color(0xFFF2F2F5),
        onSurfaceVariant: const Color(0xFF9A9AA8),
        outlineVariant: const Color(0xFF2A2A30),
      ),
      scaffoldBackgroundColor: Colors.black,
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