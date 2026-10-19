import 'package:course_helper/pages/widget/pattern_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'single dot does not submit; drawing claims gesture over scroll view',
    (tester) async {
      final controller = ScrollController();
      final results = <List<int>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: controller,
              child: Column(
                children: [
                  SizedBox(
                    width: 300,
                    height: 300,
                    child: PatternLock(
                      onInputComplete: (value) async {
                        results.add(value);
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(height: 1500),
                ],
              ),
            ),
          ),
        ),
      );
      final origin = tester.getTopLeft(find.byType(PatternLock));
      await tester.tapAt(origin + const Offset(50, 50));
      await tester.pump();
      expect(results, isEmpty);
      final gesture = await tester.startGesture(origin + const Offset(50, 250));
      await gesture.moveTo(origin + const Offset(50, 50));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(results, [
        [6, 3, 0],
      ]);
      expect(controller.offset, 0);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
