import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:course_helper/main.dart';
import 'package:course_helper/pages/accounts.dart';
import 'package:course_helper/pages/login.dart';
import 'package:course_helper/pages/widget/miuix_liquid_glass_nav_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('登录页手势与按钮响应回归测试 (LoginPage HitTest & Interactions)', () {
    testWidgets('密码登录：表单与登录按钮可正常点击与响应校验', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MiuixTheme(
            data: MiuixThemeData.light(),
            child: const LoginPage(initialLoginType: 'password'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 验证标题为密码登录
      expect(find.text('密码登录'), findsWidgets);

      // 验证存在登录按钮 (MiuixButton)
      final loginBtnFinder = find.widgetWithText(MiuixButton, '登录');
      expect(loginBtnFinder, findsOneWidget);

      // 点击登录按钮（未填内容，应触发验证拦截并显示校验提示，绝不卡死或无响应）
      await tester.tap(loginBtnFinder);
      await tester.pumpAndSettle();

      // 应有校验报错提示「请输入账号」
      expect(find.text('请输入账号'), findsOneWidget);

      // 输入账号
      final textFields = find.byType(MiuixTextField);
      expect(textFields, findsNWidgets(2)); // 账号 + 密码

      await tester.enterText(textFields.first, '13800138000');
      await tester.pumpAndSettle();

      // 再次点击登录按钮，应报错「请输入密码」
      await tester.tap(loginBtnFinder);
      await tester.pumpAndSettle();
      expect(find.text('请输入密码'), findsOneWidget);

      // 密码显隐按钮可正常点击（初始为 visibility_off）
      final visibilityIcon = find.byIcon(Icons.visibility_off);
      expect(visibilityIcon, findsOneWidget);
      await tester.tap(visibilityIcon);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.visibility), findsOneWidget);
    });

    testWidgets('验证码登录：验证码获取与登录按钮可正常交互', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MiuixTheme(
            data: MiuixThemeData.light(),
            child: const LoginPage(initialLoginType: 'captcha'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('验证码登录'), findsWidgets);

      final sendCaptchaBtn = find.widgetWithText(MiuixButton, '获取验证码');
      expect(sendCaptchaBtn, findsOneWidget);

      final loginBtnFinder = find.widgetWithText(MiuixButton, '验证码登录');
      expect(loginBtnFinder, findsOneWidget);

      // 点击获取验证码（未填手机号）
      await tester.tap(sendCaptchaBtn);
      await tester.pumpAndSettle();

      // 点击登录按钮
      await tester.tap(loginBtnFinder);
      await tester.pumpAndSettle();

      expect(find.text('请输入账号'), findsOneWidget);
    });
  });

  group('账号页添加账号与路由跳转回归测试 (AccountsSheet & Route Transition)', () {
    testWidgets('从账号页点击加号，再点击密码登录，能够顺利进入 LoginPage 并且点击登录按钮有响应', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MiuixTheme(
            data: MiuixThemeData.light(),
            child: const AccountsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 找到 FAB 并点击
      final fabFinder = find.byType(MiuixFloatingActionButton);
      expect(fabFinder, findsOneWidget);
      await tester.tap(fabFinder);
      await tester.pumpAndSettle();

      // 检查抽屉是否出现
      final passwordPrefFinder = find.text('密码登录');
      expect(passwordPrefFinder, findsOneWidget);

      // 点击密码登录
      await tester.tap(passwordPrefFinder);
      await tester.pumpAndSettle();

      // 应该已经进入了 LoginPage
      expect(find.byType(LoginPage), findsOneWidget);

      // 找到登录按钮
      final loginBtnFinder = find.widgetWithText(MiuixButton, '登录');
      expect(loginBtnFinder, findsOneWidget);

      // 点击登录按钮
      await tester.tap(loginBtnFinder);
      await tester.pumpAndSettle();

      // 校验失败显示提示「请输入账号」，表明手势完全未被遮挡
      expect(find.text('请输入账号'), findsOneWidget);
    });

    testWidgets('从账号页点击加号，再点击验证码登录，能够顺利进入 LoginPage 并且获取验证码与登录按钮均可交互', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MiuixTheme(
            data: MiuixThemeData.light(),
            child: const AccountsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fabFinder = find.byType(MiuixFloatingActionButton);
      await tester.tap(fabFinder);
      await tester.pumpAndSettle();

      final smsPrefFinder = find.text('验证码登录');
      expect(smsPrefFinder, findsOneWidget);

      await tester.tap(smsPrefFinder);
      await tester.pumpAndSettle();

      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.text('获取验证码'), findsOneWidget);

      final sendCodeBtn = find.widgetWithText(MiuixButton, '获取验证码');
      await tester.tap(sendCodeBtn);
      await tester.pumpAndSettle();

      final loginBtnFinder = find.widgetWithText(MiuixButton, '验证码登录');
      await tester.tap(loginBtnFinder);
      await tester.pumpAndSettle();

      expect(find.text('请输入账号'), findsOneWidget);
    });
  });

  group('液态玻璃底栏与滑动切换测试 (MiuixLiquidGlassNavigationBar & Sliding Tabs)', () {
    testWidgets('底栏包含4个Tab项并响应点击事件', (tester) async {
      int selected = 0;
      final controller = PageController();

      await tester.pumpWidget(
        MaterialApp(
          home: MiuixTheme(
            data: MiuixThemeData.light(),
            child: Scaffold(
              body: MiuixLiquidGlassNavigationBar(
                items: const [
                  MiuixLiquidGlassNavItem(icon: Icon(Icons.school), label: '课程', contentDescription: '课程'),
                  MiuixLiquidGlassNavItem(icon: Icon(Icons.account_circle), label: '账号', contentDescription: '账号'),
                  MiuixLiquidGlassNavItem(icon: Icon(Icons.folder), label: '课件', contentDescription: '课件'),
                  MiuixLiquidGlassNavItem(icon: Icon(Icons.settings), label: '设置', contentDescription: '设置'),
                ],
                selectedIndex: selected,
                pageController: controller,
                bottomPadding: 16.0,
                onSelect: (index) {
                  selected = index;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('课程'), findsOneWidget);
      expect(find.text('账号'), findsOneWidget);
      expect(find.text('课件'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);

      // 点击切换到第二个 Tab (账号)
      await tester.tap(find.text('账号'));
      await tester.pumpAndSettle();
      expect(selected, equals(1));

      // 点击切换到第四个 Tab (设置)
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(selected, equals(3));
    });

    testWidgets('PageView 与液态玻璃底栏联动滑动，不发生溢出与异常', (tester) async {
      final controller = PageController();
      int selected = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: MiuixTheme(
            data: MiuixThemeData.light(),
            child: Scaffold(
              body: Stack(
                children: [
                  PageView(
                    controller: controller,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: (i) => selected = i,
                    children: const [
                      Center(child: Text('Page 0')),
                      Center(child: Text('Page 1')),
                      Center(child: Text('Page 2')),
                      Center(child: Text('Page 3')),
                    ],
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: MiuixLiquidGlassNavigationBar(
                      items: const [
                        MiuixLiquidGlassNavItem(icon: Icon(Icons.school), label: '课程'),
                        MiuixLiquidGlassNavItem(icon: Icon(Icons.account_circle), label: '账号'),
                        MiuixLiquidGlassNavItem(icon: Icon(Icons.folder), label: '课件'),
                        MiuixLiquidGlassNavItem(icon: Icon(Icons.settings), label: '设置'),
                      ],
                      selectedIndex: selected,
                      pageController: controller,
                      bottomPadding: 16.0,
                      onSelect: (i) {
                        selected = i;
                        controller.jumpToPage(i);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Page 0'), findsOneWidget);

      // 左右滑动手势：向左滑切到 Page 1
      await tester.fling(find.text('Page 0'), const Offset(-600, 0), 1000);
      await tester.pumpAndSettle();

      expect(find.text('Page 1'), findsOneWidget);
      expect(selected, equals(1));
    });

    testWidgets('MainPage 点击远距离 Tab，中间切页过程中底栏 selectedIndex 稳定不抖动', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MainPage(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('设置'), findsOneWidget);

      // 点击设置 Tab
      await tester.tap(find.text('设置'));

      final observedIndices = <int>[];
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 35));
        final navBar = tester.widget<MiuixLiquidGlassNavigationBar>(find.byType(MiuixLiquidGlassNavigationBar));
        observedIndices.add(navBar.selectedIndex);
      }

      await tester.pump(const Duration(milliseconds: 400));
      final finalNavBar = tester.widget<MiuixLiquidGlassNavigationBar>(find.byType(MiuixLiquidGlassNavigationBar));
      observedIndices.add(finalNavBar.selectedIndex);

      // 验证过程中绝无跳变回 1 或 2，全程稳定为 3
      expect(observedIndices.every((idx) => idx == 3), isTrue);
    });
  });
}
