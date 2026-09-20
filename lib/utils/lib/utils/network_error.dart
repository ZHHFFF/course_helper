/// 网络错误识别工具
///
/// 用于区分「网络层失败」（断网 / 连接失败 / 超时 / 证书异常）与
/// 「业务层失败」（服务器正常返回但业务码非成功），
/// 这样答题提交失败时能明确告诉用户到底是网络问题还是业务问题。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// 错误归类
enum RequestErrorKind {
  /// 网络层错误：无网络、连不上、超时、DNS、证书
  network,

  /// 认证错误：API Key 无效 / 未授权
  auth,

  /// 服务端错误：5xx
  server,

  /// 请求错误：地址或参数不对（4xx）
  request,

  /// 未知
  unknown,
}

/// 错误描述
class RequestErrorInfo {
  final RequestErrorKind kind;

  /// 面向用户的简短描述
  final String message;

  /// 原始异常
  final Object error;

  const RequestErrorInfo({
    required this.kind,
    required this.message,
    required this.error,
  });

  /// 是否属于网络层失败
  bool get isNetwork => kind == RequestErrorKind.network;

  @override
  String toString() => message;
}

/// 把任意异常翻译成可读的错误信息
RequestErrorInfo describeError(Object error) {
  if (error is RequestErrorInfo) return error;

  if (error is DioException) return _fromDio(error);

  if (error is SocketException) {
    return RequestErrorInfo(
      kind: RequestErrorKind.network,
      message: '网络不可用，请检查手机网络连接',
      error: error,
    );
  }

  if (error is TimeoutException) {
    return RequestErrorInfo(
      kind: RequestErrorKind.network,
      message: '请求超时，请检查网络后重试',
      error: error,
    );
  }

  if (error is HandshakeException) {
    return RequestErrorInfo(
      kind: RequestErrorKind.network,
      message: 'HTTPS 证书校验失败，请检查网络是否被劫持',
      error: error,
    );
  }

  final text = error.toString();
  if (text.contains('SocketException') ||
      text.contains('Connection refused') ||
      text.contains('Connection timed out') ||
      text.contains('Failed host lookup') ||
      text.contains('Network is unreachable')) {
    return RequestErrorInfo(
      kind: RequestErrorKind.network,
      message: '网络不可用，请检查手机网络连接',
      error: error,
    );
  }

  return RequestErrorInfo(
    kind: RequestErrorKind.unknown,
    message: text,
    error: error,
  );
}

/// 便捷方法：只要一句可读描述
String describeErrorShort(Object error) => describeError(error).message;

/// 是否网络层失败
bool isNetworkError(Object error) => describeError(error).isNetwork;

RequestErrorInfo _fromDio(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
      return RequestErrorInfo(
        kind: RequestErrorKind.network,
        message: '连接超时：无法连接到服务器',
        error: e,
      );
    case DioExceptionType.sendTimeout:
      return RequestErrorInfo(
        kind: RequestErrorKind.network,
        message: '发送超时：数据上传耗时过长',
        error: e,
      );
    case DioExceptionType.receiveTimeout:
      return RequestErrorInfo(
        kind: RequestErrorKind.network,
        message: '响应超时：服务器长时间未返回数据',
        error: e,
      );
    case DioExceptionType.connectionError:
      return RequestErrorInfo(
        kind: RequestErrorKind.network,
        message: '无法连接服务器：请检查网络或接口地址',
        error: e,
      );
    case DioExceptionType.badCertificate:
      return RequestErrorInfo(
        kind: RequestErrorKind.network,
        message: '证书校验失败，请检查网络是否被劫持',
        error: e,
      );
    case DioExceptionType.cancel:
      return RequestErrorInfo(
        kind: RequestErrorKind.network,
        message: '请求已取消',
        error: e,
      );
    case DioExceptionType.badResponse:
      final code = e.response?.statusCode ?? 0;
      if (code == 401 || code == 403) {
        return RequestErrorInfo(
          kind: RequestErrorKind.auth,
          message: '认证失败（HTTP $code）：API Key 无效或无权限',
          error: e,
        );
      }
      if (code == 404) {
        return RequestErrorInfo(
          kind: RequestErrorKind.request,
          message: '接口不存在（HTTP 404）：请检查 API 地址',
          error: e,
        );
      }
      if (code == 429) {
        return RequestErrorInfo(
          kind: RequestErrorKind.request,
          message: '请求过于频繁（HTTP 429）：请稍后重试',
          error: e,
        );
      }
      if (code >= 500) {
        return RequestErrorInfo(
          kind: RequestErrorKind.server,
          message: '服务器错误（HTTP $code）：请稍后重试',
          error: e,
        );
      }
      return RequestErrorInfo(
        kind: RequestErrorKind.request,
        message: '请求被拒绝（HTTP $code）',
        error: e,
      );
    case DioExceptionType.unknown:
      final inner = e.error;
      if (inner is SocketException) {
        return RequestErrorInfo(
          kind: RequestErrorKind.network,
          message: '网络不可用，请检查手机网络连接',
          error: e,
        );
      }
      final text = (inner ?? e).toString();
      if (text.contains('SocketException') ||
          text.contains('Failed host lookup')) {
        return RequestErrorInfo(
          kind: RequestErrorKind.network,
          message: '网络不可用，请检查手机网络连接',
          error: e,
        );
      }
      return RequestErrorInfo(
        kind: RequestErrorKind.unknown,
        message: '请求失败：$text',
        error: e,
      );
  }
}

