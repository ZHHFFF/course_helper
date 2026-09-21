import 'package:course_helper/utils/problem_publish.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 造一个「第 5 页的题已发布」的场景
  /// 发题消息给的是 prob='prob-abc'，PPT 里那页的 problemId='pid-xyz'
  /// —— 故意让两者不同，模拟两套 ID 命名空间
  Map<int, String> publishedSlideOf() => {4: 'prob-abc'};

  group('判据 1：页号映射（最可靠，不依赖 ID 比对）', () {
    test('prob 和 problemId 不同值时，靠页号映射仍能判断出来', () {
      // 这是核心回归：原来的代码拿 prob 去 contains problemId，
      // 两个值不一样就永远判不出来，提交按钮永远不出现
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 4, // 第 5 页
          publishedSlideOf: publishedSlideOf(),
          currentProblemId: 'pid-xyz', // ← 和 prob 不同
          publishedProbs: {'prob-abc'},
          timelineProblemId: null,
        ),
        isTrue,
      );
    });

    test('页号对不上 → 不判为已发布', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 3, // 第 4 页，不是发布的那页
          publishedSlideOf: publishedSlideOf(),
          currentProblemId: 'pid-xyz',
          publishedProbs: {'prob-abc'},
          timelineProblemId: null,
        ),
        isFalse,
      );
    });
  });

  group('判据 2：当前页 problemId 在已发布集合里', () {
    test('prob == problemId 时命中', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 0,
          publishedSlideOf: const {}, // 还没解析出页号
          currentProblemId: 'same-id',
          publishedProbs: {'same-id'},
          timelineProblemId: null,
        ),
        isTrue,
      );
    });

    test('不在集合里 → false', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 0,
          publishedSlideOf: const {},
          currentProblemId: 'other-id',
          publishedProbs: {'same-id'},
          timelineProblemId: null,
        ),
        isFalse,
      );
    });
  });

  group('判据 3：时间轴点开的那道题', () {
    test('timelineProblemId 命中', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 0,
          publishedSlideOf: const {},
          currentProblemId: null, // 当前页没题
          publishedProbs: {'tl-id'},
          timelineProblemId: 'tl-id',
        ),
        isTrue,
      );
    });

    test('timelineProblemId 不在集合里 → false', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 0,
          publishedSlideOf: const {},
          currentProblemId: null,
          publishedProbs: {'other'},
          timelineProblemId: 'tl-id',
        ),
        isFalse,
      );
    });
  });

  group('边界：不该误判', () {
    test('全空 → false', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 0,
          publishedSlideOf: const {},
          currentProblemId: null,
          publishedProbs: const {},
          timelineProblemId: null,
        ),
        isFalse,
      );
    });

    test('空字符串的 problemId 不会误命中（集合里也有空串时）', () {
      // 防止「两个都空 → contains 返回 true」这种荒谬情况
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 0,
          publishedSlideOf: const {},
          currentProblemId: '',
          publishedProbs: {''},
          timelineProblemId: null,
        ),
        isFalse,
      );
    });

    test('空字符串的 timelineProblemId 不会误命中', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 0,
          publishedSlideOf: const {},
          currentProblemId: null,
          publishedProbs: {''},
          timelineProblemId: '',
        ),
        isFalse,
      );
    });

    test('页号映射里有别的页，不会连带当前页', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 9,
          publishedSlideOf: {0: 'p0', 1: 'p1', 2: 'p2'},
          currentProblemId: null,
          publishedProbs: {'p0', 'p1', 'p2'},
          timelineProblemId: null,
        ),
        isFalse,
      );
    });
  });

  group('组合：多道题发布过，只认当前页', () {
    final published = {2: 'prob-A', 5: 'prob-B'};
    final probs = {'prob-A', 'prob-B'};

    test('第 3 页 → 已发布', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 2,
          publishedSlideOf: published,
          currentProblemId: 'pid-a',
          publishedProbs: probs,
          timelineProblemId: null,
        ),
        isTrue,
      );
    });

    test('第 6 页 → 已发布', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 5,
          publishedSlideOf: published,
          currentProblemId: 'pid-b',
          publishedProbs: probs,
          timelineProblemId: null,
        ),
        isTrue,
      );
    });

    test('第 4 页（中间那页，没发布） → 未发布', () {
      expect(
        isCurrentProblemPublished(
          currentSlideIndex: 3,
          publishedSlideOf: published,
          currentProblemId: 'pid-none',
          publishedProbs: probs,
          timelineProblemId: null,
        ),
        isFalse,
      );
    });
  });
}
