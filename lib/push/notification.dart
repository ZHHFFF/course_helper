import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/app_logger.dart';

/// 共用一份通知插件，防止不同业务重复初始化并覆盖配置。
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void>? _initialization;
  int _nextId = 0;

  /// 并发调用共享初始化；失败后允许下次重试。
  Future<void> initialize() async {
    try {
      await (_initialization ??= _initialize());
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        ),
      ),
    );
  }

  /// 调用者可沿用消息 ID；提醒失败时仍继续处理应用内活动。
  Future<void> show({
    required String title,
    required String body,
    required AndroidNotificationDetails androidDetails,
    String? payload,
    int? id,
  }) async {
    try {
      await initialize();
      await _plugin.show(
        id: id ?? _nextId++,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: const DarwinNotificationDetails(
            presentSound: true,
            presentAlert: false,
            presentBanner: false,
            presentList: false,
          ),
        ),
      );
    } catch (e) {
      AppLogger.w('通知', '系统通知失败：$e');
    }
  }
}
