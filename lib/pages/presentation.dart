import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket, File;

import '../api/course.dart';
import '../api/image.dart';
import '../api/api_service.dart';
import '../models/presentation.dart';
import '../session/account.dart';
import '../platform.dart';
// [新增] 答案检索模块导入
import '../api/answer_search.dart';
import '../models/answer_result.dart';
// [新增] PPT 缓存 + 后台识题
import '../cache/answer_cache.dart';
import '../cache/answer_queue.dart';
import '../cache/cached_image.dart';
import '../cache/course_cache.dart';
import '../cache/ppt_cache.dart';
import '../cache/question_hash.dart';
import '../cache/slide_scanner.dart';
import '../setting/auto_answer_setting.dart';
// [/新增]
import '../utils/answer_filling.dart';
import '../utils/app_logger.dart';
import '../utils/keep_alive_service.dart';
import '../utils/network_error.dart';
import '../utils/problem_publish.dart';
import '../utils/ppt_exporter.dart';
import 'widget/answer_search_dialog.dart';
import 'widget/suggested_answer_card.dart';
// [/新增]

// 前台服务的启动/停止/权限申请/跨 isolate 上报，全部搬到了
// `lib/utils/keep_alive_service.dart`。
// 搬家的原因：原来这套逻辑是本文件的私有方法，只有进课堂才会跑，
// 于是「不进课堂就测不了」—— 而没有正在上课的课程时根本进不去。
// 抽出去之后「前台服务自检」页也能调，随时能验。

class PresentationPage extends StatefulWidget {
  final String lessonId;
  final String title;

  /// 课程 ID（雨课堂的 `course_id`）。
  ///
  /// 为什么要传：缓存目录是按 **lessonId** 分的，而课件页要按 **课程** 聚合，
  /// 两者的对应关系必须落盘才留得住 —— 见 `CourseCache.writeMeta`。
  /// 老调用点没传时是空串，不会写坏已有的 meta。
  final String courseId;

  const PresentationPage({
    super.key,
    required this.lessonId,
    required this.title,
    this.courseId = '',
  });

  @override
  State<PresentationPage> createState() => _PresentationPageState();
}

