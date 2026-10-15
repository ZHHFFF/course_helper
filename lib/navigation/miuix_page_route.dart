import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'miuix_navigation_motion.dart';

/// Material routing semantics with a shared visual-progress controller.
/// SDK primary/secondary animations expose this same value to both pages.
class MiuixPageRoute<T> extends MaterialPageRoute<T> {
  MiuixPageRoute({
    required super.builder,
    super.settings,
    super.requestFocus,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.barrierDismissible,
    super.traversalEdgeBehavior,
    super.directionalTraversalEdgeBehavior,
  });

  ValueNotifier<Widget>? _transitionChild;
  Widget? _cachedTransitions;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (_transitionChild == null) {
      _transitionChild = ValueNotifier(child);
      _cachedTransitions = _MiuixTransitionHost(
        route: this,
        child: ValueListenableBuilder<Widget>(
          valueListenable: _transitionChild!,
          builder: (_, value, _) => value,
        ),
      );
    } else {
      _transitionChild!.value = child;
    }
    return _cachedTransitions!;
  }

  // The complete secondary effect is ours; prevent the SDK from constructing
  // a second delegated/proxied transition around the same page.
  @override
  DelegatedTransitionBuilder? get delegatedTransition => null;

  bool _gestureActive = false;
  bool _acceptingUpdates = false;
  bool _settling = false;
  bool _disposed = false;
  double _releaseVelocity = 0;
  Duration _lastTime = Duration.zero;
  double _lastValue = 1;
  NavigatorState? _gestureNavigator;

  @override
  Duration get transitionDuration => MiuixNavigationMotion.pushDuration;

  @override
  Duration get reverseTransitionDuration => MiuixNavigationMotion.popDuration;

  @override
  void install() {
    super.install();
    controller!.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (_settling &&
        (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed)) {
      _stopGesture();
    }
  }

  double get _physicalWidth {
    final query = MediaQuery.of(navigator!.context);
    return query.size.width * query.devicePixelRatio;
  }

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(navigator!.context);

  @override
  Simulation? createSimulation({required bool forward}) {
    final start = controller!.value;
    final end = forward ? 1.0 : 0.0;
    if (_reduceMotion) return _InstantSimulation(end);
    if (_gestureActive || (end - start).abs() < 0.999) {
      _settling = _gestureActive;
      return MiuixNavigationMotion.settle(
        start,
        end,
        _gestureActive ? _releaseVelocity : controller!.velocity,
        physicalWidth: _physicalWidth,
      );
    }
    return MiuixNavigationMotion.tween(start, end, forward);
  }

  @override
  void handleStartBackGesture({double progress = 1}) {
    if (_disposed || _gestureActive || !isCurrent || !popGestureEnabled) return;
    _gestureActive = _acceptingUpdates = true;
    _settling = false;
    _releaseVelocity = 0;
    _lastTime = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    _lastValue = progress;
    _gestureNavigator = navigator;
    super.handleStartBackGesture(progress: progress);
  }

  @override
  void handleUpdateBackGestureProgress({required double progress}) {
    if (_disposed || !_acceptingUpdates) return;
    if (!isCurrent) {
      if (!_settling) abandonGesture();
      return;
    }
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    final dt =
        (now - _lastTime).inMicroseconds / Duration.microsecondsPerSecond;
    if (dt > 0) {
      _releaseVelocity = dt <= 0.1 ? (progress - _lastValue) / dt : 0;
      _lastValue = progress;
      _lastTime = now;
    }
    super.handleUpdateBackGestureProgress(progress: progress);
  }

  double _velocityAtRelease() {
    final elapsed =
        SchedulerBinding.instance.currentSystemFrameTimeStamp - _lastTime;
    return elapsed > const Duration(milliseconds: 100) ? 0 : _releaseVelocity;
  }

  @override
  void handleCancelBackGesture() {
    if (_disposed || !_gestureActive || !_acceptingUpdates) return;
    _acceptingUpdates = false;
    _releaseVelocity = _velocityAtRelease();
    _cancelToRest();
  }

  void _cancelToRest() {
    if (!isCurrent) {
      abandonGesture();
      return;
    }
    _settling = true;
    if (_reduceMotion || controller!.value == 1) {
      controller!.value = 1;
      _stopGesture();
    } else {
      controller!.animateWith(
        MiuixNavigationMotion.settle(
          controller!.value,
          1,
          _releaseVelocity,
          physicalWidth: _physicalWidth,
        ),
      );
    }
  }

  @override
  void handleCommitBackGesture() {
    if (_disposed || !_gestureActive || !_acceptingUpdates) return;
    if (!isCurrent) {
      abandonGesture();
      return;
    }
    _acceptingUpdates = false;
    _releaseVelocity = _velocityAtRelease();
    unawaited(_commit());
  }

  Future<void> _commit() async {
    // maybePop rechecks PopScope and intervening navigation. didPop selects the
    // seeded simulation; unlike SDK handleCommit, it never resets to upperBound.
    await navigator?.maybePop<T>();
    if (_disposed || !_gestureActive) return;
    if (isCurrent) {
      _cancelToRest();
    } else if (!_settling) {
      abandonGesture();
    }
  }

  /// A new route can cover a finger-held page. Restore that page and release
  /// exactly our own Navigator gesture, while the dispatcher consumes its end.
  void abandonGesture() {
    if (_disposed || !_gestureActive) return;
    if (!_settling) {
      controller!.animateWith(
        MiuixNavigationMotion.settle(
          controller!.value,
          1,
          _velocityAtRelease(),
          physicalWidth: _physicalWidth,
        ),
      );
    }
    _stopGesture();
  }

  void _stopGesture() {
    if (!_gestureActive) return;
    _gestureActive = _acceptingUpdates = _settling = false;
    final owner = _gestureNavigator;
    _gestureNavigator = null;
    if (owner != null && owner.mounted) owner.didStopUserGesture();
  }

  @override
  void dispose() {
    _disposed = true;
    _transitionChild?.dispose();
    _stopGesture();
    controller?.removeStatusListener(_onStatus);
    super.dispose();
  }
}

/// Used only when accessibility requests instant navigation.
class _InstantSimulation extends Simulation {
  _InstantSimulation(this.end);
  final double end;

  @override
  double x(double time) => end;

  @override
  double dx(double time) => 0;

  @override
  bool isDone(double time) => true;
}

class _MiuixTransitionHost extends StatelessWidget {
  const _MiuixTransitionHost({required this.route, required this.child});
  final MiuixPageRoute<dynamic> route;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Theme.of(context).pageTransitionsTheme.buildTransitions(
        route,
        context,
        route.animation!,
        route.secondaryAnimation!,
        child,
      );
}
