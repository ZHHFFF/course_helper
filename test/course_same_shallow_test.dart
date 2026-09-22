// 钉住 `Course.sameShallowAs` 的语义 —— 课程页「静默刷新不重建」的判定前提。
//
// 背景（真机 bug：页面反复重载）：
// 课程页有个 3 秒轮询，只要在线课堂数据变了就重新加载列表。旧实现无条件先
// `setState(_isLoading = true)`，于是每 3 秒把列表切回 loading 再切回来。
// 修复的关键是「数据没变就别 setState」，而这个判定必须走字段比对：
// `Course` **没有**覆写 `operator ==`，接口每次返回的都是新对象，
// 用 `==` 永远为 false，优化等于没写。
//
// 所以这里把 `sameShallowAs` 的边界钉死：哪些字段参与、哪些不参与。
import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/models/course.dart';

Course makeCourse({
  String courseId = 'c1',
  String classId = 'cl1',
  String? cpi = 'cpi1',
  String image = 'img',
  String name = '高等数学',
  String teacher = '张三',
  bool state = true,
  String? note = '课堂1',
  String? schools = '某大学',
  String? beginDate = '2026-09-01',
  String? endDate = '2027-01-01',
  String? lessonId = 'L1',
  CourseSettings? settings,
}) {
  return Course(
    courseId: courseId,
    classId: classId,
    cpi: cpi,
    image: image,
    name: name,
    teacher: teacher,
    state: state,
    note: note,
    schools: schools,
    beginDate: beginDate,
    endDate: endDate,
    lessonId: lessonId,
    settings: settings,
  );
}

void main() {
  group('Course.sameShallowAs', () {
    test('字段全等 → true（两份不同实例）', () {
      final a = makeCourse();
      final b = makeCourse();
      expect(identical(a, b), isFalse, reason: '必须是两个不同实例才有意义');
      expect(a.sameShallowAs(b), isTrue);
    });

    test('未覆写 operator ==，所以 == 判不出来（这是必须用 sameShallowAs 的原因）',
        () {
      final a = makeCourse();
      final b = makeCourse();
      // 如果哪天有人给 Course 加了 operator ==，这条会失败 ——
      // 那时应当重新评估课程页的静默刷新逻辑，而不是直接删掉这个测试。
      expect(a == b, isFalse);
      expect(a.sameShallowAs(b), isTrue);
    });

    // 逐个字段确认「变了就不相等」，防止哪天新增字段漏加进比较
    final mutations = <String, Course Function()>{
      'courseId': () => makeCourse(courseId: 'other'),
      'classId': () => makeCourse(classId: 'other'),
      'cpi': () => makeCourse(cpi: 'other'),
      'image': () => makeCourse(image: 'other'),
      'name': () => makeCourse(name: '其他课'),
      'teacher': () => makeCourse(teacher: '李四'),
      'state': () => makeCourse(state: false),
      'note': () => makeCourse(note: '课堂2'),
      'schools': () => makeCourse(schools: '另一所大学'),
      'beginDate': () => makeCourse(beginDate: '2026-10-01'),
      'endDate': () => makeCourse(endDate: '2027-02-01'),
      'lessonId': () => makeCourse(lessonId: 'L2'),
    };

    mutations.forEach((field, build) {
      test('$field 不同 → false', () {
        expect(makeCourse().sameShallowAs(build()), isFalse);
      });
    });

    test('null → 非 null 也要判为不同（如 note 从有到无）', () {
      expect(makeCourse(note: '课堂1').sameShallowAs(makeCourse(note: null)),
          isFalse);
      expect(makeCourse(note: null).sameShallowAs(makeCourse(note: null)),
          isTrue);
    });

    test('settings 不参与比较', () {
      // 为什么要显式钉：轮询回来的 Course 永远没有 settings（它由 withSettings
      // 在本地单独挂上去）。若把 settings 纳入比较，每次轮询都会判定为「变了」，
      // 于是又退回「每 3 秒重建一次」。
      final withSettings = makeCourse(
        settings: CourseSettings(imageObjectIds: const ['obj-1']),
      );
      expect(withSettings.sameShallowAs(makeCourse()), isTrue);
    });

    test('同一个实例自身比较 → true', () {
      final a = makeCourse();
      expect(a.sameShallowAs(a), isTrue);
    });
  });
}
