import 'dart:ui' as ui;

import 'package:course_helper/navigation/card_page_transition.dart';
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
                        CardPageTransition(
                          progress: progress,
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
            final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
            if (progress == 1) {
              expect(rect, const Rect.fromLTWH(0, 0, 400, 800));
              expect(clip.borderRadius, BorderRadius.zero);
            } else {
              expect(rect.width, lessThan(400));
              expect(rect.top, greaterThan(0));
              expect(
                clip.borderRadius.resolve(TextDirection.ltr).topLeft.x,
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
              child: const Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: _underColor),
                  CardPageTransition(progress: 0.5, child: SizedBox.expand()),
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
}
