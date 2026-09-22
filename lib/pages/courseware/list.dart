// ============================================================================
// 课件 Tab（底栏第 3 个）
// ============================================================================
//
// 需求原文（2026-09-22）：
//   「一个是缓存的 ppt，增加查看缓存的 ppt，和删除的按钮，取消自动删除 ppt」
//   「那一页你看看能不能读取全部课程，并能打开，打开后显示每节课的 ppt，
//     不叫 ppt 缓存了，具体改什么名你能推荐吗」
//   「但是课件如果打开了，就要保活，切回去还是那个页面」
//
// 名字取「**课件**」（而不是「PPT 缓存」）：
//   - 用户面对的是「这门课的课件」，不是「缓存目录」；缓存只是实现细节
//   - 它既是查看器也是管理器（能删），「缓存」二字只描述了后一半
//
// 【三层结构，全部在**同一个 Tab 内**切换】
//
//   courseList  全部课程（网络优先，离线退回本地缓存）
//     └ pptList 某门课已缓存的课件列表（查看 / 删除）
//         └ viewer 离线浏览（PageView + 导出 PDF）
//
// ⚠️ 三层是 `_stage` 状态切换，**不是** `Navigator.push`。
// 原因：push 出来的路由会盖住玻璃底栏，而底栏是 `main.dart` 里用
// `Stack` + `Positioned` 贴在页面之上的 —— 被盖住就没法切 Tab，
// 「课件打开后切走再切回还是那个页面」这条需求就落不了地。
// 代价是全屏看课件时底栏仍在（可用高度少 ~80dp），用户已确认接受。
//
// 保活：`main.dart` 用 `Offstage` 包住本页，切 Tab 不销毁 State，
// 所以 `_stage` / 滚动位置 / 当前翻到第几页都会原样保留。
// ============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../api/course.dart';
import '../../cache/course_cache.dart';
import '../../models/course.dart';
import '../../platform.dart';
import '../../session/account.dart';
import '../../utils/app_logger.dart';
import '../courses/content.dart';
import '../widget/miuix_nav_metrics.dart';
import 'viewer.dart';

/// 课件页当前所在层
enum _Stage { courseList, pptList, viewer }

/// 第一层的列表项：一门课 + 它的课件缓存概况。
///
/// 为什么不直接用 `models/course.dart` 的 `Course`：课件页的数据来源有两个 ——
/// 网络课程列表（有名称/教师）和**本地缓存目录**（有课件，但只有 courseId +
/// 课程名）。离线、退课、换平台时远程列表可能拿不到，此时必须能只靠本地缓存
/// 把课列出来，否则「明明缓存了却看不到」。所以这里是一个合并后的视图模型。
class _CourseEntry {
  _CourseEntry({
    required this.courseId,
    required this.name,
    required this.teacher,
    required this.lessonIds,
    required this.presentationCount,
    required this.fromCache,
    this.classId = '',
    this.cpi = '',
  });

  /// 空字符串 = 没有 meta.json 的旧版缓存（只能按 lessonId 定位）
  final String courseId;

  final String name;
  final String teacher;

  /// 这门课对应的所有 lessonId（每上一次课就多一个）
  final List<String> lessonIds;

  /// 已缓存课件份数（删除后会变，故非 final）
  int presentationCount;

  /// 只来自本地缓存（网络列表里没有这门课）
  final bool fromCache;

  /// 学习通跳课程内容页要用
  final String classId;
  final String cpi;
}

class CoursewarePage extends StatefulWidget {
  const CoursewarePage({super.key});

  @override
  State<CoursewarePage> createState() => _CoursewarePageState();
}

class _CoursewarePageState extends State<CoursewarePage> {
  static const String _tag = 'Courseware';

  /// 顶栏「滚动折叠」的行为对象。必须**只创建一次**（它持有折叠进度）。
  late final MiuixExitUntilCollapsedScrollBehavior _topBarBehavior =
      miuixScrollBehavior();

  /// 列表顶部留白（= 顶栏**展开态**高度），只记最大值、不跟随折叠回缩。
  /// 切层时要重置（各层的展开高度不同，不重置会留下上一层的最大值）。
  double _topBarInset = 0;

  _Stage _stage = _Stage.courseList;