class _PresentationPageState extends State<PresentationPage>
    with WidgetsBindingObserver {
  WebSocket? _ws;
  final ScrollController _scrollController = ScrollController();
  final PageController _pageController = PageController();

  int _currentSlideIndex = 0;
  int _currentLessonSlideIndex = 0;
  int _totalCount = 0;
  List<Map<String, dynamic>> _slides = [];
  String? _currentPresentationId;
  final List<String> _unlockedProblemIds = [];

  bool _isLoading = false;
  bool _isInitialized = false;
  final List<TimelineEvent> _timeline = [];

  Problem? _currentProblem;
  String? _timelineProblemId;
  List<String>? _answer;
  String? _textAnswer;
  bool _isProblemExpanded = true;

  final List<XFile> _selectedImages = [];
  static const int _maxImageCount = 9;
  final List<String> _uploadedImageUrls = [];

  int? _countdownSeconds;
  Timer? _countdownTimer;

  Offset _menuPosition = Offset.zero;
  bool _isFullScreen = false;

  /// [新增] 正在导出 PDF（防止重复点击）
  bool _isExporting = false;

  // [新增] PPT 缓存 + 后台识题
  /// 整份 PPT 的识题结果（拿到 PPT 的那一刻就扫完了）
  SlideScanResult _scan = const SlideScanResult.empty();

  /// 幻灯片模型（扫描、图片预取用；`_slides` 是给 UI 用的 Map 版）
  List<PresentationSlide> _slideModels = const [];

  /// 指纹 → 建议答案（缓存命中 或 本次检索拿到的）
  final Map<String, CachedAnswer> _suggested = {};

  /// 正在排队 / 请求中的指纹
  final Set<String> _searching = {};

  /// 当前页对应的题目指纹（当前页没题时为 null）
  String? _currentHash;

  // ============ [新增] 自动答题 ============

  /// 已经自动提交过的指纹（防重复提交）
  final Set<String> _autoSubmitted = {};

  /// 待自动提交的题目队列（串行处理，避免连发两题时丢掉后一道）
  final List<String> _autoSubmitQueue = [];

  // ============ 已发布题目的「单一事实来源」 ============
  //
  // 背景：发题消息（unlockproblem）给的是 `prob`，而 PPT 里题目的字段叫
  // `problemId` —— **两套 ID 命名空间**。原来的代码拿一边的值去
  // `contains` 另一边的集合（比如「提交」按钮的条件），
  // 万一两个值不一样，按钮就永远不出现、自动提交也找不到题目。
  //
  // 修法：在**边界处归一化一次** —— 收到发题消息就把 `prob` 解析成
  // 「PPT 里的页号」，记在这里。之后所有判断都读这个映射，
  // 不再到处做 ID 字符串比对。

  /// 已发布的题目：PPT 页号（0-based） → 服务器给的 prob
  final Map<int, String> _publishedSlideOf = {};

  /// 老师发题后，最多等多久让 AI 把答案搜出来
  ///
  /// AI 一道题要 3~6 秒，老师发题那一刻答案通常还没回来。
  /// 超过这个时间还拿不到就放弃（总比交白卷强）。
  static const Duration answerWait = Duration(seconds: 25);

  /// 当前作答区（[_answer] / [_textAnswer]）属于哪道题
  String? _answerOwnerProblemId;

  /// 每道题各自的作答 —— 切页时按题存取，而不是一清了之
  ///
  /// `_answer` / `_textAnswer` 是单份字段，切题时必须换掉，
  /// 否则 A 题选完翻到 B 题，B 题会显示 A 的答案（自动提交就会交串）。
  /// 但**直接清空**又会把用户填好的答案弄丢 ——
  /// 「填完翻页看一眼再翻回来，答案没了」。
  /// 所以按 problemId 存一份，切回去能原样恢复。
  final Map<String, List<String>> _answersByProblem = {};
  final Map<String, String> _textAnswersByProblem = {};

  /// 切题：先存下旧题的作答，再恢复新题的
  void _syncAnswerOwner() {
    final newId = _currentProblem?.problemId;
    if (newId == _answerOwnerProblemId) return;

    // 1. 把旧题的作答存起来
    final oldId = _answerOwnerProblemId;
    if (oldId != null) {
      final a = _answer;
      if (a != null && a.any((k) => k.trim().isNotEmpty)) {
        _answersByProblem[oldId] = List<String>.of(a);
      }
      final t = _textAnswer;
      if (t != null && t.trim().isNotEmpty) {
        _textAnswersByProblem[oldId] = t;
      }
    }

    // 2. 换成新题的作答（没有就清空）
    _answerOwnerProblemId = newId;
    _answer = newId == null ? null : _answersByProblem[newId]?.toList();
    _textAnswer = newId == null ? null : _textAnswersByProblem[newId];
    if (newId == null) {
      _uploadedImageUrls.clear();
    }
  }

  StreamSubscription<AnswerJobResult>? _answerSub;
  // [/新增]

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _answerSub = AnswerQueue.results.listen(_onAnswerReady);
    _initialize();
    _startForegroundService();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 图片预取只在 App 前台时跑：后台下载既费电又容易被系统掐断
    SlideImagePrefetcher.paused = state != AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _answerSub?.cancel();

    // 已经在飞的 AI 请求不打断（让它跑完顺手把答案存下来），
    // 但排队里还没开跑的全部作废
    AnswerQueue.cancelPending();

    // [改] 退出课堂**不再丢弃**预取队列。
    //
    // 原来这里是 SlideImagePrefetcher.cancel()，会把没下完的页全扔掉，
    // 下次进来重新下 —— 这正是「第二次进入已缓存 0」的成因之一。
    // 现在只把它挂起（省电/省流量交给 paused 控制），队列和进度都留着，
    // 下次进同一份 PPT 时 start() 会用磁盘命中把已下好的页跳过。
    //
    // 注意：图片本身是靠磁盘文件判断「有没有缓存」，不依赖这个内存队列，
    // 所以即使进程被杀，下次进来照样命中。
    PptCache.clearMemory();
    AnswerCache.clearMemory();

    // 离开课堂 = 这节课对本人结束了。缓存再留 24 小时，
    // 防止「下课后还想回去翻两眼」时页面空白
    if (_currentPresentationId != null) {
      unawaited(CourseCache.markFinished(widget.lessonId));
    }

    if (_ws != null) {
      final leaveData = {
        "op": "leavelesson",
        "lessonid": widget.lessonId
      };
      _ws?.add(jsonEncode(leaveData));
    }

    _countdownTimer?.cancel();
    _ws?.close();
    _pageController.dispose();
    _scrollController.dispose();
    _stopForegroundService();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _checkToken();

    // ⚠️ 这里**曾经**每次进课堂都跑一遍 `CourseCache.cleanup()`
    // （结束标记超 24h 删 / 7 天无写入删）。2026-09-22 用户拍板
    // 「取消自动删除 ppt」—— 缓存改成**只由用户在课件页手动删**，
    // 所以这行已删除。`CourseCache.cleanup()` 本身保留（设置页里还有
    // 手动触发的入口），只是不再自动跑。

    // 把本节课已有的答案缓存读进内存，切页时展示是同步的、不闪
    await AnswerCache.preload(widget.lessonId);
    AnswerQueue.resetCounters();

    _connectWebSocket();
  }

  /// 后台队列检索完一题
  void _onAnswerReady(AnswerJobResult result) {
    if (!mounted) return;
    setState(() {
      _suggested[result.hash] = result.answer;
      _searching.remove(result.hash);
    });
    // [新增] 答案到手 → 如果正是当前页的题，自动填进作答区（只填不交）
    unawaited(_autoSelectIfCurrent(result.hash));
  }

  // ==================== [新增] 自动预选 ====================

  /// 答案到手后，如果这题正是当前页，自动填进作答区
  ///
  /// 只填不提交。提交由 [_maybeAutoSubmit] 在老师发布题目后触发。
  /// 已经填过的指纹不会重复填，避免覆盖用户的手动修改。
  Future<void> _autoSelectIfCurrent(String hash) async {
    await AutoAnswerSetting.ensureLoaded();
    if (!AutoAnswerSetting.autoSelect.value) return;
    if (!mounted) return;
    if (_currentHash != hash) return; // 不是当前页的题，不抢填

    // 判据是「作答区有没有内容」，不是「有没有自动填过」。
    //
    // 因为切题时 `_syncAnswerOwner()` 会把 `_answer` 换成新题的值
    // （旧题的存进 `_answersByProblem`，切回来能恢复）：
    // 如果用「填过就不再填」的标记，A→B→A 切回来时 A 会被误判成
    // 已经处理过而不重新填。而「有内容就不动」同时兼顾了
    // 「不覆盖用户手动修改」。
    if (_isAnswerFilled()) return;

    final cached = _suggested[hash];
    if (cached == null || !cached.usable || cached.results.isEmpty) return;

    final scanned = _scan.byHash[hash];
    if (scanned == null) return;

    _fillAnswerSilently(scanned.question, cached.results.first);
  }

  /// 静默填充（不弹 SnackBar，避免自动答题时刷屏）
  ///
  /// 注意三种题型读的字段不一样，必须和 `_buildAnswerOptions()` 的分支对齐：
  /// - problemType 1/2/3/6（单选/多选/投票/判断）→ `_answer`（选项 key 列表）
  /// - problemType 4（填空）→ 题干里有 `[填空N]` 标记时读 `_answer`
  ///   （每空一项），没有标记时 UI 退化成单个输入框、读 `_textAnswer`
  /// - problemType 5（简答）→ `_textAnswer`
  ///
  /// 之前一律按「选择题 / 非选择题」二分，填空题会被写成 `_textAnswer`，
  /// 而 UI 读的是 `_answer` → 填了等于没填。
  ///
  /// 返回是否真的填进去了（调用方可以据此决定要不要提示用户）。
  bool _fillAnswerSilently(
    StandardizedQuestion question,
    AnswerSearchResult picked, {
    String logTag = '自动答题',
  }) {
    final problem = _currentProblem;
    if (problem == null || !mounted) return false;

    final raw = picked.answer.trim();

    // 该写哪个字段由题型决定 —— 这段判断逻辑抽到了 AnswerFilling，
    // 那边有单测覆盖（写错字段的表现是「填了等于没填」，UI 上看不出来）
    switch (AnswerFilling.fieldFor(problem.problemType, problem.body)) {
      // ---- 填空题（多个空）：每空一项写进 _answer ----
      case AnswerField.fillBlanks:
        final count = AnswerFilling.blankCount(problem.body);
        final list = AnswerFilling.splitBlanks(raw, count);
        if (list.isEmpty) return false;
        setState(() => _answer = list);
        AppLogger.i(logTag, '已自动预选（填空 $count 空）：${list.join(" | ")}');
        return true;

      // ---- 填空题（没标记，UI 是单个输入框）----
      case AnswerField.fillSingle:
        if (raw.isEmpty) return false;
        setState(() => _textAnswer = raw);
        AppLogger.i(logTag, '已自动预选（填空）：$raw');
        return true;

      // ---- 简答题 ----
      case AnswerField.shortAnswer:
        if (raw.isEmpty) return false;
        setState(() => _textAnswer = raw);
        AppLogger.i(logTag, '已自动预选（简答）：$raw');
        return true;

      // ---- 选择题（单选/多选/判断/投票）----
      case AnswerField.choice:
        final options = (problem.options ?? const [])
            .map((o) => StandardizedOption(key: o.key, value: o.value))
            .toList();
        final keys = picked.matchOptionKeys(options);
        if (keys.isEmpty) return false;
        setState(() => _answer = keys);
        AppLogger.i(logTag, '已自动预选：${keys.join("、")}（${picked.source}）');
        return true;
    }
  }

  // ==================== [新增] 自动提交 ====================

  /// 老师发布题目（unlockproblem）后，按设置决定是否自动提交
  ///
  /// 流程：定位题目所在页 → 切过去 → 确保答案已填 → 随机延迟 → 提交
  /// 老师发布题目（unlockproblem）后，按设置决定是否自动提交
  ///
  /// 用队列串行处理：老师连着发两道题时，两个调用会同时进来。
  /// 原来用一个 `_autoSubmitting` 布尔标记挡，结果是后来的那道题
  /// 走到提交那一步发现「有人正在提交」就**直接丢掉**了。
  /// 现在改成排队，前一道处理完接着处理下一道。
  Future<void> _maybeAutoSubmit(String problemId) async {
    try {
      await AutoAnswerSetting.ensureLoaded();
      AppLogger.i(
        '自动答题',
        '收到发题 $problemId｜开关：自动提交=${AutoAnswerSetting.autoSubmit.value} '
            '预选=${AutoAnswerSetting.autoSelect.value}｜PPT ${_slideModels.length} 页',
      );

      // 不管自动提交开没开，都要先把 prob 解析成 PPT 页号并记下来 ——
      // 「提交」按钮的显示依赖这个映射（见 _publishedSlideOf 的说明）。
      // 这是「边界处归一化一次」，比让各处去 contains 比对可靠。
      final index = await _waitForProblemSlide(problemId);
      if (!mounted) return;
      if (index >= 0) {
        setState(() => _publishedSlideOf[index] = problemId);
        AppLogger.i('自动答题', '已记录发布位置：第 ${index + 1} 页 ← $problemId');
      } else {
        AppLogger.w('自动答题',
            '解析不出 $problemId 对应哪一页，「提交」按钮可能不会出现');
      }

      if (!AutoAnswerSetting.autoSubmit.value) {
        AppLogger.i('自动答题', '「自动提交」开关是关的，只记录发布位置');
        return;
      }
      if (_autoSubmitted.contains(problemId)) {
        AppLogger.i('自动答题', '题目 $problemId 已经提交过，跳过');
        return;
      }
      if (_autoSubmitQueue.contains(problemId)) return;

      _autoSubmitQueue.add(problemId);

      // 已经有消费者在跑了 → 它会把这道题也处理掉，这里直接返回
      if (_autoSubmitQueue.length > 1) return;

      while (_autoSubmitQueue.isNotEmpty) {
        if (!mounted) break;
        final id = _autoSubmitQueue.removeAt(0);
        await _doAutoSubmit(id);
      }
    } catch (e, st) {
      AppLogger.e('自动答题', '自动提交调度出错：$e\n$st');
    }
  }

  /// 真正干活的：定位题目 → 切页 → 等答案 → 填 → 延迟 → 提交
  ///
  /// 只由 [_maybeAutoSubmit] 的队列循环调用，保证同一时刻只有一道题在跑。
  Future<void> _doAutoSubmit(String problemId) async {
    if (_autoSubmitted.contains(problemId)) return;

    try {
      // ---- 第 1 步：先定位并切到题目页 ----
      //
      // 这一步必须**排在等答案前面**：切过去之后「提交」按钮会立刻出现，
      // 就算答案还没搜好、用户等不及了，他也能自己点提交，不至于干瞪眼。
      final index = await _waitForProblemSlide(problemId);
      if (index < 0) {
        AppLogger.w('自动答题',
            '题目 $problemId 在这份 PPT 里找不到对应页（PPT 共 ${_slideModels.length} 页）');
        return;
      }
      AppLogger.i('自动答题', '题目 $problemId 在第 ${index + 1} 页');

      if (index != _currentSlideIndex) {
        _toSlide(index + 1, animate: false);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (!mounted) return;

      // 把当前页题目的 problemId 也补进「已解锁」。
      //
      // 为什么要补：发题消息给的是 `prob`，而「提交」按钮的条件是
      // `_unlockedProblemIds.contains(_currentProblem!.problemId)` ——
      // 两者字段名不同，万一值也不一样，就算切到了正确的页按钮也不会出现。
      // 我们已经确认这一页就是老师发的那道题（index 是定位出来的），
      // 所以把它的 problemId 加进去是安全的。
      // 这样用户等不及自动提交时，也能自己点提交。
      final curId = _currentProblem?.problemId;
      if (curId != null &&
          curId.isNotEmpty &&
          !_unlockedProblemIds.contains(curId)) {
        AppLogger.i('自动答题',
            '当前页 problemId=$curId 不在已解锁列表里，补进去（让提交按钮出现）');
        setState(() => _unlockedProblemIds.add(curId));
      }

      final hash = _currentHash;
      if (hash == null) {
        AppLogger.w('自动答题', '第 ${index + 1} 页没识别到题目，放弃自动提交');
        return;
      }

      // 先确认这题确实被扫描器收录了。
      //
      // 没收录 = AI 根本没搜过它（题干为空、或题目整个画成图片被标记成
      // 需要识图）。这种情况下等下去也没用，直接放弃，别白等 25 秒。
      final scanned = _scan.byHash[hash];
      if (scanned == null) {
        AppLogger.w(
          '自动答题',
          '指纹 ${_short(hash)} 不在扫描结果里（题干为空或题目是图片），放弃自动提交',
        );
        return;
      }
      if (scanned.needsVision) {
        AppLogger.w('自动答题', '这题需要识图，AI 文本检索拿不到答案，放弃自动提交');
        return;
      }

      // ---- 第 2 步：等答案就绪 ----
      //
      // AI 检索一道题要 3~6 秒。老师发题那一刻答案大概率还没回来，
      // 原来这里是「没答案就 return」→ 结果什么都不做。
      // 现在改成最多等 [answerWait] 秒。
      var cached = _suggested[hash];
      if (cached == null || !cached.usable) {
        // 等答案的时间**不能超过本题的剩余作答时间** ——
        // 否则等到答案了，题也早就关闭、交不上去了。
        // 留 2 秒余量给「填写 + 提交」这两步。
        final remain = _countdownSeconds;
        final budget = (remain != null && remain > 0)
            ? Duration(
                seconds: (remain - 2).clamp(1, answerWait.inSeconds))
            : answerWait;
        AppLogger.i(
          '自动答题',
          '答案还没搜好，最多等 ${budget.inSeconds}s'
              '（本题剩余 ${remain == null || remain <= 0 ? "不限时" : "${remain}s"}）',
        );
        cached = await _waitForAnswer(hash, timeout: budget);
      }
      if (cached == null || !cached.usable || cached.results.isEmpty) {
        AppLogger.w('自动答题',
            '等到超时仍没拿到可用答案（status=${cached?.status}），放弃自动提交');
        return;
      }
      if (!mounted) return;

      // ---- 第 2.5 步：确认还停在题目所在的页 ----
      //
      // 等答案的这几秒里，老师完全可能翻页（slide / slidenav 会把用户带走）。
      // 这时候往下走，答案会被填到**当前页别的题**上，提交也就交错了题。
      // 所以提交前必须复核一次，不在了就切回去。
      if (_currentSlideIndex != index) {
        AppLogger.w(
          '自动答题',
          '等答案期间页面被翻到第 ${_currentSlideIndex + 1} 页，切回第 ${index + 1} 页',
        );
        _toSlide(index + 1, animate: false);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!mounted) return;
        if (_currentHash != hash) {
          AppLogger.w('自动答题', '切回来之后指纹对不上了，放弃自动提交');
          return;
        }
      }

      // ---- 第 3 步：填答案 ----
      if (!_isAnswerFilled()) {
        _fillAnswerSilently(scanned.question, cached.results.first);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }

      if (!mounted) return;
      if (!_isAnswerFilled()) {
        AppLogger.w('自动答题', '答案没能填进作答区，放弃自动提交');
        return;
      }

      // ---- 第 4 步：拟人化延迟后提交 ----
      final delay = AutoAnswerSetting.randomDelay();
      AppLogger.i('自动答题', '${delay.inMilliseconds}ms 后自动提交题目 $problemId');
      await Future<void>.delayed(delay);
      if (!mounted) return;

      _autoSubmitted.add(problemId);

      // 提交可能因为网络抖动失败 —— 那就**静默丢答案**了。
      //
      // 重试的两条边界：
      // 1. 只重试「网络失败」（请求根本没到服务器）。
      //    服务端明确拒绝（比如题已关闭）不重试 —— 重试没意义，还可能重复提交。
      // 2. 只在**没带图片**时重试。图片提交完就被清掉了，
      //    带图重试会变成空答案，反而更糟。
      //
      // ⚠️ 另外要认清一件事：这里的「网络失败」其实**分不出**
      //   「请求根本没到服务器」和「到了但回包丢了」—— 超时就是这种模糊态。
      //   所以重试本质是 at-least-once，理论上可能重复提交。
      //   同一道题交两次、服务端按最后一次算，影响可控，可以接受。
      final hadImages = _uploadedImageUrls.isNotEmpty;
      var netFails = await _submitAnswer(
          auto: true, problemIdOverride: problemId, silent: true);

      var attempt = 0;
      while (netFails > 0 && attempt < 2 && !hadImages && mounted) {
        attempt++;
        AppLogger.w(
          '自动答题',
          '提交 $problemId 有 $netFails 个账号网络失败，第 $attempt 次重试',
        );
        await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
        if (!mounted) break;
        netFails = await _submitAnswer(
            auto: true, problemIdOverride: problemId, silent: true);
      }

      // 日志必须说实话 —— 现在它是我唯一的验证手段。
      //
      // 原来这里无条件打「已自动提交」，于是：
      //   - 重试 2 次后仍网络失败 → 照样打成功
      //   - 这题带图（按设计不重试）而第一次就失败 → 也照样打成功
      // 结果日志一片祥和、答案其实丢了，照日志根本查不出问题。
      if (netFails > 0) {
        AppLogger.e(
          '自动答题',
          '题目 $problemId 提交失败：仍有 $netFails 个账号网络异常，'
              '${hadImages ? "这题带图，按设计不重试（重试会变成空答案）" : "已重试 $attempt 次"}'
              ' —— 答案没交上去，需要手动补交',
        );
        _toast('自动提交失败：$netFails 个账号网络异常，请手动补交');
      } else {
        AppLogger.i('自动答题', '已自动提交题目 $problemId（请求已到达服务器）');
        _toast('已自动提交');
      }
    } catch (e, st) {
      // unawaited() 会把异常吞掉，日志里什么都看不到 —— 必须自己兜住
      AppLogger.e('自动答题', '自动提交题目 $problemId 时出错：$e\n$st');
      _autoSubmitted.remove(problemId); // 允许下次重试
    }
  }

  /// 等某道题的答案就绪（AI 检索要几秒）
  ///
  /// 拿到**终态**就立刻返回，不傻等到超时：
  /// - `ok` + 有结果 → 可用，返回
  /// - `failed`（超时/鉴权/模型报错）、`empty`（模型说没答案）
  ///   → 这两种再等也不会变（`_enqueueScan` 每题只提交一次，不会自动重试），
  ///     提前返回，省下最多 25 秒 —— 这 25 秒在限时题里很宝贵。
  Future<CachedAnswer?> _waitForAnswer(
    String hash, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final c = _suggested[hash];
      if (c != null) {
        if (c.usable) return c;
        if (c.status == CachedAnswerStatus.failed ||
            c.status == CachedAnswerStatus.empty) {
          AppLogger.i('自动答题', '答案是终态（${c.status}），不再等待');
          return c;
        }
      }
      if (!mounted) return null;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return _suggested[hash];
  }

  /// 题目在 PPT 里的页号（0-based），找不到返回 -1
  ///
  /// 两条路：
  /// 1. 直接比 PPT 里题目的 `problemId`
  /// 2. **兜底**：从时间轴找。时间轴事件的 `problemId` 和发题消息的 `prob`
  ///    是同一个字段（都读 JSON 里的 `prob`），而且事件里带 `si`（1-based
  ///    页码，和 `_toSlide` / `showpresentation` 同源）——
  ///    万一 `prob` 和 PPT 里的 `problemId` 不是同一个值，靠这条也能定位。
  int _indexOfProblem(String problemId) {
    for (var i = 0; i < _slideModels.length; i++) {
      if (_slideModels[i].problem?.problemId == problemId) return i;
    }

    for (final e in _timeline) {
      if (e.problemId != problemId) continue;
      // 不同一份 PPT 的页码不能混用
      if (e.presentationId != null &&
          _currentPresentationId != null &&
          e.presentationId != _currentPresentationId) {
        continue;
      }
      final si = e.slideIndex;
      if (si == null || si <= 0) continue;
      final idx = si - 1;
      if (idx >= 0 && idx < _slideModels.length) {
        AppLogger.i(
          '自动答题',
          'PPT 里没匹配到 problemId=$problemId，改用时间轴的 si 定位到第 ${idx + 1} 页',
        );
        return idx;
      }
    }

    return -1;
  }

  /// 等 PPT 加载完再找题目所在页
  ///
  /// 老师有可能在 PPT 还没到的时候就发题（尤其是刚上课那一下），
  /// 这时候直接返回 -1 会白白错过一次自动提交。
  Future<int> _waitForProblemSlide(
    String problemId, {
    int tries = 6,
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    for (var i = 0; i < tries; i++) {
      final index = _indexOfProblem(problemId);
      if (index >= 0) return index;
      if (!mounted) return -1;
      if (i < tries - 1) await Future<void>.delayed(interval);
    }

    // 找不到就把三方都打出来：
    //   1. 发题消息给的 ID
    //   2. PPT 里各页题目的 problemId
    //   3. 时间轴里各事件的 problemId + si
    // 这样能一眼分清是「ID 对不上」还是「题目确实不在这份 PPT 里」，
    // 也能看出时间轴里到底有没有刚发的这道题（兜底方案的前提）。
    final slides = <String>[];
    for (var i = 0; i < _slideModels.length; i++) {
      final id = _slideModels[i].problem?.problemId;
      if (id != null && id.isNotEmpty) slides.add('${i + 1}页:$id');
    }
    final timeline = _timeline
        .where((e) => e.problemId != null && e.problemId!.isNotEmpty)
        .map((e) => 'si=${e.slideIndex}:${e.problemId}')
        .toList();
    AppLogger.w(
      '自动答题',
      '找不到题目 $problemId\n'
          '  PPT（${_slideModels.length} 页）里的题目=[${slides.isEmpty ? "无" : slides.join("，")}]\n'
          '  时间轴里的题目=[${timeline.isEmpty ? "无" : timeline.join("，")}]',
    );
    return -1;
  }

  /// 当前页的题是不是老师已经发布的 —— 决定「提交」按钮出不出现
  ///
  /// 具体判据在纯函数 [isCurrentProblemPublished] 里（有单测覆盖）。
  /// 这里只负责把页面状态喂进去。
  bool _isCurrentProblemPublished() => isCurrentProblemPublished(
        currentSlideIndex: _currentSlideIndex,
        publishedSlideOf: _publishedSlideOf,
        currentProblemId: _currentProblem?.problemId,
        publishedProbs: _unlockedProblemIds.toSet(),
        timelineProblemId: _timelineProblemId,
      );

  /// 当前页的答案是否已经填好
  bool _isAnswerFilled() {
    if (_currentProblem == null) return false;
    // 填空的 `_answer` 是「每空一项」，可能是个长度不为 0 但全是空串的列表
    // （用户点过输入框又没输）—— 所以要按**内容**判断，不能只看长度。
    final keys = _answer;
    if (keys != null && keys.any((k) => k.trim().isNotEmpty)) return true;
    final text = _textAnswer;
    return text != null && text.trim().isNotEmpty;
  }

  // [新增] 搜索答案 - 从当前题目提取题干和选项，调用检索模块
  // 检索结果可一键回填到当前作答（只回填，不自动提交）
  Future<void> _searchAnswer() async {
    final problem = _currentProblem;
    if (problem == null) return;

    final question = _questionOfCurrentSlide();
    final hash = _currentHash ?? QuestionHash.of(question);
    final cached = _suggested[hash];
    if (!mounted) return;

    final picked = await showDialog<AnswerSearchResult>(
      context: context,
      builder: (context) => AnswerSearchDialog(
        question: question,
        // 已经有真答案就直接摆出来，不用再等一次请求
        initial: (cached != null && cached.usable)
            ? AnswerSearchSnapshot(
                results: cached.results,
                error: cached.error,
                fromCache: true,
              )
            : null,
        // 没拿到真答案时，手动点进来就是想要一次真实检索
        refreshOnOpen: cached == null || !cached.usable,
        onSearch: ({required bool forceRefresh}) =>
            _searchThroughQueue(question, hash, forceRefresh: forceRefresh),
      ),
    );
    if (picked == null || !mounted) return;

    _applyPickedAnswer(picked, question);
  }

  /// 走后台队列检索（自动去重 + 命中缓存 + 并发限流）
  Future<AnswerSearchSnapshot> _searchThroughQueue(
    StandardizedQuestion question,
    String hash, {
    bool forceRefresh = false,
  }) async {
    final result = await AnswerQueue.submit(AnswerJob(
      lessonId: widget.lessonId,
      hash: hash,
      question: question,
      forceRefresh: forceRefresh,
    ));

    if (result == null) {
      // 没配 AI / 被取消 → 退回直接检索，至少还能拿到内置答案
      final results = await AnswerSearchApi.search(question);
      if (mounted) setState(() => _searching.remove(hash));
      return AnswerSearchSnapshot(
        results: results,
        error: AnswerSearchApi.lastAIError,
      );
    }

    if (mounted) {
      setState(() {
        _suggested[result.hash] = result.answer;
        _searching.remove(result.hash);
      });
    }

    return AnswerSearchSnapshot(
      results: result.answer.results,
      error: result.answer.error,
      fromCache: result.fromCache,
    );
  }

  /// 把选中的检索结果写回作答状态
  void _applyPickedAnswer(
      AnswerSearchResult picked, StandardizedQuestion question) {
    // 复用统一填充逻辑（按题型决定写 _answer 还是 _textAnswer）。
    // 原来这里也是「选择题 / 非选择题」二分，填空题会填到 UI 不读的字段上。
    final ok = _fillAnswerSilently(question, picked, logTag: '填入答案');

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已填入，请核对后提交' : '未能匹配到选项，请手动选择'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
  // [/新增]

  /// 某一页 PPT 里的所有文字（题干为空时兜底用）
  String _slideTextAt(int index) {
    if (index < 0 || index >= _slideModels.length) return '';
    return SlideScanner.slideTextOf(_slideModels[index]);
  }

  /// 某一页 PPT 的图片地址（题目只写在 PPT 上时，交给多模态模型识别）
  String _slideCoverAt(int index) {
    if (index < 0 || index >= _slideModels.length) return '';
    return SlideScanner.slideImageOf(_slideModels[index]);
  }

  String _currentSlideText() => _slideTextAt(_currentSlideIndex);

  String _currentSlideCover() => _slideCoverAt(_currentSlideIndex);

  /// 用当前页信息构建标准化题目
  StandardizedQuestion _questionOfCurrentSlide() {
    final problem = _currentProblem;
    if (problem == null) {
      return StandardizedQuestion(questionText: '', questionType: 'unknown');
    }
    return AnswerSearchApi.fromRainClassroomProblem(
      problem,
      slideText: _currentSlideText(),
      imageUrl: _currentSlideCover(),
    );
  }

  /// 当前页的题目指纹
  ///
  /// 正常情况下直接取扫描阶段算好的，避免每次切页重算一遍 SHA-256。
  /// 扫描阶段没收录这一页时（题目是个「空壳」被跳过了）才现算一个，
  /// 这样手动检索拿到的结果仍然有地方展示。
    void _refreshCurrentHash() {
      final scanned = _scan.forSlide(_currentSlideIndex);
      if (scanned != null) {
        _currentHash = scanned.hash;
      } else if (_currentProblem == null) {
        _currentHash = null;
      } else {
        _currentHash = QuestionHash.of(_questionOfCurrentSlide());
      }

      // 切到一道「答案早就搜好」的题时，`_onAnswerReady` 不会再触发
      // （那个事件只在答案刚到手的那一刻发一次），
      // 所以这里补一次自动预选 —— 否则预搜虽然跑完了，
      // 老师发题后翻到那一页也不会自动填。
      final h = _currentHash;
      if (h != null) {
        // 诊断用：把「当前页指纹」和「已经有答案的指纹」都打出来，
        // 一眼就能看出是「没搜到」还是「搜到了但对不上」
        AppLogger.i(
          '自动答题',
          '第 ${_currentSlideIndex + 1} 页指纹=${_short(h)}'
              '｜已有答案的题=[${_suggested.keys.map(_short).join(",")}]',
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_autoSelectIfCurrent(h));
        });
      }
    }

    String _short(String s) => s.length <= 8 ? s : s.substring(0, 8);
    // [/新增]

  Future<void> _checkToken() async {
    final lessonToken = RCCourseApi().lessonToken;
    if (lessonToken == null) {
      final allAccounts = AccountManager.allAccounts;

      // [新增] 记录网络异常，避免和业务错误混在一起
      final Map<String, String> errorByUid = {};

      final results = await ApiService.sendForEachUser(
        allAccounts,
        (user) async {
          try {
            final api = RCCourseApi(user);
            return await api.checkIn(widget.lessonId);
          } catch (e) {
            errorByUid[user.uid.toString()] = describeErrorShort(e);
            rethrow;
          }
        },
      );

      for (int i = 0; i < results.length; i++) {
        final result = results[i];
        final user = allAccounts[i];

        final netError = errorByUid[user.uid.toString()];
        if (netError != null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Uid${user.uid} 网络异常：$netError'))
            );
          }
          continue;
        }

        if (result != 0) {
          if (result == 50070){
            if (mounted) {
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    content: const Text('请先扫描动态二维码'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('确定')
                      ),
                    ]
                  );
                },
              );
            }
            return;
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Uid${user.uid}签到错误：$result'))
              );
            }
          }
        }
      }
    }
  }

  /// 启动前台服务
  ///
  /// 关键路径上**不能放权限弹窗**。两个权限都会弹系统界面，而插件用的是
  /// `startActivityForResult` 模式、没有超时；Activity 被系统重建时回调永远不来，
  /// `await` 就会卡死在这里 —— 服务根本没机会启动。所以顺序是：
  /// **先起服务，再弹权限**，权限各自带超时兜底。
  Future<void> _startForegroundService() async {
    await KeepAliveService.start();
  }

  Future<void> _stopForegroundService() async {
    await KeepAliveService.stop();
  }

  Future<void> _connectWebSocket() async {
    try {
      late String lessonUrl;
      final currentServerName = PlatformManager().currentServer.name;
      lessonUrl = currentServerName == 'yuketang'?
      'wss://www.yuketang.cn/wsapp/' : 'wss://$currentServerName.yuketang.cn/wsapp/';

      final ws = await WebSocket.connect(lessonUrl);
      _ws = ws;

      final helloData = {
        "op": "hello",
        "userid": AccountManager.currentSessionId,
        "role": "student",
        "auth": RCCourseApi().lessonToken,
        "lessonid": widget.lessonId
      };

      ws.add(jsonEncode(helloData));

      ws.listen(
        (message) {
          _handleMessage(message);
        },
      );
    } catch (e) {
      AppLogger.e('WebSocket', '连接失败：$e');
    }
  }

  void _toSlide(int slideIndex, {bool animate = true}) {
    final targetIndex = slideIndex - 1;
    if (targetIndex < 0) return;

    setState(() {
      // _currentLessonSlideIndex = 老师当前所在页（「回到当前页」按钮靠它判断）
      _currentLessonSlideIndex = targetIndex;
      _currentSlideIndex = targetIndex;
        if (targetIndex < _slides.length) {
          _currentProblem = _slides[targetIndex]['problem'];
        }
        _syncAnswerOwner();
        _refreshCurrentHash();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;

      if (animate) {
        _pageController.animateToPage(
          targetIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut
        );
      } else {
        _pageController.jumpToPage(targetIndex);
      }
    });
  }

  void _handleMessage(dynamic message) async {
    // op 提到 try 外面：catch 里要用它。
    // 之前异常只写 '解析消息失败：$e'，**不知道是哪条消息炸的** ——
    // 上课排查时完全靠猜。现在带上 op，一眼能看出是 unlockproblem 还是别的。
    String? op;
    try {
      final data = jsonDecode(message);
      op = data['op']?.toString();

      AppLogger.d('WebSocket', 'S2C：$message');

      final messageText = data['message'];

      switch (op) {
        case 'hello':
          if (messageText == 'lesson finished') {
            // 课堂结束 → 打标记，缓存再留 24 小时就清掉
            unawaited(CourseCache.markFinished(widget.lessonId));
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('课堂已结束')),
                );
              }
            });
            return;
          }

          final presentationId = data['presentation'];
          final slideIndex = data['slideindex'];
          final timeline = data['timeline'] as List?;

          String? latestPresId;
          int? latestSlideIndex;
          if (timeline != null) {
            for (var event in timeline.reversed) {
              if (event['type'] == 'slide' && event['pres'] != null) {
                latestPresId = event['pres'];
                latestSlideIndex = event['si'];
                break;
              }
            }
          }

          final targetPresId = latestPresId ?? presentationId;
          final targetSlideIndex = latestSlideIndex ?? slideIndex;

          if (targetPresId != null) {
            await _loadPresentation(targetPresId);
            if (targetSlideIndex != null && targetSlideIndex > 0) {
              _toSlide(targetSlideIndex, animate: false);
            }
          }

          if (timeline != null) {
            _addTimelineEvents(timeline);
          }

          setState(() {
            _isInitialized = true;
          });
          break;

        case 'unlockproblem':
          final problemData = data['problem'];
          if (problemData != null) {
            final problemId = problemData['prob'];
            final limit = problemData['limit'];
            final dt = problemData['dt'];

            // 诊断：把发题消息的原样打出来。
            // 关键是确认 `prob` 和 PPT 里的 `problemId` 是不是同一个值 ——
            // 不是的话「提交」按钮和自动提交都找不到题目。
            AppLogger.i('自动答题', '收到 unlockproblem 原始数据：$problemData');

            if (limit != null && limit > 0) {
              setState(() {
                _countdownSeconds = limit;
                if (problemId != null && !_unlockedProblemIds.contains(problemId)) {
                  _unlockedProblemIds.add(problemId);
                }
                if (_currentProblem != null && dt != null) {
                  _currentProblem = _currentProblem!.copyWith(dt: dt);
                }
              });
              _startCountdown(limit);
            } else if (problemId != null) {
              // 不限时的题：没有倒计时，但一样要记进「已解锁」
              setState(() {
                if (!_unlockedProblemIds.contains(problemId)) {
                  _unlockedProblemIds.add(problemId);
                }
              });
            }

            // [新增] 老师发布了题目 → 按设置尝试自动提交
            //
            // 注意这行**必须在 limit 判断之外**：不限时的题（limit 为 null/0）
            // 也要能自动提交，否则那类题永远不会触发。
            if (problemId != null) {
              unawaited(_maybeAutoSubmit(problemId.toString()));
            }
          }
          break;

        case 'showpresentation':
          final presentationId = data['presentation'];
          final slideIndex = data['slideindex'];
          final timeline = data['timeline'] as List?;

          if (presentationId != null && presentationId != _currentPresentationId) {
            await _loadPresentation(presentationId);
          }

          if (slideIndex != null) {
            _toSlide(slideIndex);
          }

          if (timeline != null) {
            _addTimelineEvents(timeline);
          }
          break;

        case 'slide':
        case 'slidenav':
          final slideIndex = op == 'slide' ?
          data['slideindex'] : data['slide']?['si'];
          if (slideIndex != null) {
            _toSlide(slideIndex);
          }
          break;

        case 'extendtime':
          final problemData = data['problem'];
          if (problemData != null) {
            final extend = problemData['extend'];
            if (extend != null && extend > 0) {
              setState(() {
                if (_countdownSeconds != null) {
                  _countdownSeconds = (_countdownSeconds! + extend).toInt();
                }
              });
            }
          }
          break;

        case 'callpaused':
          final eventData = data['event'];
          if (eventData != null) {
            final code = eventData['code'];
            final dt = eventData['dt'];
            if (code == 'RANDOM_PICK') {
              setState(() {
                _timeline.add(TimelineEvent(
                  type: 'randompick',
                  code: 'RANDOM_PICK',
                  title: eventData['title'],
                  timestamp: DateTime.fromMillisecondsSinceEpoch(dt)
                ));
              });
            }
          }
          break;

        case 'showfinished':
          final eventData = data['event'];
          if (eventData != null) {
            final code = eventData['code'];
            final title = eventData['title'];
            final dt = eventData['dt'];

            if (code == 'SHOW_FINISH') {
              setState(() {
                _timeline.add(TimelineEvent(
                  type: 'event',
                  code: code,
                  title: title,
                  timestamp: DateTime.fromMillisecondsSinceEpoch(dt),
                ));
              });
            }
          }
          break;

        case 'lessonfinished':
          final eventData = data['event'];
          if (eventData != null) {
            final code = eventData['code'];
            final title = eventData['title'];
            final dt = eventData['dt'];

            if (code == 'LESSON_FINISH') {
              unawaited(CourseCache.markFinished(widget.lessonId));
              setState(() {
                _timeline.add(TimelineEvent(
                  type: 'event',
                  code: code,
                  title: title,
                  timestamp: DateTime.fromMillisecondsSinceEpoch(dt)
                ));
              });
            }
          }
          break;
      }
      } catch (e, st) {
        AppLogger.e(
          'WebSocket',
          '处理消息失败 op=${op ?? "?"}：$e\n$st',
        );
      }
  }

  void _addTimelineEvents(List timeline) {
    for (var event in timeline) {
      final type = event['type'];
      final code = event['code'];
      final title = event['title'];
      final dt = event['dt'];
      final si = event['si'];
      final total = event['total'];
      final limit = event['limit'];
      final prob = event['prob'];
      final pres = event['pres'];

      if (type != null) {
        String eventType = type;
        String eventTitle = title ?? '';

        if (type == 'event' && code != null) {
          if (code == 'RANDOM_PICK') {
            eventType = 'randompick';
            eventTitle = title ?? '随机点名';
          }
        }

        if (eventType == 'slide') {
          continue;
        }

        setState(() {
          _timeline.add(TimelineEvent(
            type: eventType,
            code: code,
            title: eventTitle,
            slideIndex: si,
            total: total,
            limit: limit,
            timestamp: DateTime.fromMillisecondsSinceEpoch(dt),
            problemId: prob,
            presentationId: pres,
            problemDt: dt
          ));

          if (eventType == 'problem' && prob != null && !_unlockedProblemIds.contains(prob)) {
            _unlockedProblemIds.add(prob);
          }
        });
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _loadPresentation(String presentationId) async {
    if (_isLoading || presentationId == _currentPresentationId) return;

    setState(() {
      _isLoading = true;
    });

    Presentation? presentation;
    try {
      final pptData = await RCCourseApi().getPresentation(presentationId);
      if (pptData != null) {
        // 整份 PPT 元数据落盘：老师来回切同一份时不用重复请求。
        // 顺手把「这节课属于哪门课」记进 meta.json —— 课件页靠它把
        // lessonId 目录归到课程名下（老缓存就是缺这个，只能显示一串数字）。
        unawaited(PptCache.save(
          widget.lessonId,
          presentationId,
          pptData,
          courseId: widget.courseId,
          courseName: widget.title,
        ));
        presentation = Presentation.fromJson(pptData);
      }
    } catch (e) {
      AppLogger.e('Presentation', '加载 PPT 失败：$e');
      AppLogger.w('Presentation', '加载 PPT 失败：$e');
    }

    // 请求失败就退回上次的缓存，别让界面空着
    presentation ??= await PptCache.load(widget.lessonId, presentationId);

    if (!mounted) return;

    if (presentation == null) {
      // 修 bug：原实现在 pptData 为 null 时不会复位 _isLoading，
      // 界面会永远停在「加载 PPT 中…」
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PPT 加载失败，可稍后重试')),
      );
      return;
    }

    final slides = presentation.slides;
    setState(() {
      _slideModels = slides;
      _slides = slides
          .map((slide) => {
                'index': slide.index,
                'cover': slide.cover,
                'coverAlt': slide.coverAlt,
                'thumbnail': slide.thumbnail,
                'problem': slide.problem,
                // [新增] 保留形状文本，用于题干缺失时兜底
                'shapes': slide.shapes,
              })
          .toList();
      _totalCount = slides.length;
      _currentPresentationId = presentationId;
      if (_slides.isNotEmpty &&
          _currentSlideIndex >= 0 &&
          _currentSlideIndex < _slides.length) {
        _currentProblem = slides[_currentSlideIndex].problem;
      }
      _isLoading = false;
    });

    // 整份 PPT 到手 = 所有题都到手了。识题是纯内存计算，几十毫秒的事，
    // 所以是「拿到就全判完」，不需要等用户翻页、更不需要等图片下载
    _indexQuestions(slides);
  }

  /// 拿到整份 PPT 后立刻做的事：识题 → 排队检索 → 预取图片
  void _indexQuestions(List<PresentationSlide> slides) {
    final scan = SlideScanner.scanSlides(slides);

    // 先把已在缓存里的答案同步塞进来，切页时展示是同步的、不会闪
    final suggested = <String, CachedAnswer>{};
    for (final item in scan.questions) {
      final hit = AnswerCache.readMemory(widget.lessonId, item.hash);
      if (hit != null) suggested[item.hash] = hit;
    }

    setState(() {
      _scan = scan;
      _suggested
        ..clear()
        ..addAll(suggested);
      // 换了一份 PPT → 上一份的「检索中」标记全部作废
      _searching.clear();
      _refreshCurrentHash();
    });

    AppLogger.i(
      'Presentation',
      '识题完成：共 ${scan.total} 题'
          '（可自动检索 ${scan.autoSearchable.length}，'
          '需识图 ${scan.visionOnly.length}，'
          '跳过空壳 ${scan.skippedNotUsable}，'
          '同题重复 ${scan.duplicateCount}）',
    );

    // 后台把整份 PPT 的图拉下来（只下载字节、不解码，不吃内存）
    SlideImagePrefetcher.start(
      widget.lessonId,
      SlideScanner.imageUrlsOf(slides),
    );

    unawaited(_enqueueScan(scan));
  }

  /// 把扫出来的题逐条丢进 AI 队列
  ///
  /// 队列自带并发闸门（2）和 in-flight 去重，所以这里可以放心地一次全丢进去。
  Future<void> _enqueueScan(SlideScanResult scan) async {
    await AnswerSearchApi.initialize();
    if (!mounted) return;

    if (!AnswerSearchApi.isAIConfigured) {
      AppLogger.i('Presentation', '未配置 AI，跳过自动检索（只展示已有缓存）');
      return;
    }

    final todo = scan.autoSearchable
        .where((item) => !(_suggested[item.hash]?.shouldSkipRefetch() ?? false))
        .toList();

    setState(() {
      _searching
        ..clear()
        ..addAll(todo.map((item) => item.hash));
    });

    for (final item in todo) {
      unawaited(
        AnswerQueue.submit(AnswerJob(
            lessonId: widget.lessonId,
            hash: item.hash,
            question: item.question,
          )).then((result) {
            if (!mounted) return;
            setState(() {
              if (result != null) _suggested[result.hash] = result.answer;
              _searching.remove(item.hash);
            });

            // 自动预选不在这里触发 —— AnswerQueue 现在**不管走缓存还是
            // 真去请求都会广播**（契约统一在 submit() 的出口），
            // 所以 _onAnswerReady 一定会被调到，那边负责预选。
            //
            // 这里仍然写一次 _suggested：广播是流，万一界面刚好在
            // dispose 边缘错过了，这里能兜住，而且写两次是幂等的。
          }).catchError((Object e) {
          AppLogger.w('Presentation', '自动检索失败（${item.hash}）：$e');
          if (mounted) {
            setState(() => _searching.remove(item.hash));
          }
        }),
      );
    }
  }

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        if (_countdownSeconds != null && _countdownSeconds! > 0) {
          _countdownSeconds = _countdownSeconds! - 1;
        } else {
          timer.cancel();
        }
      });
    });
  }

  /// PPT 右上角浮层：页码 + 脱离老师那页时出现的「回到当前页」按钮
  ///
  /// 默认跟随老师（老师翻页时 [_toSlide] 会把两边的下标一起改掉）。
  /// 用户手动翻页只会改 `_currentSlideIndex`，于是两个下标不相等 → 按钮出现。
  /// 按钮名字保持中立，不出现「同步/跟随」这类词。
  Widget _buildSlideOverlay() {
    final scheme = Theme.of(context).colorScheme;
    final following = _currentSlideIndex == _currentLessonSlideIndex;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!following) ...[
          Material(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _toSlide(_currentLessonSlideIndex + 1),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.my_location, size: 14, color: scheme.onPrimary),
                    const SizedBox(width: 4),
                    Text(
                      '回到当前页',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: following
              ? RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    children: [
                      TextSpan(
                        text: '当前 ',
                        style: TextStyle(color: scheme.primary),
                      ),
                      TextSpan(
                        text: '${_currentSlideIndex + 1}/$_totalCount',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              : Text(
                  '${_currentSlideIndex + 1}/$_totalCount',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
        ),
      ],
    );
  }

  /// 建议答案卡片（只展示，用户点了「填入」才会写进作答状态）
  Widget _buildSuggestedCard() {
    final hash = _currentHash;
    if (hash == null) return const SizedBox.shrink();

    final problem = _currentProblem;
    final scanned = _scan.forSlide(_currentSlideIndex);
    final question = scanned?.question ??
        (problem == null
            ? StandardizedQuestion(questionText: '', questionType: 'unknown')
            : _questionOfCurrentSlide());

    final options = (problem?.options ?? const <ProblemOption>[])
        .map((o) => StandardizedOption(key: o.key, value: o.value))
        .toList();

    final cached = _suggested[hash];

    return SuggestedAnswerCard(
      cached: cached,
      isSearching: _searching.contains(hash),
      needsVision: scanned?.needsVision ?? false,
      options: options,
      onApply: () {
        final best = cached?.best;
        if (best != null) _applyPickedAnswer(best, question);
      },
      onDetails: _searchAnswer,
      onRetry: () => _retryCurrent(hash),
    );
  }

  /// 手动重新检索当前页这道题（忽略缓存）
  Future<void> _retryCurrent(String hash) async {
    final problem = _currentProblem;
    if (problem == null) return;

    final question =
        _scan.forSlide(_currentSlideIndex)?.question ?? _questionOfCurrentSlide();

    setState(() {
      _searching.add(hash);
      _suggested.remove(hash);
    });

    await _searchThroughQueue(question, hash, forceRefresh: true);
  }

  Widget _buildFullScreenPPT() {
    return Stack(
      children: [
        PageView.builder(
          controller: _pageController,
          itemCount: _slides.length,
          onPageChanged: (index) {
            setState(() {
              _currentSlideIndex = index;
              _currentProblem = _slides[index]['problem'];
              _syncAnswerOwner();
              // 注意：这里**不**动 _currentLessonSlideIndex ——
              // 用户手动翻页就表示脱离了老师那页，按钮才会出现
              _refreshCurrentHash();
            });
          },
          itemBuilder: (context, index) {
            final slide = _slides[index];
            final cover = slide['coverAlt'] as String?;
            return Center(
              child: cover != null
                  ? GestureDetector(
                      onLongPressDown: (details) {
                        setState(() {
                          _menuPosition = details.globalPosition;
                        });
                      },
                      onLongPress: () async {
                        final RenderBox? overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
                        if (overlay == null) return;

                        final result = await showMenu<String>(
                          context: context,
                          position: RelativeRect.fromLTRB(
                            _menuPosition.dx,
                            _menuPosition.dy,
                            _menuPosition.dx + 1,
                            _menuPosition.dy + 1,
                          ),
                          items: [
                            const PopupMenuItem<String>(
                              value: 'save',
                              child: Text('保存图片'),
                            ),
                            const PopupMenuItem<String>(
                              value: 'fullscreen',
                              child: Text('退出全屏'),
                            ),
                          ],
                        );

                        if (result == 'save') {
                          await _saveImageToGallery(cover);
                        } else if (result == 'fullscreen') {
                          setState(() {
                            _isFullScreen = false;
                          });
                        }
                      },
                      // 走本课程的磁盘图片缓存（预取过就是秒开，断网也能看）
                      child: Image(
                        image: SlideImage(widget.lessonId, cover),
                        fit: BoxFit.contain,
                        width: double.infinity,
                        height: double.infinity,
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return const Center(
                            child: Icon(
                              Icons.error_outline,
                              size: 48,
                              color: Colors.grey,
                            ),
                          );
                        },
                      ),
                    )
                  : const Center(
                      child: Text(
                        '暂无 PPT',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
            );
          },
        ),
        Positioned(
          right: 16,
          top: 16,
          child: _buildSlideOverlay(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _isFullScreen ? null : AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        actions: [
          // [新增] 课件缓存进度 + 导出 PDF
          //
          // 缓存没完成时 PDF 按钮是禁用的（防呆），
          // 避免用户上来就点，导出一个只有几页的残缺 PDF。
          ValueListenableBuilder<SlidePrefetchProgress>(
            valueListenable: SlideImagePrefetcher.progress,
            builder: (context, p, _) {
              if (p.isRunning) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: Text(
                      '缓存中 ${p.label}',
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                );
              }
              if (p.isNotEmpty && !p.isComplete) {
                return IconButton(
                  tooltip: '课件缓存不完整（${p.label}），点击重试',
                  onPressed: _retryPrefetch,
                  icon: const Icon(Icons.refresh),
                );
              }
              return IconButton(
                tooltip: p.isComplete ? '导出整份 PPT 为 PDF' : '课件还没开始缓存',
                onPressed: (_isExporting || !p.isComplete)
                    ? null
                    : _exportPresentationPdf,
                icon: _isExporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.picture_as_pdf_outlined),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text(
                    '加载 PPT 中...',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            )
          : !_isInitialized
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text(
                        '等待课堂数据...',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : _isFullScreen
                  ? _buildFullScreenPPT()
                  : Column(
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        children: [
                          PageView.builder(
                            controller: _pageController,
                            itemCount: _slides.length,
                            onPageChanged: (index) {
                              setState(() {
                                _currentSlideIndex = index;
                                _currentProblem = _slides[index]['problem'];
                                _syncAnswerOwner();
                                // 同全屏视图：手动翻页不改变老师所在页
                                _refreshCurrentHash();
                              });
                            },
                            itemBuilder: (context, index) {
                              final slide = _slides[index];
                              final cover = slide['coverAlt'] as String?;
                              return Center(
                                child: cover != null
                                    ? GestureDetector(
                                        onLongPressDown: (details) {
                                          setState(() {
                                            _menuPosition = details.globalPosition;
                                          });
                                        },
                                        onLongPress: () async {
                                          final RenderBox? overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
                                          if (overlay == null) return;

                                          final result = await showMenu<String>(
                                            context: context,
                                            position: RelativeRect.fromLTRB(
                                              _menuPosition.dx,
                                              _menuPosition.dy,
                                              _menuPosition.dx + 1,
                                              _menuPosition.dy + 1,
                                            ),
                                            items: [
                                              const PopupMenuItem<String>(
                                                value: 'save',
                                                child: Text('保存图片')
                                              ),
                                              PopupMenuItem<String>(
                                                value: 'fullscreen',
                                                child: Text('全屏')
                                              ),
                                            ],
                                          );

                                          if (result == 'save') {
                                            await _saveImageToGallery(cover);
                                          } else if (result == 'fullscreen') {
                                            setState(() {
                                              _isFullScreen = !_isFullScreen;
                                            });
                                          }
                                        },
                                        // 走本课程的磁盘图片缓存
                                        child: Image(
                                          image: SlideImage(widget.lessonId, cover),
                                          fit: BoxFit.contain,
                                          width: double.infinity,
                                          height: double.infinity,
                                          loadingBuilder: (context, child, progress) {
                                            if (progress == null) return child;
                                            return const Center(
                                              child: CircularProgressIndicator(),
                                            );
                                          },
                                          errorBuilder: (context, error, stackTrace) {
                                            return const Center(
                                              child: Icon(
                                                Icons.error_outline,
                                                size: 48,
                                                color: Colors.grey,
                                              ),
                                            );
                                          },
                                        ),
                                      )
                                    : const Center(
                                        child: Text(
                                          '暂无 PPT',
                                          style: TextStyle(color: Colors.grey),
                                        ),
                                      ),
                              );
                            },
                          ),
                          Positioned(
                            right: 16,
                            top: 16,
                            child: _buildSlideOverlay(),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            if (_currentProblem != null)
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surface,
                                  border: Border(
                                    top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                                    bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant, width: 1),
                                  ),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.max,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _isProblemExpanded = !_isProblemExpanded;
                                        });
                                      },
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context).colorScheme.primary,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              _getProblemTypeLabel(_currentProblem!.problemType),
                                              style: TextStyle(
                                                color: Theme.of(context).colorScheme.onPrimary,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (_currentProblem!.problemType == 3 && _currentProblem!.pollingCount != null && _currentProblem!.pollingCount! > 1)
                                            Text(
                                              '（最多${_currentProblem!.pollingCount}项）',
                                              style: TextStyle(
                                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                                fontSize: 12,
                                              ),
                                            ),
                                          const SizedBox(width: 8),
                                          if (_currentProblem!.score > 0)
                                            Text(
                                              '(${(_currentProblem!.score / 100).toStringAsFixed(0)}分)',
                                              style: TextStyle(
                                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                                fontSize: 12,
                                              ),
                                            ),
                                          const Spacer(),
                                          // 倒计时红标：题目已发布 + 有倒计时才显示
                                          if (_isCurrentProblemPublished() && _countdownSeconds != null)
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                              decoration: BoxDecoration(
                                                color: Theme.of(context).colorScheme.errorContainer,
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.timer_outlined,
                                                    size: 18,
                                                    color: Theme.of(context).colorScheme.onErrorContainer,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    '${_countdownSeconds! ~/ 60}:${(_countdownSeconds! % 60).toString().padLeft(2, '0')}',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.bold,
                                                      color: Theme.of(context).colorScheme.onErrorContainer,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          const SizedBox(width: 12),
                                          Icon(
                                            _isProblemExpanded
                                                ? Icons.keyboard_arrow_up
                                                : Icons.keyboard_arrow_down,
                                            size: 20,
                                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (_isProblemExpanded) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                        _currentProblem!.body,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      _buildAnswerOptions(),
                                      // [新增] 建议答案（后台自动检索的结果，只展示不提交）
                                      _buildSuggestedCard(),
                                      // [新增] 搜索答案按钮 - 在答案选项下方
                                      const SizedBox(height: 8),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton.icon(
                                          onPressed: _searchAnswer,
                                          icon: const Icon(Icons.search, size: 18),
                                          label: const Text('搜索答案'),
                                          style: TextButton.styleFrom(
                                            foregroundColor: Theme.of(context).colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                      // [/新增]
                                      // 单一事实来源判断，不再在这里裸写 ID 比对
                                      // （发题消息用 prob，PPT 用 problemId，两套命名空间）
                                      if (_isCurrentProblemPublished()) ...[
                                        const SizedBox(height: 16),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.end,
                                          children: [
                                            ElevatedButton(
                                              onPressed: () async {await _submitAnswer();},
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: Theme.of(context).colorScheme.primary,
                                                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                              ),
                                              child: const Text(
                                                '提交',
                                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                              ),
                                            )
                                          ]
                                        ),
                                      ],
                                    ],
                                  ],
                                ),
                              ),
                            ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              controller: _scrollController,
                              padding: const EdgeInsets.all(12),
                              itemCount: _timeline.length,
                              itemBuilder: (context, index) {
                                final event = _timeline[index];
                                return _buildTimelineItem(event);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildTimelineItem(TimelineEvent event) {
    Color bgColor;
    IconData icon;

    switch (event.type) {
      case 'event':
        switch (event.code) {
          case 'LESSON_START':
            bgColor = Colors.green;
            icon = Icons.school;
            break;
          case 'SHOW_PRESENTATION':
          case 'START_PRESENTATION':
            bgColor = Colors.blue;
            icon = Icons.slideshow;
            break;
          case 'SHOW_FINISH':
            bgColor = Colors.orange;
            icon = Icons.stop_circle;
            break;
          case 'LESSON_FINISH':
            bgColor = Colors.red;
            icon = Icons.school;
          default:
            bgColor = Colors.grey;
            icon = Icons.info;
        }
        break;
      case 'problem':
        bgColor = Colors.purple;
        icon = Icons.quiz;
        break;
      case 'randompick':
        bgColor = Colors.orange;
        icon = Icons.person_add;
        break;
      default:
        bgColor = Colors.grey;
        icon = Icons.info;
    }

    return GestureDetector(
      onTap: event.type == 'problem' ? () => _handleTimelineProblemClick(event) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: bgColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                icon,
                color: bgColor,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _getEventTitle(event),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ),
                        if (event.type == 'problem')
                          Icon(
                            Icons.arrow_forward_ios,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatTime(event.timestamp),
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getEventTitle(TimelineEvent event) {
    switch (event.type) {
      case 'slide':
        return '第 ${event.slideIndex} 页';
      case 'problem':
        final limit = event.limit;
        if (limit != null && limit > 0) {
          return '题目发布（作答时间：$limit秒）';
        }
        return '题目发布';
      default:
        return event.title ?? '';
    }
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) {
      return '刚刚';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}分钟前';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}小时前';
    } else {
      return '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
  }

  String _getProblemTypeLabel(int type) {
    return ProblemType.fromId(type).label;
  }

  Future<void> _handleTimelineProblemClick(TimelineEvent event) async {
    if (event.problemId == null || event.presentationId == null) return;

    if (event.presentationId != _currentPresentationId) {
      await _loadPresentation(event.presentationId!);
    }

    final slideIndex = event.slideIndex;
    if (slideIndex != null && slideIndex > 0) {
      // 时间轴里的 si 是 1-based 页码（和 _toSlide / showpresentation 同一个来源），
      // 之前这里少减了 1，会导致点开时间轴的题之后页面比老师那页多出一页，
      // 右上角立刻冒出「回到当前页」按钮
      final targetIndex = slideIndex - 1;

      if (_pageController.hasClients) {
        _pageController.animateToPage(
          targetIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut
        );
      }

      setState(() {
        _currentSlideIndex = targetIndex;
        if (targetIndex >= 0 && targetIndex < _slides.length) {
          _currentProblem = _slides[targetIndex]['problem'];
          if (_currentProblem != null && event.problemDt != null) {
            _currentProblem = _currentProblem!.copyWith(dt: event.problemDt);
          }
        }
        _timelineProblemId = event.problemId;
        if (event.problemId != null && !_unlockedProblemIds.contains(event.problemId!)) {
          _unlockedProblemIds.add(event.problemId!);
        }
        _countdownSeconds = 0;
        _refreshCurrentHash();
      });
    }
  }

  /// 提交答案
  ///
  /// [problemIdOverride] 用于自动提交：直接传**服务器发题时给的 ID**（`prob`），
  /// 而不是用 `_currentProblem.problemId`。
  /// 两个字段名不同，万一值也不一样，用 PPT 里那个 ID 提交会被服务器拒。
  /// 返回**网络失败**的账号数（0 = 没有网络问题）
  ///
  /// 注意只统计「请求没到服务器」这类网络异常，
  /// 服务端明确拒绝（比如题已关闭）不算 —— 那种重试没意义还可能重复提交。
  Future<int> _submitAnswer({
    bool auto = false,
    String? problemIdOverride,
    bool silent = false,
  }) async {
    final problemId =
        problemIdOverride ?? _currentProblem?.problemId ?? _timelineProblemId;
    if (problemId == null) return 0;

    final problemType = _currentProblem?.problemType ?? 0;
    final problemDt = _currentProblem?.dt;

    if (_answer == null && _textAnswer == null && _uploadedImageUrls.isEmpty) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先选择或填写答案')),
        );
      }
      return 0;
    }

    final isTimeout = _countdownSeconds != null && _countdownSeconds! <= 0;

    return await _submitForAllAccounts(problemId, problemType,
        _uploadedImageUrls, isTimeout, problemDt,
        auto: auto, silent: silent);
  }

  /// 返回**网络失败**的账号数（0 = 没有网络问题）
  Future<int> _submitForAllAccounts(String problemId, int problemType,
      List<String>? imageUrls, bool isTimeout, int? problemDt,
      {bool auto = false, bool silent = false}) async {
    final allAccounts = AccountManager.allAccounts;

    if (allAccounts.isEmpty) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可用的账号')),
        );
      }
      return 0;
    }

    int successCount = 0;
    final List<String> failedAccounts = [];

    // [新增] 记录每个账号的异常原因，用于区分网络失败与业务失败
    final Map<String, String> errorByUid = {};

    final results = await ApiService.sendForEachUser(
      allAccounts,
      (user) async {
        try {
          final api = RCCourseApi(user);
          return await api.answer(
            problemId,
            problemType,
            retry: isTimeout,
            time: isTimeout ? problemDt : null,
            options: _answer,
            content: _textAnswer,
            imageUrls: imageUrls
          );
        } catch (e) {
          errorByUid[user.uid.toString()] = describeErrorShort(e);
          rethrow;
        }
      },
    );

    int networkFailCount = 0;

    for (int i = 0; i < results.length; i++) {
      final result = results[i];
      final user = allAccounts[i];

      if (result != null && result['code'] == 0) {
        successCount++;
      } else {
        final netError = errorByUid[user.uid.toString()];
        if (netError != null) {
          networkFailCount++;
          failedAccounts.add('${user.name}: [网络异常] $netError');
        } else {
          failedAccounts.add('${user.name}: ${result?["msg"] ?? "提交失败"}');
        }
      }
    }

      // silent：自动提交的重试过程中不弹结果，等重试全部走完再统一报一次，
      // 否则「网络异常」和「全部提交成功」会先后叠两条 SnackBar，自相矛盾。
      if (!silent) {
        _showSubmitResult(
          successCount,
          allAccounts.length,
          failedAccounts,
          networkFailCount: networkFailCount,
          auto: auto,
        );
      }

    setState(() {
      _countdownSeconds = 0;
      _selectedImages.clear();
      _uploadedImageUrls.clear();
    });

    return networkFailCount;
  }

    void _showSubmitResult(
      int successCount,
      int totalCount,
      List<String> failedAccounts, {
      int networkFailCount = 0,
      bool auto = false,
    }) {
      if (!mounted) return;

    final bool allNetworkFailed = successCount == 0 &&
        networkFailCount > 0 &&
        networkFailCount == failedAccounts.length;

    String title;
    if (successCount == totalCount) {
      title = '全部提交成功';
    } else if (allNetworkFailed) {
      title = '网络异常，提交未完成';
    } else if (networkFailCount > 0) {
      title = '部分失败（含网络异常）';
    } else {
      title = '部分失败';
    }

    String message = '答案提交完成！\n成功：$successCount/$totalCount';
    if (networkFailCount > 0) {
      message += '\n网络异常：$networkFailCount 个账号';
      message += '\n\n提示：网络异常表示请求没有到达服务器，'
          '通常是断网、超时或接口无法访问。请检查手机网络后重新提交。';
    }
      if (failedAccounts.isNotEmpty) {
        message += '\n\n失败账号:\n${failedAccounts.join('\n')}';
      }

      // 自动提交不弹模态框：课堂上弹窗会挡住界面、还得手动关，
      // 连发几道题就会叠一堆。改成 SnackBar，瞄一眼就知道结果。
      if (auto) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$title（$successCount/$totalCount）'),
            duration: const Duration(seconds: 3),
          ),
        );
        return;
      }

      showDialog(
        context: context,
      builder: (context) => AlertDialog(
        title: Text(
          title,
          style: TextStyle(
            color: successCount == totalCount
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
        ),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Widget _buildAnswerOptions() {
    if (_currentProblem == null) return const SizedBox.shrink();

    switch (_currentProblem!.problemType) {
      case 1:
      case 3:
      case 6:
        return _buildChoiceOptions();
      case 2:
        return _buildMultipleChoiceOptions();
      case 4:
        return _buildFillBlankInputs();
      case 5:
        return _buildShortAnswerInputs();
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _pickImages() async {
    try {
      final ImagePicker picker = ImagePicker();

      final remainingCount = _maxImageCount - _selectedImages.length;

      final List<XFile> images = await picker.pickMultiImage(
          limit: remainingCount,
          imageQuality: 80
      );

      if (images.isNotEmpty) {
        final uploadFutures = images.map((image) async {
          try {
            final file = File(image.path);
            final imageUrl = await RCImageApi.uploadImage(file);
            return {'image': image, 'url': imageUrl};
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('图片上传失败：${image.path}')),
              );
            }
            return null;
          }
        }).toList();

        final results = await Future.wait(uploadFutures);

        if (mounted) {
          setState(() {
            for (final result in results) {
              if (result != null && result['url'] != null) {
                _selectedImages.add(result['image'] as XFile);
                _uploadedImageUrls.add(result['url'] as String);
              }
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片失败：$e')),
        );
      }
    }
  }

  void _removeImage(int index) {
    setState(() {
      _selectedImages.removeAt(index);
      _uploadedImageUrls.removeAt(index);
    });
  }

  Widget _buildShortAnswerInputs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '请输入答案',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                onChanged: (value) {
                  _textAnswer = value;
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 32),
              onPressed: _pickImages,
              tooltip: '添加图片（最多 9 张）'
            ),
          ],
        ),
        if (_selectedImages.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 80,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _selectedImages.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(_selectedImages[index].path),
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        right: 4,
                        top: 4,
                        child: GestureDetector(
                          onTap: () => _removeImage(index),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.8),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFillBlankInputs() {
    if (_currentProblem == null) return const SizedBox.shrink();

    final body = _currentProblem!.body;
    final blanks = <String>[];
    final pattern = RegExp(r'\[填空\d*\]');
    final matches = pattern.allMatches(body);

    for (var match in matches) {
      blanks.add(match.group(0) ?? '');
    }

    if (blanks.isEmpty) {
      return TextField(
        decoration: const InputDecoration(
          hintText: '请输入答案',
          border: OutlineInputBorder(),
        ),
        onChanged: (value) {
          _textAnswer = value;
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(blanks.length, (index) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            decoration: InputDecoration(
              labelText: '填空${index + 1}',
              hintText: '请输入第${index + 1}个空的答案',
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              final answers = List<String>.from(_answer ?? []);
              while (answers.length <= index) {
                answers.add('');
              }
              answers[index] = value;
              _answer = answers;
            },
          ),
        );
      }),
    );
  }

  Widget _buildChoiceOptions() {
    if (_currentProblem == null) return const SizedBox.shrink();

    final options = _currentProblem!.options;
    if (options == null || options.isEmpty) {
      return const SizedBox.shrink();
    }

    return RadioGroup<String>(
      groupValue: _answer?.firstOrNull,
      onChanged: (value) {
        setState(() {
          _answer = value != null ? [value] : null;
        });
      },
      child: Column(
        children: options.map((option) {
          return RadioListTile<String>(
            value: option.key,
            title: Text('${option.key}. ${option.value}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            activeColor: Theme.of(context).colorScheme.primary,
            controlAffinity: ListTileControlAffinity.trailing,
            toggleable: true,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMultipleChoiceOptions() {
    if (_currentProblem == null) return const SizedBox.shrink();

    final options = _currentProblem!.options;
    if (options == null || options.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      children: options.map((option) {
        final key = option.key;
        final isSelected = (_answer ?? []).contains(key);
        return CheckboxListTile(
          value: isSelected,
          title: Text('$key. ${option.value}'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          activeColor: Theme.of(context).colorScheme.primary,
          controlAffinity: ListTileControlAffinity.trailing,
          onChanged: (value) {
            setState(() {
              final selectedKeys = _answer?.toSet() ?? <String>{};
              if (value == true) {
                selectedKeys.add(key);
              } else {
                selectedKeys.remove(key);
              }
              _answer = selectedKeys.toList();
            });
          },
        );
      }).toList(),
    );
  }

  Future<void> _saveImageToGallery(String imageUrl) async {
    try {
      final file = await DefaultCacheManager().getSingleFile(imageUrl);
      final bytes = await file.readAsBytes();

      await PhotoManager.editor.saveImage(
        bytes,
        filename: 'RainClassroom_${DateTime.now().millisecondsSinceEpoch}.jpg'
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片已保存到相册')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    }
  }

  // ==================== [新增] 导出整份 PPT 为 PDF ====================

  /// 当前 PPT 的所有幻灯片图片地址（去重、保序）
  List<String> _allSlideImageUrls() {
    final urls = <String>[];
    final seen = <String>{};
    for (final slide in _slideModels) {
      final url =
          (slide.coverAlt.trim().isNotEmpty ? slide.coverAlt : slide.cover)
              .trim();
      if (url.isEmpty || !seen.add(url)) continue;
      urls.add(url);
    }
    return urls;
  }

  /// 还有几张没缓存（只查磁盘，不触发下载）
  Future<int> _missingSlideCount(List<String> urls) async {
    var missing = 0;
    for (final url in urls) {
      final hit = await SlideImageStore.existing(widget.lessonId, url);
      if (hit == null) missing++;
    }
    return missing;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  /// 重新拉一遍没缓存完的页（AppBar 上那个刷新按钮）
  void _retryPrefetch() {
    if (_slideModels.isEmpty) return;
    AppLogger.i('PPT缓存', '手动重试缓存');
    SlideImagePrefetcher.start(
      widget.lessonId,
      SlideScanner.imageUrlsOf(_slideModels),
    );
  }

  /// 把当前这份 PPT 的所有页面合成一个 PDF
  ///
  /// - 图片走 [SlideImageStore]（磁盘缓存 + 并发去重），不另起一套缓存
  /// - 合成放在后台 isolate（`PptExporter.build`），不卡 UI
  /// - 完成后调起系统分享，可直接存到文件 / 发微信
  Future<void> _exportPresentationPdf() async {
    if (_isExporting) return;

    if (_slideModels.isEmpty) {
      _toast('还没有加载到 PPT');
      return;
    }

    // [防呆] 必须整份课件都缓存完才能导，否则会生成残缺 PDF。
    // 实测 bug：第二次进课堂时缓存还没开始下，导出只拿到 1/42 页。
    final urls = _allSlideImageUrls();
    final missing = await _missingSlideCount(urls);
    if (missing > 0) {
      final p = SlideImagePrefetcher.progress.value;
      AppLogger.w(
        '导出PDF',
        '拒绝导出：缓存未完成 ${p.label}（缺 $missing 张）',
      );
      _toast('课件还在缓存中（${p.label}），等缓存完成再转 PDF');
      return;
    }

    setState(() => _isExporting = true);

    try {
      // 1. 逐页取本地文件（上面已确认全部命中，这里只读盘、不下载）
      final paths = <String>[];
      for (final url in urls) {
        final file = await SlideImageStore.existing(widget.lessonId, url);
        if (file != null) paths.add(file.path);
      }

      // 2. 最终完整性校验：拿到的必须一页不少
      if (paths.length != urls.length) {
        AppLogger.w('导出PDF', '完整性校验失败：${paths.length}/${urls.length}');
        _toast('课件缓存发生变化（${paths.length}/${urls.length}），请等缓存完成');
        return;
      }
      AppLogger.i('导出PDF', '完整性校验通过：${paths.length}/${urls.length}');

      if (paths.isEmpty) {
        throw Exception('没有取到任何幻灯片图片');
      }

      // 2. 后台 isolate 合成
      final result = await PptExporter.build(paths);
      if (!result.ok || result.bytes == null) {
        throw Exception(result.error ?? '生成 PDF 失败');
      }

      // 3. 落盘 + 系统分享
      final dir = await getApplicationDocumentsDirectory();
      final raw =
          'PPT_${widget.title}_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final safe = raw.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
      final out = File('${dir.path}/$safe');
      await out.writeAsBytes(result.bytes!);

      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final origin =
          box != null ? box.localToGlobal(Offset.zero) & box.size : null;

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(out.path, mimeType: 'application/pdf')],
          subject: '${widget.title} 课件',
          text: '共 ${result.written} 页',
          sharePositionOrigin: origin,
        ),
      );

      AppLogger.i(
          '导出PDF', '已导出 ${result.written}/${result.total} 页 → ${out.path}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出 ${result.written}/${result.total} 页')),
        );
      }
    } catch (e) {
      AppLogger.e('导出PDF', '$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }
}

class TimelineEvent {
  final String type;
  final String? code;
  final String? title;
  final int? slideIndex;
  final int? total;
  final int? limit;
  final DateTime timestamp;
  final String? problemId;
  final String? presentationId;
  final int? problemDt;

  TimelineEvent({
    required this.type,
    required this.code,
    required this.title,
    this.slideIndex,
    this.total,
    this.limit,
    required this.timestamp,
    this.problemId,
    this.presentationId,
    this.problemDt,
  });
}
