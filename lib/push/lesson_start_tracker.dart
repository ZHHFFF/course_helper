/// 记录同一账号、服务器下的在线课节。初次快照静默，同课程新课节也可提醒。
class LessonStartTracker {
  String? _scope;
  Set<String>? _previous;

  void reset() {
    _scope = null;
    _previous = null;
  }

  List<Map> update(String scope, List<dynamic> lessons) {
    if (_scope != scope) {
      _scope = scope;
      _previous = null;
    }
    final current = <String, Map>{};
    for (final entry in lessons.whereType<Map>()) {
      final courseId = entry['courseId']?.toString() ?? '';
      final lessonId = entry['lessonId']?.toString() ?? '';
      if (courseId.isEmpty || lessonId.isEmpty) continue;
      current['$courseId|$lessonId'] = entry;
    }
    final added = _previous == null
        ? <Map>[]
        : [
            for (final entry in current.entries)
              if (!_previous!.contains(entry.key)) entry.value,
          ];
    _previous = current.keys.toSet();
    return added;
  }
}
