/// 课件管理（v4.8.8 新增能力）单测
///
/// 覆盖 `CourseCache` 里为「课件」Tab 新增的一整组 API：
///   writeMeta / readMeta / listLessons / listPresentations /
///   deletePresentation / findLessonIdsByCourseId / clearCourse / safeFile
///
/// 为什么值得单测：这一组几乎全在**删除**路径上（删课件、清课程），
/// 出问题的表现是「用户的数据没了」或者「磁盘越清越大」，**都不会报错**。
///
/// 尤其 `_sweepOrphanImages`：图片是**同一节课的所有 PPT 共享**一个
/// `ppt/images/` 目录的，误删会让**别的课件**变成一片空白，
/// 而当场看不出任何异常 —— 所以用一条专门的用例钉住「不能误删共享图」。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:course_helper/cache/course_cache.dart';
import 'package:course_helper/cache/ppt_cache.dart';
import 'package:course_helper/utils/image_cache_key.dart';

import 'support/cache_test_env.dart';

/// 造一份 PPT 的原始 JSON（结构对齐雨课堂 `/presentation/fetch` 的 data）
Map<String, dynamic> _pptData(String title, List<String> imageUrls) => {
      'title': title,
      'width': 720,
      'height': 540,
      'version': '1.0',
      'slides': [
        for (var i = 0; i < imageUrls.length; i++)
          {
            'id': 'slide-$i',
            'index': i,
            'cover': imageUrls[i],
            'coverAlt': imageUrls[i],
            'thumbnail': imageUrls[i],
            'shapes': <dynamic>[],
            'note': '',
          },
      ],
    };

/// 在磁盘上伪造一张「已缓存」的幻灯片图片。
///
/// ⚠️ 文件名必须是 `imageCacheDigest(url).bin` —— 与 `SlideImageStore.fileFor`
/// 完全一致，否则「孤儿图片清理」的用例会假绿（文件根本不在它找的位置）。
Future<File> _seedImage(String lessonId, String url) async {
  final pptDir = await CourseCache.pptDir(lessonId);
  final dir = Directory(p.join(pptDir.path, 'images'));
  if (!await dir.exists()) await dir.create(recursive: true);
  final file = File(p.join(dir.path, '${imageCacheDigest(url)}.bin'));
  await file.writeAsBytes(List<int>.filled(64, 7));
  return file;
}

