import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'card_page_transition.dart';

/// Shared by the light and dark themes. The preference controls Android's
/// gesture preview, not system back or ordinary push/pop navigation.
PageTransitionsTheme appPageTransitionsTheme({required bool predictiveBack}) =>
    PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: _CardPageTransitionsBuilder(
            platform: platform,
            predictiveBack: predictiveBack,
          ),
      },
    );

class _CardPageTransitionsBuilder extends PageTransitionsBuilder {
  const _CardPageTransitionsBuilder({
    required this.platform,
    required this.predictiveBack,
  });

  final TargetPlatform platform;
  final bool predictiveBack;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 600);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final transition = _CardRouteTransition(
      route: route,
      animation: animation,
      systemGestureEnabled:
          platform == TargetPlatform.android && predictiveBack,
      child: child,
    );
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
      // Keep the SDK's edge gesture controller, with its visual transforms
      // held still. Both the gesture and ordinary routes use our page layer.
      return const CupertinoPageTransitionsBuilder().buildTransitions(
        route,
        context,
        kAlwaysCompleteAnimation,
        kAlwaysDismissedAnimation,
        transition,
      );
    }
    return transition;
  }
}

enum _BackPhase { idle, dragging, cancel, commit }

/// The SDK owns the route controller and Navigator gesture lifecycle. This
/// observer adapts the visual progress without introducing a second ticker,
/// modifying the navigation stack, or rebuilding the page subtree.
class _CardRouteTransition extends StatefulWidget {
  const _CardRouteTransition({
    required this.route,
    required this.animation,
    required this.systemGestureEnabled,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final Animation<double> animation;
  final bool systemGestureEnabled;
  final Widget child;

  @override
  State<_CardRouteTransition> createState() => _CardRouteTransitionState();
}

class _CardRouteTransitionState extends State<_CardRouteTransition>
    with WidgetsBindingObserver {
  _BackPhase _phase = _BackPhase.idle;
  double _settleStart = 1;
  double _commitOrigin = 1;
  bool _tracking = false;
  late CurvedAnimation _ordinaryAnimation;

  void _bindAnimation() {
    _ordinaryAnimation = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    widget.animation.addStatusListener(_onAnimationStatus);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindAnimation();
  }

  @override
  void didUpdateWidget(_CardRouteTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onAnimationStatus);
      _ordinaryAnimation.dispose();
      _bindAnimation();
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (mounted &&
        _phase == _BackPhase.cancel &&
        status == AnimationStatus.completed) {
      setState(() => _phase = _BackPhase.idle);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.animation.removeStatusListener(_onAnimationStatus);
    _ordinaryAnimation.dispose();
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final route = widget.route;
    if (!mounted ||
        !widget.systemGestureEnabled ||
        MediaQuery.disableAnimationsOf(context) ||
        backEvent.isButtonEvent ||
        !route.isCurrent ||
        route.popGestureInProgress ||
        !route.popGestureEnabled) {
      return false;
    }
    _tracking = true;
    setState(() => _phase = _BackPhase.dragging);
    route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!mounted || !_tracking) return;
    widget.route.handleUpdateBackGestureProgress(
      progress: 1 - backEvent.progress,
    );
  }

  @override
  void handleCancelBackGesture() {
    if (!mounted || !_tracking) return;
    _tracking = false;
    setState(() {
      _settleStart = widget.animation.value;
      _phase = _settleStart == 1 ? _BackPhase.idle : _BackPhase.cancel;
    });
    widget.route.handleCancelBackGesture();
  }

  @override
  void handleCommitBackGesture() {
    if (!mounted || !_tracking) return;
    // A PopScope may change its decision while the finger is down. Do not
    // bypass it with the SDK's unconditional Navigator.pop at commit.
    if (widget.route.popDisposition == RoutePopDisposition.doNotPop) {
      handleCancelBackGesture();
      widget.route.onPopInvokedWithResult(false, null);
      return;
    }
    _tracking = false;
    setState(() {
      _settleStart = widget.animation.value;
      _phase = _BackPhase.commit;
    });
    widget.route.handleCommitBackGesture();
    // Also support SDKs that reverse from the current value instead of 1.
    _commitOrigin = widget.animation.value;
  }

  double _visualProgress() {
    final raw = widget.animation.value.clamp(0.0, 1.0);
    switch (_phase) {
      case _BackPhase.dragging:
        return raw;
      case _BackPhase.cancel:
        if (_settleStart == 1) return 1;
        final remaining = ((raw - _settleStart) / (1 - _settleStart)).clamp(
          0.0,
          1.0,
        );
        return _settleStart +
            (1 - _settleStart) * Curves.easeOutCubic.transform(remaining);
      case _BackPhase.commit:
        // TransitionRoute resets its controller to 1 at commit. Map that
        // restart onto the remaining distance, including the very first frame.
        if (_commitOrigin == 0) return 0;
        final remaining = (1 - raw / _commitOrigin).clamp(0.0, 1.0);
        return _settleStart * (1 - Curves.easeOutCubic.transform(remaining));
      case _BackPhase.idle:
        return widget.route.popGestureInProgress
            ? raw
            : _ordinaryAnimation.value;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.animation,
    child: widget.child,
    builder: (context, child) {
      final reduceMotion =
          MediaQuery.disableAnimationsOf(context) &&
          !widget.route.popGestureInProgress;
      return CardPageTransition(
        progress: reduceMotion ? 1 : _visualProgress(),
        child: child!,
      );
    },
  );
}
