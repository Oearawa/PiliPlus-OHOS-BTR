// Loopback proxy behaviour that matters for the player integration:
// one connection budget for both tracks, refusal of unsupported input, and a
// visible failure when the source cannot serve byte ranges so the player can
// fall back to the direct URL.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

class _Source {
  _Source(this.source);

  final Uint8List source;
  late HttpServer server;
  int delayMs = 0;

  /// Answer every request with 200 and the whole body (no Range support).
  bool ignoreRange = false;

  Uri uri(String name) => Uri.parse('http://127.0.0.1:${server.port}/$name');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    try {
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
      if (ignoreRange) {
        response.statusCode = HttpStatus.ok;
        response.headers.contentLength = source.length;
        response.add(source);
        await response.close();
        return;
      }
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
        // Client went away.
      }
    }
  }

  Future<void> close() => server.close(force: true);
}

Future<int> _status(HttpClient client, Uri uri) async {
  final HttpClientRequest request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
  final HttpClientResponse response = await request.close();
  await response.drain<void>();
  return response.statusCode;
}

void main() {
  late Uint8List bytes;
  late _Source source;
  late HttpClient client;

  setUp(() async {
    bytes = Uint8List.fromList(
      List<int>.generate(300000, (int i) => (i * 29 + 11) % 251),
    );
    source = _Source(bytes);
    await source.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await source.close();
  });

  test('video and audio share one connection budget', () async {
    source.delayMs = 25;
    final RipperRangeProxy proxy = RipperRangeProxy(
      settings: const RipperSettings(concurrency: 1),
      userAgent: 'test-player',
    );
    await proxy.start();
    try {
      final Uri video = proxy.register(<Uri>[source.uri('video.m4s')]);
      final Uri audio = proxy.register(
        <Uri>[source.uri('audio.m4s')],
        isAudio: true,
      );
      expect(proxy.trackCount, 2);
      await Future.wait(<Future<int>>[
        _status(client, video),
        _status(client, audio),
      ]);
      // One slot for the whole session: audio never doubles the budget.
      expect(proxy.semaphore.limit, 1);
      expect(proxy.semaphore.peakActive, 1);
    } finally {
      await proxy.close();
    }
  });

  test('a track without an http url is refused instead of proxied', () async {
    final RipperRangeProxy proxy = RipperRangeProxy(
      concurrency: 2,
      userAgent: 'test-player',
    );
    await proxy.start();
    try {
      expect(
        () => proxy.register(<Uri>[Uri.parse('ftp://example.com/a.m4s')]),
        throwsStateError,
      );
      expect(proxy.trackCount, 0);
    } finally {
      await proxy.close();
    }
  });

  test(
    'a source that ignores Range produces a 502 the player can fall back on',
    () async {
      source.ignoreRange = true;
      final RipperRangeProxy proxy = RipperRangeProxy(
        settings: const RipperSettings(concurrency: 2, maxRounds: 1),
        userAgent: 'test-player',
      );
      await proxy.start();
      try {
        final Uri track = proxy.register(<Uri>[source.uri('video.m4s')]);
        expect(await _status(client, track), HttpStatus.badGateway);
        // The session itself is still usable for another attempt (the player
        // simply retries with the direct URL after this).
        expect(proxy.port, greaterThan(0));
      } finally {
        await proxy.close();
      }
    },
  );

  test('registering before start is a state error, not a hang', () {
    final RipperRangeProxy proxy = RipperRangeProxy(
      concurrency: 2,
      userAgent: 'test-player',
    );
    expect(
      () => proxy.register(<Uri>[source.uri('video.m4s')]),
      throwsStateError,
    );
  });

  test('a closed proxy refuses new tracks', () async {
    final RipperRangeProxy proxy = RipperRangeProxy(
      concurrency: 2,
      userAgent: 'test-player',
    );
    await proxy.start();
    await proxy.close();
    expect(
      () => proxy.register(<Uri>[source.uri('video.m4s')]),
      throwsStateError,
    );
  });
}
