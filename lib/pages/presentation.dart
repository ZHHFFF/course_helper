import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, WebSocket, File;

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
import '../utils/app_logger.dart';
import '../utils/network_error.dart';
import '../utils/ppt_exporter.dart';
import '../utils/storage.dart';
import 'widget/answer_search_dialog.dart';
import 'widget/suggested_answer_card.dart';
// [/新增]

/// 权限弹窗的超时兜底
///
/// 插件的 `requestNotificationPermission()` / `requestIgnoreBatteryOptimization()`
/// 都是 `startActivityForResult` 模式：Dart 侧的 Future 只在
/// `onRequestPermissionsResult` / `onActivityResult` 回来时才完成，**插件没有超时**。
/// Activity 一旦被系统重建，那个回调就永远不来了 → await 卡死。
const Duration _permissionTimeout = Duration(seconds: 30);

/// 「电池优化豁免」问过一次就不再问
const String _batteryOptAskedKey = 'foreground_service_battery_opt_asked';

@pragma('vm:entry-point')
void _startForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_WebSocketKeepAliveHandler());
}

class _WebSocketKeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class PresentationPage extends StatefulWidget {
  final String lessonId;
  final String title;

  const PresentationPage({
    super.key,
    required this.lessonId,
    required this.title,
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

  /// 已经自动预选过的指纹（避免覆盖用户的手动修改）
  final Set<String> _autoSelected = {};

  /// 已经自动提交过的指纹（防重复提交）
  final Set<String> _autoSubmitted = {};

  /// 正在自动提交中
  bool _autoSubmitting = false;

  /// 当前作答区（[_answer] / [_textAnswer]）属于哪道题
  ///
  /// `_answer` 是单个字段、不分题目存，切题时必须清空，
  /// 否则 A 题选完翻到 B 题，B 题会显示 A 的答案 ——
  /// 自动提交就会把 A 的答案交到 B 上。
  String? _answerOwnerProblemId;

  /// 切题时清空作答区（同一道题不重复清，免得把用户刚填的擦掉）
  void _resetAnswerIfProblemChanged() {
    final id = _currentProblem?.problemId;
    if (id == _answerOwnerProblemId) return;
    _answerOwnerProblemId = id;
    _answer = null;
    _textAnswer = null;
    _uploadedImageUrls.clear();
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

    // 进课堂先按策略清一遍过期缓存（只 stat 一层目录，很便宜）
    unawaited(CourseCache.cleanup());
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
    if (_autoSelected.contains(hash)) return;
    // 用户已经自己填过了 → 不覆盖
    if (_isAnswerFilled()) return;

    final cached = _suggested[hash];
    if (cached == null || !cached.usable || cached.results.isEmpty) return;

    final scanned = _scan.byHash[hash];
    if (scanned == null) return;

    _autoSelected.add(hash);
    _fillAnswerSilently(scanned.question, cached.results.first);
  }

  /// 静默填充（不弹 SnackBar，避免自动答题时刷屏）
  void _fillAnswerSilently(
    StandardizedQuestion question,
    AnswerSearchResult picked,
  ) {
    final problem = _currentProblem;
    if (problem == null || !mounted) return;

    final options = (problem.options ?? const [])
        .map((o) => StandardizedOption(key: o.key, value: o.value))
        .toList();
    final keys = picked.matchOptionKeys(options);

    setState(() {
      if (keys.isNotEmpty) {
        _answer = keys;
      } else if (!question.isChoice && picked.answer.trim().isNotEmpty) {
        _textAnswer = picked.answer.trim();
      } else {
        return; // 没匹配上，什么都不做
      }
    });

    AppLogger.i(
      '自动答题',
      '已自动预选：${keys.isNotEmpty ? keys.join("、") : picked.answer}'
          '（${picked.source}）',
    );
  }

  // ==================== [新增] 自动提交 ====================

  /// 老师发布题目（unlockproblem）后，按设置决定是否自动提交
  ///
  /// 流程：定位题目所在页 → 切过去 → 确保答案已填 → 随机延迟 → 提交
  Future<void> _maybeAutoSubmit(String problemId) async {
    await AutoAnswerSetting.ensureLoaded();
    if (!AutoAnswerSetting.autoSubmit.value) return;
    if (_autoSubmitting) return;
    if (_autoSubmitted.contains(problemId)) return;

    final index = await _waitForProblemSlide(problemId);
    if (index < 0) {
      AppLogger.w('自动答题', '发布的题目 $problemId 在这份 PPT 里找不到对应页');
      return;
    }

    // 切到题目所在页（_toSlide 是 1-based）
    if (index != _currentSlideIndex) {
      _toSlide(index + 1, animate: false);
      // 给 setState / 布局一点时间，让 _currentProblem 和 _currentHash 生效
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!mounted) return;

    final hash = _currentHash;
    if (hash == null) {
      AppLogger.w('自动答题', '第 ${index + 1} 页没识别到题目，放弃自动提交');
      return;
    }

    // 还没填就现场补填一次（预搜没赶上时走这条路）
    if (!_isAnswerFilled()) {
      final cached = _suggested[hash];
      if (cached == null || !cached.usable || cached.results.isEmpty) {
        AppLogger.w('自动答题', '题目 $problemId 还没有可用答案，放弃自动提交');
        return;
      }
      final scanned = _scan.byHash[hash];
      if (scanned == null) return;
      _fillAnswerSilently(scanned.question, cached.results.first);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    if (!mounted) return;
    if (!_isAnswerFilled()) {
      AppLogger.w('自动答题', '答案没能填上，放弃自动提交');
      return;
    }

    // 拟人化延迟：避免「老师刚发就秒交」这种明显的脚本特征
    final delay = AutoAnswerSetting.randomDelay();
    AppLogger.i('自动答题', '${delay.inMilliseconds}ms 后自动提交题目 $problemId');
    await Future<void>.delayed(delay);
    if (!mounted || _autoSubmitting) return;

    _autoSubmitting = true;
    _autoSubmitted.add(problemId);
    try {
      await _submitAnswer();
      AppLogger.i('自动答题', '已自动提交题目 $problemId');
    } catch (e) {
      AppLogger.e('自动答题', '自动提交失败：$e');
      _autoSubmitted.remove(problemId); // 失败了允许下次重试
    } finally {
      _autoSubmitting = false;
    }
  }

  /// 题目在 PPT 里的页号（0-based），找不到返回 -1
  int _indexOfProblem(String problemId) {
    for (var i = 0; i < _slideModels.length; i++) {
      if (_slideModels[i].problem?.problemId == problemId) return i;
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
    return -1;
  }

  /// 当前页的答案是否已经填好
  bool _isAnswerFilled() {
    if (_currentProblem == null) return false;
    final keys = _answer;
    if (keys != null && keys.isNotEmpty) return true;
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
    final rawOptions = _currentProblem?.options ?? const [];
    final options = rawOptions
        .map((o) => StandardizedOption(key: o.key, value: o.value))
        .toList();

    final keys = picked.matchOptionKeys(options);

    String message;
    if (keys.isNotEmpty) {
      setState(() {
        _answer = keys;
      });
      message = '已填入 ${keys.join('、')}，请核对后提交';
    } else if (!question.isChoice && picked.answer.trim().isNotEmpty) {
      setState(() {
        _textAnswer = picked.answer.trim();
      });
      message = '已填入答案文本，请核对后提交';
    } else {
      message = '未能匹配到选项，请手动选择';
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
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
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_autoSelectIfCurrent(h));
        });
      }
    }
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
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'websocket_service',
          channelName: 'WebSocket Background Service',
          channelDescription: 'Keep WebSocket connection alive'
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(5000),
          allowWifiLock: true
        ),
      );

      // 返回值必须看。插件内部会等 5 秒确认 isRunningService 变成 true，
      // 起不来就返回 ServiceRequestFailure（ServiceTimeoutException）。
      // 原来直接 await 把返回值丢掉，失败就被无声吞掉了 ——
      // AndroidManifest.xml 漏声明 <service> 正是这样藏了这么久。
      final ServiceRequestResult result;
      if (await FlutterForegroundTask.isRunningService) {
        result = await FlutterForegroundTask.restartService();
      } else {
        result = await FlutterForegroundTask.startService(
          notificationTitle: '课堂助手',
          notificationText: '正在保持 WebSocket 连接...',
          callback: _startForegroundCallback,
        );
      }

      switch (result) {
        case ServiceRequestSuccess():
          AppLogger.i('ForegroundService', '前台服务已启动');
        case ServiceRequestFailure(:final error):
          AppLogger.e(
            'ForegroundService',
            '前台服务启动失败：$error。检查 AndroidManifest.xml 是否声明了 '
                'com.pravera.flutter_foreground_task.service.ForegroundService',
          );
          // 服务都没起来，权限申请也就没意义了
          return;
      }
    } catch (e, s) {
      AppLogger.e('ForegroundService', '前台服务启动异常：$e');
      debugPrint('前台服务启动异常：$e\n$s');
      return;
    }

    // 服务已经在跑了，再来处理权限 —— 这一步再怎么出问题都影响不到服务
    unawaited(_requestForegroundPermissions());
  }

  /// 申请前台服务需要的两个权限（**必须在服务启动之后调用**）
  Future<void> _requestForegroundPermissions() async {
    if (!Platform.isAndroid) return;

    // 1) 通知权限
    // Android 13+ 不申请的话服务照样在跑，但那条常驻通知不会显示 ——
    // 「拉通知栏看有没有通知」这个验证手段就会给出假阴性。
    // 只在 denied 时申请，permanently_denied 就不反复弹窗了。
    try {
      final current = await FlutterForegroundTask.checkNotificationPermission()
          .timeout(_permissionTimeout);
      if (current == NotificationPermission.denied) {
        final after =
            await FlutterForegroundTask.requestNotificationPermission()
                .timeout(_permissionTimeout);
        AppLogger.i('ForegroundService', '通知权限申请结果：$after');
        if (after == NotificationPermission.granted) {
          // 通知是在没权限的时候推出去的，现在有权限了得重新推一次才会显示
          await _refreshServiceNotification();
        }
      }
    } catch (e) {
      AppLogger.w('ForegroundService', '申请通知权限失败或超时：$e');
    }

    // 2) 电池优化豁免
    // 国产 ROM 上这个对后台存活影响很大，值得问；但只在没问过的时候问一次，
    // 否则每次进课堂都弹一个系统设置页，拒绝之后还会一直弹。
    try {
      if (StorageManager.prefs.getBool(_batteryOptAskedKey) ?? false) return;

      final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations
          .timeout(_permissionTimeout);
      if (ignoring) return;

      await StorageManager.prefs.setBool(_batteryOptAskedKey, true);
      await FlutterForegroundTask.requestIgnoreBatteryOptimization()
          .timeout(_permissionTimeout);
    } catch (e) {
      AppLogger.w('ForegroundService', '申请电池优化豁免失败或超时：$e');
    }
  }

  /// 权限后补上来时，让那条常驻通知重新推一次
  Future<void> _refreshServiceNotification() async {
    try {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.updateService(
        notificationTitle: '课堂助手',
        notificationText: '正在保持 WebSocket 连接...',
      );
    } catch (e) {
      AppLogger.w('ForegroundService', '刷新前台通知失败：$e');
    }
  }

  Future<void> _stopForegroundService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        final result = await FlutterForegroundTask.stopService();
        if (result is ServiceRequestFailure) {
          AppLogger.w('ForegroundService', '前台服务停止失败：${result.error}');
        }
      }
    } catch (e) {
      AppLogger.w('ForegroundService', '前台服务停止异常：$e');
    }
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
      debugPrint('WebSocket 连接失败：$e');
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
        _resetAnswerIfProblemChanged();
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
    try {
      final data = jsonDecode(message);
      final op = data['op'];

      debugPrint('WebSocket S2C：$message');

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
    } catch (e) {
      debugPrint('解析消息失败：$e');
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
        // 整份 PPT 元数据落盘：老师来回切同一份时不用重复请求
        unawaited(PptCache.save(widget.lessonId, presentationId, pptData));
        presentation = Presentation.fromJson(pptData);
      }
    } catch (e) {
      debugPrint('加载 PPT 失败：$e');
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
        .where((item) => !(_suggested[item.hash]?.isFresh() ?? false))
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
              _resetAnswerIfProblemChanged();
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
                                _resetAnswerIfProblemChanged();
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
                                          if (_currentProblem != null && _unlockedProblemIds.contains(_currentProblem!.problemId) && _countdownSeconds != null)
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
                                      if ((_currentProblem != null && _unlockedProblemIds.contains(_currentProblem!.problemId)) ||
                                          (_timelineProblemId != null && _unlockedProblemIds.contains(_timelineProblemId!))) ...[
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

  Future<void> _submitAnswer() async {
    final problemId = _currentProblem?.problemId ?? _timelineProblemId;
    if (problemId == null) return;

    final problemType = _currentProblem?.problemType ?? 0;
    final problemDt = _currentProblem?.dt;

    if (_answer == null && _textAnswer == null && _uploadedImageUrls.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先选择或填写答案')),
        );
      }
      return;
    }

    final isTimeout = _countdownSeconds != null && _countdownSeconds! <= 0;

    await _submitForAllAccounts(problemId, problemType, _uploadedImageUrls, isTimeout, problemDt);
  }

  Future<void> _submitForAllAccounts(String problemId, int problemType, List<String>? imageUrls, bool isTimeout, int? problemDt) async {
    final allAccounts = AccountManager.allAccounts;

    if (allAccounts.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可用的账号')),
        );
      }
      return;
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

    _showSubmitResult(
      successCount,
      allAccounts.length,
      failedAccounts,
      networkFailCount: networkFailCount,
    );

    setState(() {
      _countdownSeconds = 0;
      _selectedImages.clear();
      _uploadedImageUrls.clear();
    });
  }

  void _showSubmitResult(
    int successCount,
    int totalCount,
    List<String> failedAccounts, {
    int networkFailCount = 0,
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
