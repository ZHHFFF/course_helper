import 'dart:ui' as ui;

import 'package:course_helper/navigation/miuix_page_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _capture = ValueKey('card-pixel-capture');
const _foreground = ValueKey('card-pixel-foreground');
const _underColor = Color(0xFF008744);
const _frontColor = Color(0xFF0057E7);

void main() {
  for (final dark in [false, true]) {
    for (final rtl in [false, true]) {
      for (final progress in [0.15, 0.5, 0.85, 1.0]) {
        testWidgets(
          'opaque page, rounded corners and scrim at $progress, dark=$dark rtl=$rtl',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(400, 800);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetPhysicalSize);
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
                home: Directionality(
                  textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                  child: RepaintBoundary(
                    key: _capture,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: _underColor),
                        MiuixPageTransition(
                          animation: AlwaysStoppedAnimation(progress),
                          child: const ColoredBox(
                            key: _foreground,
                            color: _frontColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            final rect = tester.getRect(find.byKey(_foreground));
            final clip = tester.renderObject<RenderMiuixPageTransition>(
              find.byType(MiuixPageTransition),
            );
            if (progress == 1) {
              expect(rect, const Rect.fromLTWH(0, 0, 400, 800));
              expect(clip.effectiveCorners, BorderRadius.zero);
            } else {
              expect(rect.width, 400);
              expect(rect.top, 0);
              expect(
                (rtl
                        ? clip.effectiveCorners.topRight
                        : clip.effectiveCorners.topLeft)
                    .x,
                greaterThan(0),
              );
            }
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(_capture),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              try {
                final bytes = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                int argb(int x, int y) {
                  final i = (y * image.width + x) * 4;
                  return (bytes.getUint8(i + 3) << 24) |
                      (bytes.getUint8(i) << 16) |
                      (bytes.getUint8(i + 1) << 8) |
                      bytes.getUint8(i + 2);
                }

                final insideX = rtl
                    ? rect.right.floor() - 30
                    : rect.left.ceil() + 30;
                expect(
                  argb(insideX, 400),
                  _frontColor.toARGB32(),
                  reason: 'foreground must not be blended with the old page',
                );
                if (progress < 1) {
                  final outsideX = rtl ? 398 : 1;
                  final color = Color(argb(outsideX, 400));
                  final expected = Color.alphaBlend(
                    Colors.black.withValues(alpha: 0.18 * progress),
                    _underColor,
                  );
                  expect(
                    (color.g * 255 - expected.g * 255).abs(),
                    lessThanOrEqualTo(1),
                  );
                  // The rounded corner reveals the old route instead of a white
                  // or black rectangle outside the scaled card.
                  final cornerX = rtl
                      ? rect.right.floor() - 1
                      : rect.left.ceil() + 1;
                  final corner = Color(argb(cornerX, rect.top.ceil() + 1));
                  expect(corner.toARGB32(), isNot(_frontColor.toARGB32()));
                  expect(corner.g, greaterThan(corner.b));
                }
                for (final y in [0, 1, 20, 400, 799]) {
                  for (var x = 0; x < 400; x += 5) {
                    expect(
                      argb(x, y) >> 24,
                      255,
                      reason: 'no holes around page edges',
                    );
                  }
                }
              } finally {
                image.dispose();
              }
            });
          },
        );
      }
    }
    testWidgets(
      'transparent page content is backed by opaque theme surface, dark=$dark',
      (tester) async {
        final surface = dark ? Colors.black : Colors.white;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(scaffoldBackgroundColor: surface),
            home: RepaintBoundary(
              key: _capture,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: _underColor),
                  MiuixPageTransition(
                    animation: AlwaysStoppedAnimation(0.5),
                    child: SizedBox.expand(),
                  ),
                ],
              ),
            ),
          ),
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_capture),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final i = (300 * image.width + 700) * 4;
            expect(bytes.getUint8(i), surface.toARGB32() >> 16 & 255);
            expect(bytes.getUint8(i + 3), 255);
          } finally {
            image.dispose();
          }
        });
      },
    );
  }
  const asymmetric = BorderRadius.only(
    topLeft: Radius.zero,
    topRight: Radius.circular(16),
    bottomLeft: Radius.circular(32),
    bottomRight: Radius.circular(48),
  );
  for (final entry in <String, BorderRadius?>{
    'unavailable': null,
    'square display': BorderRadius.zero,
    'asymmetric display': asymmetric,
  }.entries) {
    for (final rtl in [false, true]) {
      for (final dpr in [1.0, 3.0]) {
        testWidgets('system corners ${entry.key}, rtl=$rtl dpr=$dpr', (
          tester,
        ) async {
          final physical = entry.value ?? BorderRadius.circular(28);
          final target = rtl
              ? BorderRadius.only(
                  topRight: physical.topRight,
                  bottomRight: physical.bottomRight,
                )
              : BorderRadius.only(
                  topLeft: physical.topLeft,
                  bottomLeft: physical.bottomLeft,
                );
          final maxRadius = rtl
              ? physical.bottomRight.x
              : physical.bottomLeft.x;
          final halfway = 1 - maxRadius / (2 * 800);
          Future<void> show(double progress) => tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(devicePixelRatio: dpr)
                      .applyDisplayCornerRadii(entry.value),
                  child: Directionality(
                    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                    child: MiuixPageTransition(
                      animation: AlwaysStoppedAnimation(progress),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          );
          // Check both travel directions and cancellation back to fullscreen.
          // Values are in logical pixels: a high-DPI view must not divide them
          // a second time, and RTL must not swap physical display corners.
          for (final frame in [
            (0.4, target),
            (halfway, target * 0.5),
            (1.0, BorderRadius.zero),
            (halfway, target * 0.5),
            (0.4, target),
            (halfway, target * 0.5),
            (1.0, BorderRadius.zero),
          ]) {
            await show(frame.$1);
            final clip = tester.renderObject<RenderMiuixPageTransition>(
              find.byType(MiuixPageTransition),
            );
            void expectCorners(BorderRadiusGeometry? actual) {
              final corners = actual!.resolve(TextDirection.ltr);
              final expected = frame.$2;
              for (final pair in [
                (corners.topLeft, expected.topLeft),
                (corners.topRight, expected.topRight),
                (corners.bottomLeft, expected.bottomLeft),
                (corners.bottomRight, expected.bottomRight),
              ]) {
                expect(pair.$1.x, closeTo(pair.$2.x, 1e-8));
                expect(pair.$1.y, closeTo(pair.$2.y, 1e-8));
              }
            }

            expectCorners(clip.effectiveCorners);
          }
        });
      }
    }
  }

  testWidgets(
    'updated display metrics refresh corners without losing page input',
    (tester) async {
      final radii = ValueNotifier<BorderRadius?>(asymmetric);
      addTearDown(radii.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ValueListenableBuilder<BorderRadius?>(
              valueListenable: radii,
              builder: (_, value, child) => MediaQuery(
                data: MediaQuery.of(context).applyDisplayCornerRadii(value),
                child: child!,
              ),
              child: MiuixPageTransition(
                animation: AlwaysStoppedAnimation(0.5),
                child: Material(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: TextField(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'keep draft');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final inputState = tester.state(find.byType(TextField));
      for (final value in [
        BorderRadius.circular(60),
        BorderRadius.zero,
        null,
        asymmetric,
      ]) {
        radii.value = value;
        await tester.pump();
        expect(
          tester
              .renderObject<RenderMiuixPageTransition>(
                find.byType(MiuixPageTransition),
              )
              .effectiveCorners,
          BorderRadius.only(
            topLeft: (value ?? BorderRadius.circular(28)).topLeft,
            bottomLeft: (value ?? BorderRadius.circular(28)).bottomLeft,
          ),
        );
        expect(tester.state(find.byType(TextField)), same(inputState));
        expect(find.text('keep draft'), findsOneWidget);
      }
    },
  );
}
