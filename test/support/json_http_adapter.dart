import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';

/// 与真实请求共享 Dio 解码路径，响应时机由用例自己的 Future 控制。
class JsonHttpAdapter implements HttpClientAdapter {
  JsonHttpAdapter(this.respond);

  final Future<Map<String, dynamic>> Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(await respond(options)),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );

  @override
  void close({bool force = false}) {}
}
