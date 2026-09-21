import 'package:course_helper/utils/image_cache_key.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这套规则被踩过两次坑，两次在 UI 上都看不出来，所以这里钉死。
void main() {
  group('imageCacheIdentity：只取路径，丢掉签名 query', () {
    test('剥掉 ? 后面的全部 query', () {
      expect(
        imageCacheIdentity(
          'https://x.yuketang.cn/slide/1/a.jpg?imageView2/2/w/1280&e=123&token=abc',
        ),
        'https://x.yuketang.cn/slide/1/a.jpg',
      );
    });

    test('剥掉 # 后面的 fragment', () {
      expect(
        imageCacheIdentity('https://x.yuketang.cn/slide/1/a.jpg#frag'),
        'https://x.yuketang.cn/slide/1/a.jpg',
      );
    });

    test('query 和 fragment 都有时，从最前面那个开始剥', () {
      expect(
        imageCacheIdentity('https://h/a.jpg?e=1#f'),
        'https://h/a.jpg',
      );
    });

    test('前后空白先 trim 掉', () {
      expect(imageCacheIdentity('  https://h/a.jpg  '), 'https://h/a.jpg');
    });

    test('没有 query 的 URL 原样返回', () {
      expect(imageCacheIdentity('https://h/a.jpg'), 'https://h/a.jpg');
    });

    // ---- 回归用例 1：缓存键不能带签名 ----
    //
    // 雨课堂的 token 每次进课堂重新签发。带 query 做 key 的话，
    // 第二次进同一个课堂算出的 key 完全不同 → 缓存永远命中不了。
    test('回归：同一张图、token 不同 → 必须是同一个身份', () {
      const p1 = 'https://h/slide/1/cover312_20260921074817.jpg'
          '?imageView2/2/w/1280&e=1789970808&token=IAM-gsAAA:111';
      const p2 = 'https://h/slide/1/cover312_20260921074817.jpg'
          '?imageView2/2/w/1280&e=1789979999&token=IAM-gsBBB:222';
      expect(imageCacheIdentity(p1), imageCacheIdentity(p2));
    });

    // ---- 回归用例 2：同一张源图、不同尺寸参数也是同一个身份 ----
    //
    // 落盘文件名唯一，所以「同一张源图只存一份」是刻意的。
    // 如果这里判成两个不同身份，预取队列会把同一张图排两遍，
    // 两个 worker 就会抢写同一个目标文件、互相 delete + rename。
    test('回归：同一张图、尺寸参数不同 → 必须是同一个身份', () {
      const w1280 = 'https://h/slide/1/a.jpg?imageView2/2/w/1280';
      const w640 = 'https://h/slide/1/a.jpg?imageView2/2/w/640';
      expect(imageCacheIdentity(w1280), imageCacheIdentity(w640));
    });

    test('不同路径 → 不同身份（不能过度合并）', () {
      expect(
        imageCacheIdentity('https://h/slide/1/a.jpg?e=1'),
        isNot(imageCacheIdentity('https://h/slide/2/a.jpg?e=1')),
      );
    });
  });

  group('imageCacheDigest', () {
    test('是 40 位小写十六进制（sha1）', () {
      final d = imageCacheDigest('https://h/a.jpg?e=1');
      expect(d, matches(RegExp(r'^[0-9a-f]{40}$')));
    });

    test('身份相同 → 摘要相同（缓存命中的前提）', () {
      expect(
        imageCacheDigest('https://h/a.jpg?token=A'),
        imageCacheDigest('https://h/a.jpg?token=B'),
      );
    });

    test('身份不同 → 摘要不同', () {
      expect(
        imageCacheDigest('https://h/a.jpg'),
        isNot(imageCacheDigest('https://h/b.jpg')),
      );
    });

    test('同一输入稳定可复现', () {
      const u = 'https://h/slide/1/a.jpg?e=1';
      expect(imageCacheDigest(u), imageCacheDigest(u));
    });
  });
}
