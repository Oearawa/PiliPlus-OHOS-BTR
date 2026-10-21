// End-to-end host tests for the loopback range proxy: a real `HttpServer`
// plays the CDN, another one is the proxy, and a plain `HttpClient` plays the
// player asking for byte ranges.
//
// Mirrors the role of upstream's browser tests (`dev/regression-smoke-test.js`)
// without a browser.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

class _SourceServer {
  _SourceServer(this.source);

  final Uint8List source;
  late HttpServer server;
  Duration delay = Duration.zero;

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/video.m4s');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final String? header = request.headers.value(HttpHeaders.rangeHeader);
      final RegExpMatch? match = RegExp(
        r'^bytes=(\d+)-(\d+)$',
      ).firstMatch(header ?? '');
      if (match == null) {
        response.statusCode = HttpStatus.badRequest;
        await response.close();
        return;
      }
      final int start = int.parse(match.group(1)!);
      final int end = math.min(int.parse(match.group(2)!), source.length - 1);
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${source.length}',
      );
      response.headers.contentLength = end - start + 1;
      response.add(Uint8List.sublistView(source, start, end + 1));
      await response.close();
    } on Object {
      try {
        await response.close();
      } on Object {
        // Client gone.
      }
    }
  }

  Future<void> close() => server.close(force: true);
}

class _Result {
  _Result(this.status, this.bytes, this.headers);

  final int status;
  final Uint8List bytes;
  final HttpHeaders headers;
}

Future<_Result> _request(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  String? range,
}) async {
  final HttpClientRequest request = await client.openUrl(method, uri);
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
  final HttpClientResponse response = await request.close();
  final BytesBuilder builder = BytesBuilder(copy: false);
  await for (final List<int> chunk in response) {
    builder.add(chunk);
  }
  return _Result(response.statusCode, builder.takeBytes(), response.headers);
}

void main() {
  late Uint8List source;
  late _SourceServer cdn;
  late RipperRangeProxy proxy;
  late HttpClient client;
  late Uri media;

  setUp(() async {
    source = Uint8List.fromList(
      List<int>.generate(1100000, (int i) => (i * 53 + 7) % 251),
    );
    cdn = _SourceServer(source);
    await cdn.start();
    proxy = RipperRangeProxy(concurrency: 4, userAgent: 'test-player');
    await proxy.start();
    media = proxy.register(<Uri>[cdn.uri]);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await proxy.close();
    await cdn.close();
  });

  test('serves a whole track with 200 and exact bytes', () async {
    final _Result result = await _request(client, media);
    expect(result.status, HttpStatus.ok);
    expect(result.bytes, source);
    expect(result.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
  });

  test('serves a bounded, an open-ended and a suffix range', () async {
    final _Result bounded = await _request(
      client,
      media,
      range: 'bytes=100-199',
    );
    expect(bounded.status, HttpStatus.partialContent);
    expect(bounded.bytes, source.sublist(100, 200));
    expect(
      bounded.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-199/${source.length}',
    );

    final _Result open = await _request(client, media, range: 'bytes=1099000-');
    expect(open.bytes, source.sublist(1099000));

    final _Result suffix = await _request(client, media, range: 'bytes=-100');
    expect(suffix.bytes, source.sublist(source.length - 100));
  });

  test('answers HEAD without a body', () async {
    final _Result result = await _request(client, media, method: 'HEAD');
    expect(result.status, HttpStatus.ok);
    expect(result.bytes, isEmpty);
    expect(
      result.headers.value(HttpHeaders.contentLengthHeader),
      '${source.length}',
    );
  });

  test('answers an unsatisfiable range with 416', () async {
    final _Result result = await _request(
      client,
      media,
      range: 'bytes=${source.length + 10}-',
    );
    expect(result.status, HttpStatus.requestedRangeNotSatisfiable);
  });

  test('does not serve an unregistered path', () async {
    final Uri unknown = Uri.parse('http://127.0.0.1:${proxy.port}/not-a-track');
    final _Result result = await _request(client, unknown);
    expect(result.status, HttpStatus.notFound);
  });

  test('closing the proxy cancels the in-flight request', () async {
    cdn.delay = const Duration(seconds: 5);
    final Future<_Result> pending = _request(client, media);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await proxy.close();
    await expectLater(
      pending.timeout(const Duration(seconds: 3)),
      throwsA(anything),
    );
  });
}
