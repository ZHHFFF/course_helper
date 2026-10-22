import 'dart:io';

import 'package:course_helper/cache/answer_draft_store.dart';
import 'package:course_helper/cache/course_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/cache_test_env.dart';

void main() {
  late CacheTestEnv env;
  setUp(() async => env = await CacheTestEnv.create());
  tearDown(() async => env.dispose());

  test('落盘后重新读取选择、填空和文本；不同课堂及课件互不覆盖', () async {
    await AnswerDraftStore.save('lesson', 'ppt-A', 'p1',
        AnswerDraft(options: ['A', 'C']));
    await AnswerDraftStore.save('lesson', 'ppt-B', 'p1',
        AnswerDraft(options: ['第一空', '', '第三空']));
    await AnswerDraftStore.save('other-lesson', 'ppt-A', 'p1',
        AnswerDraft(text: '另一课堂答案'));
    final first = await AnswerDraftStore.readLesson('lesson');
    expect(first.answers[AnswerDraftStore.key('ppt-A', 'p1')]!.options,
        ['A', 'C']);
    expect(first.answers[AnswerDraftStore.key('ppt-B', 'p1')]!.options,
        ['第一空', '', '第三空']);
    final other = await AnswerDraftStore.readLesson('other-lesson');
    expect(other.answers[AnswerDraftStore.key('ppt-A', 'p1')]!.text,
        '另一课堂答案');
  });

  test('快速连续修改、清空、立即重读，以最后一次修改为准', () async {
    final options = ['A'];
    final first = AnswerDraftStore.save('lesson', 'ppt', 'p1',
        AnswerDraft(options: options));
    options.add('B'); // 保存的是快照，不受调用方后续修改影响。
    final second = AnswerDraftStore.save('lesson', 'ppt', 'p2',
        AnswerDraft(text: '保留另一题'));
    final cleared = AnswerDraftStore.save('lesson', 'ppt', 'p1',
        AnswerDraft(options: []));
    final saved = await AnswerDraftStore.readLesson('lesson');
    await Future.wait([first, second, cleared]);
    expect(saved.answers[AnswerDraftStore.key('ppt', 'p1')]!.options, isEmpty);
    expect(saved.answers[AnswerDraftStore.key('ppt', 'p2')]!.text, '保留另一题');
  });

  test('结束清理与在途写入串行，结束后的迟到保存不能复活答案', () async {
    final saving = AnswerDraftStore.save('lesson', 'ppt', 'p1',
        AnswerDraft(options: ['B']));
    final ending = AnswerDraftStore.finishLesson('lesson');
    final lateSave = AnswerDraftStore.save('lesson', 'ppt', 'p1',
        AnswerDraft(text: '迟到写入'));
    await Future.wait([saving, ending, lateSave]);
    final saved = await AnswerDraftStore.readLesson('lesson');
    expect(saved.finished, isTrue);
    expect(saved.answers, isEmpty);
  });

  test('损坏条目不影响其他题目恢复', () async {
    final dir = await CourseCache.lessonDir('lesson');
    await CourseCache.writeJson(File('${dir.path}/answer_drafts.json'), {
      'answers': {
        'broken': {'options': 'invalid'},
        'valid': {'text': '有效答案'},
      },
    });
    final saved = await AnswerDraftStore.readLesson('lesson');
    expect(saved.answers.keys, ['valid']);
    expect(saved.answers['valid']!.text, '有效答案');
  });
}
