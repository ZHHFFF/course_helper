/// 前台服务（保活）的统一入口
///
/// **为什么要有这一层**：这套逻辑原来是 `_PresentationPageState` 的私有方法，
/// 只有进课堂（`PresentationPage`）才会跑。结果是「不进课堂就测不了」——
/// 而没有正在上课的课程时，课程列表是空的、根本点不进去。
/// 抽出来之后「前台服务自检」页也能调，随时能验。
///
/// 这个文件里每个 `注意` 都是踩过的坑，别删：
/// 1. `<service>` 必须在 AndroidManifest.xml 里声明，插件不声明，
///    漏了会**静默失败**（Android 对未声明组件不报错）
/// 2. `startService()` 的返回值必须看，否则失败无声（插件内部等 5 秒确认）
/// 3. 权限弹窗**不能挡在 `startService()` 前面**：插件的权限申请走
///    `startActivityForResult`，没有超时，Activity 被重建就永久卡死
/// 4. `initCommunicationPort()` 不会自动调用，不调就收不到保活 isolate 的消息
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_logger.dart';
import 'storage.dart';

/// 前台服务的通知文案
const String kKeepAliveNotificationTitle = '课堂助手';
const String kKeepAliveNotificationText = '正在保持 WebSocket 连接...';

/// 保活 isolate → 主 isolate 的上报入口
///
/// **必须是顶层函数**：`addTaskDataCallback` 内部用 `contains` 去重，
/// 实例方法的 tear-off 每次都是新对象、去不掉重，事件会被重复记 N 遍。
void _onKeepAliveTaskData(Object data) {
  switch (data) {
    case 'started':
      AppLogger.i(KeepAliveService.tag, '保活 isolate 已启动');
    case 'timeout':
      AppLogger.w(
        KeepAliveService.tag,
        '前台服务被系统超时终止 —— Android 15+ 对 dataSync 类型有累计时长上限',
      );
    case 'stopped':
      AppLogger.i(KeepAliveService.tag, '前台服务已停止（正常退出，或用户划掉了 App）');
    default:
      AppLogger.d(KeepAliveService.tag, '保活 isolate 消息：$data');
  }
}

/// 这个类跑在**后台 isolate**，和主 isolate 的静态状态是两套。
/// 直接调 `AppLogger` 只会写进后台那边没人读的内存队列，
/// 所以一律 `sendDataToMain` 交给主 isolate 去记。
class _WebSocketKeepAliveHandler extends TaskHandler {
  static void _report(String event) {
    FlutterForegroundTask.sendDataToMain(event);
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _report('started');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // 这里是「服务死掉」唯一的信号来源。以前是空实现，
    // 于是服务被系统掐掉时应用内完全看不出来。
    _report(isTimeout ? 'timeout' : 'stopped');
  }
}

@pragma('vm:entry-point')
void keepAliveCallback() {
  FlutterForegroundTask.setTaskHandler(_WebSocketKeepAliveHandler());
}

class KeepAliveService {
  KeepAliveService._();

  /// 日志 tag，方便在「运行日志」页搜
  static const String tag = 'ForegroundService';

  /// 权限弹窗的超时兜底
  ///
  /// 插件的 `requestNotificationPermission()` / `requestIgnoreBatteryOptimization()`
  /// 都是 `startActivityForResult` 模式：Dart 侧的 Future 只在
  /// `onRequestPermissionsResult` / `onActivityResult` 回来时才完成，**插件没有超时**。
  /// Activity 一旦被系统重建，那个回调就永远不来了 → await 卡死。
  static const Duration _permissionTimeout = Duration(seconds: 30);

  /// 「电池优化豁免」问过一次就不再问
  static const String _batteryOptAskedKey = 'foreground_service_battery_opt_asked';

  /// 最近一次操作的结果，自检页直接读它显示
  static final ValueNotifier<String> lastResult = ValueNotifier<String>('尚未操作');

  static bool _portReady = false;

  /// 开一次跨 isolate 通道
  ///
  /// 插件**不会**自动开：`init()` 和 `startService()` 都不管这件事。
  /// 不调的话保活 isolate 的 `sendDataToMain` 是静默 no-op，
  /// onStart / onDestroy 发什么都不会有人收到。
  static void _ensureCommunicationPort() {
    if (_portReady) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(_onKeepAliveTaskData);
    _portReady = true;
  }

