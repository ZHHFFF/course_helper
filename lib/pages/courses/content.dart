import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../api/course.dart';
import '../../models/active.dart';
import 'list.dart';
import 'settings.dart';

class CourseContentPage extends StatefulWidget {
  final String courseId;
  final String courseName;
  final String classId;
  final String cpi;

  const CourseContentPage({
    super.key,
    required this.courseId,
    required this.courseName,
    required this.classId,
    required this.cpi,
  });

  @override
  State<CourseContentPage> createState() => _CourseContentPageState();
}

class _CourseContentPageState extends State<CourseContentPage> {
  List<Active> _activeList = [];
  bool _isContentLoading = false;
  late CXCourseApi _courseApi;

  @override
  void initState() {
    super.initState();
    _courseApi = CXCourseApi();
    _loadCourseContent();
  }

  Future<void> _loadCourseContent() async {
    setState(() {
      _isContentLoading = true;
    });

    try {
      final List<Active>? contentList = await _courseApi.getActiveList(
        widget.courseId,
        widget.classId,
        widget.cpi,
      );

      if (contentList != null) {
        setState(() {
          _activeList = contentList;
          _isContentLoading = false;
        });
      } else {
        setState(() {
          _activeList = [];
          _isContentLoading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('获取内容列表失败')),
          );
        }
      }
    } catch (e) {
      setState(() {
        _activeList = [];
        _isContentLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取内容列表时发生错误：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;

    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: widget.courseName,
        blurred: true,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Icon(Icons.arrow_back_ios_new, size: 20),
        ),
        actions: [
          MiuixIconButton(
            child: const Icon(Icons.settings, size: 20),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => CourseSettingsPage(
                    courseId: widget.courseId,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      content: (contentPadding) {
        if (_isContentLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (_activeList.isEmpty) {
          return Center(
            child: MiuixText(
              '暂无内容',
              fontSize: 18,
              color: colors.onSurfaceVariantSummary,
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: _loadCourseContent,
          child: ListView.builder(
            padding: EdgeInsets.only(
              top: contentPadding.top,
              bottom: contentPadding.bottom + 16,
            ),
            itemCount: _activeList.length,
            itemBuilder: (context, index) {
              final active = _activeList[index];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: MiuixCard(
                  feedbackType: MiuixPressFeedbackType.sink,
                  onPressed: () {
                    CoursesPage.navigateToActive(
                      context,
                      active,
                      widget.courseId,
                      widget.classId,
                      widget.cpi,
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: active.status
                                ? colors.primaryContainer.withValues(alpha: 0.2)
                                : colors.secondaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(
                            child: Icon(
                              active.getIcon(),
                              color: active.status ? colors.primary : colors.onSurfaceVariantActions,
                              size: 26,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              MiuixText(
                                active.name,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              MiuixText(
                                active.description.isEmpty ? '手动结束' : active.description,
                                fontSize: 13,
                                color: colors.onSurfaceVariantSummary,
                              ),
                              const SizedBox(height: 2),
                              MiuixText(
                                '参与人数：${active.attendNum}',
                                fontSize: 12,
                                color: colors.onSurfaceVariantSummary,
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
            },
          ),
        );
      },
    );
  }
}
