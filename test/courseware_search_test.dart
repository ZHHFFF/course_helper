import 'package:course_helper/pages/courseware/course_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final courses = [
    (name: '医用物理学', teacher: '刘友明'),
    (name: '病理生理学A[理论学时]', teacher: '郭军堂'),
    (name: 'English Biology', teacher: 'Smith'),
    (name: '物理实验', teacher: '陈老师'),
  ];

  List<({String name, String teacher})> search(String query) => filterCourses(
    courses,
    query,
    nameOf: (course) => course.name,
    teacherOf: (course) => course.teacher,
  );

  test('空搜索词返回全部课程', () {
    expect(search(''), courses);
  });
  test('搜索课程名和中文部分匹配', () {
    expect(search('病理'), [courses[1]]);
    expect(search('物理'), [courses[0], courses[3]]);
  });
  test('搜索教师姓名', () {
    expect(search('刘友明'), [courses[0]]);
  });
  test('英文大小写不敏感', () {
    expect(search('bIoLoGy'), [courses[2]]);
    expect(search('sMiTh'), [courses[2]]);
  });
  test('忽略搜索词前后空格', () {
    expect(search('  病理  '), [courses[1]]);
  });
  test('搜索不到结果', () {
    expect(search('不存在'), isEmpty);
  });
  test('结果保持原顺序，清空后恢复全部，且不改变原列表', () {
    final original = courses.toList();
    final filtered = search('物理');
    expect(filtered, [courses[0], courses[3]]);
    expect(courses, original);
    expect(search(''), original);
    expect(identical(filtered, courses), isFalse);
  });
}
