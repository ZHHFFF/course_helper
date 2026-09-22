import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'dart:async';

import '../api/api_service.dart';
import '../session/account.dart';
import '../utils/storage.dart';

/// 平台类型枚举
enum PlatformType {
  chaoxing, // 学习通
  rainClassroom // 雨课堂
}

/// 雨课堂服务器类型枚举
enum RainClassroomServerType {
  yuketang, // 雨课堂
  pro, // 荷塘雨课堂
  changjiang, // 长江雨课堂
  huanghe // 黄河雨课堂
}

/// 雨课堂各服务器的标识色。
///
/// 原先住在 `pages/accounts.dart`。2026-09-22 服务器切换入口从账号页右上角菜单
/// 搬到「设置」Tab，两个文件都要用这份色板 —— 放到枚举定义处最合适，
/// 避免两处各写一遍导致不同步。
const Map<RainClassroomServerType, Color> kRainClassroomServerColors = {
  RainClassroomServerType.yuketang: Color(0xFF5096F5),
  RainClassroomServerType.pro: Color(0xFF7B3BB5),
  RainClassroomServerType.changjiang: Color(0xFFC21F30),
  RainClassroomServerType.huanghe: Color(0xFFB57232),
};

/// 雨课堂各服务器的显示名。
const Map<RainClassroomServerType, String> kRainClassroomServerNames = {
  RainClassroomServerType.yuketang: '雨课堂',
  RainClassroomServerType.pro: '荷塘 · 雨课堂',
  RainClassroomServerType.changjiang: '长江 · 雨课堂',
  RainClassroomServerType.huanghe: '黄河 · 雨课堂',
};

/// 平台状态管理器
class PlatformManager {
  static final PlatformManager _instance = PlatformManager._internal();
  factory PlatformManager() => _instance;
  PlatformManager._internal();

  static const _platformKey = 'current_platform';
  static const _serverKey = 'current_server';
  PlatformType _currentPlatform = PlatformType.chaoxing;

  /// 雨课堂服务器的**新装默认值**。
  ///
  /// 2026-09-22 用户要求「雨课堂默认为长江雨课堂」。
  /// ⚠️ 只改默认值、不动已装机用户的存量设置：`initialize()` 里读得到
  /// `current_server` 就以后者为准，所以老用户不会被这次改动改掉。
  RainClassroomServerType _currentServer = RainClassroomServerType.changjiang;

  /// 获取当前平台
  PlatformType get currentPlatform => _currentPlatform;

  bool get isChaoxing => _currentPlatform == PlatformType.chaoxing;
  bool get isRainClassroom => _currentPlatform == PlatformType.rainClassroom;
  
  /// 获取当前雨课堂服务器
  RainClassroomServerType get currentServer => _currentServer;

  /// 初始化平台
  Future<void> initialize() async {
    try {
      final platformStr = StorageManager.prefs.getString(_platformKey);

      if (platformStr != null && platformStr.isNotEmpty) {
        switch (platformStr.toLowerCase()) {
          case 'chaoxing':
            _currentPlatform = PlatformType.chaoxing;
            break;
          case 'rainclassroom':
            _currentPlatform = PlatformType.rainClassroom;
            break;
        }
      }
      
      // 加载雨课堂服务器设置
      final serverStr = StorageManager.prefs.getString(_serverKey);
      if (serverStr != null && serverStr.isNotEmpty) {
        switch (serverStr.toLowerCase()) {
          case 'yuketang':
            _currentServer = RainClassroomServerType.yuketang;
            break;
          case 'pro':
            _currentServer = RainClassroomServerType.pro;
            break;
          case 'changjiang':
            _currentServer = RainClassroomServerType.changjiang;
            break;
          case 'huanghe':
            _currentServer = RainClassroomServerType.huanghe;
            break;
        }
      }
      
      // 触发平台变化回调，初始化 headers
      ApiService.onPlatformChange!();
    } catch (e) {
      debugPrint('加载平台失败：$e');
    }
  }

  /// 设置平台
  Future<void> setPlatform(PlatformType platform) async {
    final oldPlatform = _currentPlatform;

    if (oldPlatform != platform) {
      _currentPlatform = platform;
      try {
        StorageManager.prefs.setString(_platformKey, _currentPlatform.name);
      } catch (e) {
        debugPrint('保存平台失败：$e');
      }
      ApiService.onPlatformChange?.call();
      await AccountManager.switchToPlatformAccounts();
    }
  }
  
  /// 设置雨课堂服务器
  Future<void> setServer(RainClassroomServerType server) async {
    if (_currentServer != server) {
      _currentServer = server;
      try {
        StorageManager.prefs.setString(_serverKey, _currentServer.name);
      } catch (e) {
        debugPrint('保存服务器失败：$e');
      }
      ApiService.onPlatformChange?.call();
    }
  }
}
