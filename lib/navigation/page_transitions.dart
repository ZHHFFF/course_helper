import 'package:cupertino_predictive_back/cupertino_predictive_back.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Ordinary routes always slide horizontally. The preference only changes
/// Android's system gesture animation; it does not disable system back.
PageTransitionsTheme appPageTransitionsTheme({required bool predictiveBack}) =>
    PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _AndroidPageTransitionsBuilder(
          predictiveBack: predictiveBack,
        ),
        TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: const CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: const _HorizontalPageTransitionsBuilder(),
        TargetPlatform.linux: const _HorizontalPageTransitionsBuilder(),
        TargetPlatform.fuchsia: const _HorizontalPageTransitionsBuilder(),
      },
    );

class _AndroidPageTransitionsBuilder extends PageTransitionsBuilder {
  const _AndroidPageTransitionsBuilder({required this.predictiveBack});

  final bool predictiveBack;

  @override
  Duration get transitionDuration =>
      CupertinoRouteTransitionMixin.kTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Do not unmount the SDK gesture observer before an active gesture ends.
    // A preference change applies to the next gesture, including after cancel.
    final PageTransitionsBuilder builder =
        predictiveBack || route.popGestureInProgress
        ? const CupertinoPushPredictiveBackBuilder()
        : const _HorizontalPageTransitionsBuilder();
    return builder.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

/// Cupertino motion without an iOS edge-swipe detector on non-Apple platforms.
class _HorizontalPageTransitionsBuilder extends PageTransitionsBuilder {
  const _HorizontalPageTransitionsBuilder();

  @override
  Duration get transitionDuration =>
      CupertinoRouteTransitionMixin.kTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => CupertinoPageTransition(
    primaryRouteAnimation: animation,
    secondaryRouteAnimation: secondaryAnimation,
    linearTransition: route.popGestureInProgress,
    child: child,
  );
}
