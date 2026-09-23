// 钉住「重连补查」的判定 —— 防「后台断线漏掉发题、这道题永远不提交」回归，
// 同时防「误把历史题/别的页的题补交上去」。
//
// 场景：`unlockproblem` 是推送。连接在老师发题那一刻断着 → 事件永久丢失 →
// 重连也补不回 → 这道题再也不会自动提交。
// 解法：重连后服务端回的 timeline 里把最新那道题捞出来补交。
//
// 三道闸门（宁可漏补，也不能交错）：
//   1. 只看最新一条 problem 事件
//   2. dt 必须在窗口内
//   3. si 必须等于老师当前所在页
import 'package:flutter_test/flutter_test.dart';

import 'package:course_helper/utils/problem_publish.dart';

/// 造一条 timeline 的 problem 事件
Map<String, dynamic> problemEvent({
  required String prob,
  required int si,
  required DateTime at,
}) =>
    {
      'type': 'problem',
      'prob': prob,
      'si': si,
      'dt': at.millisecondsSinceEpoch,
    };

void main() {
  final now = DateTime(2026, 9, 23, 14, 0, 0);

  group('pickResyncProblemId', () {
    test('断线期间漏掉的题：时间近 + 老师就在这一页 → 补交', () {
      final d = pickResyncProblemId(
        timeline: [
          {'type': 'slide', 'pres': 'p1', 'si': 1},
          problemEvent(prob: 'q1', si: 5, at: now.subtract(const Duration(seconds: 20))),
        ],
        now: now,
        currentLessonSlideIndex: 4, // 0-based → 对应 si=5
        alreadySubmitted: {},
      );
      expect(d.problemId, 'q1');
    });

    test('取最新那条，不看旧的', () {
      final d = pickResyncProblemId(
        timeline: [
          problemEvent(prob: 'old', si: 5, at: now.subtract(const Duration(seconds: 90))),
          problemEvent(prob: 'new', si: 5, at: now.subtract(const Duration(seconds: 10))),
        ],
        now: now,
        currentLessonSlideIndex: 4,
        alreadySubmitted: {},
      );
      expect(d.problemId, 'new');
    });

    group('闸门 2：时间', () {
      test('超出窗口的历史题不补', () {
        final d = pickResyncProblemId(
          timeline: [
            problemEvent(prob: 'q1', si: 5, at: now.subtract(const Duration(minutes: 30))),
          ],
          now: now,
          currentLessonSlideIndex: 4,
          alreadySubmitted: {},
        );
        expect(d.problemId, isNull);
        expect(d.reason, contains('超出补交窗口'));
      });

      test('正好在窗口边界内 → 补', () {
        final d = pickResyncProblemId(
          timeline: [
            problemEvent(prob: 'q1', si: 5, at: now.subtract(const Duration(minutes: 2, seconds: 59))),
          ],
          now: now,
          currentLessonSlideIndex: 4,
          alreadySubmitted: {},
        );
        expect(d.problemId, 'q1');
      });

      test('dt 在未来（时钟偏差）也不补，避免误判', () {
        final d = pickResyncProblemId(
          timeline: [
            problemEvent(prob: 'q1', si: 5, at: now.add(const Duration(minutes: 10))),
          ],
          now: now,
          currentLessonSlideIndex: 4,
          alreadySubmitted: {},
        );
        expect(d.problemId, isNull);
      });

      test('没有 dt 时不卡这条闸门（只靠位置闸门兜）', () {
        final d = pickResyncProblemId(
          timeline: [
            {'type': 'problem', 'prob': 'q1', 'si': 5},
          ],
          now: now,
          currentLessonSlideIndex: 4,
          alreadySubmitted: {},
        );
        expect(d.problemId, 'q1');
      });
    });

    group('闸门 3：位置', () {
      test('最新题不在老师当前页 → 不补', () {
        final d = pickResyncProblemId(
          timeline: [
            problemEvent(prob: 'q1', si: 9, at: now.subtract(const Duration(seconds: 10))),
          ],
          now: now,
          currentLessonSlideIndex: 4, // 老师在第 5 页
          alreadySubmitted: {},
        );
        expect(d.problemId, isNull);
        expect(d.reason, contains('不是当前题'));
      });

      test('拿不到老师当前页时，不卡这条闸门', () {
        final d = pickResyncProblemId(
          timeline: [
            problemEvent(prob: 'q1', si: 9, at: now.subtract(const Duration(seconds: 10))),
          ],
          now: now,
          currentLessonSlideIndex: null,
          alreadySubmitted: {},
        );
        expect(d.problemId, 'q1');
      });
    });

    group('去重与空数据', () {
      test('已提交过的不重复补', () {
        final d = pickResyncProblemId(
          timeline: [
            problemEvent(prob: 'q1', si: 5, at: now.subtract(const Duration(seconds: 10))),
          ],
          now: now,
          currentLessonSlideIndex: 4,
          alreadySubmitted: {'q1'},
        );
        expect(d.problemId, isNull);
        expect(d.reason, contains('已经提交过'));
      });

      test('timeline 里没有 problem 事件 → null', () {
        final d = pickResyncProblemId(
          timeline: [
            {'type': 'slide', 'pres': 'p1', 'si': 1},
          ],
          now: now,
          currentLessonSlideIndex: 0,
          alreadySubmitted: {},
        );
        expect(d.problemId, isNull);
      });

      test('空 timeline → null', () {
        final d = pickResyncProblemId(
          timeline: const [],
          now: now,
          currentLessonSlideIndex: 0,
          alreadySubmitted: {},
        );
        expect(d.problemId, isNull);
      });

      test('prob 为空 → null', () {
        final d = pickResyncProblemId(
          timeline: [
            {'type': 'problem', 'prob': '', 'si': 5, 'dt': now.millisecondsSinceEpoch},
          ],
          now: now,
          currentLessonSlideIndex: 4,
          alreadySubmitted: {},
        );
        expect(d.problemId, isNull);
      });

      test('prob 是数字也能取到（服务器有时给 int）', () {
        final d = pickResyncProblemId(
          timeline: [
            {'type': 'problem', 'prob': 12345, 'si': 5, 'dt': now.millisecondsSinceEpoch},
          ],
          now: now,
          currentLessonSlideIndex: 4,
          alreadySubmitted: {},
        );
        expect(d.problemId, '12345');
      });
    });
  });
}
