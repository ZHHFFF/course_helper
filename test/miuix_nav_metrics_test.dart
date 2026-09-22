// Miuix 模糊底栏的几何契约测试。
//
// 背景：底栏是 `Stack` + `Positioned` 贴边叠加的，**不占** Scaffold 的
// `bottomNavigationBar` 槽位。因此有三处要依赖「底栏占位高度」这一个数据：
//   1. 页面滚动内容底部留白（避免最后一项被盖）→ miuixNavBarClearance
//   2. 页面塞进 `MiuixScaffold.bottomBar` 的透明占位 → miuixNavBarOccupied
//   3. 全局 `MediaQuery.padding.bottom` 注入（让 SnackBar / BottomSheet
//      自动抬到底栏之上）                  → miuixNavBarOccupiedHeight
//
// 本测试锁定三者的数值关系，并守住踩过的坑：
//   - 计算必须读 `viewPadding`，**不能**读被 `_GlassNavInsets` 撑大过的 `padding`；
//   - 占位高度必须与包里的 `MiuixNavigationBarDefaults.itemHeight` 一致。
//
// 历史：
//   - 更早的 `liquid_glass_nav_bar_test.dart` 断言自研底栏那套
//     「抬起 8 + 内容高 52 = 60」的几何，已随组件一并删除。
//   - 本文件曾覆盖「悬浮 / 贴边两态高度不同」——2026-09-22 用户拍板
//     「底部导航栏改为 miuix 标准样式，采用非悬浮的固定布局」后，两态合一，
//     那些分叉用例（含 `NavBarSetting.floating`）已删除。

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/pages/widget/miuix_nav_metrics.dart';

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
  group('底栏几何常量', () {
    test('内容高 64（对齐 LSPosed 实测参照物与 Miuix 库默认值）', () {
      // 参照物：一加 13 上的 LSPosed 管理器（Miuix 应用）
      //   胶囊 [86,2458][1178,2682] → 高 224px ÷ 3.5 = 64.0dp
      expect(miuixNavBarContentHeight, 64);
    });

    test('⚠️ 必须与 MiuixNavigationBarDefaults.itemHeight 一致', () {
      // 底栏本体由包里的 `MiuixNavigationBar` 渲染，它的行高是库定义的
      // `itemHeight`。我们不再往组件里传高度，所以这个契约必须由测试钉住：
      // 一旦库里改了 itemHeight 而这里没跟，页面留白就会与实际底栏高度
      // 各说各话（症状：列表最后一项被压住 / 底部空一大截）。
      expect(
        miuixNavBarContentHeight,
        MiuixNavigationBarDefaults.itemHeight,
      );
    });

    test('占位高度 = 内容高（已无「抬起」，底栏贴边）', () {
      expect(miuixNavBarOccupiedHeight, miuixNavBarContentHeight);
      expect(miuixNavBarOccupiedHeight, 64);
    });
  });

  group('miuixNavBarOccupied', () {
    testWidgets('= 安全区 + 64', (tester) async {
      final occupied = await _inMediaQuery(
        tester,
        const MediaQueryData(viewPadding: EdgeInsets.only(bottom: 16)),
        miuixNavBarOccupied,
      );
      expect(occupied, 16 + miuixNavBarContentHeight);
      expect(occupied, 80);
    });

    testWidgets('无安全区时只剩底栏自身高度', (tester) async {
      final occupied = await _inMediaQuery(
        tester,
        const MediaQueryData(),
        miuixNavBarOccupied,
      );
      expect(occupied, miuixNavBarOccupiedHeight);
    });

    testWidgets('⚠️ 必须读 viewPadding，不能被撑大的 padding 带偏', (tester) async {
      // 上层 `_GlassNavInsets` 会为了给 SnackBar 让位，把 `padding.bottom`
      // 撑大 `miuixNavBarOccupiedHeight`，而 `viewPadding` 保持原值。
      // 若这里误用 `MediaQuery.of(context).padding`，就会再加一遍 64 ——
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

      // 只算一次 64，而不是 16 + 64 + 64
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