void main() {
  late CacheTestEnv env;

  setUp(() async {
    env = await CacheTestEnv.create();
  });

  tearDown(() async {
    await env.dispose();
  });

  group('课程元信息 meta.json', () {
    test('写进去能读回来', () async {
      await CourseCache.writeMeta('lesson-a',
          courseId: 'c-1', courseName: '高等数学');

      final meta = await CourseCache.readMeta('lesson-a');

      expect(meta, isNotNull);
      expect(meta!.courseId, 'c-1');
      expect(meta.courseName, '高等数学');
      expect(meta.displayName, '高等数学');
      expect(meta.updatedAt, greaterThan(0));
    });

    test('没写过时返回 null，不抛异常', () async {
      expect(await CourseCache.readMeta('never-used'), isNull);
    });

    test('两个字段都传空 → 不产生文件', () async {
      await CourseCache.writeMeta('lesson-a');
      final file = await CourseCache.metaFile('lesson-a');
      expect(await file.exists(), isFalse);
    });

    test('⚠️ 空串不覆盖已有值（学习通路径拿不到课程名时会传空）', () async {
      await CourseCache.writeMeta('lesson-a',
          courseId: 'c-1', courseName: '高等数学');
      await CourseCache.writeMeta('lesson-a'); // 两个都空 → 直接返回
      await CourseCache.writeMeta('lesson-a', courseId: 'c-1'); // 只补 courseId

      final meta = await CourseCache.readMeta('lesson-a');
      expect(meta!.courseName, '高等数学', reason: '课程名不该被空串抹掉');
    });

    test('displayName 在没课程名时退回 lessonId', () async {
      const meta = LessonMeta(lessonId: 'lesson-x');
      expect(meta.displayName, 'lesson-x');
    });
  });

  group('listLessons', () {
    test('列出所有已缓存的课，带课件份数', () async {
      await PptCache.save('lesson-a', 'ppt-1', _pptData('第一讲', []),
          courseId: 'c-1', courseName: '高数');
      await PptCache.save('lesson-a', 'ppt-2', _pptData('第二讲', []),
          courseId: 'c-1', courseName: '高数');
      await PptCache.save('lesson-b', 'ppt-3', _pptData('导论', []),
          courseId: 'c-2', courseName: '物理');

      final lessons = await CourseCache.listLessons();

      expect(lessons.length, 2);
      final a = lessons.firstWhere((l) => l.lessonId == 'lesson-a');
      expect(a.courseId, 'c-1');
      expect(a.name, '高数');
      expect(a.presentationCount, 2);
      expect(a.hasPresentations, isTrue);
    });

    test('⚠️ 老缓存（没有 meta.json）用第一份 PPT 的标题兜底', () async {
      // 模拟 v4.8.8 之前的缓存：有 ppt/*.json，但没有 meta.json。
      // 课程名以前**从来没落过盘**，所以只能拿 PPT 标题顶一下，
      // 至少比一串 lessonId 数字可读。
      final pptDir = await CourseCache.pptDir('legacy-lesson');
      await CourseCache.writeJson(
        File(p.join(pptDir.path, 'ppt-9.json')),
        {
          'presentationId': 'ppt-9',
          'savedAt': DateTime.now().millisecondsSinceEpoch,
          'data': _pptData('线性代数第一讲', []),
        },
      );

      final lessons = await CourseCache.listLessons();
      final legacy = lessons.firstWhere((l) => l.lessonId == 'legacy-lesson');

      expect(legacy.courseId, isEmpty);
      expect(legacy.name, '线性代数第一讲');
      expect(legacy.presentationCount, 1);
    });

    test('空缓存返回空列表', () async {
      expect(await CourseCache.listLessons(), isEmpty);
    });
  });

  group('listPresentations', () {
    test('按落盘时间倒序，带页数与 lessonId', () async {
      await PptCache.save('lesson-a', 'old', _pptData('旧的', ['u1']));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await PptCache.save('lesson-a', 'new', _pptData('新的', ['u2', 'u3']));

      final list = await CourseCache.listPresentations('lesson-a');

      expect(list.length, 2);
      expect(list.first.presentationId, 'new');
      expect(list.first.displayTitle, '新的');
      expect(list.first.slideCount, 2);
      expect(list.first.lessonId, 'lesson-a', reason: '查看/删除都要靠它定位');
      expect(list.last.slideCount, 1);
    });

    test('标题为空时 displayTitle 退回 presentationId', () async {
      await PptCache.save('lesson-a', 'ppt-42', _pptData('', []));
      final list = await CourseCache.listPresentations('lesson-a');
      expect(list.single.displayTitle, 'ppt-42');
    });

    test('目录不存在时返回空列表', () async {
      expect(await CourseCache.listPresentations('never-used'), isEmpty);
    });
  });

  group('deletePresentation', () {
    test('删掉 json，并清掉只被它引用的图片', () async {
      const url = 'https://x.cn/a.jpg';
      await PptCache.save('lesson-a', 'ppt-1', _pptData('唯一', [url]));
      final img = await _seedImage('lesson-a', url);

      final freed = await CourseCache.deletePresentation('lesson-a', 'ppt-1');

      expect(freed, greaterThan(0));
      expect(await img.exists(), isFalse);
      expect(await CourseCache.listPresentations('lesson-a'), isEmpty);
    });

    test('⚠️⚠️ 不误删别的课件还在用的图片（图片是同一节课共享的）', () async {
      const shared = 'https://x.cn/shared.jpg';
      const onlyA = 'https://x.cn/only-a.jpg';
      const onlyB = 'https://x.cn/only-b.jpg';

      await PptCache.save('lesson-a', 'ppt-a', _pptData('A', [shared, onlyA]));
      await PptCache.save('lesson-a', 'ppt-b', _pptData('B', [shared, onlyB]));

      final fShared = await _seedImage('lesson-a', shared);
      final fOnlyA = await _seedImage('lesson-a', onlyA);
      final fOnlyB = await _seedImage('lesson-a', onlyB);

      await CourseCache.deletePresentation('lesson-a', 'ppt-a');

      expect(await fShared.exists(), isTrue, reason: 'ppt-b 还在用，不能删');
      expect(await fOnlyA.exists(), isFalse, reason: '只有 ppt-a 用，是孤儿，该删');
      expect(await fOnlyB.exists(), isTrue);
      expect(await CourseCache.listPresentations('lesson-a'), hasLength(1));
    });

    test('删不存在的课件不炸，返回 0', () async {
      expect(await CourseCache.deletePresentation('never-used', 'nope'), 0);
    });
  });

  group('按课程聚合', () {
    test('findLessonIdsByCourseId 找出同一门课的多个 lessonId', () async {
      await CourseCache.writeMeta('lesson-1',
          courseId: 'c-1', courseName: '高数');
      await CourseCache.writeMeta('lesson-2',
          courseId: 'c-1', courseName: '高数');
      await CourseCache.writeMeta('lesson-3',
          courseId: 'c-2', courseName: '物理');

      final ids = await CourseCache.findLessonIdsByCourseId('c-1');

      expect(ids, containsAll(['lesson-1', 'lesson-2']));
      expect(ids, isNot(contains('lesson-3')));
    });

    test('courseId 为空 → 空列表（不做全量匹配）', () async {
      await CourseCache.writeMeta('lesson-1', courseId: 'c-1');
      expect(await CourseCache.findLessonIdsByCourseId(''), isEmpty);
    });

    test('clearCourse 清掉该 courseId 下所有 lessonId，不动别人的', () async {
      await CourseCache.writeMeta('lesson-1',
          courseId: 'c-1', courseName: '高数');
      await CourseCache.writeMeta('lesson-2',
          courseId: 'c-1', courseName: '高数');
      await CourseCache.writeMeta('lesson-3',
          courseId: 'c-2', courseName: '物理');
      await PptCache.save('lesson-1', 'ppt-1', _pptData('A', []));
      await PptCache.save('lesson-3', 'ppt-3', _pptData('B', []));

      await CourseCache.clearCourse('c-1');

      final left = await CourseCache.listLessons();
      expect(left.map((l) => l.lessonId).toList(), ['lesson-3']);
    });
  });

  group('safeFile', () {
    test('非法字符被白名单化', () {
      expect(CourseCache.safeFile('a/b:c'), 'a_b_c');
    });

    test('空串 → unknown', () {
      expect(CourseCache.safeFile('   '), 'unknown');
    });

    test('纯数字原样保留（雨课堂的 presentationId 就是数字）', () {
      expect(CourseCache.safeFile('1234567'), '1234567');
    });

    test('⚠️ 写 / 列 / 删三处必须走同一套命名', () async {
      // 从 `PptCache` 提上来的动机就是这个：两处各写一份白名单逻辑迟早写歪，
      // 写歪的表现是「列表里有、点进去 404」或者「删不掉」。
      await PptCache.save('lesson-a', 'has/slash', _pptData('X', []));

      final list = await CourseCache.listPresentations('lesson-a');
      expect(list.single.presentationId, 'has/slash');

      await CourseCache.deletePresentation('lesson-a', 'has/slash');
      expect(await CourseCache.listPresentations('lesson-a'), isEmpty);
    });
  });
}
