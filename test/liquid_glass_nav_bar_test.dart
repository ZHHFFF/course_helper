// 玻璃底栏的几何契约测试。
//
// 背景：底栏是 Stack + Positioned 悬浮叠加的，**不占** Scaffold 的
// bottomNavigationBar 槽位。因此有三处需要依赖「底栏占位高度」这个常量：
//   1. 页面滚动内容底部留白（避免最后一项被盖）→ glassNavBarClearance
//   2. 浮动按钮抬高（避免 FAB 被盖）           → glassNavFabLocation
//   3. 全局 MediaQuery.padding.bottom 注入     → glassNavBarOccupiedHeight
//      （让 SnackBar / BottomSheet 自动抬到底栏之上）
//
// 本测试锁定这三者的数值关系，防止后续调底栏高度时漏改某一处。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/pages/widget/liquid_glass_nav_bar.dart';

void main() {
  group('底栏占位高度常量', () {
    test('glassNavBarOccupiedHeight = 抬起 8 + 内容高 52', () {
      expect(glassNavBarLift, 8);
      expect(glassNavBarContentHeight, 52);
      expect(
        glassNavBarOccupiedHeight,
        glassNavBarLift + glassNavBarContentHeight,
      );
      expect(glassNavBarOccupiedHeight, 60);
    });

    test('整体高度比 Material 默认标签栏（80）更紧凑', () {
      // Liquid Glass 的观感要求"薄薄一层"，这里锁住它不能变厚
      expect(glassNavBarOccupiedHeight, lessThan(80));
    });
  });

  group('glassNavBarClearance', () {
    testWidgets('等于 占位高度 + 安全区 + 24 呼吸间距', (tester) async {
      late double clearance;

      await tester.pumpWidget(
        MediaQuery(
          // 模拟一个底部安全区 48 的设备
          data: const MediaQueryData(padding: EdgeInsets.only(bottom: 48)),
          child: Builder(
            builder: (context) {
              clearance = glassNavBarClearance(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(clearance, glassNavBarOccupiedHeight + 48 + 24);
      expect(clearance, 60 + 48 + 24);
    });

    testWidgets('无安全区时等于 占位高度 + 24', (tester) async {
      late double clearance;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Builder(
            builder: (context) {
              clearance = glassNavBarClearance(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(clearance, glassNavBarOccupiedHeight + 24);
    });
  });

  group('glassNavFabLocation', () {
    testWidgets('把 FAB 摆到「底栏顶边 + 16 呼吸间距」之上', (tester) async {
      const screenHeight = 800.0;
      const screenWidth = 400.0;
      const safeBottom = 24.0;
      const fabSize = 56.0;
      const breathing = 16.0;

      late FloatingActionButtonLocation location;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(screenWidth, screenHeight),
            padding: EdgeInsets.only(bottom: safeBottom),
          ),
          child: Builder(
            builder: (context) {
              location = glassNavFabLocation(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // 用 ScaffoldPrelayoutGeometry 的真实构造方式算 FAB 的 Y 偏移。
      // 这里直接复现框架内部的计算：FAB 底边应落在
      //   screenHeight - (占位高度 + 安全区) - 16
      final barOccupied = glassNavBarOccupiedHeight + safeBottom;
      final expectedTop =
          screenHeight - barOccupied - breathing - fabSize;

      final geometry = ScaffoldPrelayoutGeometry(
        bottomSheetSize: Size.zero,
        contentBottom: screenHeight,
        contentTop: 0,
        floatingActionButtonSize: const Size(fabSize, fabSize),
        minInsets: const EdgeInsets.all(0),
        minViewPadding: EdgeInsets.only(bottom: safeBottom),
        scaffoldSize: const Size(screenWidth, screenHeight),
        snackBarSize: Size.zero,
        materialBannerSize: Size.zero,
        textDirection: TextDirection.ltr,
      );

      final offset = location.getOffset(geometry);

      expect(offset.dy, expectedTop);
      // FAB 底边必须完全落在底栏顶边之上
      expect(offset.dy + fabSize, lessThanOrEqualTo(screenHeight - barOccupied));
    });

    testWidgets('FAB 底边不会压到底栏（含安全区）', (tester) async {
      const screenHeight = 900.0;
      const safeBottom = 48.0;
      const fabSize = 56.0;

      late FloatingActionButtonLocation location;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(400, screenHeight),
            padding: EdgeInsets.only(bottom: safeBottom),
          ),
          child: Builder(
            builder: (context) {
              location = glassNavFabLocation(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final geometry = ScaffoldPrelayoutGeometry(
        bottomSheetSize: Size.zero,
        contentBottom: screenHeight,
        contentTop: 0,
        floatingActionButtonSize: const Size(fabSize, fabSize),
        minInsets: const EdgeInsets.all(0),
        minViewPadding: EdgeInsets.only(bottom: safeBottom),
        scaffoldSize: const Size(400, screenHeight),
        snackBarSize: Size.zero,
        materialBannerSize: Size.zero,
        textDirection: TextDirection.ltr,
      );

      final offset = location.getOffset(geometry);
      final barTop = screenHeight - (glassNavBarOccupiedHeight + safeBottom);

      expect(offset.dy + fabSize, lessThanOrEqualTo(barTop));
    });
  });

  group('GlassBarStyle 枚举完整性', () {
    test('四种底栏方案都还在（改枚举时提醒同步改预览页与主流程）', () {
      expect(GlassBarStyle.values, hasLength(4));
      expect(
        GlassBarStyle.values,
        containsAll(<GlassBarStyle>[
          GlassBarStyle.floatingBlur,
          GlassBarStyle.edgeBlur,
          GlassBarStyle.floatingFake,
          GlassBarStyle.miniPill,
        ]),
      );
    });
  });
}
