import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_miuix/miuix.dart';

/// App tuning, using the APIs exported by the locked flutter_miuix 1.2.0.
class MiuixNavigationMotion {
  MiuixNavigationMotion._();

  static const pushDuration = Duration(milliseconds: 300);
  static const popDuration = Duration(milliseconds: 260);
  static const parallax = 0.25;
  static const dimAmount = 0.18;
  static const fallbackCornerRadius = 28.0;
  static const springResponse = 0.25;

  static Simulation tween(
    double start,
    double end,
    bool forward, {
    Duration? duration,
    Curve? curve,
  }) => _NavigationTween(
    start,
    end,
    duration ?? (forward ? pushDuration : popDuration),
    curve ?? (forward ? MiuixMotion.standardDecelerate : MiuixMotion.sinOut),
  );

  static Simulation settle(
    double start,
    double end,
    double velocity, {
    required double physicalWidth,
  }) {
    final spring = folmeSpring(damping: 1, response: springResponse);
    final omega = math.sqrt(spring.stiffness / spring.mass);
    final distance = end - start;
    // Critical damping alone does not prevent a velocity-seeded crossing.
    // Bound the seed to the monotonic, non-overshooting interval.
    final seed = distance >= 0
        ? velocity.clamp(0.0, omega * distance)
        : velocity.clamp(omega * distance, 0.0);
    return SpringSimulation(
      spring,
      start,
      end,
      seed,
      snapToEnd: true,
      tolerance: Tolerance(
        distance: 0.5 / math.max(physicalWidth, 1),
        velocity: 0.02,
      ),
    );
  }
}

class _NavigationTween extends Simulation {
  _NavigationTween(this.start, this.end, Duration duration, this.curve)
    : seconds = duration.inMicroseconds / Duration.microsecondsPerSecond;

  final double start;
  final double end;
  final double seconds;
  final Curve curve;

  @override
  double x(double time) {
    if (time <= 0) return start;
    if (time >= seconds) return end;
    return start + (end - start) * curve.transform(time / seconds);
  }

  @override
  double dx(double time) {
    if (time < 0 || time >= seconds) return 0;
    const step = 0.00001;
    final before = math.max(0.0, time - step);
    return (x(time + step) - x(before)) / (time + step - before);
  }

  @override
  bool isDone(double time) => time >= seconds;
}
