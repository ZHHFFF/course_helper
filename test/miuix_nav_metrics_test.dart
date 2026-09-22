// Miuix 玻璃底栏的几何契约测试。
//
// 背景：底栏是 `Stack` + `Positioned` 悬浮叠加的，**不占** Scaffold 的
// `bottomNavigationBar` 槽位。因此有三处要依赖「底栏占位高度」这一个数据：
//   1. 页面滚动内容底部留白（避免最后一项被盖）→ miuixNavBarClearance
//   2. 页面塞进 `MiuixScaffold.bottomBar` 的透明占位 → miuixNavBarOccupied
//   3. 全局 `MediaQuery.padding.bottom` 注入（让 SnackBar / BottomSheet
//      自动抬到底栏之上）                  → miuixNavBarOccupiedHeight
//
// 本测试锁定三者的数值关系，并守住两个踩过坑的约束：
//   - 悬浮 / 贴边两态高度不同，页面留白必须跟着变；
//   - 计算必须读 `viewPadding`，**不能**读被 `_GlassNavInsets` 撑大过的 `padding`。
//
// 注：本文件替代了旧的 `liquid_glass_nav_bar_test.dart`。旧测试断言的是自研底栏
// 那套「抬起 8 + 内容高 52 = 60」的几何（已作废，4 个用例长期红灯），
// 底栏换成 `MiuixGlassNavigationBar` 后几何变为「抬起 12 + 内容高 64 = 76」。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/pages/widget/miuix_nav_metrics.dart';
import 'package:course_helper/setting/navbar_setting.dart';

