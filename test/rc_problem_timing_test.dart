import 'package:course_helper/utils/rc_problem_timing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Inject elapsed time to cover clock skew and deadline crossing without sleeps.
  var elapsed = 0;
  ProblemPublication live({int limit = 60, int? start = 100000}) =>
      ProblemPublication(
        problemId: 'p1',
        presentationId: 'ppt',
        receivedAtMs: 40000,
        publishedAtMs: start,
        limitSeconds: limit,
        live: true,
        elapsedMilliseconds: () => elapsed,
      );
  setUp(() => elapsed = 0);

  test('手机慢一分钟时，以发题时间加实际经过时间提交，避免 -59 秒', () {
    final publication = live();
    elapsed = 1000;
    expect(41000 - 100000, -59000); // Old phone/server mixed clock result.
    expect(publication.submissionTimeMs(), 101000);
    expect(publication.remainingSeconds(), 59);
  });

  test('校准服务器时间优先，秒级 Date 舍入不产生负用时', () {
    final publication = live();
    expect(publication.submissionTimeMs(serverNowMs: 99900), 100000);
    expect(publication.submissionTimeMs(serverNowMs: 102000), 102000);
  });

  test('延迟跨过截止时间后才判补交，提交时间不回填发题时间', () {
    final publication = live(limit: 1);
    elapsed = 999;
    expect(publication.isExpired(), isFalse);
    elapsed = 1000;
    expect(publication.isExpired(), isTrue);
    elapsed = 1500;
    expect(publication.submissionTimeMs(), 101500);
  });

  test('不限时题不继承前题的超时状态', () {
    final expired = live(limit: 1);
    elapsed = 2000;
    expect(expired.isExpired(), isTrue);
    expect(live(limit: 0).remainingSeconds(), isNull);
    expect(live(limit: 0).isExpired(), isFalse);
  });

  test('历史发题保留原截止时间，重连不重新获得完整倒计时', () {
    final publication = ProblemPublication(
      problemId: 'p1',
      presentationId: 'ppt',
      receivedAtMs: 150000,
      publishedAtMs: 100000,
      limitSeconds: 60,
      live: false,
      elapsedMilliseconds: () => elapsed,
    );
    expect(publication.remainingSeconds(), 10);
    elapsed = 12000;
    expect(publication.isExpired(), isTrue);
    expect(publication.submissionTimeMs(), 162000);
  });
  test('服务器 Date 校准容忍缺损头，并正确处理缓存 Age', () {
    expect(ServerTimeAnchor.fromHttpDate('invalid'), isNull);
    expect(
      ServerTimeAnchor.fromHttpDate(
        'Fri, 13 Nov 2026 12:00:00 GMT',
        ageSeconds: -1,
      ),
      isNull,
    );
    final anchor = ServerTimeAnchor.fromHttpDate(
      'Fri, 13 Nov 2026 12:00:00 GMT',
      ageSeconds: 10,
    )!;
    expect(
      anchor.timestampMs,
      DateTime.utc(2026, 11, 13, 12, 0, 10).millisecondsSinceEpoch,
    );
  });
}
