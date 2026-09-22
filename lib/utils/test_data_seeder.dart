// ============================================================================
// 开发期压测假数据（仅用于性能测量，不进正式包行为）
// ============================================================================
//
// 为什么需要：底栏玻璃要采样「身后的页面内容」，只有内容**持续移动**时才能
// 观察 backdrop 采样是否跟得上。而本项目两个 Tab 页平时都没什么可滚的：
//   - 课程页：没登录/没课时是空态「暂无正在上课的课程」
//   - 账号页：真实账号通常只有几个，列表撑不满一屏
// 于是需要一个能造出长列表的开关。
//
// 用法（不传这个 define 时，下面所有分支都是编译期常量 false，会被 tree-shake，
// 正式包的行为与体积完全不受影响）：
//   flutter build apk --release --dart-define=SEED_TEST_DATA=40
//   → 账号页 / 课程页各注入 40 条假数据
//
// ⚠️ 假数据**只在内存里**：
//   - 账号：只追加到 `accounts.dart` 的本地 `_accounts`，**不写 SharedPreferences**，
//     所以不会污染用户真实的账号列表；
//   - 课程：只在 `_loadCourses()` 里替代网络请求的返回值。
// ============================================================================

import '../models/course.dart';
import '../models/user.dart';

class TestDataSeeder {
  TestDataSeeder._();

  /// 注入条数。`--dart-define=SEED_TEST_DATA=40`；不传则为 0（= 关闭）。
  static const int count = int.fromEnvironment('SEED_TEST_DATA');

  /// 是否开启。编译期常量，未开启时调用点会被 tree-shake。
  static const bool enabled = count > 0;

  /// 造 [n] 条假账号。
  ///
  /// 头像**复用真实账号的头像地址**（轮流取）：这些地址在 `AvatarCache` 里
  /// 已经有缓存好的请求结果，所以列表滚动时不会产生任何网络请求 ——
  /// 否则假地址会一直走失败路径，测出来的就不是渲染性能了。
  static List<User> buildFakeAccounts(int n, List<User> realAccounts) {
    if (n <= 0) return const [];
    // 没有任何真实账号时用空账号兜底，保证列表项结构完整
    final avatarPool = realAccounts.isEmpty
        ? const <String>['']
        : realAccounts.map((u) => u.avatar).toList();
    final platform = realAccounts.isEmpty
        ? 'chaoxing'
        : realAccounts.first.platform;

    return List<User>.generate(n, (i) {
      final seq = (i + 1).toString().padLeft(2, '0');
      return User(
        name: '压测账号 $seq',
        avatar: avatarPool[i % avatarPool.length],
        phone: '+8613800000${(i + 1).toString().padLeft(3, '0')}',
        uid: 'seed_account_$i',
        school: '压测大学',
        platform: platform,
        status: i % 4 != 0,
      );
    });
  }

  /// 造 [n] 条假课程。
  ///
  /// `image` 留空：课程卡片对空图有兜底，且避免假地址触发网络重试。
  static List<Course> buildFakeCourses(int n) {
    if (n <= 0) return const [];
    return List<Course>.generate(n, (i) {
      final seq = (i + 1).toString().padLeft(2, '0');
      return Course(
        courseId: 'seed_course_$i',
        classId: 'seed_class_$i',
        image: '',
        name: '压测课程 $seq',
        teacher: '压测教师 $seq',
        note: '压测班级 $seq',
        schools: '压测大学',
        state: i.isEven,
      );
    });
  }
}
