// Host tests for the parts of the download engine the auto-concurrency layer
// depends on: duplicate suppression, timeout classification and recovery.
//
// A real loopback `HttpServer` plays the CDN. Every scenario is driven by
// counters and short timeouts, so nothing here depends on Bilibili.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/idm_downloader.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _Cdn {
  _Cdn(this.source);

  final Uint8List source;
  late HttpServer server;

  int requests = 0;
  final List<String> ranges = <String>[];
  int delayMs = 0;

  /// Answer the first N requests with this status (0 disables).
  int failStatus = 0;
  int failFirst = 0;

  /// Wait this long before sending response headers on the first N requests.
  int slowHeaderMs = 0;
  int slowHeaderFirst = 0;

  /// Send half of the body, then wait longer than the stall timeout.
  bool stallBody = false;

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/media.m4s');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    final int index = requests;
    requests += 1;
    final String? header = request.headers.value(HttpHeaders.rangeHeader);
    ranges.add(header ?? '');
    final HttpResponse response = request.response;
    try {
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
      if (index < slowHeaderFirst) {
        await Future<void>.delayed(Duration(milliseconds: slowHeaderMs));
      }
      if (failStatus > 0 && index < failFirst) {
        response.statusCode = failStatus;
        await response.close();
        return;
      }
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
      final Uint8List body = Uint8List.sublistView(source, start, end + 1);
      if (stallBody && body.length > 1) {
        final int half = body.length ~/ 2;
        response.add(Uint8List.sublistView(body, 0, half));
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        response.add(Uint8List.sublistView(body, half));
      } else {
        response.add(body);
      }
      await response.close();
    } on Object {
      try {
        await response.close();
      } on Object {
        // The client gave up.
      }
    }
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late Uint8List source;
  late _Cdn cdn;
  late CdnResolver resolver;
  late List<int> statuses;

  setUp(() async {
    source = Uint8List.fromList(
      List<int>.generate(400000, (int i) => (i * 41 + 3) % 251),
    );
    cdn = _Cdn(source);
    await cdn.start();
    resolver = CdnResolver(<Uri>[cdn.uri]);
    statuses = <int>[];
  });

  tearDown(() async {
    await cdn.close();
  });

  IdmDownloader downloader({
    int concurrency = 4,
    int maxRounds = 1,
    Duration firstByte = const Duration(seconds: 2),
    Duration stall = const Duration(seconds: 2),
  }) {
    final IdmDownloader instance = IdmDownloader(
      settings: RipperSettings(
        concurrency: concurrency,
        maxRounds: maxRounds,
        firstByteTimeout: firstByte,
        stallTimeout: stall,
        attemptTimeout: const Duration(seconds: 10),
      ),
      userAgent: 'test-agent',
    );
    instance.onHttpStatus = statuses.add;
    return instance;
  }

  group('duplicate suppression', () {
    test('the same byte range is transferred once', () async {
      final IdmDownloader engine = downloader(concurrency: 2);
      cdn.delayMs = 40;
      final ByteRange range = ByteRange(0, source.length - 1);
      await Future.wait(<Future<DownloadResult>>[
        engine.downloadRange(range, resolver, trackKey: 'video'),
        engine.downloadRange(range, resolver, trackKey: 'video'),
      ]);
      // Two pieces per window, so exactly two CDN requests: the second caller
      // waited for the transfer already in flight.
      expect(cdn.requests, 2);
      expect(cdn.ranges.toSet().length, 2);
      engine.close();
    });

    test('video and audio never share a transfer', () async {
      final IdmDownloader engine = downloader(concurrency: 2);
      cdn.delayMs = 40;
      final ByteRange range = ByteRange(0, source.length - 1);
      await Future.wait(<Future<DownloadResult>>[
        engine.downloadRange(range, resolver, trackKey: 'video'),
        engine.downloadRange(range, resolver, trackKey: 'audio'),
      ]);
      expect(cdn.requests, 4);
      engine.close();
    });

    test('a caller that gives up does not cancel the shared transfer', () async {
      final IdmDownloader engine = downloader(concurrency: 1);
      cdn.delayMs = 120;
      final ByteRange range = ByteRange(0, 65535);
      // The first caller owns the transfer; the second one only waits for it.
      final Future<DownloadResult> kept = engine.downloadRange(
        range,
        resolver,
        trackKey: 'video',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final RipperAbortSignal signal = RipperAbortSignal();
      final Future<DownloadResult> abandoned = engine.downloadRange(
        range,
        resolver,
        signal: signal,
        trackKey: 'video',
      );
      final Future<void> expectation = expectLater(
        abandoned,
        throwsA(isA<RipperAbortException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      signal.abort();
      await expectation;
      final DownloadResult result = await kept;
      expect(result.byteLength, 65536);
      expect(cdn.requests, 1);
      engine.close();
    });
  });

  group('timeout classification', () {
    test('a missing first byte is reported as -1 and retried', () async {
      final IdmDownloader engine = downloader(
        maxRounds: 2,
        firstByte: const Duration(milliseconds: 120),
      );
      cdn.slowHeaderFirst = 1;
      cdn.slowHeaderMs = 400;
      final DownloadResult result = await engine.downloadRange(
        const ByteRange(0, 65535),
        resolver,
      );
      expect(statuses, contains(-1));
      expect(result.byteLength, 65536);
      engine.close();
    });

    test('a stalled body is reported as -2, not as a first-byte timeout', () async {
      final IdmDownloader engine = downloader(
        stall: const Duration(milliseconds: 120),
      );
      cdn.stallBody = true;
      await expectLater(
        engine.downloadRange(const ByteRange(0, 65535), resolver),
        throwsA(isA<RipperHttpException>()),
      );
      expect(statuses, contains(-2));
      expect(statuses, isNot(contains(-1)));
      engine.close();
    });
  });

  group('server pushback and recovery', () {
    test('412 is reported to the controller', () async {
      final IdmDownloader engine = downloader();
      cdn.failStatus = 412;
      cdn.failFirst = 10;
      await expectLater(
        engine.downloadRange(const ByteRange(0, 65535), resolver),
        throwsA(isA<RipperHttpException>()),
      );
      expect(statuses, contains(412));
      engine.close();
    });

    test('a piece that failed once succeeds on the next round', () async {
      final IdmDownloader engine = downloader(maxRounds: 2);
      cdn.failStatus = 503;
      cdn.failFirst = 1;
      final DownloadResult result = await engine.downloadRange(
        const ByteRange(0, 65535),
        resolver,
      );
      expect(result.byteLength, 65536);
      expect(statuses, contains(503));
      engine.close();
    });
  });

  test('body chunks are reported as activity', () async {
    final IdmDownloader engine = downloader(concurrency: 2);
    final List<int> chunks = <int>[];
    engine.onActivity = chunks.add;
    await engine.downloadRange(ByteRange(0, source.length - 1), resolver);
    expect(chunks, isNotEmpty);
    expect(chunks.reduce((int a, int b) => a + b), source.length);
    expect(engine.activityAgeMs, isNotNull);
    engine.close();
  });

  test('a cancelled attempt keeps its slot accounting clean', () async {
    final IdmDownloader engine = downloader(concurrency: 1);
    cdn.delayMs = 200;
    final RipperAbortSignal signal = RipperAbortSignal();
    final Future<DownloadResult> pending = engine.downloadRange(
      ByteRange(0, source.length - 1),
      resolver,
      signal: signal,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    signal.abort();
    await expectLater(pending, throwsA(isA<RipperAbortException>()));
    // Every acquired slot was released: the semaphore is empty again.
    expect(engine.semaphore.active, 0);
    expect(engine.semaphore.queued, 0);
    engine.close();
  });
}
