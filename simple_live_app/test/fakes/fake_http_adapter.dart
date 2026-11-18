import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 不联网的 dio：每个请求交给 [handler] 回答，请求都记在 [requests] 里
class FakeHttpAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  FakeHttpAdapter(this.handler);

  static Dio dio(FakeHttpAdapter adapter) => Dio()..httpClientAdapter = adapter;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return await handler(options);
  }

  @override
  void close({bool force = false}) {}

  /// 请求了这个地址的那些
  List<RequestOptions> to(String url) =>
      requests.where((e) => e.uri.toString() == url).toList();

  static ResponseBody json(
    Object? body, {
    int status = 200,
    Map<String, List<String>> headers = const {},
  }) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
          ...headers,
        },
      );

  static ResponseBody bytes(
    List<int> data, {
    int status = 200,
    Duration delay = Duration.zero,
  }) =>
      ResponseBody(
        Stream.fromFuture(
          Future.delayed(delay, () => Uint8List.fromList(data)),
        ),
        status,
        headers: {
          Headers.contentLengthHeader: ["${data.length}"],
          Headers.contentTypeHeader: ["application/octet-stream"],
        },
      );

  static ResponseBody text(String body, {int status = 200}) =>
      ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: ["text/plain"],
        },
      );

  static ResponseBody redirect(String location, {int status = 302}) =>
      ResponseBody(
        const Stream.empty(),
        status,
        isRedirect: true,
        headers: {
          "location": [location],
        },
      );
}
