import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 前台服务的回归护栏。
///
/// `flutter_foreground_task` **不自己声明 `<service>`**，要求宿主 App 在
/// `AndroidManifest.xml` 里声明（插件 README：`Warning: Do not change service name.`）。
/// 漏了它不会报错 —— 显式 Intent 指向未声明组件时框架返回 null 且不抛异常，
/// 插件把 `result.success(true)` 当成功上报，Dart 侧完全看不出来。
///
/// 后果是 `_startForegroundService()` 整条链路变成死代码：没有前台通知、
/// 没有唤醒锁、没有 isolate 保活，App 切后台/锁屏后 WebSocket 可能被冻结
/// → 漏签到、漏题。
///
/// 这个 bug 在仓库里藏了很久，用几条断言钉住，别再让它回来。
void main() {
  const manifestPath = 'android/app/src/main/AndroidManifest.xml';
  const serviceClass =
      'com.pravera.flutter_foreground_task.service.ForegroundService';

  late String manifest;

  /// 把 ForegroundService 那个 `<service ...>` 元素整段切出来，
  /// 只在这个范围内断言，避免被文件里别的组件（MainActivity、receiver）干扰。
  String foregroundServiceElement() {
    final nameIndex = manifest.indexOf(serviceClass);
    if (nameIndex < 0) return '';

    final open = manifest.lastIndexOf('<service', nameIndex);
    final close = manifest.indexOf('>', nameIndex);
    if (open < 0 || close < 0) return '';

    return manifest.substring(open, close + 1);
  }

  setUpAll(() {
    final file = File(manifestPath);
    expect(
      file.existsSync(),
      isTrue,
      reason: '找不到 $manifestPath（测试需在包根目录下运行）',
    );
    manifest = file.readAsStringSync();
  });

  test('声明了 flutter_foreground_task 的前台服务', () {
    expect(
      manifest,
      contains(serviceClass),
      reason: '缺 <service> 会让 startService 静默失败（无通知、无保活），'
          '切后台后 WebSocket 可能被冻结，导致漏签到、漏题',
    );
    expect(
      foregroundServiceElement(),
      isNotEmpty,
      reason: '<service> 元素切不出来，检查标签有没有写歪',
    );
  });

  test('foregroundServiceType 与已声明的权限一致', () {
    // Android 14+ 要求 service 声明的每个 type 都有对应权限，
    // 多声明 type 会在启动时被系统拒掉
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
      reason: '要么补权限，要么把 service 的 type 改小',
    );
    expect(
      foregroundServiceElement(),
      contains('android:foregroundServiceType="dataSync"'),
      reason: 'remoteMessaging 没有对应权限，照抄插件 README 会让服务起不来',
    );
  });

  test('stopWithTask=true，划掉 App 后不留僵尸服务', () {
    expect(
      foregroundServiceElement(),
      contains('android:stopWithTask="true"'),
    );
  });

  test('service 不导出', () {
    expect(
      foregroundServiceElement(),
      contains('android:exported="false"'),
    );
  });
}
