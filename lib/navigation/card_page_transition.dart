import 'package:flutter/material.dart';

/// An opaque foreground page over the live, stationary previous route.
/// [progress] is 0 offscreen and 1 fullscreen, for push, pop and cancellation.
class CardPageTransition extends StatelessWidget {
  const CardPageTransition({
    super.key,
    required this.progress,
    required this.child,
  });

  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final revealed = progress.clamp(0.0, 1.0);
    final away = 1 - revealed;
    // Restore scale and corners before reaching fullscreen, continuously.
    final cardAmount = (away / 0.18).clamp(0.0, 1.0);
    final radius = BorderRadius.circular(28 * cardAmount);
    final direction = Directionality.of(context) == TextDirection.ltr ? 1 : -1;
    return Stack(
      fit: StackFit.expand,
      children: [
        // This affects only the previous page, never the foreground opacity.
        IgnorePointer(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.18 * revealed),
          ),
        ),
        FractionalTranslation(
          translation: Offset(direction * away, 0),
          child: Transform.scale(
            scale: 1 - 0.015 * cardAmount,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08 * cardAmount),
                    blurRadius: 12 * cardAmount,
                    offset: Offset(-3 * direction * cardAmount, 0),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: ColoredBox(
                  color: Theme.of(
                    context,
                  ).scaffoldBackgroundColor.withAlpha(255),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