  bool _loading = true;
  List<_CourseEntry> _entries = [];

  _CourseEntry? _entry;

  bool _pptLoading = false;
  List<CachedPresentation> _presentations = [];

  CachedPresentation? _viewerPpt;

  /// 待确认删除的课件（配合 `MiuixWindowBottomSheet`）
  CachedPresentation? _pendingDelete;
  bool _showDeleteSheet = false;

  final MiuixSnackbarHostState _snackbarHost = MiuixSnackbarHostState();

  @override
  void initState() {
    super.initState();
    _loadCourses();
  }

  @override
  void dispose() {
    _snackbarHost.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    unawaited(_snackbarHost.showSnackbar(message));
  }

  // ── 第一层：全部课程 ──────────────────────────────────────────────────

  Future<void> _loadCourses() async {
    setState(() => _loading = true);

    // ① 本地：已缓存的课。这是「哪门课有课件」的唯一可靠来源，离线也能用。
    List<CachedLesson> cached = const [];
    try {
      cached = await CourseCache.listLessons();
    } catch (e) {
      AppLogger.w(_tag, '读取本地缓存失败：$e');
    }

    // ② 远程：全部课程。失败不影响本页可用（只是列表少一些、没有教师名）。
    List<Course> remote = const [];
    // 在课的课 → lessonId。`getAllCourses()` 刻意不 join「正在上课」，
    // 所以那边 `Course.lessonId` 恒为 null；只有 `getCoursesList()` 带得出来。
    // v4.8.8 之前的缓存没有 meta.json，只能靠这个把缓存目录名对上课程。
    final onLessonIdByCourse = <String, String>{};
    if (AccountManager.hasActiveSession()) {
      try {
        final list = PlatformManager().isChaoxing
            ? await CXCourseApi.getCoursesList()
            : await RCCourseApi.getAllCourses();
        remote = list ?? const [];
      } catch (e) {
        AppLogger.w(_tag, '读取课程列表失败：$e');
      }

      if (!PlatformManager().isChaoxing) {
        try {
          final onLesson = await RCCourseApi.getCoursesList();
          for (final c in onLesson ?? const <Course>[]) {
            final lid = c.lessonId?.trim() ?? '';
            if (c.courseId.isNotEmpty && lid.isNotEmpty) {
              onLessonIdByCourse[c.courseId] = lid;
            }
          }
        } catch (e) {
          // 拿不到不影响本页 —— 只是老缓存少一条兜底关联路径
          AppLogger.w(_tag, '读取在课列表失败（不影响课件列表）：$e');
        }
      }
    }

    if (!mounted) return;

    final byCourse = <String, List<CachedLesson>>{};
    for (final lesson in cached) {
      byCourse.putIfAbsent(lesson.courseId, () => []).add(lesson);
    }
    final lessonIdsByCourseId = <String, List<String>>{
      for (final e in byCourse.entries)
        e.key: [for (final l in e.value) l.lessonId],
    };
    // 目录名 → CachedLesson：兜底关联和计数都要用
    final cachedByDirName = <String, CachedLesson>{
      for (final l in cached) l.lessonId: l,
    };
    // 已经被某门课认领的 lessonId —— 别在第三档「未关联」里再列一遍
    final absorbed = <String>{};

    final entries = <_CourseEntry>[];
    final seen = <String>{};

    // 远程课程（主）
    for (final course in remote) {
      if (course.courseId.isEmpty || !seen.add(course.courseId)) continue;

      final ids = resolveLessonIdsForCourse(
        courseId: course.courseId,
        lessonIdsByCourseId: lessonIdsByCourseId,
        cachedDirNames: cachedByDirName.keys.toSet(),
        onLessonId: onLessonIdByCourse[course.courseId],
      );
      absorbed.addAll(ids);

      entries.add(_CourseEntry(
        courseId: course.courseId,
        name: course.name,
        teacher: course.teacher,
        classId: course.classId,
        cpi: course.cpi ?? '',
        lessonIds: ids.toList(),
        presentationCount: ids.fold(
            0, (sum, id) => sum + (cachedByDirName[id]?.presentationCount ?? 0)),
        fromCache: false,
      ));
    }

    // 有缓存、但远程列表里没有的（离线 / 退课 / 换了平台）也要列出来
    for (final lesson in cached) {
      if (lesson.courseId.isEmpty || seen.contains(lesson.courseId)) continue;
      seen.add(lesson.courseId);
      final lessons = byCourse[lesson.courseId]!;
      absorbed.addAll(lessons.map((l) => l.lessonId));
      entries.add(_CourseEntry(
        courseId: lesson.courseId,
        name: lesson.name,
        teacher: '',
        lessonIds: [for (final l in lessons) l.lessonId],
        presentationCount:
            lessons.fold(0, (sum, l) => sum + l.presentationCount),
        fromCache: true,
      ));
    }

    // 没有 courseId 的旧版缓存（meta.json 是 v4.8.8 才有的）：单独列出来，
    // 用 lessonId 当身份，至少能看、能删。
    // ⚠️ 已经被上面按「在课 lessonId」认领走的不再列一遍，否则同一份课件会出现两次。
    for (final lesson in cached) {
      if (lesson.courseId.isNotEmpty) continue;
      if (absorbed.contains(lesson.lessonId)) continue;
      entries.add(_CourseEntry(
        courseId: '',
        name: lesson.name,
        teacher: '未关联课程 · 进一次这门课即可自动关联',
        lessonIds: [lesson.lessonId],
        presentationCount: lesson.presentationCount,
        fromCache: true,
      ));
    }

    // 有课件的排前面 —— 用户进这一页十有八九是冲着已缓存的课件来的。
    // ⚠️ 不用 `sort` 拼比较函数：`List.sort` 不保证稳定，同组内顺序会被打乱。
    final withCache = entries.where((e) => e.presentationCount > 0).toList();
    final without = entries.where((e) => e.presentationCount == 0).toList();

    setState(() {
      _entries = [...withCache, ...without];
      _loading = false;
    });
  }

