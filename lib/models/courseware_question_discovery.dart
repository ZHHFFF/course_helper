import '../cache/slide_scanner.dart';
import 'presentation.dart';

/// 本地识题快照，不表示教师已发布或允许作答。
class CoursewareQuestionDiscovery {
  final String lessonId;
  final String presentationId;
  final SlideQuestion item;
  final String slideImageUrl;

  const CoursewareQuestionDiscovery({
    required this.lessonId,
    required this.presentationId,
    required this.item,
    required this.slideImageUrl,
  });

  /// scanner 使用数组下标，显示页码只在这个边界加一。
  int get pageNumber => item.slideIndex + 1;

  (String, String, int, String) get identity =>
      (lessonId, presentationId, item.slideIndex, item.hash);
}

/// 一个课件对应一个本地时间线条目；重扫替换快照，不追加重复卡片。
class CoursewareQuestionBatch {
  final String lessonId;
  final String presentationId;
  final String title;
  final List<CoursewareQuestionDiscovery> questions;

  CoursewareQuestionBatch.fromScan({
    required this.lessonId,
    required this.presentationId,
    required this.title,
    required SlideScanResult scan,
    required List<PresentationSlide> slides,
  }) : questions = List.unmodifiable(
         {
           for (final item in scan.questions)
             if (item.slideIndex >= 0 && item.slideIndex < slides.length)
               (
                 lessonId,
                 presentationId,
                 item.slideIndex,
                 item.hash,
               ): CoursewareQuestionDiscovery(
                 lessonId: lessonId,
                 presentationId: presentationId,
                 item: item,
                 slideImageUrl: SlideScanner.slideImageOf(
                   slides[item.slideIndex],
                 ),
               ),
         }.values,
       );

  (String, String) get identity => (lessonId, presentationId);
}