  /// 启动前台服务
  ///
  /// 顺序很关键：**先起服务，再弹权限**。原因见 `_requestPermissions`。
  static Future<ServiceRequestResult?> start() async {
    _ensureCommunicationPort();

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'websocket_service',
        channelName: 'WebSocket Background Service',
        channelDescription: 'Keep WebSocket connection alive',
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        allowWifiLock: true,
        // allowWakeLock 保持默认 true：息屏后 CPU 靠它不睡，
        // WebSocket 收消息才不会被拖到超时。耗电换可靠，这个 App 的价值就在这。
      ),
    );

    final ServiceRequestResult result;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        result = await FlutterForegroundTask.restartService();
      } else {
        result = await FlutterForegroundTask.startService(
          notificationTitle: kKeepAliveNotificationTitle,
          notificationText: kKeepAliveNotificationText,
          callback: keepAliveCallback,
        );
      }
    } catch (e, s) {
      AppLogger.e(tag, '前台服务启动异常：$e');
      debugPrint('前台服务启动异常：$e\n$s');
      lastResult.value = '启动异常：$e';
      return null;
    }

    // 返回值必须看。插件内部会等 5 秒确认 isRunningService 变成 true，
    // 起不来就返回 ServiceRequestFailure（ServiceTimeoutException）。
    // 直接 await 把返回值丢掉，失败就被无声吞掉了 ——
    // AndroidManifest.xml 漏声明 <service> 正是这样藏了这么久。
    switch (result) {
      case ServiceRequestSuccess():
        AppLogger.i(tag, '前台服务已启动');
        lastResult.value = '已启动';
      case ServiceRequestFailure(:final error):
        AppLogger.e(
          tag,
          '前台服务启动失败：$error。检查 AndroidManifest.xml 是否声明了 '
              'com.pravera.flutter_foreground_task.service.ForegroundService',
        );
        lastResult.value = '启动失败：$error';
        // 服务都没起来，权限申请也就没意义了
        return result;
    }

    // 服务已经在跑了，再来处理权限 —— 这一步再怎么出问题都影响不到服务
    unawaited(_requestPermissions());
    return result;
  }

  /// 停止前台服务
  static Future<void> stop() async {
    try {
      if (!await FlutterForegroundTask.isRunningService) {
        lastResult.value = '未在运行';
        return;
      }
      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestFailure) {
        AppLogger.w(tag, '前台服务停止失败：${result.error}');
        lastResult.value = '停止失败：${result.error}';
      } else {
        AppLogger.i(tag, '前台服务已停止');
        lastResult.value = '已停止';
      }
    } catch (e) {
      AppLogger.w(tag, '前台服务停止异常：$e');
      lastResult.value = '停止异常：$e';
    }
  }

  /// 申请前台服务需要的两个权限（**必须在服务启动之后调用**）
  ///
  /// 两个权限都会弹系统界面，而插件没有超时；Activity 被系统重建时
  /// Dart 侧的 Future 可能永远不完成。加 timeout 只是兜底，
  /// 真正靠得住的是「别让它们挡在服务前面」。
  static Future<void> _requestPermissions() async {
    if (!Platform.isAndroid) return;

    // 1) 通知权限
    // Android 13+ 不申请的话服务照样在跑，但那条常驻通知不会显示 ——
    // 「拉通知栏看有没有通知」这个验证手段就会给出假阴性。
    // 只在 denied 时申请，permanently_denied 就不反复弹窗了。
    try {
      final current = await FlutterForegroundTask.checkNotificationPermission()
          .timeout(_permissionTimeout);
      if (current == NotificationPermission.denied) {
        final after =
            await FlutterForegroundTask.requestNotificationPermission()
                .timeout(_permissionTimeout);
        AppLogger.i(tag, '通知权限申请结果：$after');
        if (after == NotificationPermission.granted) {
          // 通知是在没权限的时候推出去的，现在有权限了得重新推一次才会显示
          await refreshNotification();
        }
      }
    } catch (e) {
      AppLogger.w(tag, '申请通知权限失败或超时：$e');
    }

    // 2) 电池优化豁免
    // 国产 ROM 上这个对后台存活影响很大，值得问；但只在没问过的时候问一次，
    // 否则每次进课堂都弹一个系统设置页，拒绝之后还会一直弹。
    try {
      if (StorageManager.prefs.getBool(_batteryOptAskedKey) ?? false) return;

      final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations
          .timeout(_permissionTimeout);
      if (ignoring) return;

      await StorageManager.prefs.setBool(_batteryOptAskedKey, true);
      await FlutterForegroundTask.requestIgnoreBatteryOptimization()
          .timeout(_permissionTimeout);
    } catch (e) {
      AppLogger.w(tag, '申请电池优化豁免失败或超时：$e');
    }
  }

  /// 权限后补上来时，让那条常驻通知重新推一次
  static Future<void> refreshNotification() async {
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.updateService(
        notificationTitle: kKeepAliveNotificationTitle,
        notificationText: kKeepAliveNotificationText,
      );
    } catch (e) {
      AppLogger.w(tag, '刷新前台通知失败：$e');
    }
  }

  // ---------------------------------------------------------------------------
  // 给自检页用的状态查询
  // ---------------------------------------------------------------------------

  /// 服务在不在跑
  static Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  /// 通知权限状态（Android 13+）
  static Future<NotificationPermission> notificationPermission() =>
      FlutterForegroundTask.checkNotificationPermission();

  /// 有没有拿到电池优化豁免
  static Future<bool> isIgnoringBatteryOptimizations() =>
      FlutterForegroundTask.isIgnoringBatteryOptimizations;

  /// 申请电池优化豁免（自检页手动触发，不受「只问一次」限制）
  static Future<void> requestBatteryOptimizationExemption() async {
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization()
          .timeout(_permissionTimeout);
    } catch (e) {
      AppLogger.w(tag, '申请电池优化豁免失败或超时：$e');
    }
  }
}
