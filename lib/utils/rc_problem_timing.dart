import 'dart:io' show HttpDate, HttpException;

/// A server time observation advanced with a monotonic clock, so changing the
/// phone clock cannot change an in-flight classroom submission timestamp.
class ServerTimeAnchor {
  ServerTimeAnchor(this.timestampMs) : _elapsed = Stopwatch()..start();

  /// Date is rounded to seconds; cache Age must be added for cached responses.
  static ServerTimeAnchor? fromHttpDate(String date, {int ageSeconds = 0}) {
    if (ageSeconds < 0) return null;
    try {
      return ServerTimeAnchor(
        HttpDate.parse(date).millisecondsSinceEpoch + ageSeconds * 1000,
      );
    } on HttpException {
      return null;
    }
  }

  final int timestampMs;
  final Stopwatch _elapsed;
  int get nowMs => timestampMs + _elapsed.elapsedMilliseconds;
}

/// Publication evidence belongs to one problem in one presentation. The PPT's
/// embedded `dt` and the currently visible page are never publication evidence.
class ProblemPublication {
  ProblemPublication({
    required this.problemId,
    required this.presentationId,
    required int receivedAtMs,
    required bool live,
    this.slideIndex,
    this.publishedAtMs,
    this.limitSeconds,
    int Function()? elapsedMilliseconds,
  }) : _receivedAtMs = receivedAtMs,
       _live = live {
    final watch = Stopwatch()..start();
    _elapsedMilliseconds =
        elapsedMilliseconds ?? () => watch.elapsedMilliseconds;
  }

  final String problemId;
  final String presentationId;
  final int? slideIndex;
  final int? publishedAtMs;
  int? limitSeconds;
  final int _receivedAtMs;
  final bool _live;
  late final int Function() _elapsedMilliseconds;

  /// Prefer calibrated server time. Without it a live publication's own server
  /// timestamp plus elapsed time avoids mixing phone and server wall clocks.
  /// Timeline recovery uses receipt time, bounded by the publication timestamp.
  int submissionTimeMs({int? serverNowMs}) {
    final fallback = (_live ? publishedAtMs : null) ?? _receivedAtMs;
    final now = serverNowMs ?? fallback + _elapsedMilliseconds();
    final start = publishedAtMs;
    return start != null && now < start ? start : now;
  }

  /// Missing/zero limits mean no deadline. Missing start time uses receipt time
  /// for elapsed timing only; it is never filled from a different PPT problem.
  int? remainingSeconds({int? serverNowMs}) {
    final limit = limitSeconds;
    if (limit == null || limit <= 0) return null;
    final start = publishedAtMs ?? _receivedAtMs;
    final remaining =
        start + limit * 1000 - submissionTimeMs(serverNowMs: serverNowMs);
    return remaining <= 0 ? 0 : (remaining + 999) ~/ 1000;
  }

  bool isExpired({int? serverNowMs}) =>
      remainingSeconds(serverNowMs: serverNowMs) == 0;
}
