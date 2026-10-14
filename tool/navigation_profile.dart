// Profile-only probe. Run through tool/run_navigation_profile.sh; not an app entry.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:course_helper/navigation/page_transitions.dart';
import 'package:course_helper/navigation/miuix_page_route.dart';
import 'package:course_helper/navigation/miuix_navigation_motion.dart';
import 'package:course_helper/pages/widget/navigation_bar_host.dart';
import 'package:course_helper/setting/theme_setting.dart';

final _nav = GlobalKey<NavigatorState>();
final _frames = <Map<String, Object?>>[];
final _intervals = <Map<String, Object?>>[];
final _builds = <String, int>{};
final _style = ValueNotifier('plain');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.addTimingsCallback((frames) {
    for (final frame in frames) {
      _frames.add({
        'vsync_us': frame.timestampInMicroseconds(FramePhase.vsyncStart),
        'ui_us': frame.buildDuration.inMicroseconds,
        'raster_us': frame.rasterDuration.inMicroseconds,
        'total_us': frame.totalSpan.inMicroseconds,
      });
    }
  });
  runApp(const _ProfileApp());
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_measure()));
}

Future<void> _measure() async {
  await Future<void>.delayed(const Duration(seconds: 2));
  for (final style in ['plain', 'blur', 'glass']) {
    ThemeSetting.blurEnabled.value = style != 'plain';
    ThemeSetting.floatingNavBar.value = style == 'glass';
    ThemeSetting.liquidGlass.value = true;
    _style.value = style;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (var i = 0; i < 12; i++) {
      final task = developer.TimelineTask()
        ..start('navigation.push', arguments: {'style': style, 'iteration': i});
      final start = developer.Timeline.now;
      final route = _CandidateRoute(builder: (_) => const _ProbePage('detail'));
      unawaited(_nav.currentState!.push<void>(route));
      // Both implementations reach their exact endpoint within this window.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      task.finish();
      if (i >= 2) {
        _intervals.add({
          'style': style,
          'phase': 'push',
          'start_us': start,
          'end_us': developer.Timeline.now,
        });
      }
      final popTask = developer.TimelineTask()
        ..start('navigation.pop', arguments: {'style': style, 'iteration': i});
      final popStart = developer.Timeline.now;
      await _nav.currentState!.maybePop<void>();
      await route.completed;
      popTask.finish();
      if (i >= 2) {
        _intervals.add({
          'style': style,
          'phase': 'pop',
          'start_us': popStart,
          'end_us': developer.Timeline.now,
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  final output = Platform.environment['NAV_PROFILE_OUTPUT'];
  if (output == null) throw StateError('NAV_PROFILE_OUTPUT is required');
  final file = File('$output/frames.json');
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode({
      'mode': const bool.fromEnvironment('dart.vm.profile')
          ? 'profile'
          : 'other',
      'platform': Platform.operatingSystem,
      'candidate': Platform.environment['NAV_PROFILE_CANDIDATE'],
      'run_id': Platform.environment['NAV_PROFILE_RUN_ID'],
      'shader_filter_supported': ImageFilter.isShaderFilterSupported,
      'frames': _frames,
      'intervals': _intervals,
      'body_builds': _builds,
      'note':
          'Desktop software GL. Not Android hardware or predictive-back acceptance.',
    }),
  );
  // Keep the service alive for its final flush. The runner stops this desktop
  // app through Flutter's machine protocol, preserving the process exit status.
}

class _ProfileApp extends StatefulWidget {
  const _ProfileApp();
  @override
  State<_ProfileApp> createState() => _ProfileAppState();
}

class _ProfileAppState extends State<_ProfileApp> {
  // PROFILE_MODERN_START
  final dispatcher = MiuixBackGestureDispatcher();
  @override
  void dispose() {
    dispatcher.dispose();
    super.dispose();
  }
  // PROFILE_MODERN_END

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    navigatorKey: _nav,
    // PROFILE_MODERN_START
    navigatorObservers: [dispatcher],
    // PROFILE_MODERN_END
    theme: ThemeData(
      platform: TargetPlatform.android,
      pageTransitionsTheme: appPageTransitionsTheme(predictiveBack: true),
    ),
    builder: (_, child) =>
        MiuixTheme(data: MiuixThemeData.light(), child: child!),
    onGenerateRoute: (settings) => _CandidateRoute(
      settings: settings,
      builder: (_) => const _ProbePage('home'),
    ),
  );
}

class _ProbePage extends StatelessWidget {
  const _ProbePage(this.name);
  final String name;

  @override
  Widget build(BuildContext context) {
    _builds[name] = (_builds[name] ?? 0) + 1;
    return ValueListenableBuilder<String>(
      valueListenable: _style,
      builder: (_, style, _) => Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            MiuixScaffold(
              topBar: MiuixTopAppBar(
                title: name,
                largeTitle: name,
                blurred: style != 'plain',
                navigationIcon: name == 'detail'
                    ? MiuixIconButton(
                        onPressed: () => _nav.currentState!.maybePop(),
                        child: const Icon(Icons.arrow_back),
                      )
                    : null,
              ),
              content: (padding) => ListView(
                padding: padding,
                children: [
                  for (var i = 0; i < 20; i++)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: MiuixCard(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('$name / cached content $i'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (style == 'glass' && name == 'home')
              Align(
                alignment: Alignment.bottomCenter,
                child: NavigationBarHost(selectedIndex: 3, onSelect: (_) {}),
              ),
          ],
        ),
      ),
    );
  }
}

// PROFILE_MODERN_START
class _CandidateRoute extends MiuixPageRoute<void> {
  _CandidateRoute({required super.builder, super.settings});

  @override
  Simulation? createSimulation({required bool forward}) {
    final candidate =
        Platform.environment['NAV_PROFILE_CANDIDATE'] ?? '300-260';
    if (candidate == '300-260') return super.createSimulation(forward: forward);
    final milliseconds = candidate == 'native500'
        ? 500
        : int.parse(candidate.split('-')[forward ? 0 : 1]);
    return MiuixNavigationMotion.tween(
      controller!.value,
      forward ? 1 : 0,
      forward,
      duration: Duration(milliseconds: milliseconds),
      curve: candidate == 'native500'
          ? const _ComposeNavCurve()
          : (forward ? MiuixMotion.standardDecelerate : MiuixMotion.sinOut),
    );
  }
}

// Reference NavSettleEasing(.8, .95), used only in the Profile comparison.
class _ComposeNavCurve extends Curve {
  const _ComposeNavCurve();
  @override
  double transformInternal(double t) {
    final omega = 2 * math.pi / .8;
    final r = -.95 * omega;
    final w = omega * math.sqrt(1 - .95 * .95);
    return (math.exp(r * t) * (-math.cos(w * t) + r / w * math.sin(w * t)) + 1)
        .clamp(0.0, 1.0);
  }
}
// PROFILE_MODERN_END