/// 在给定的 MediaQuery 下求值 [body]，返回结果。
Future<T> _inMediaQuery<T>(
  WidgetTester tester,
  MediaQueryData data,
  T Function(BuildContext context) body,
) async {
  late T value;
  await tester.pumpWidget(
    MediaQuery(
      data: data,
      child: Builder(
        builder: (context) {
          value = body(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return value;
}

void main() {
  // 每个用例都显式设置形态，跑完还原成默认（悬浮），避免污染其它测试文件。
  setUp(() => NavBarSetting.floating.value = true);
  tearDown(() => NavBarSetting.floating.value = true);

  group('底栏几何常量', () {
    test('内容高 64 / 抬起 12（对齐 LSPosed 实测参照物）', () {
      // 参照物：一加 13 上的 LSPosed 管理器（Miuix 应用）
      //   胶囊 [86,2458][1178,2682] → 高 224px ÷ 3.5 = 64.0dp
      //   离屏底 98px = 28dp，其中 16dp 是手势条安全区 → 额外抬起 12dp
      expect(miuixNavBarContentHeight, 64);
      expect(miuixNavBarLift, 12);
    });

    test('占位高度 = 抬起 + 内容高 = 76', () {
      expect(
        miuixNavBarOccupiedHeight,
        miuixNavBarLift + miuixNavBarContentHeight,
      );
      expect(miuixNavBarOccupiedHeight, 76);
    });

    test('⚠️ main.dart 里的 _kNavBarHeight / _kNavBottomGap 必须与这里一致', () {
      // 这两个常量在 main.dart 里是私有静态常量（`_kNavBarHeight = 64`、
      // `_kNavBottomGap = 12`），无法直接 import 断言，故在此留一条数值契约：
      // 一旦改动这里，务必同步改 main.dart 传给 MiuixGlassNavigationBar 的参数，
      // 否则「底栏实际高度」与「页面留白」会各说各话（症状：留白不对齐 / FAB 被压）。
      expect(miuixNavBarContentHeight, 64, reason: 'main.dart 的 _kNavBarHeight');
      expect(miuixNavBarLift, 12, reason: 'main.dart 的 _kNavBottomGap');
    });
  });

  group('miuixNavBarOccupied', () {
    testWidgets('悬浮态 = 安全区 + 76', (tester) async {
      NavBarSetting.floating.value = true;
      final occupied = await _inMediaQuery(
        tester,
        const MediaQueryData(viewPadding: EdgeInsets.only(bottom: 16)),
        miuixNavBarOccupied,
      );
      expect(occupied, 16 + miuixNavBarOccupiedHeight);
      expect(occupied, 92);
    });

    testWidgets('贴边态 = 安全区 + 64（不含抬起）', (tester) async {
      NavBarSetting.floating.value = false;
      final occupied = await _inMediaQuery(
        tester,
        const MediaQueryData(viewPadding: EdgeInsets.only(bottom: 16)),
        miuixNavBarOccupied,
      );
      expect(occupied, 16 + miuixNavBarContentHeight);
      expect(occupied, 80);
    });

    testWidgets('无安全区时只剩底栏自身高度', (tester) async {
      final floating = await _inMediaQuery(
        tester,
        const MediaQueryData(),
        miuixNavBarOccupied,
      );
      expect(floating, miuixNavBarOccupiedHeight);

      NavBarSetting.floating.value = false;
      final edge = await _inMediaQuery(
        tester,
        const MediaQueryData(),
        miuixNavBarOccupied,
      );
      expect(edge, miuixNavBarContentHeight);
    });

    testWidgets('悬浮态一定比贴边态高（贴边态末项被遮的历史 bug）', (tester) async {
      const mq = MediaQueryData(viewPadding: EdgeInsets.only(bottom: 16));

      NavBarSetting.floating.value = true;
      final floating = await _inMediaQuery(tester, mq, miuixNavBarOccupied);

      NavBarSetting.floating.value = false;
      final edge = await _inMediaQuery(tester, mq, miuixNavBarOccupied);

      // 贴边态栏底边贴屏底，少了那 12dp 抬起，所以占位更小。
      // 页面留白若写死成悬浮态的值，贴边态会多留 12dp（难看但不出错）；
      // 反过来写死成贴边态的值，悬浮态末项会被遮 —— 这才是必须防的。
      expect(edge, lessThan(floating));
      expect(floating - edge, miuixNavBarLift);
    });

    testWidgets('⚠️ 必须读 viewPadding，不能被撑大的 padding 带偏', (tester) async {
      // 上层 `_GlassNavInsets` 会为了给 SnackBar 让位，把 `padding.bottom`
      // 撑大 `miuixNavBarOccupiedHeight`，而 `viewPadding` 保持原值。
      // 若这里误用 `MediaQuery.of(context).padding`，就会再加一遍 76 ——
      // 历史 bug：列表滚到底空一大截，底栏也被顶得极高。
      final occupied = await _inMediaQuery(
        tester,
        const MediaQueryData(
          viewPadding: EdgeInsets.only(bottom: 16),
          // 模拟 _GlassNavInsets 注入后的 padding
          padding: EdgeInsets.only(bottom: 16 + miuixNavBarOccupiedHeight),
        ),
        miuixNavBarOccupied,
      );

      // 只算一次 76，而不是 16 + 76 + 76
      expect(occupied, 16 + miuixNavBarOccupiedHeight);
      expect(occupied, isNot(16 + miuixNavBarOccupiedHeight * 2));
    });
  });

  group('miuixNavBarClearance', () {
    testWidgets('等于 占位高度 + 16 呼吸间距', (tester) async {
      const mq = MediaQueryData(viewPadding: EdgeInsets.only(bottom: 16));

      final occupied = await _inMediaQuery(tester, mq, miuixNavBarOccupied);
      final clearance = await _inMediaQuery(tester, mq, miuixNavBarClearance);

      expect(clearance, occupied + 16);
      expect(clearance, 16 + miuixNavBarOccupiedHeight + 16);
    });

    testWidgets('无安全区时 = 占位高度 + 16', (tester) async {
      final clearance = await _inMediaQuery(
        tester,
        const MediaQueryData(),
        miuixNavBarClearance,
      );
      expect(clearance, miuixNavBarOccupiedHeight + 16);
    });
  });
}
