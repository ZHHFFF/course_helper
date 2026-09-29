import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/api/course.dart';
import 'package:course_helper/models/user.dart';

User _user(String uid) => User(
  name: uid,
  avatar: '',
  phone: '',
  uid: uid,
  school: '',
  platform: 'rainClassroom',
);

void main() {
  setUp(RCCourseApi.debugClearTokens);
  tearDown(RCCourseApi.debugClearTokens);

  test('A → B：旧 token 不满足 B，B 的新 record 整体替换 A', () {
    final user = _user('u1');
    final api = RCCourseApi(user);
    api.debugStoreTokensForLesson('A', 'bearer-A', 'lesson-A');

    expect(RCCourseApi.accountsNeedingCheckIn([user], 'B'), [user]);
    expect(api.lessonTokenFor('B'), isNull);

    api.debugStoreTokensForLesson('B', 'bearer-B', 'lesson-B');
    expect(api.hasTokensForLesson('B'), isTrue);
    expect(api.hasTokensForLesson('A'), isFalse);
    expect(api.bearerToken, 'bearer-B');
    expect(api.lessonTokenFor('B'), 'lesson-B');
    expect(api.lessonTokenFor('A'), isNull);
  });

  test('A → A：同一账号同一课时可复用', () {
    final user = _user('u1');
    RCCourseApi(user).debugStoreTokensForLesson('A', 'bearer-A', 'lesson-A');

    expect(RCCourseApi.accountsNeedingCheckIn([user], 'A'), isEmpty);
    expect(RCCourseApi(user).lessonTokenFor('A'), 'lesson-A');
  });

  test('多账号按 uid 和 lesson 独立判断', () {
    final user1 = _user('u1');
    final user2 = _user('u2');
    final user3 = _user('u3');
    RCCourseApi(user1).debugStoreTokensForLesson('A', 'bearer-1', 'lesson-1');
    RCCourseApi(user2).debugStoreTokensForLesson('B', 'bearer-2', 'lesson-2');

    expect(RCCourseApi.accountsNeedingCheckIn([user1, user2, user3], 'B'), [
      user1,
      user3,
    ]);
    expect(RCCourseApi(user2).lessonTokenFor('B'), 'lesson-2');
    expect(RCCourseApi(user1).lessonTokenFor('B'), isNull);
    expect(RCCourseApi(user3).lessonTokenFor('B'), isNull);
  });

  test('只有部分 token 时不能跳过 checkIn', () {
    final user = _user('u1');
    RCCourseApi(user).debugStoreTokensForLesson('A', 'bearer-A', '');
    expect(RCCourseApi.accountsNeedingCheckIn([user], 'A'), [user]);
  });
}
