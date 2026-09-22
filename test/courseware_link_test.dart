import 'package:course_helper/cache/course_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// 课程 ↔ 课件缓存的关联逻辑。
///
/// 这条链路出错的症状很隐蔽：课件页能列出所有课程，但**点进去每门课都是
/// 「还没有缓存课件」**，而缓存其实好好地躺在磁盘上（只是没被认领）。
void main() {
  group('resolveLessonIdsForCourse', () {
    test('meta.json 里 courseId 对上的会被关联', () {
      final ids = resolveLessonIdsForCourse(
        courseId: 'c1',
        lessonIdsByCourseId: {'c1': ['l1', 'l2']},
        cachedDirNames: {'l1', 'l2'},
      );
      expect(ids, {'l1', 'l2'});
    });

    // ---- 回归用例：老缓存没有 meta.json ----
    //
    // v4.8.8 之前的版本从来没写过 meta.json，用户手里已有的缓存全是
    // 「无 courseId」的。没有这条兜底，课件页就会列出一堆点进去空白的课程。
    test('回归：没有 meta，但在课的 lessonId 能按目录名对上', () {
      final ids = resolveLessonIdsForCourse(
        courseId: 'c1',
        lessonIdsByCourseId: const {}, // 老缓存：一个都关联不上
        cachedDirNames: {'l9'},
        onLessonId: 'l9',
      );
      expect(ids, {'l9'});
    });

    test('在课的 lessonId 在磁盘上没有对应目录 → 不关联', () {
      final ids = resolveLessonIdsForCourse(
        courseId: 'c1',
        lessonIdsByCourseId: const {},
        cachedDirNames: {'l1'},
        onLessonId: 'l999',
      );
      expect(ids, isEmpty);
    });

    test('两条来源都有时合并去重', () {
      final ids = resolveLessonIdsForCourse(
        courseId: 'c1',
        lessonIdsByCourseId: {'c1': ['l1']},
        cachedDirNames: {'l1', 'l2'},
        onLessonId: 'l2',
      );
      expect(ids, {'l1', 'l2'});
    });

    test('同一节课同时来自 meta 和在课 lessonId → 只算一次', () {
      final ids = resolveLessonIdsForCourse(
        courseId: 'c1',
        lessonIdsByCourseId: {'c1': ['l1']},
        cachedDirNames: {'l1'},
        onLessonId: 'l1',
      );
      expect(ids, {'l1'});
    });

    test('在课 lessonId 会先做 safeName 规范化再比对目录名', () {
      // 目录名是 safeName 之后的形态；原始 lessonId 带斜杠/点要能对上
      final dir = CourseCache.safeName('../weird id');
      final ids = resolveLessonIdsForCourse(
        courseId: 'c1',
        lessonIdsByCourseId: const {},
        cachedDirNames: {dir},
        onLessonId: '../weird id',
      );
      expect(ids, {dir});
    });

    test('没有在课信息、也没有 meta → 空集（不该瞎猜）', () {
      final ids = resolveLessonIdsForCourse(
        courseId: 'c1',
        lessonIdsByCourseId: const {},
        cachedDirNames: {'l1', 'l2'},
      );
      expect(ids, isEmpty);
    });

    test('courseId 为空串 → 不该把 byCourse[""] 里的东西算进来', () {
      final ids = resolveLessonIdsForCourse(
        courseId: '',
        lessonIdsByCourseId: {'': ['orphan1']},
        cachedDirNames: {'orphan1'},
      );
      expect(ids, isEmpty);
    });

    test('在课 lessonId 是空白串 → 当作没有', () {
      final ids = resolveLessonIdsForCourse(
        courseId: 'c1',
        lessonIdsByCourseId: const {},
        cachedDirNames: {'l1'},
        onLessonId: '   ',
      );
      expect(ids, isEmpty);
    });

    test('返回的是可变集合（调用方会 addAll 到 absorbed）', () {
      final ids = resolveLessonIdsForCourse(
        courseId: 'c1',
        lessonIdsByCourseId: const {},
        cachedDirNames: const {},
      );
      ids.add('x');
      expect(ids, {'x'});
    });
  });
}
