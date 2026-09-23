/// 雨课堂教学活动 / 课件模型与纯函数解析
///
/// 核心来源：`/v2/api/web/logs/learn/{classroom_id}?actype=-1&page=0&offset=500&sort=-1`
/// 覆盖：课堂教学 (Type 14)、课件 (Type 2)、公告 (Type 6)、慕课 (Type 15) 等，
/// 以及课堂回放流 (replay / live stream) 的提取。
library;

class RCActivity {
  final String id;
  final int type;
  final String title;
  final String coursewareId; // 对于 Type 14（课堂），这就是 lessonId
  final String classroomId;
  final int createdAt;
  final String? replayUrl;
  final Map<String, dynamic> raw;

  const RCActivity({
    required this.id,
    required this.type,
    required this.title,
    required this.coursewareId,
    required this.classroomId,
    required this.createdAt,
    this.replayUrl,
    this.raw = const {},
  });

  /// 是否为课堂教学活动（Type 14）
  bool get isLesson => type == 14;

  /// 是否为课件资料（Type 2）
  bool get isCourseware => type == 2;

  /// 是否有回放视频流
  bool get hasReplay => replayUrl != null && replayUrl!.trim().isNotEmpty;

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
    final id = (json['id'] ?? json['activity_id'] ?? '').toString();
    final type = (json['type'] as num?)?.toInt() ??
        int.tryParse(json['type']?.toString() ?? '0') ??
        0;
    final title = (json['title'] ?? json['name'] ?? '未命名活动').toString().trim();
    final coursewareId = (json['courseware_id'] ?? json['coursewareId'] ?? id).toString();
    final cId = (json['classroom_id'] ?? json['classroomId'] ?? classroomId).toString();

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

    return RCActivity(
      id: id,
      type: type,
      title: title.isEmpty ? '未命名活动' : title,
      coursewareId: coursewareId,
      classroomId: cId,
      createdAt: createdAt,
      replayUrl: replayUrl,
      raw: json,
    );
  }

  /// 从活动数据中解析回放流或播放地址
  static String? extractReplayUrl(Map<String, dynamic> json) {
    for (final key in const ['replay_url', 'replayUrl', 'video_url', 'play_url', 'live_url']) {
      final val = json[key]?.toString().trim() ?? '';
      if (val.startsWith('http')) return val;
    }

    final replay = json['replay'];
    if (replay is String && replay.trim().startsWith('http')) {
      return replay.trim();
    } else if (replay is Map) {
      for (final key in const ['url', 'play_url', 'live_url', 'stream_url', 'm3u8']) {
        final val = replay[key]?.toString().trim() ?? '';
        if (val.startsWith('http')) return val;
      }
    }

    final live = json['live'];
    if (live is Map) {
      final val = (live['url'] ?? live['play_url'] ?? live['stream'])?.toString().trim() ?? '';
      if (val.startsWith('http')) return val;
    }

    final video = json['video'];
    if (video is Map) {
      final val = (video['url'] ?? video['play_url'])?.toString().trim() ?? '';
      if (val.startsWith('http')) return val;
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

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'coursewareId': coursewareId,
    'classroomId': classroomId,
    'createdAt': createdAt,
    if (replayUrl != null) 'replayUrl': replayUrl,
  };
}