  Future<void> _openCourse(_CourseEntry entry) async {
    // 学习通没有「课件」这套缓存（它的内容是活动列表），直接进课程内容页。
    // 用户明确说过「学习通跑不通没事，优先跑雨课堂」。
    if (PlatformManager().isChaoxing) {
      if (entry.classId.isEmpty) {
        _toast('这门课缺少班级信息，暂时打不开');
        return;
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CourseContentPage(
            courseId: entry.courseId,
            courseName: entry.name,
            classId: entry.classId,
            cpi: entry.cpi,
          ),
        ),
      );
      return;
    }

    setState(() {
      _entry = entry;
      _stage = _Stage.pptList;
      _pptLoading = true;
      _presentations = [];
      _topBarInset = 0;
    });

    final all = <CachedPresentation>[];
    for (final lessonId in entry.lessonIds) {
      all.addAll(await CourseCache.listPresentations(lessonId));
    }
    all.sort((a, b) => b.savedAt.compareTo(a.savedAt));

    if (!mounted) return;
    setState(() {
      _presentations = all;
      _pptLoading = false;
    });
  }

  // ── 第二层：某门课的课件列表 ──────────────────────────────────────────

  Future<void> _deletePresentation(CachedPresentation ppt) async {
    final freed =
        await CourseCache.deletePresentation(ppt.lessonId, ppt.presentationId);
    if (!mounted) return;

    setState(() {
      _presentations.removeWhere((p) =>
          p.lessonId == ppt.lessonId &&
          p.presentationId == ppt.presentationId);
    });

    // 第一层的计数同步（`_entry` 是同一个对象引用，改完即可）
    final entry = _entry;
    if (entry != null) {
      var total = 0;
      for (final lessonId in entry.lessonIds) {
        total += (await CourseCache.listPresentations(lessonId)).length;
      }
      if (!mounted) return;
      setState(() => entry.presentationCount = total);
    }

    _toast('已删除，释放 ${_formatBytes(freed)}');
  }

  void _askDelete(CachedPresentation ppt) {
    setState(() {
      _pendingDelete = ppt;
      _showDeleteSheet = true;
    });
  }

  // ── 第三层：离线浏览 ──────────────────────────────────────────────────

  void _openViewer(CachedPresentation ppt) {
    setState(() {
      _viewerPpt = ppt;
      _stage = _Stage.viewer;
      _topBarInset = 0;
    });
  }

  /// 逐层退回（viewer → pptList → courseList）
  void _goBack() {
    setState(() {
      switch (_stage) {
        case _Stage.viewer:
          _stage = _Stage.pptList;
          _viewerPpt = null;
        case _Stage.pptList:
          _stage = _Stage.courseList;
          _entry = null;
        case _Stage.courseList:
          break;
      }
      _topBarInset = 0;
    });
  }

  // ── 界面 ──────────────────────────────────────────────────────────────

  String get _topBarTitle {
    switch (_stage) {
      case _Stage.courseList:
        return '课件';
      case _Stage.pptList:
        return _entry?.name ?? '课件';
      case _Stage.viewer:
        return _viewerPpt?.displayTitle ?? '课件';
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 只在最顶层允许真正退出（退出 App / 返回上一路由）；
      // 内层拦下来自己退一层，避免 push 出来的路由盖住底栏。
      canPop: _stage == _Stage.courseList,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _goBack();
      },
      child: MiuixScaffold(
        topBar: MiuixTopAppBar(
          title: _topBarTitle,
          // 大标题只在顶层出现；内层标题可能很长（课程名），用小标题即可
          largeTitle: _stage == _Stage.courseList ? '课件' : null,
          blurred: true,
          scrollBehavior: _topBarBehavior,
          // ⚠️ `MiuixTopAppBar` 没有 `onBack`，返回键自己塞 `navigationIcon`
          navigationIcon: _stage == _Stage.courseList
              ? null
              : MiuixIconButton(
                  onPressed: _goBack,
                  child: const Icon(Icons.arrow_back_ios_new, size: 20),
                ),
        ),
        snackbarHost: MiuixSnackbarHost(
          state: _snackbarHost,
          blurSigma: 30,
          blurBackgroundAlpha: 0.55,
        ),
        // 底栏是全局叠加的，不在本页脚手架里 —— 透明占位让内容与 FAB 让开
        bottomBar: SizedBox(height: miuixNavBarOccupied(context)),
        content: (contentPadding) {
          // 只记最大高度，不跟随折叠回缩（原因见 courses/list.dart 同名注释）
          if (contentPadding.top > _topBarInset) {
            _topBarInset = contentPadding.top;
          }
          return Stack(
            children: [
              MiuixScrollBehaviorListener(
                behavior: _topBarBehavior,
                child: _buildStage(context, contentPadding),
              ),
              // 删除确认抽屉。用**窗口级**的 `MiuixWindowBottomSheet`：
              // 本页是 Tab 页，页内级弹窗/抽屉会落在玻璃底栏**下面**
              // （遮罩盖不住底栏、底栏还保持可点）—— 同 accounts.dart 里的说明。
              _buildDeleteSheet(context),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStage(BuildContext context, EdgeInsets contentPadding) {
    switch (_stage) {
      case _Stage.courseList:
        return _buildCourseList(context, contentPadding);
      case _Stage.pptList:
        return _buildPptList(context, contentPadding);
      case _Stage.viewer:
        final ppt = _viewerPpt;
        if (ppt == null) return const SizedBox.shrink();
        return CoursewareViewer(
          lessonId: ppt.lessonId,
          presentationId: ppt.presentationId,
          title: ppt.displayTitle,
        );
    }
  }

  Widget _buildCourseList(BuildContext context, EdgeInsets contentPadding) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_entries.isEmpty) {
      return _buildEmpty(
        context,
        title: '还没有任何课程',
        summary: AccountManager.hasActiveSession()
            ? '下拉可以刷新课程列表'
            : '先在「账号」页登录，才能读取课程',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadCourses,
      child: ListView.builder(
        itemCount: _entries.length,
        padding: EdgeInsets.only(
          top: _topBarInset,
          bottom: contentPadding.bottom + 16,
        ),
        itemBuilder: (context, index) =>
            _buildCourseTile(context, _entries[index]),
      ),
    );
  }

  Widget _buildCourseTile(BuildContext context, _CourseEntry entry) {
    final colors = MiuixTheme.of(context).colors;
    final hasCache = entry.presentationCount > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: MiuixCard(
        feedbackType: MiuixPressFeedbackType.sink,
        onPressed: () => _openCourse(entry),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: hasCache
                      ? colors.primaryContainer
                      : colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Icon(
                    hasCache
                        ? Icons.folder_copy
                        : Icons.folder_copy_outlined,
                    size: 24,
                    color: hasCache
                        ? colors.onPrimaryContainer
                        : colors.onSecondaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MiuixText(
                      entry.name,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (entry.teacher.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      MiuixText(
                        entry.teacher,
                        fontSize: 13,
                        color: colors.onSurfaceVariantSummary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    MiuixText(
                      hasCache
                          ? '${entry.presentationCount} 份课件'
                          : '暂无课件',
                      fontSize: 12,
                      color: hasCache
                          ? colors.primary
                          : colors.onSurfaceVariantSummary,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: colors.onSurfaceVariantActions,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPptList(BuildContext context, EdgeInsets contentPadding) {
    if (_pptLoading) return const Center(child: CircularProgressIndicator());

    if (_presentations.isEmpty) {
      return _buildEmpty(
        context,
        title: '这门课还没有缓存课件',
        summary: '进课堂打开 PPT 时会自动缓存到本地，之后断网也能看',
      );
    }

    return ListView.builder(
      itemCount: _presentations.length,
      padding: EdgeInsets.only(
        top: _topBarInset,
        bottom: contentPadding.bottom + 16,
      ),
      itemBuilder: (context, index) =>
          _buildPptTile(context, _presentations[index]),
    );
  }

  Widget _buildPptTile(BuildContext context, CachedPresentation ppt) {
    final colors = MiuixTheme.of(context).colors;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: MiuixCard(
        feedbackType: MiuixPressFeedbackType.sink,
        onPressed: () => _openViewer(ppt),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MiuixText(
                      ppt.displayTitle,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    MiuixText(
                      '${ppt.slideCount} 页 · ${_formatDate(ppt.savedAt)} · '
                      '${_formatBytes(ppt.bytes)}',
                      fontSize: 12,
                      color: colors.onSurfaceVariantSummary,
                    ),
                  ],
                ),
              ),
              // ⚠️ `MiuixIconButton` 在卡片内部，它自己的手势识别器比外层
              // `MiuixCard` 的更深 → 先入竞技场并获胜，所以点删除不会同时触发
              // 「打开课件」。
              MiuixIconButton(
                onPressed: () => _askDelete(ppt),
                child: Icon(
                  Icons.delete_outline,
                  size: 22,
                  color: colors.onSurfaceVariantActions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(
    BuildContext context, {
    required String title,
    required String summary,
  }) {
    final colors = MiuixTheme.of(context).colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiuixIcon(
              icon: Icons.folder_open_outlined,
              size: 44,
              tint: colors.onSurfaceVariantSummary,
            ),
            const SizedBox(height: 12),
            MiuixText(title, fontSize: 16, color: colors.onBackgroundVariant),
            const SizedBox(height: 6),
            MiuixText(
              summary,
              fontSize: 13,
              color: colors.onSurfaceVariantSummary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeleteSheet(BuildContext context) {
    final ppt = _pendingDelete;
    final colors = MiuixTheme.of(context).colors;

    return MiuixWindowBottomSheet(
      show: _showDeleteSheet && ppt != null,
      title: '删除课件',
      onDismissRequest: () => setState(() => _showDeleteSheet = false),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiuixText(
            '确定删除「${ppt?.displayTitle ?? ''}」吗？',
            fontSize: 15,
          ),
          const SizedBox(height: 8),
          MiuixText(
            '这份课件的本地缓存会被移除，它独占的图片也会一并清理。'
            '下次进课堂时会重新缓存。',
            fontSize: 13,
            color: colors.onSurfaceVariantSummary,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              MiuixTextButton(
                '取消',
                onPressed: () => setState(() => _showDeleteSheet = false),
              ),
              const SizedBox(width: 8),
              MiuixTextButton(
                '删除',
                onPressed: () {
                  final target = ppt;
                  setState(() {
                    _showDeleteSheet = false;
                    _pendingDelete = null;
                  });
                  if (target != null) {
                    unawaited(_deletePresentation(target));
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 小工具 ──────────────────────────────────────────────────────────────

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

String _formatDate(int millis) {
  if (millis <= 0) return '时间未知';
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}
