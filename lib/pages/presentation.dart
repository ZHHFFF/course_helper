import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket, File;
import 'dart:math' as math;

import '../api/course.dart';
import '../api/image.dart';
import '../api/api_service.dart';
import '../models/presentation.dart';
import '../session/account.dart';
import '../platform.dart';
// [新增] 答案检索模块导入
import '../api/answer_search.dart';
import '../models/answer_result.dart';
import '../setting/auto_answer_setting.dart';
import '../utils/app_logger.dart';
import '../utils/network_error.dart';
import '../utils/ppt_exporter.dart';
import 'widget/answer_search_dialog.dart';
// [/新增]

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

class _PresentationPageState extends State<PresentationPage> {
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

  // ============ [新增] PPT 预取 ============
  bool _isPrefetching = false;
  int _prefetchDone = 0;
  int _prefetchTotal = 0;

  // ============ [新增] 预搜答案 / 自动提交 ============
  /// problemId -> 已搜好的答案
  final Map<String, AnswerSearchResult> _preSearchedAnswers = {};
  /// 正在搜的 problemId，防止重复请求
  final Set<String> _preSearching = {};
  /// 已经自动提交过的 problemId，防止重复提交
  final Set<String> _autoSubmitted = {};
  bool _isExporting = false;

  // ============ [新增] 诊断：预搜到底提前了多少 ============
  /// 进入课堂（收到 hello）的时刻
  DateTime? _lessonEnteredAt;
  /// problemId -> 预搜完成的时刻
  final Map<String, DateTime> _preSearchedAt = {};
  /// problemId -> 老师发布的时刻（unlockproblem）
  final Map<String, DateTime> _unlockedAt = {};

  @override
  void initState() {
    super.initState();
    AutoAnswerSetting.ensureLoaded();
    _initialize();
    _startForegroundService();
  }

  @override
  void dispose() {
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
    _connectWebSocket();
  }

  // [新增] 搜索答案 - 从当前题目提取题干和选项，调用检索模块
  // 检索结果可一键回填到当前作答（只回填，不自动提交）
  Future<void> _searchAnswer() async {
    if (_currentProblem == null) return;

    final question = AnswerSearchApi.fromRainClassroomProblem(
      _currentProblem!,
      slideText: _currentSlideText(),
      imageUrl: _currentSlideCover(),
    );
    if (!mounted) return;

    final picked = await showDialog<AnswerSearchResult>(
      context: context,
      builder: (context) => AnswerSearchDialog(question: question),
    );
    if (picked == null || !mounted) return;

    _applyPickedAnswer(picked, question);
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

  /// 当前 PPT 页里的所有文字（题干为空时兜底用）
  String _currentSlideText() {
    if (_slides.isEmpty ||
        _currentSlideIndex < 0 ||
        _currentSlideIndex >= _slides.length) {
      return '';
    }
    final shapes = _slides[_currentSlideIndex]['shapes'] as List?;
    if (shapes == null || shapes.isEmpty) return '';

    final buffer = StringBuffer();
    for (final shape in shapes) {
      final text = (shape is Shape ? shape.text : null)?.trim() ?? '';
      if (text.isEmpty) continue;
      buffer.writeln(text);
    }
    return buffer.toString().trim();
  }

  /// 当前 PPT 页的图片地址（题目只写在 PPT 上时，交给多模态模型识别）
  String _currentSlideCover() {
    if (_slides.isEmpty ||
        _currentSlideIndex < 0 ||
        _currentSlideIndex >= _slides.length) {
      return '';
    }
    final slide = _slides[_currentSlideIndex];
    final coverAlt = (slide['coverAlt'] as String?)?.trim() ?? '';
    if (coverAlt.isNotEmpty) return coverAlt;
    return (slide['cover'] as String?)?.trim() ?? '';
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

  Future<void> _startForegroundService() async {
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

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

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        notificationTitle: '课堂助手',
        notificationText: '正在保持 WebSocket 连接...',
        callback: _startForegroundCallback,
      );
    }
  }

