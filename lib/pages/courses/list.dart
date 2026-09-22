import 'package:flutter/material.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:collection/collection.dart';
// [新增] Miuix：顶栏 / 脚手架按「所有规范都按 miuix」迁移
import 'package:flutter_miuix/miuix.dart';

import '../../platform.dart';
import '../../api/course.dart';
import '../../api/api_service.dart';
import '../../session/account.dart';
import '../../models/course.dart';
import '../../models/active.dart';
import '../widget/scan.dart';
import '../widget/avatar.dart';
// [新增] 悬浮玻璃底栏的底部占位高度（几何常量模块）
import '../widget/miuix_nav_metrics.dart';
// [新增] 开发期压测假数据（--dart-define=SEED_TEST_DATA=N 时才有内容）
import '../../utils/test_data_seeder.dart';
// [新增] 底栏「悬浮 / 贴边」形态（脚手架要按它算底部占位）
import '../../setting/navbar_setting.dart';
import '../actives/sign_in/sign_in.dart';
import '../actives/topic_discuss.dart';
import '../actives/quiz.dart';
import '../actives/evaluate.dart';
import '../actives/vote.dart';
import '../actives/questionnaire.dart';
import 'content.dart';
import '../presentation.dart';


class CoursesPage extends StatefulWidget {
  const CoursesPage({super.key});

  @override
  State<CoursesPage> createState() => _CoursesPageState();

  static void navigateToActive(BuildContext context, Active active, String courseId, String classId, String cpi) {
    if (!active.status) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该活动已结束')),
      );
      return;
    }

    switch (active.activeType) {
      case ActiveType.signIn:
      case ActiveType.signOut:
      case ActiveType.scheduledSignIn:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => SignInPage(
              active: active,
              courseId: courseId,
              classId: classId,
              cpi: cpi
            ),
          ),
        );
        break;
      
      case ActiveType.topicDiscuss:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TopicDiscussPage(active: active),
          ),
        );
        break;
      
      case ActiveType.quiz:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => QuizPage(
              active: active,
              courseId: courseId,
              classId: classId
            ),
          ),
        );
        break;
      
      case ActiveType.evaluation:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => EvaluatePage(
              active: active,
              courseId: courseId,
              classId: classId
            ),
          ),
        );
        break;
      
      case ActiveType.vote:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VotePage(
              active: active,
              courseId: courseId,
              classId: classId
            ),
          ),
        );
        break;

      case ActiveType.questionnaire:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => QuestionnairePage(
              active: active,
              courseId: courseId,
              classId: classId
            ),
          ),
        );
        break;
      
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('该活动类型暂不支持'),
          ),
        );
    }
  }
}

final GlobalKey coursesPageKey = GlobalKey();

class _CoursesPageState extends State<CoursesPage> with WidgetsBindingObserver {
  List<Course> _courses = [];
  bool _isLoading = true;
  StreamSubscription? _accountChangeSubscription;
  Timer? _refreshTimer;
  List<dynamic> _lastOnLessonCourses = [];
  bool _isVisible = false;

  /// 顶栏「滚动折叠」的行为对象。
  ///
  /// ⚠️ 必须**只创建一次**（放在 State 字段里，不能在 `build()` 里 new）：
  /// 它内部持有 `MiuixTopAppBarState`，也就是当前折叠进度。每次重建都换一个
  /// 新实例的话，折叠进度会被反复重置回「完全展开」，表现为**滚不动 / 一松手
  /// 就弹回大标题**。
  late final MiuixExitUntilCollapsedScrollBehavior _topBarBehavior =
      miuixScrollBehavior();

  /// 列表顶部留白（= 顶栏**展开态**高度），只记最大值、不跟随折叠回缩。
  ///
  /// ⚠️ 这里**不能**直接用 `contentPadding.top`。折叠量是滚动位置的纯函数
  /// （源码注释：`heightOffset = -(pixels - minScrollExtent)`），于是：
  ///
  /// ```text
  /// item 屏上 y = padding.top − scrollOffset
  /// ```
  ///
  /// 若 `padding.top` 也跟着折叠变小，就变成 `(142−s) − s = 142−2s` ——
  /// 内容会以**两倍速**往栏底钻，跟栏的收缩完全脱节（经典的「双重滚动」）。
  /// 固定成展开态高度后：`142 − s` 恰好等于栏的底边 → 内容始终贴着栏底走。
  ///
  /// 副作用：`MiuixScaffold` 的 `contentPadding` 每帧都在变 → 内容每帧重建。
  /// 但 ListView 的 padding 是常量，RenderObject 不会真的重排，代价可接受。
  double _topBarInset = 0;

