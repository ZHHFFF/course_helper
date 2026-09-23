import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/api/rc_crawler.dart';
import 'package:course_helper/models/rc_activity.dart';

void main() {
  group('RCActivity 教学活动与课件解析', () {
    test('标准活动列表解析（包含课堂教学 Type 14 与课件 Type 2）', () {
      final json = {
        'code': 0,
        'data': {
          'activities': [
            {
              'id': 1001,
              'type': 14,
              'title': '第一讲 计算机系统概述',
              'courseware_id': 'lesson_abc_1',
              'classroom_id': 20001,
              'created': 1710000000000,
            },
            {
              'id': 1002,
              'type': 2,
              'title': '第1讲 课件与预习资料',
              'courseware_id': 'cw_xyz_2',
              'classroom_id': 20001,
              'created': 1710100000000,
            },
            {
              'id': 1003,
              'type': 6,
              'title': '期中考试公告',
              'created': 1710200000000,
            }
          ]
        }
      };

      final list = RCActivity.parseActivitiesJson(json, classroomId: '20001');
      expect(list.length, 3);

      // 默认按时间倒序排（1003 -> 1002 -> 1001）
      final first = list[0];
      expect(first.id, '1003');
      expect(first.type, 6);
      expect(first.typeName, '公告通知');
      expect(first.isLesson, isFalse);

      final second = list[1];
      expect(second.id, '1002');
      expect(second.type, 2);
      expect(second.typeName, '课件资料');
      expect(second.isCourseware, isTrue);
      expect(second.coursewareId, 'cw_xyz_2');

      final third = list[2];
      expect(third.id, '1001');
      expect(third.type, 14);
      expect(third.typeName, '课堂教学');
      expect(third.isLesson, isTrue);
      expect(third.coursewareId, 'lesson_abc_1');
      expect(third.classroomId, '20001');
    });

    test('秒级时间戳自动转换为毫秒', () {
      final json = {
        'data': {
          'activities': [
            {
              'id': 1,
              'type': 14,
              'title': '测试',
              'created': 1710000000, // 10 位秒级时间戳
            }
          ]
        }
      };

      final list = RCActivity.parseActivitiesJson(json);
      expect(list.first.createdAt, 1710000000000);
    });

    test('ISO-8601 时间字符串解析', () {
      final json = {
        'data': {
          'activities': [
            {
              'id': 2,
              'type': 14,
              'title': '测试2',
              'created': '2026-03-10T12:00:00.000Z',
            }
          ]
        }
      };

      final list = RCActivity.parseActivitiesJson(json);
      expect(list.first.createdAt, DateTime.parse('2026-03-10T12:00:00.000Z').millisecondsSinceEpoch);
    });

    test('缺省与异常数据兜底', () {
      final json = {
        'data': {
          'activities': [
            {'invalid': 'data'},
            'not a map',
            null,
          ]
        }
      };

      final list = RCActivity.parseActivitiesJson(json, classroomId: '999');
      expect(list.length, 1);
      expect(list.first.title, '未命名活动');
      expect(list.first.classroomId, '999');
      expect(list.first.type, 0);
    });

    test('空输入或非标准顶层结构不崩溃', () {
      expect(RCActivity.parseActivitiesJson(null), isEmpty);
      expect(RCActivity.parseActivitiesJson({}), isEmpty);
      expect(RCActivity.parseActivitiesJson({'data': null}), isEmpty);
      expect(RCActivity.parseActivitiesJson('bad json'), isEmpty);
    });
  });

  group('RCActivity 回放流解析', () {
    test('直接 replay_url 提取', () {
      final url = RCActivity.extractReplayUrl({
        'replay_url': 'https://live.yuketang.cn/record/123.m3u8',
      });
      expect(url, 'https://live.yuketang.cn/record/123.m3u8');
    });

    test('字符串型 replay 字段提取', () {
      final url = RCActivity.extractReplayUrl({
        'replay': 'https://live.yuketang.cn/record/456.m3u8',
      });
      expect(url, 'https://live.yuketang.cn/record/456.m3u8');
    });

    test('对象型 replay / stream_url 提取', () {
      final url = RCActivity.extractReplayUrl({
        'replay': {
          'stream_url': 'https://live.yuketang.cn/stream/789.flv',
        },
      });
      expect(url, 'https://live.yuketang.cn/stream/789.flv');
    });

    test('嵌套 live / video 对象提取', () {
      final liveUrl = RCActivity.extractReplayUrl({
        'live': {'play_url': 'https://live.yuketang.cn/live/live.m3u8'},
      });
      expect(liveUrl, 'https://live.yuketang.cn/live/live.m3u8');

      final videoUrl = RCActivity.extractReplayUrl({
        'video': {'url': 'https://vod.yuketang.cn/video/v.mp4'},
      });
      expect(videoUrl, 'https://vod.yuketang.cn/video/v.mp4');
    });

    test('无回放或非法地址返回 null', () {
      expect(RCActivity.extractReplayUrl({}), isNull);
      expect(RCActivity.extractReplayUrl({'replay': 'not-a-url'}), isNull);
      expect(RCActivity.extractReplayUrl({'replay_url': ''}), isNull);
    });
  });

  group('RCCrawler 课程提取与多路合并', () {
    test('extractCoursesList 支持各种响应包装', () {
      final wrappedInList = {
        'code': 0,
        'data': {
          'list': [
            {'classroom_id': 1, 'name': '课A'}
          ]
        }
      };
      expect(RCCrawler.extractCoursesList(wrappedInList).length, 1);

      final directDataList = {
        'code': 0,
        'data': [
          {'classroom_id': 2, 'name': '课B'}
        ]
      };
      expect(RCCrawler.extractCoursesList(directDataList).length, 1);

      expect(RCCrawler.extractCoursesList(null), isEmpty);
      expect(RCCrawler.extractCoursesList({}), isEmpty);
    });

    test('mergeCourses 合并移动端在修、Web端与归档结课课程', () {
      final learningList = [
        {
          'course_id': 101,
          'classroom_id': 201,
          'course_name': '数据结构',
          'classroom_name': '2026春季班',
          'teacher': {'name': '严老师', 'avatar': 'https://img/yan.png'},
        }
      ];

      final webCourses = [
        {
          'course_id': 102,
          'classroom_id': 202,
          'course_name': '操作系统',
          'classroom_name': '2026春季班',
          'teacher_name': '汤老师',
        },
        // 课 101 在 Web 端也存在（测试去重）
        {
          'course_id': 101,
          'classroom_id': 201,
          'course_name': '数据结构',
        }
      ];

      final archivedCourses = [
        {
          'course_id': 100,
          'classroom_id': 200,
          'course_name': '离散数学',
          'classroom_name': '2025秋季班',
          'teacher_name': '屈老师',
        }
      ];

      final merged = RCCrawler.mergeCourses(
        learningList: learningList,
        webCourses: webCourses,
        archivedCourses: archivedCourses,
      );

      // 共 3 门课（201, 202, 200）
      expect(merged.length, 3);

      final c201 = merged.firstWhere((c) => c.classId == '201');
      expect(c201.name, '数据结构');
      expect(c201.teacher, '严老师');
      expect(c201.state, isTrue); // 进行中

      final c202 = merged.firstWhere((c) => c.classId == '202');
      expect(c202.name, '操作系统');
      expect(c202.state, isTrue);

      final c200 = merged.firstWhere((c) => c.classId == '200');
      expect(c200.name, '离散数学');
      expect(c200.state, isFalse); // 已结课
      expect(c200.note, contains('已结课'));
    });

    test('在课 lessonId 顺利挂接到对应课程', () {
      final learningList = [
        {
          'course_id': 101,
          'classroom_id': 201,
          'course_name': '编译原理',
        }
      ];

      final merged = RCCrawler.mergeCourses(
        learningList: learningList,
        onLessonMap: {'101': 'lesson_live_888'},
      );

      expect(merged.length, 1);
      expect(merged.first.lessonId, 'lesson_live_888');
    });

    test('已结课课程排在进行中课程之后', () {
      final merged = RCCrawler.mergeCourses(
        learningList: [
          {'course_id': 1, 'classroom_id': 11, 'course_name': 'B课程'}
        ],
        archivedCourses: [
          {'course_id': 2, 'classroom_id': 22, 'course_name': 'A课程（已结课）'}
        ],
      );

      expect(merged.length, 2);
      expect(merged[0].state, isTrue); // 进行中的B课程排前
      expect(merged[1].state, isFalse); // 已结课的A课程排后
    });
  });
}
