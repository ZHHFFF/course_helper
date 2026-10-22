import 'package:course_helper/navigation/miuix_navigation_motion.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ordinary routes respond quickly and land exactly without a tail', () {
    final push = MiuixNavigationMotion.tween(0, 1, true);
    final pop = MiuixNavigationMotion.tween(1, 0, false);
    expect(push.x(0), 0);
    expect(push.x(0.1), inInclusiveRange(0.55, 0.56));
    expect(push.x(0.3), 1);
    expect(push.dx(0.3), 0);
    expect(pop.x(0), 1);
    expect(pop.x(0.1), inInclusiveRange(0.43, 0.44));
    expect(pop.x(0.26), 0);
    expect(pop.dx(0.26), 0);
  });
  for (final start in [0.0, 0.03, 0.5, 0.98, 1.0]) {
    for (final end in [0.0, 1.0]) {
      for (final velocity in [-100.0, -2.0, 0.0, 2.0, 100.0]) {
        test(
          'critical settle from $start to $end at $velocity has no bounce or residue',
          () {
            final spring = MiuixNavigationMotion.settle(
              start,
              end,
              velocity,
              physicalWidth: 800,
            );
            expect(spring.x(0), closeTo(start, 1e-12));
            var previous = start;
            for (var frame = 1; frame <= 100; frame++) {
              final value = spring.x(frame / 120);
              expect(value, inInclusiveRange(0.0, 1.0));
              expect(
                value,
                end >= start
                    ? greaterThanOrEqualTo(previous - 1e-12)
                    : lessThanOrEqualTo(previous + 1e-12),
              );
              previous = value;
            }
            expect(spring.isDone(0.7), isTrue);
            expect(spring.x(0.7), end);
            expect(spring.dx(0.7), 0);
          },
        );
      }
    }
  }
  test(
    'useful release velocity changes early trajectory while preserving the first frame',
    () {
      final rest = MiuixNavigationMotion.settle(0.5, 0, 0, physicalWidth: 800);
      final released = MiuixNavigationMotion.settle(
        0.5,
        0,
        -2,
        physicalWidth: 800,
      );
      expect(rest.x(0), released.x(0));
      expect(released.dx(0), closeTo(-2, 1e-9));
      expect(released.x(0.03), lessThan(rest.x(0.03)));
    },
  );
}