  void refreshCourses() {
    _loadCourses();
  }

  void onVisibilityChanged(bool visible) {
    _isVisible = visible;
    if (visible) {
      _startPeriodicRefresh();
    } else {
      _refreshTimer?.cancel();
    }
  }

  /// 使用在线课堂数据更新课程列表
  void updateWithOnLessonCourses(List<Map<String, dynamic>>? onLessonCourses) {
    _loadCourses(onLessonCourses);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isVisible = true;
    _loadCourses();

    // 监听账户变更事件
    _accountChangeSubscription =
        AccountChangeNotifier().accountChanges.listen((_) {
          if (mounted) {
            _lastOnLessonCourses = [];
            _loadCourses();
          }
          _startPeriodicRefresh();
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _refreshTimer?.cancel();
    if (state == AppLifecycleState.resumed) {
      _startPeriodicRefresh();
    }
  }

  void _startPeriodicRefresh() {
    if (!_isVisible || PlatformManager().isChaoxing) return;

    if (_refreshTimer != null && _refreshTimer!.isActive) return;

    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted || !AccountManager.hasActiveSession()) return;

      try {
        final onLessonCourses = await RCCourseApi.getOnLesson();
        if (onLessonCourses != null && mounted) {
          if (!const DeepCollectionEquality().equals(_lastOnLessonCourses, onLessonCourses)) {
            _lastOnLessonCourses = onLessonCourses;
            _loadCourses(onLessonCourses);
          }
        }
      } catch (e) {
        debugPrint('Periodic refresh error: $e');
      }
    });
  }

  Future<void> _loadCourses([List<dynamic>? onLessonCourses]) async {
    setState(() {
      _isLoading = true;
    });

    if (!AccountManager.hasActiveSession()) {
      setState(() {
        _courses = [];
        _isLoading = false;
      });
      return;
    }

    // 开发期压测：短路掉网络请求，直接给一长串假课程（详见 test_data_seeder.dart）。
    // 未传 --dart-define=SEED_TEST_DATA 时这里是编译期常量 false，会被 tree-shake。
    if (TestDataSeeder.enabled) {
      setState(() {
        _courses = TestDataSeeder.buildFakeCourses(TestDataSeeder.count);
        _isLoading = false;
      });
      return;
    }

    try {
      late List<Course>? coursesData;
      if (PlatformManager().isChaoxing) {
        coursesData = await CXCourseApi.getCoursesList();
      } else if (PlatformManager().isRainClassroom) {
        coursesData = await RCCourseApi.getCoursesList(onLessonCourses);
      }

      if (coursesData != null && coursesData.isNotEmpty) {
        setState(() {
          _courses = coursesData!;
          _isLoading = false;
        });
      } else {
        setState(() {
          _courses = [];
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _courses = [];
        _isLoading = false;
      });
    }
  }

  Future<void> handleScanContent(String result) async {
    if (!AccountManager.hasActiveSession()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('二维码内容'),
              content: SelectableText(result),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      });
      return;
    }
  
    if (result.startsWith('http')) {
      try {
        final uri = Uri.parse(result);
        final baseUrl = uri.origin + uri.path;
        final params = uri.queryParameters;
  
        // 判断是否为签到 URL
        if (baseUrl == 'https://mobilelearn.chaoxing.com/widget/sign/e') {
          if (!PlatformManager().isChaoxing) {
            await PlatformManager().setPlatform(PlatformType.chaoxing);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('自动切换平台为学习通')),
            );
          }
          if (!AccountManager.hasActiveSession()) {
            if (!mounted) return;
            showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('提示'),
                  content: const Text('没有可用账号'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('确定'),
                    ),
                  ],
                );
              },
            );
            return;
          }
  
          final activeId = params['id'];
          if (activeId != null) {
            final response = await ApiService.sendRequest(result, responseType: ResponseType.plain, allowRedirects: false);
            if (response == null) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请求失败')),
              );
              return;
            }
            final locationUrl = response.headers['location']?.first;

            final uri = Uri.parse(locationUrl!);
            final params = uri.queryParameters;

            final classId = params['classId'] ?? '';
            final decodedRcode = Uri.decodeComponent(params['rcode']!);
            RegExp encRegex = RegExp(r'enc=([^&\s]+)');
            Match? match = encRegex.firstMatch(decodedRcode);

            if (match != null) {
              final enc = match.group(1);

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SignInPage(
                    active: Active(
                        type: 2,
                        id: activeId,
                        name: '二维码签到',
                        description: '',
                        startTime: 0,
                        url: '',
                        attendNum: 0,
                        status: true,
                        signType: SignType.qrCode
                    ),
                    courseId: '',
                    classId: classId,
                    cpi: '',
                    enc: enc
                  ),
                ),
              );
            } else {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('未找到 enc 参数')),
              );
            }
          }
        } else if (baseUrl.contains('.yuketang.cn/api/v3/lesson/check-in/dynamic-qr-code')){
          if (!PlatformManager().isRainClassroom) {
            await PlatformManager().setPlatform(PlatformType.rainClassroom);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('自动切换平台为雨课堂')),
            );
          }
          if (!AccountManager.hasActiveSession()) {
            if (!mounted) return;
            showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  content: const Text('没有可用账号'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('确定'),
                    ),
                  ],
                );
              },
            );
            return;
          }
  
          await _multiScan(context, result);
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('扫描到链接'),
                  content: SelectableText(result),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                );
              },
            );
          });
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('URL 解析失败：$e')),
        );
      }
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('扫描结果：$result')),
      );
    }
  }

  /// 为所有用户扫描
  Future<void> _multiScan(BuildContext context, String qrCodeUrl) async {
    final allAccounts = AccountManager.allAccounts;
    if (allAccounts.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可用的账号进行签到'))
      );
      return;
    }
  
    setState(() {
      _isLoading = true;
    });
  
    int successCount = 0;
    final List<String> failedAccounts = [];
  
    final results = await ApiService.sendForEachUser(
      allAccounts,
      (user) async {
        final api = RCCourseApi(user);
        return await api.scan(qrCodeUrl);
      },
    );

    for (int i = 0; i < results.length; i++) {
      final status = results[i];
      final user = allAccounts[i];
      
      if (status == 0) {
        successCount++;
      } else if (status == 51203) {
        failedAccounts.add('${user.name} (动态二维码过期)');
      } else {
        failedAccounts.add('${user.name} (错误码：$status)');
      }
    }
    
  
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
  
    _showMultiScanResult(context, successCount, allAccounts.length, failedAccounts);
  }

  /// 显示所有签到结果
  void _showMultiScanResult(BuildContext context, int successCount, int totalCount, List<String> failedAccounts) {
    String message = '签到完成！\n成功: $successCount/$totalCount';
    if (failedAccounts.isNotEmpty) {
      message += '\n\n失败账号:\n${failedAccounts.join('\n')}';
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          successCount == totalCount ? '全部签到成功' : '部分失败',
          style: TextStyle(
            color: successCount == totalCount ? Colors.green : Colors.orange,
          ),
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 底栏形态一变，底栏占位高度就得跟着变，所以整个脚手架包在监听里
    return ValueListenableBuilder<bool>(
      valueListenable: NavBarSetting.floating,
      builder: (context, _, _) => MiuixScaffold(
        // 顶栏换成 Miuix 玻璃顶栏。
        //
        // ⚠️ 模糊能看见的前提是「内容从顶栏底下滚过去」：`MiuixScaffold` 的
        // body 铺满整屏、栏画在其上，滚动列表再自己吃掉顶部留白
        // —— offset=0 时首项正好在栏下方，一往上滚就钻进栏底，
        // 顶栏里的 `BackdropFilter` 才有东西可糊。
        //
        // 若改用 `Scaffold.appBar` 槽位，body 会被顶到栏下面，两者永不重叠
        // → 糊了个寂寞（这正是之前一直没做顶栏模糊的原因）。
        //
        // `scrollBehavior` 让顶栏随滚动从「大标题 142dp」折到「小标题 92dp」。
        topBar: MiuixTopAppBar(
          title: '课程',
          largeTitle: '课程',
          blurred: true,
          scrollBehavior: _topBarBehavior,
          actions: [
            MiuixIconButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ScanPage(
                      onScanResult: handleScanContent,
                    ),
                  ),
                );
              },
              child: const Icon(Icons.qr_code_scanner),
            ),
          ],
        ),
        // 底栏是全局叠加的，不在本页脚手架里。用一块透明占位告诉脚手架
        // 「底下有这么高的东西」，contentPadding 与 FAB 就会自动让开，
        // 页面自己不用再算留白。
        bottomBar: SizedBox(height: miuixNavBarOccupied(context)),
        // 把顶栏折叠行为挂到滚动通知上（只认 depth==0 的竖向滚动体）
        content: (contentPadding) {
          // 只记最大高度，不跟随折叠回缩 —— 原因见 `_topBarInset` 的注释
          if (contentPadding.top > _topBarInset) {
            _topBarInset = contentPadding.top;
          }
          return MiuixScrollBehaviorListener(
            behavior: _topBarBehavior,
            child: RefreshIndicator(
        onRefresh: _loadCourses,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _courses.isEmpty
            ? Center(
                child: MiuixText(
                  PlatformManager().isRainClassroom ? '暂无正在上课的课程' : '暂无内容',
                  fontSize: 18,
                  color: MiuixTheme.of(context).colors.onBackgroundVariant,
                ),
              )
            : ListView.builder(
                itemCount: _courses.length,
                // 顶部留白吃掉顶栏高度 → 内容才会从顶栏底下滚过（玻璃顶栏的关键）。
                // 底部留白由脚手架的 bottomBar 占位给出，再加 16dp 余量。
                padding: EdgeInsets.only(
                  top: _topBarInset,
                  bottom: contentPadding.bottom + 16,
                ),
                itemBuilder: (context, index) {
                  final course = _courses[index];
                  final colors = MiuixTheme.of(context).colors;
                  return Padding(
                    // MiuixCard 没有 margin 参数，外边距由外面这层 Padding 提供
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: MiuixCard(
                      // 点击交给 MiuixCard（内部是 MiuixPressable，自带 Miuix
                      // 的按压反馈），不再自己套 InkWell
                      feedbackType: MiuixPressFeedbackType.sink,
                      onPressed: () {
                        Navigator.push(
                          context,
                          PlatformManager().isChaoxing ?
                          MaterialPageRoute(
                            builder: (context) => CourseContentPage(
                              courseId: course.courseId,
                              courseName: course.name,
                              classId: course.classId,
                              cpi: course.cpi!
                            ),
                          ) : MaterialPageRoute(
                            builder: (context) => PresentationPage(
                              lessonId: course.lessonId!,
                              title: course.name
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          // 原来是 Stack + Positioned 把 chevron 垂直居中，
                          // 改成 Row 居中对齐即可（头像也跟着与文字块居中）
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (course.image.isNotEmpty)
                              AvatarWidget(
                                imageUrl: course.image,
                                size: 50,
                                borderRadius: 6,
                                iconSize: 25,
                              )
                            else
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  color: colors.secondaryContainer,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Center(
                                  child: Icon(
                                    Icons.school,
                                    color: colors.onSecondaryContainer,
                                    size: 25,
                                  ),
                                ),
                              ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  MiuixText(
                                    course.name,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  MiuixText(
                                    course.teacher,
                                    fontSize: 14,
                                    color: colors.onSurfaceVariantSummary,
                                  ),
                                  const SizedBox(height: 5),
                                  if (course.note != null)
                                    MiuixText(
                                      course.note!,
                                      fontSize: 12,
                                      color: colors.onSurfaceVariantSummary,
                                    ),
                                  if (course.schools != null)
                                    MiuixText(
                                      course.schools!,
                                      fontSize: 12,
                                      color: colors.onSurfaceVariantSummary,
                                    ),
                                  if (course.beginDate != null &&
                                      course.endDate != null)
                                    MiuixText(
                                      '开课时间：${course.beginDate} 至 ${course.endDate}',
                                      fontSize: 12,
                                      color: colors.onSurfaceVariantSummary,
                                    ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              // 卡片内的「可点」提示色，用 Miuix 的 actions 色
                              color: colors.onSurfaceVariantActions,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
            );
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accountChangeSubscription?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }
}
