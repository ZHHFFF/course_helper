import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'miuix_navigation_motion.dart';
import 'miuix_page_route.dart';
import 'miuix_page_transition.dart';

PageTransitionsTheme appPageTransitionsTheme({required bool predictiveBack}) =>
    PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _MiuixPageTransitionsBuilder(
          predictiveBack: predictiveBack,
        ),
        TargetPlatform.iOS: _MiuixPageTransitionsBuilder(appleGesture: true),
        TargetPlatform.macOS: _MiuixPageTransitionsBuilder(appleGesture: true),
        TargetPlatform.windows: _MiuixPageTransitionsBuilder(),
        TargetPlatform.linux: _MiuixPageTransitionsBuilder(),
        TargetPlatform.fuchsia: _MiuixPageTransitionsBuilder(),
      },
    );

class _MiuixPageTransitionsBuilder extends PageTransitionsBuilder {
  const _MiuixPageTransitionsBuilder({
    this.appleGesture = false,
    this.predictiveBack = true,
  });
  final bool predictiveBack;
  final bool appleGesture;

  @override
  Duration get transitionDuration => MiuixNavigationMotion.pushDuration;
  @override
  Duration get reverseTransitionDuration => MiuixNavigationMotion.popDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final layer = MiuixPageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
    if (appleGesture) {
      // Retain the native SDK edge detector, keeping its visual animation inert.
      return const CupertinoPageTransitionsBuilder().buildTransitions(
        route,
        context,
        kAlwaysCompleteAnimation,
        kAlwaysDismissedAnimation,
        layer,
      );
    }
    return layer;
  }
}

/// One stable system observer per Navigator. It survives route removal, so a
/// pending native commit is consumed by the original session, never another page.
class MiuixBackGestureDispatcher extends NavigatorObserver
    with WidgetsBindingObserver {
  MiuixBackGestureDispatcher() {
    WidgetsBinding.instance.addObserver(this);
  }

  final List<Route<dynamic>> _routes = [];
  MiuixPageRoute<dynamic>? _session;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _session?.abandonGesture();
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _routes.remove(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    }
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // The binding replaces its observer list on every start. Retain ownership
    // of a duplicate start so its terminal event cannot pop a different route.
    if (_session != null) return true;
    if (backEvent.isButtonEvent || _routes.isEmpty) {
      return false;
    }
    final route = _routes.last;
    final context = navigator?.context;
    final builder = context == null
        ? null
        : Theme.of(
            context,
          ).pageTransitionsTheme.builders[TargetPlatform.android];
    if (context == null ||
        builder is! _MiuixPageTransitionsBuilder ||
        !builder.predictiveBack ||
        Theme.of(context).platform != TargetPlatform.android ||
        MediaQuery.disableAnimationsOf(context) ||
        route is! MiuixPageRoute ||
        !route.isCurrent ||
        route.popGestureInProgress ||
        !route.popGestureEnabled) {
      return false;
    }
    _session = route;
    route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) =>
      _session?.handleUpdateBackGestureProgress(
        progress: 1 - backEvent.progress,
      );

  @override
  void handleCancelBackGesture() {
    final route = _session;
    _session = null;
    route?.handleCancelBackGesture();
  }

  @override
  void handleCommitBackGesture() {
    final route = _session;
    _session = null;
    route?.handleCommitBackGesture();
  }

  void dispose() {
    _session?.abandonGesture();
    _session = null;
    WidgetsBinding.instance.removeObserver(this);
    _routes.clear();
  }
}