  Future<void> _stopForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
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
      _currentLessonSlideIndex = targetIndex;
      _currentSlideIndex = targetIndex;
      if (targetIndex < _slides.length) {
        _currentProblem = _slides[targetIndex]['problem'];
      }
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
          // [诊断] 记录进课堂时刻，用来算「预搜比发布早了多少」
          _lessonEnteredAt ??= DateTime.now();
          AppLogger.i('诊断', '进入课堂，开始计时');
          break;

        case 'unlockproblem':
          final problemData = data['problem'];
          if (problemData != null) {
            final problemId = problemData['prob']?.toString();
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
            }

            // [新增] 题目刚发布：填入预搜答案，并按设置决定是否自动提交
            if (problemId != null && problemId.isNotEmpty) {
              unawaited(_handleProblemPublished(
                problemId,
                dt: dt is int ? dt : null,
              ));
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

    try {
      final pptData = await RCCourseApi().getPresentation(presentationId);
      if (pptData != null) {
        final presentation = Presentation.fromJson(pptData);
        setState(() {
          _slides = presentation.slides
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
          _totalCount = presentation.slides.length;
          _currentPresentationId = presentationId;
          if (_slides.isNotEmpty && _currentSlideIndex >= 0 && _currentSlideIndex < _slides.length) {
            _currentProblem = presentation.slides[_currentSlideIndex].problem;
          }
          _isLoading = false;
        });

        // [新增] 幻灯片就绪后，后台并行做两件事：
        //   1. 把整份 PPT 图片预取到本地缓存（翻页秒开）
        //   2. 把所有题目的答案提前搜好（老师一发布就能直接交）
        unawaited(_prefetchSlideImages());
        unawaited(_preSearchAllAnswers());
      }
    } catch (e) {
      debugPrint('加载 PPT 失败：$e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  // ==================== [新增] PPT 图片预取 ====================

  /// 取某一页的图片地址（优先 coverAlt）
  String _slideImageUrl(Map<String, dynamic> slide) {
    final alt = (slide['coverAlt'] as String?)?.trim() ?? '';
    if (alt.isNotEmpty) return alt;
    return (slide['cover'] as String?)?.trim() ?? '';
  }

  /// 取某一页里的全部文字（题干为空时兜底）
  String _slideTextAt(int index) {
    if (index < 0 || index >= _slides.length) return '';
    final shapes = _slides[index]['shapes'] as List?;
    if (shapes == null || shapes.isEmpty) return '';
    final buffer = StringBuffer();
    for (final shape in shapes) {
      final text = (shape is Shape ? shape.text : null)?.trim() ?? '';
      if (text.isEmpty) continue;
      buffer.writeln(text);
    }
    return buffer.toString().trim();
  }

  /// 把整份 PPT 的图片预取到本地缓存 —— 翻页时就不用再等网络了
  Future<void> _prefetchSlideImages() async {
    await AutoAnswerSetting.ensureLoaded();
    if (!AutoAnswerSetting.prefetch.value) return;
    if (_isPrefetching) return;

    final urls = <String>[];
    final seen = <String>{};
    for (final slide in _slides) {
      final url = _slideImageUrl(slide);
      if (url.isNotEmpty && seen.add(url)) urls.add(url);
    }
    if (urls.isEmpty) return;

    setState(() {
      _isPrefetching = true;
      _prefetchTotal = urls.length;
      _prefetchDone = 0;
    });

    AppLogger.i('PPT预取', '开始预取 ${urls.length} 张图片');

    final cache = DefaultCacheManager();
    const concurrency = 3; // 限流，别把带宽打满影响课堂其它请求

    for (var i = 0; i < urls.length; i += concurrency) {
      if (!mounted) return;
      final batch = urls.skip(i).take(concurrency).toList();
      await Future.wait(batch.map((url) async {
        try {
          await cache.downloadFile(url);
        } catch (e) {
          debugPrint('预取图片失败：$url（$e）');
        }
      }));
      if (!mounted) return;
      setState(() {
        _prefetchDone = math.min(i + concurrency, urls.length);
      });
    }

    if (!mounted) return;
    setState(() {
      _isPrefetching = false;
    });
    AppLogger.i('PPT预取', '预取完成 $_prefetchDone/$_prefetchTotal');
  }

  // ==================== [新增] 预搜答案 ====================

  /// 把一道题标准化成检索问题（带上所在页文字和图片，题目只写在 PPT 上时交给多模态模型）
  StandardizedQuestion _questionOf(Problem problem) {
    final idx = _slides.indexWhere(
      (s) => (s['problem'] as Problem?)?.problemId == problem.problemId,
    );
    String slideText = '';
    String imageUrl = '';
    if (idx >= 0) {
      slideText = _slideTextAt(idx);
      imageUrl = _slideImageUrl(_slides[idx]);
    }
    return AnswerSearchApi.fromRainClassroomProblem(
      problem,
      slideText: slideText,
      imageUrl: imageUrl,
    );
  }

  /// 进课堂后把所有题目的答案提前搜好（不等老师发布）
  Future<void> _preSearchAllAnswers() async {
    await AutoAnswerSetting.ensureLoaded();
    if (!AutoAnswerSetting.preSearch.value) return;

    final problems = <Problem>[];
    for (final slide in _slides) {
      final p = slide['problem'];
      if (p is Problem &&
          p.problemId.isNotEmpty &&
          !_preSearchedAnswers.containsKey(p.problemId)) {
        problems.add(p);
      }
    }
    if (problems.isEmpty) return;

    AppLogger.i('预搜答案', '开始预搜 ${problems.length} 道题');

    // 串行搜：课堂上可能同时好几道题，并发容易把 API 打限流
    for (final problem in problems) {
      if (!mounted) return;
      await _preSearchOne(problem);
    }
    AppLogger.i('预搜答案', '预搜结束，已缓存 ${_preSearchedAnswers.length} 条');
  }

  /// 搜一道题并缓存结果
  Future<void> _preSearchOne(Problem problem) async {
    final id = problem.problemId;
    if (id.isEmpty) return;
    if (_preSearchedAnswers.containsKey(id)) return;
    if (_preSearching.contains(id)) return;

    _preSearching.add(id);
    try {
      final question = _questionOf(problem);
      if (!question.isUsable) {
        AppLogger.w('预搜答案', '第 $id 题题干为空且没有课件图片，跳过');
        return;
      }

      final results = await AnswerSearchApi.search(question);
      if (results.isEmpty) {
        AppLogger.w('预搜答案', '第 $id 题没搜到答案');
        return;
      }

      final best = results.first;
      _preSearchedAnswers[id] = best;
      _preSearchedAt[id] = DateTime.now();
      AppLogger.i('预搜答案', '第 $id 题已搜到：${best.answer}（来源 ${best.source}）');

      // 正好是当前题目时顺手填上
      if (mounted && _currentProblem?.problemId == id) {
        _applyAnswerToState(best, question, silent: true);
      }
    } catch (e) {
      AppLogger.e('预搜答案', '第 $id 题检索失败：$e');
    } finally {
      _preSearching.remove(id);
    }
  }

  // ==================== [新增] 自动填入 / 自动提交 ====================

  /// 把检索结果写进作答状态
  ///
  /// [silent] 为 true 时不弹 SnackBar（预搜/自动提交场景不需要打扰用户）
  /// 返回是否成功填入了内容
  bool _applyAnswerToState(
    AnswerSearchResult picked,
    StandardizedQuestion question, {
    bool silent = false,
  }) {
    final rawOptions = _currentProblem?.options ?? const [];
    final options = rawOptions
        .map((o) => StandardizedOption(key: o.key, value: o.value))
        .toList();

    final keys = picked.matchOptionKeys(options);

    bool filled = false;
    String message;

    if (keys.isNotEmpty) {
      setState(() {
        _answer = keys;
      });
      filled = true;
      message = '已填入 ${keys.join('、')}';
    } else if (!question.isChoice && picked.answer.trim().isNotEmpty) {
      setState(() {
        _textAnswer = picked.answer.trim();
      });
      filled = true;
      message = '已填入答案文本';
    } else {
      message = '未能匹配到选项，请手动选择';
    }

    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
    }
    return filled;
  }

  /// 老师发布题目（unlockproblem）后：填入预搜答案 → 自动提交
  Future<void> _handleProblemPublished(String problemId, {int? dt}) async {
    await AutoAnswerSetting.ensureLoaded();

    // [诊断] 记录发布时刻，并算出「预搜比发布早了多少」
    final unlockedAt = DateTime.now();
    _unlockedAt[problemId] = unlockedAt;
    _logPreSearchLeadTime(problemId, unlockedAt);

    // 切到题目所在那一页，保证 _currentProblem 指向正确的题
    final idx = _slides.indexWhere(
      (s) => (s['problem'] as Problem?)?.problemId == problemId,
    );
    if (idx >= 0 && idx != _currentSlideIndex) {
      _toSlide(idx + 1, animate: false);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (!mounted) return;

    if (dt != null && _currentProblem != null) {
      _currentProblem = _currentProblem!.copyWith(dt: dt);
    }

    // 没预搜到就现场补一次
    var cached = _preSearchedAnswers[problemId];
    if (cached == null && _currentProblem != null) {
      await _preSearchOne(_currentProblem!);
      cached = _preSearchedAnswers[problemId];
    }
    if (!mounted) return;

    if (cached != null && _currentProblem != null) {
      final question = _questionOf(_currentProblem!);
      _applyAnswerToState(cached, question, silent: true);
    }

    if (!AutoAnswerSetting.autoSubmit.value) return;
    if (_autoSubmitted.contains(problemId)) return;

    // 拟人化延迟，避免「秒交」被风控识别
    final delay = AutoAnswerSetting.randomDelay();
    AppLogger.i('自动答题', '第 $problemId 题 ${delay.inMilliseconds}ms 后自动提交');
    await Future<void>.delayed(delay);
    if (!mounted) return;

    if (_answer == null && _textAnswer == null && _uploadedImageUrls.isEmpty) {
      AppLogger.w('自动答题', '第 $problemId 题没有可提交的答案，跳过自动提交');
      return;
    }

    _autoSubmitted.add(problemId);
    await _submitAnswer();
  }

  /// [诊断] 打印「预搜比老师发布早了多少」
  ///
  /// 这是判断预搜方案是否成立的关键指标，真机验证时看这一条就够了：
  /// - 早 → 预搜有效，自动提交基本能赶上
  /// - 晚 → 说明题目在发布前拿不到，得改策略
  void _logPreSearchLeadTime(String problemId, DateTime unlockedAt) {
    final enteredAt = _lessonEnteredAt;
    final searchedAt = _preSearchedAt[problemId];

    final unlockSinceEnter = enteredAt == null
        ? null
        : unlockedAt.difference(enteredAt).inMilliseconds / 1000.0;

    if (searchedAt == null) {
      AppLogger.w(
        '诊断',
        '题目 $problemId：发布时【还没有】预搜结果'
        '（进课堂 ${unlockSinceEnter?.toStringAsFixed(1) ?? '?'}s 后发布）'
        '→ 这次走的是现场补搜',
      );
      return;
    }

    final searchSinceEnter = enteredAt == null
        ? null
        : searchedAt.difference(enteredAt).inMilliseconds / 1000.0;
    final lead = unlockedAt.difference(searchedAt).inMilliseconds / 1000.0;

    if (lead >= 0) {
      AppLogger.i(
        '诊断',
        '题目 $problemId：预搜比发布【早 ${lead.toStringAsFixed(1)}s】'
        '（进课堂 ${searchSinceEnter?.toStringAsFixed(1) ?? '?'}s 搜好，'
        '${unlockSinceEnter?.toStringAsFixed(1) ?? '?'}s 时老师发布）',
      );
    } else {
      AppLogger.w(
        '诊断',
        '题目 $problemId：预搜比发布【晚 ${(-lead).toStringAsFixed(1)}s】'
        '（${unlockSinceEnter?.toStringAsFixed(1) ?? '?'}s 发布，'
        '${searchSinceEnter?.toStringAsFixed(1) ?? '?'}s 才搜好）'
        '→ 说明题目在发布前拿不到',
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
                      child: Image.network(
                        cover,
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
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: _currentSlideIndex == _currentLessonSlideIndex
                ? RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                      children: [
                        TextSpan(
                          text: '当前 ',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        TextSpan(
                          text: '${_currentSlideIndex + 1}/$_totalCount',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : Text(
                    '${_currentSlideIndex + 1}/$_totalCount',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
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
          // [新增] PPT 预取进度
          if (_isPrefetching && _prefetchTotal > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '缓存 $_prefetchDone/$_prefetchTotal',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
            ),
          // [新增] 导出 PDF
          IconButton(
            tooltip: '导出整份 PPT 为 PDF',
            onPressed: _isExporting ? null : _exportPresentationPdf,
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
          ),
          // [新增] 自动答题设置
          IconButton(
            tooltip: '自动答题设置',
            onPressed: _showAutoAnswerSettings,
            icon: const Icon(Icons.auto_awesome_outlined),
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
                                        child: Image.network(
                                          cover,
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
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: _currentSlideIndex == _currentLessonSlideIndex
                                  ? RichText(
                                      text: TextSpan(
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        children: [
                                          TextSpan(
                                            text: '当前 ',
                                            style: TextStyle(
                                              color: Theme.of(context).colorScheme.primary,
                                            ),
                                          ),
                                          TextSpan(
                                            text: '${_currentSlideIndex + 1}/$_totalCount',
                                            style: TextStyle(
                                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : Text(
                                      '${_currentSlideIndex + 1}/$_totalCount',
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
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
      final targetIndex = slideIndex;

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

  Future<void> _exportPresentationPdf() async {
    if (_isExporting) return;

    if (_slides.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有加载到 PPT')),
      );
      return;
    }

    setState(() => _isExporting = true);

    try {
      // 1. 把每一页的图片取到本地（缓存里已经有的话直接命中）
      final cache = DefaultCacheManager();
      final paths = <String>[];
      final seen = <String>{};
      for (final slide in _slides) {
        final url = _slideImageUrl(slide);
        if (url.isEmpty || !seen.add(url)) continue;
        try {
          final file = await cache.getSingleFile(url);
          paths.add(file.path);
        } catch (e) {
          debugPrint('导出 PDF：取图失败 $url（$e）');
        }
      }

      if (paths.isEmpty) {
        throw Exception('没有取到任何幻灯片图片');
      }

      // 2. 在后台 isolate 里合成 PDF
      final result = await PptExporter.build(paths);
      if (!result.ok || result.bytes == null) {
        throw Exception(result.error ?? '生成 PDF 失败');
      }

      // 3. 落盘 + 调起系统分享
      final dir = await getApplicationDocumentsDirectory();
      final rawName = 'PPT_${widget.title}_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final safeName = rawName.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
      final out = File('${dir.path}/$safeName');
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

      AppLogger.i('导出PDF', '已导出 ${result.written}/${result.total} 页 → ${out.path}');
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

  // ==================== [新增] 自动答题设置面板 ====================

  Future<void> _showAutoAnswerSettings() async {
    await AutoAnswerSetting.ensureLoaded();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('自动答题设置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AutoAnswerSetting.preSearch,
                builder: (context, value, _) => SwitchListTile(
                  value: value,
                  onChanged: (v) => AutoAnswerSetting.setPreSearch(v),
                  title: const Text('进课堂即预搜答案'),
                  subtitle: const Text('不等老师发布，先把所有题目的答案搜好'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: AutoAnswerSetting.autoSubmit,
                builder: (context, value, _) => SwitchListTile(
                  value: value,
                  onChanged: (v) => AutoAnswerSetting.setAutoSubmit(v),
                  title: const Text('发布后自动提交'),
                  subtitle: const Text('老师一发题就自动交，不用手动点提交'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: AutoAnswerSetting.prefetch,
                builder: (context, value, _) => SwitchListTile(
                  value: value,
                  onChanged: (v) => AutoAnswerSetting.setPrefetch(v),
                  title: const Text('预取整份 PPT 图片'),
                  subtitle: const Text('进课堂后后台下载全部幻灯片，翻页秒开'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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
