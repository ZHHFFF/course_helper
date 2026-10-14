import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_miuix/miuix.dart';

import 'miuix_navigation_motion.dart';

/// One paint-only transform/effect layer. Its child is not rebuilt by a tick.
class MiuixPageTransition extends SingleChildRenderObjectWidget {
  const MiuixPageTransition({
    super.key,
    required this.animation,
    this.secondaryAnimation = kAlwaysDismissedAnimation,
    required super.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  double get progress => animation.value;

  @override
  RenderMiuixPageTransition createRenderObject(BuildContext context) =>
      RenderMiuixPageTransition(
        animation,
        secondaryAnimation,
        Directionality.of(context),
        MediaQuery.devicePixelRatioOf(context),
        MediaQuery.displayCornerRadiiOf(context) ??
            BorderRadius.circular(MiuixNavigationMotion.fallbackCornerRadius),
        _navigationSurface(context),
        MediaQuery.disableAnimationsOf(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMiuixPageTransition renderObject,
  ) {
    renderObject.configure(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      direction: Directionality.of(context),
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      corners:
          MediaQuery.displayCornerRadiiOf(context) ??
          BorderRadius.circular(MiuixNavigationMotion.fallbackCornerRadius),
      background: _navigationSurface(context),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    );
  }
}

class RenderMiuixPageTransition extends RenderProxyBox {
  RenderMiuixPageTransition(
    this._animation,
    this._secondaryAnimation,
    this._direction,
    this._dpr,
    this._corners,
    this._background,
    this._reduceMotion,
  );

  Animation<double> _animation;
  Animation<double> _secondaryAnimation;
  TextDirection _direction;
  double _dpr;
  BorderRadius _corners;
  Color _background;
  bool _reduceMotion;
  final _transformLayer = LayerHandle<TransformLayer>();
  final _clipLayer = LayerHandle<ClipRSuperellipseLayer>();
  final _paint = Paint();

  void configure({
    required Animation<double> animation,
    required Animation<double> secondaryAnimation,
    required TextDirection direction,
    required double devicePixelRatio,
    required BorderRadius corners,
    required Color background,
    required bool reduceMotion,
  }) {
    if (_animation != animation || _secondaryAnimation != secondaryAnimation) {
      if (attached) _unlisten();
      _animation = animation;
      _secondaryAnimation = secondaryAnimation;
      if (attached) _listen();
    }
    _direction = direction;
    _dpr = devicePixelRatio;
    _corners = corners;
    _background = background;
    _reduceMotion = reduceMotion;
    markNeedsPaint();
  }

  void _listen() {
    _animation.addListener(_tick);
    _secondaryAnimation.addListener(_tick);
  }

  void _unlisten() {
    _animation.removeListener(_tick);
    _secondaryAnimation.removeListener(_tick);
  }

  void _tick() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
  }

  @override
  void detach() {
    _unlisten();
    super.detach();
  }

  double get _primary => _reduceMotion ? 1 : _animation.value.clamp(0.0, 1.0);
  double get _covered =>
      _reduceMotion ? 0 : _secondaryAnimation.value.clamp(0.0, 1.0);
  double get _sign => _direction == TextDirection.ltr ? 1 : -1;
  double get _enterOffset =>
      ((1 - _primary) * size.width * _dpr).round() / _dpr;

  /// Only the physically leading corners are clipped. The radius cannot exceed
  /// the exposed edge distance, so the last visible pixels converge smoothly.
  BorderRadius get effectiveCorners {
    if (!hasSize || _reduceMotion) return BorderRadius.zero;
    final leading = _direction == TextDirection.ltr
        ? BorderRadius.only(
            topLeft: _corners.topLeft,
            bottomLeft: _corners.bottomLeft,
          )
        : BorderRadius.only(
            topRight: _corners.topRight,
            bottomRight: _corners.bottomRight,
          );
    final maximum = [
      _cornersForLeadingTop,
      _cornersForLeadingBottom,
    ].map((r) => math.max(r.x, r.y)).reduce(math.max);
    if (maximum == 0) return BorderRadius.zero;
    return leading * (_enterOffset / maximum).clamp(0.0, 1.0);
  }

  Radius get _cornersForLeadingTop =>
      _direction == TextDirection.ltr ? _corners.topLeft : _corners.topRight;
  Radius get _cornersForLeadingBottom => _direction == TextDirection.ltr
      ? _corners.bottomLeft
      : _corners.bottomRight;
  Offset get translation => Offset(
    _sign *
        (_enterOffset - MiuixNavigationMotion.parallax * _covered * size.width),
    0,
  );

  ui.RSuperellipse get _shape {
    final r = effectiveCorners;
    return ui.RSuperellipse.fromRectAndCorners(
      Offset.zero & size,
      topLeft: r.topLeft,
      topRight: r.topRight,
      bottomLeft: r.bottomLeft,
      bottomRight: r.bottomRight,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Parallax can uncover a few pixels around the leading clip. Extend the
    // page's own theme surface behind its moving content, not a global color.
    if (_covered > 0) {
      context.canvas.drawRect(offset & size, _paint..color = _background);
    }
    if (_primary > 0 && _primary < 1) {
      context.canvas.drawRect(
        offset & size,
        _paint
          ..color = Colors.black.withValues(
            alpha: MiuixNavigationMotion.dimAmount * _primary,
          ),
      );
    }
    _transformLayer.layer = context.pushTransform(
      needsCompositing,
      offset,
      Matrix4.translationValues(translation.dx, 0, 0),
      (context, transformedOffset) {
        void paintPage(PaintingContext context, Offset pageOffset) {
          context.canvas.drawRect(
            pageOffset & size,
            _paint..color = _background,
          );
          super.paint(context, pageOffset);
        }

        if (effectiveCorners == BorderRadius.zero) {
          _clipLayer.layer = null;
          paintPage(context, transformedOffset);
        } else {
          _clipLayer.layer = context.pushClipRSuperellipse(
            needsCompositing,
            transformedOffset,
            Offset.zero & size,
            _shape,
            paintPage,
            clipBehavior: Clip.antiAlias,
            oldLayer: _clipLayer.layer,
          );
        }
      },
      oldLayer: _transformLayer.layer,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(translation.dx, 0, 0, 1);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final local = position - translation;
    if (!_shape.contains(local)) return false;
    return super.hitTest(result, position: position);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintOffset(
        offset: translation,
        position: position,
        hitTest: (result, local) =>
            super.hitTestChildren(result, position: local),
      );

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void dispose() {
    _transformLayer.layer = null;
    _clipLayer.layer = null;
    super.dispose();
  }
}

Color _navigationSurface(BuildContext context) =>
    (context
                .dependOnInheritedWidgetOfExactType<MiuixTheme>()
                ?.data
                .colors
                .background ??
            Theme.of(context).scaffoldBackgroundColor)
        .withAlpha(255);
