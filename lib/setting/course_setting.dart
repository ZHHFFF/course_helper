import 'dart:convert';

import '../models/course.dart';
import '../utils/storage.dart';

class CourseSetting {
  static const _settingsKey = 'course_settings';

  static Future<CourseSettings?> getSettings(String courseId) async {
    final allSettings = await _getAllSettings();
    return allSettings[courseId];
  }

  static Future<Map<String, CourseSettings>> _getAllSettings() async {
    final settingsJson = StorageManager.prefs.getString(_settingsKey);
    if (settingsJson == null || settingsJson.isEmpty) {
      return {};
    }

    try {
      final Map<String, dynamic> decoded = json.decode(settingsJson);
      return decoded.map((key, value) => 
        MapEntry(key, CourseSettings.fromJson(value as Map<String, dynamic>))
      );
    } catch (e) {
      return {};
    }
  }

  static Future<void> saveSettings(String courseId, CourseSettings settings) async {
    final allSettings = await _getAllSettings();
    allSettings[courseId] = settings;
    
    final encoded = json.encode(
      allSettings.map((key, value) => MapEntry(key, value.toJson()))
    );
    await StorageManager.prefs.setString(_settingsKey, encoded);
  }

  static Future<void> updateLocation(String courseId, CourseLocation location) async {
    final settings = await getSettings(courseId);
    await saveSettings(courseId, settings?.copyWith(location: location) ?? CourseSettings(location: location));
  }
}
