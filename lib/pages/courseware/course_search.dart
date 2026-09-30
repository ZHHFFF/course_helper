/// Filter courses without changing their original order or the source list.
List<T> filterCourses<T>(
  List<T> courses,
  String query, {
  required String Function(T) nameOf,
  required String Function(T) teacherOf,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return courses.toList();
  return courses
      .where(
        (course) =>
            nameOf(course).toLowerCase().contains(needle) ||
            teacherOf(course).toLowerCase().contains(needle),
      )
      .toList();
}
