/// 幻灯片图片的**缓存身份**推导（纯函数，不依赖 Flutter，可直接单测）
///
/// 为什么单独抽出来：这套「缓存键必须是同一个身份」的规则已经被踩过两次，
/// 两次在 UI 上都看不出来，只能靠单测钉住：
///
/// 1. **缓存键带了签名 query** → 第二次进同一个课堂算出的 key 完全不同，
///    缓存永远命中不了（实测「已缓存 0」）。
/// 2. **并发去重键和落盘键不一致** → 同一张源图被两页以不同 query 引用时，
///    两个 worker 抢写同一个目标文件、互相 delete + rename，
///    其中一个报「文件不存在」，页面显示一个莫名其妙的错误图标。
///
/// 所以：**落盘文件名、并发去重键、队列去重键，三者必须都由这里推导。**
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 从图片 URL 推导「稳定的缓存身份」：只取路径部分，丢掉 query 和 fragment。
///
/// 雨课堂的图片地址长这样：
/// ```
/// https://changjiang-private-qn.yuketang.cn/slide/762156/cover312_20260921074817.jpg
///   ?imageView2/2/w/1280/format/webp&e=1789970808&token=IAM-gs****hmqa:7BqtPFRp...
/// ```
/// `e` 是签名过期时间、`token` 每次进课堂重新签发。带上它们做 key，
/// 第二次进同一个课堂就会算出完全不同的 key —— 缓存等于没有。
/// 路径里的文件名（`cover312_20260921074817.jpg`）是稳定的，用它。
///
/// 注意**只保留路径、丢掉全部 query**：同一张源图被不同页以不同尺寸参数
/// （`w/1280` vs `w/640`）引用时，落盘的是同一个文件 —— 这是刻意的，
/// 保证「一张源图只存一份」。
String imageCacheIdentity(String url) {
  var u = url.trim();
  final q = u.indexOf('?');
  if (q >= 0) u = u.substring(0, q);
  final h = u.indexOf('#');
  if (h >= 0) u = u.substring(0, h);
  return u;
}

/// 落盘文件名用的摘要（与 [imageCacheIdentity] 同源，必然是 40 位小写十六进制）
String imageCacheDigest(String url) =>
    sha1.convert(utf8.encode(imageCacheIdentity(url))).toString();
