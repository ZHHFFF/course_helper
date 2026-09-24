/// 雨课堂教学活动 / 课件模型与纯函数解析
///
/// 核心来源：`/v2/api/web/logs/learn/{classroom_id}?actype=-1&page=0&offset=500&sort=-1`
/// 覆盖：课堂教学 (Type 14)、课件 (Type 2)、公告 (Type 6)、慕课 (Type 15) 等，
/// 以及课堂回放流 (replay / live stream) 的提取。
library;

import 'dart:convert';

class RCActivity {
  final String id;
  final int type;
  final String title;
  final String coursewareId; // 对于 Type 14（课堂），这就是 lessonId
  final String classroomId;
  final int createdAt;
  final String? replayUrl;
  final String? presentationId;
  final List<String> presentationIds;
  final Map<String, dynamic> raw;

  const RCActivity({
    required this.id,
    required this.type,
    required this.title,
    required this.coursewareId,
    required this.classroomId,
    required this.createdAt,
    this.replayUrl,
    this.presentationId,
    this.presentationIds = const [],
    this.raw = const {},
  });

  /// 是否为课堂教学活动（Type 14）
  bool get isLesson => type == 14;

  /// 是否为课件资料（Type 2）
  bool get isCourseware => type == 2;

  /// 是否有回放视频流
  bool get hasReplay => replayUrl != null && replayUrl!.trim().isNotEmpty;

  /// 是否包含课件/幻灯片元数据标识
  bool get hasPresentation =>
      (presentationId != null && presentationId!.isNotEmpty) || presentationIds.isNotEmpty;

  /// 活动类型显示名称
  String get typeName {
    switch (type) {
      case 14:
        return '课堂教学';
      case 2:
        return '课件资料';
      case 6:
        return '公告通知';
      case 15:
        return '慕课视频';
      case 17:
        return '在线视频';
      default:
        return '教学活动';
    }
  }

  factory RCActivity.fromJson(Map<String, dynamic> json, {String classroomId = ''}) {
    final id = (json['id'] ?? json['activity_id'] ?? json['lesson_id'] ?? json['lessonId'] ?? '').toString().trim();
    final type = (json['type'] as num?)?.toInt() ??
        int.tryParse(json['type']?.toString() ?? '0') ??
        0;
    final title = (json['title'] ?? json['name'] ?? '未命名活动').toString().trim();

    // 解析 content（支持 Map 或 JSON 字符串）
    dynamic content = json['content'];
    if (content is String && content.trim().startsWith('{')) {
      try {
        content = jsonDecode(content);
      } catch (_) {}
    }

    var coursewareId = (json['courseware_id'] ?? json['coursewareId'] ?? '').toString().trim();
    if (coursewareId.isEmpty || coursewareId == 'null') {
      if (content is Map) {
        final cid = (content['courseware_id'] ?? content['coursewareId'] ?? content['lesson_id'] ?? content['lessonId'])?.toString().trim();
        if (cid != null && cid.isNotEmpty && cid != 'null') {
          coursewareId = cid;
        }
      }
    }
    if (coursewareId.isEmpty || coursewareId == 'null') {
      coursewareId = id;
    }

    var cId = (json['classroom_id'] ?? json['classroomId'] ?? '').toString().trim();
    if (cId.isEmpty || cId == 'null') {
      cId = classroomId.trim();
    }

    int createdAt = 0;
    final createdRaw = json['created'] ?? json['created_at'] ?? json['startTime'] ?? json['date'];
    if (createdRaw is num) {
      createdAt = createdRaw.toInt();
      if (createdAt > 0 && createdAt < 10000000000) {
        createdAt *= 1000;
      }
    } else if (createdRaw is String) {
      final parsed = DateTime.tryParse(createdRaw);
      if (parsed != null) {
        createdAt = parsed.millisecondsSinceEpoch;
      } else {
        final numVal = int.tryParse(createdRaw);
        if (numVal != null) {
          createdAt = numVal > 0 && numVal < 10000000000 ? numVal * 1000 : numVal;
        }
      }
    }

    final replayUrl = extractReplayUrl(json);
    final presIds = extractPresentationIds(json);
    final presId = presIds.isNotEmpty ? presIds.first : null;

    return RCActivity(
      id: id,
      type: type,
      title: title.isEmpty ? '未命名活动' : title,
      coursewareId: coursewareId,
      classroomId: cId,
      createdAt: createdAt,
      replayUrl: replayUrl,
      presentationId: presId,
      presentationIds: presIds,
      raw: json,
    );
  }

  /// 规范化回放或媒体 URL（处理协议相对路径 //...）
  static String? _normalizeUrl(dynamic raw) {
    if (raw == null) return null;
    var str = raw.toString().trim();
    if (str.startsWith('http://') || str.startsWith('https://')) return str;
    if (str.startsWith('//')) return 'https:$str';
    return null;
  }

  /// 从活动数据中解析回放流或播放地址
  static String? extractReplayUrl(Map<String, dynamic> json) {
    for (final key in const ['replay_url', 'replayUrl', 'video_url', 'play_url', 'live_url']) {
      final url = _normalizeUrl(json[key]);
      if (url != null) return url;
    }

    final replay = json['replay'];
    if (replay is String) {
      final url = _normalizeUrl(replay);
      if (url != null) return url;
    } else if (replay is Map) {
      for (final key in const ['url', 'play_url', 'live_url', 'stream_url', 'm3u8']) {
        final url = _normalizeUrl(replay[key]);
        if (url != null) return url;
      }
    }

    final live = json['live'] ?? json['live_info'];
    if (live is Map) {
      for (final key in const ['url', 'play_url', 'stream', 'stream_url', 'm3u8']) {
        final url = _normalizeUrl(live[key]);
        if (url != null) return url;
      }
    }

    final video = json['video'] ?? json['video_info'];
    if (video is Map) {
      for (final key in const ['url', 'play_url', 'stream', 'stream_url', 'm3u8']) {
        final url = _normalizeUrl(video[key]);
        if (url != null) return url;
      }
    }

    return null;
  }

  /// 纯函数：解析 API 响应为活动列表
  static List<RCActivity> parseActivitiesJson(dynamic responseData, {String classroomId = ''}) {
    if (responseData == null) return const [];
    dynamic listData;
    if (responseData is Map) {
      final data = responseData['data'];
      if (data is Map) {
        listData = data['activities'] ?? data['list'];
      } else if (data is List) {
        listData = data;
      } else {
        listData = responseData['activities'] ?? responseData['list'];
      }
    } else if (responseData is List) {
      listData = responseData;
    }

    if (listData is! List) return const [];

    final result = <RCActivity>[];
    for (final item in listData) {
      if (item is Map) {
        try {
          result.add(RCActivity.fromJson(Map<String, dynamic>.from(item), classroomId: classroomId));
        } catch (_) {}
      }
    }

    // 按创建时间倒序排
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  /// 从活动 JSON 中提取包含的 presentation_id 列表
  static List<String> extractPresentationIds(Map<String, dynamic> json) {
    final ids = <String>{};

    void addValid(dynamic val) {
      if (val == null) return;
      final s = val.toString().trim();
      if (s.isNotEmpty && s != 'null' && s != '0' && s != 'undefined') {
        ids.add(s);
      }
    }

    // 1. 顶层直接字段
    addValid(json['presentation_id']);
    addValid(json['presentationId']);
    addValid(json['presentation_url_id']);

    // 2. content 内嵌（Map 或 JSON 字符串）
    dynamic content = json['content'];
    if (content is String && content.trim().startsWith('{')) {
      try {
        content = jsonDecode(content);
      } catch (_) {}
    }
    if (content is Map) {
      addValid(content['presentation_id']);
      addValid(content['presentationId']);
      addValid(content['presentation_url_id']);
      if (content['id'] != null && (json['type'] == 2 || content['type'] == 'presentation')) {
        addValid(content['id']);
      }
      if (content['presentations'] is List) {
        for (final p in content['presentations']) {
          if (p is Map) {
            addValid(p['id']);
            addValid(p['presentation_id']);
            addValid(p['presentationId']);
          } else {
            addValid(p);
          }
        }
      }
      if (content['res_list'] is List) {
        for (final r in content['res_list']) {
          if (r is Map) {
            addValid(r['presentation_id']);
            addValid(r['presentationId']);
            addValid(r['id']);
          } else {
            addValid(r);
          }
        }
      }
    }

    // 3. 顶层 res_list / resList 资源列表
    final resList = json['res_list'] ?? json['resList'] ?? json['resources'];
    if (resList is List) {
      for (final r in resList) {
        if (r is Map) {
          addValid(r['presentation_id']);
          addValid(r['presentationId']);
          addValid(r['id']);
        } else {
          addValid(r);
        }
      }
    }

    // 4. 顶层 presentations 列表
    if (json['presentations'] is List) {
      for (final p in json['presentations']) {
        if (p is Map) {
          addValid(p['id']);
          addValid(p['presentation_id']);
          addValid(p['presentationId']);
        } else {
          addValid(p);
        }
      }
    }

    return ids.toList();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'coursewareId': coursewareId,
    'classroomId': classroomId,
    'createdAt': createdAt,
    if (replayUrl != null) 'replayUrl': replayUrl,
    if (presentationId != null) 'presentationId': presentationId,
    if (presentationIds.isNotEmpty) 'presentationIds': presentationIds,
  };
}
