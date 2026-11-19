// Host-only tests for the download engine: real loopback HTTP servers, strict
// 206/Content-Range validation, cancellation and the queue classes.
//
// This mirrors the role of upstream's `dev/optimization-test.js` and
// `dev/shared-core-test.js`, but with `dart:io` sockets instead of a mocked
// `fetch`.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/idm_downloader.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockCdn {
  _MockCdn(this.source);

  final Uint8List source;
  late HttpServer server;
  int active = 0;
  int peak = 0;
  int requests = 0;
  bool answerWith200 = false;
  bool wrongRange = false;
  Duration delay = Duration.zero;

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/media.m4s');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    active += 1;
    peak = math.max(peak, active);
    requests += 1;
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
      final int end = int.parse(match.group(2)!);
      if (answerWith200) {
        response.statusCode = HttpStatus.ok;
        response.headers.contentLength = source.length;
        response.add(source);
        await response.close();
        return;
      }
      final int reportedStart = wrongRange ? start + 1 : start;
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $reportedStart-$end/${source.length}',
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
    } finally {
      active -= 1;
    }
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late Uint8List source;
  late _MockCdn cdn;
  late CdnResolver resolver;
  late IdmDownloader downloader;

  setUp(() async {
    source = Uint8List.fromList(
      List<int>.generate(1100000, (int i) => (i * 37) % 251),
    );
    cdn = _MockCdn(source);
    await cdn.start();
    resolver = CdnResolver(<Uri>[cdn.uri]);
    downloader = IdmDownloader(
      settings: const RipperSettings(concurrency: 4, maxRounds: 1),
      userAgent: 'test-agent',
    );
  });

  tearDown(() async {
    downloader.close();
    await cdn.close();
  });

  test('raising an externally owned limit releases queued pieces', () async {
    final Uint8List large = Uint8List.fromList(
      List<int>.generate(4 * 1024 * 1024, (int i) => (i * 31) % 251),
    );
    final _MockCdn largeCdn = _MockCdn(large);
    await largeCdn.start();
    largeCdn.delay = const Duration(milliseconds: 80);
    final CdnResolver largeResolver = CdnResolver(<Uri>[largeCdn.uri]);
    try {
      downloader.semaphore.setLimit(1);
      final Future<DownloadResult> future = downloader.downloadRange(
        ByteRange(0, large.length - 1),
        largeResolver,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      downloader.semaphore.setLimit(4);
      await future;
      expect(downloader.semaphore.peakActive, greaterThan(1));
      expect(downloader.semaphore.limit, 4);
    } finally {
      await largeCdn.close();
    }
  });

  test('downloads a range in parallel and flushes it in file order', () async {
    final BytesBuilder received = BytesBuilder(copy: false);
    final List<ByteRange> pieces = <ByteRange>[];
    final DownloadResult result = await downloader.downloadRange(
      ByteRange(0, source.length - 1),
      resolver,
      onOrderedChunk: (Uint8List bytes, ByteRange piece, int? total) {
        expect(total, source.length);
        pieces.add(piece);
        received.add(bytes);
      },
    );
    expect(result.total, source.length);
    expect(received.takeBytes(), source);
    expect(pieces.first.start, 0);
    expect(pieces.last.end, source.length - 1);
    // Measure the semaphore's own peak instead of the mock server's handler
    // count: on a fast CI loopback the server may finish one response before
    // the next handler starts, which made >1 flaky even though the client had
    // already acquired four slots.
    expect(downloader.semaphore.peakActive, greaterThan(1));
    expect(downloader.semaphore.peakActive, lessThanOrEqualTo(4));
  });

  test('two range jobs share the same semaphore ceiling', () async {
    downloader.semaphore.setLimit(2);
    final Uint8List large = Uint8List.fromList(
      List<int>.generate(2 * 1024 * 1024, (int i) => (i * 17) % 251),
    );
    final _MockCdn largeCdn = _MockCdn(large);
    await largeCdn.start();
    largeCdn.delay = const Duration(milliseconds: 20);
    final CdnResolver largeResolver = CdnResolver(<Uri>[largeCdn.uri]);
    try {
      await Future.wait(<Future<DownloadResult>>[
        downloader.downloadRange(
          ByteRange(0, large.length - 1),
          largeResolver,
        ),
        downloader.downloadRange(
          ByteRange(0, large.length - 1),
          largeResolver,
        ),
      ]);
      expect(downloader.semaphore.peakActive, lessThanOrEqualTo(2));
    } finally {
      await largeCdn.close();
    }
  });

  test('does not reset an externally raised semaphore limit', () async {
    // This is the integration boundary that the auto controller owns. The
    // downloader used to call setLimit(settings.concurrency) on every range,
    // silently undoing every automatic level-up.
    downloader.semaphore.setLimit(16);
    await downloader.downloadRange(
      ByteRange(0, source.length - 1),
      resolver,
    );
    expect(downloader.semaphore.limit, 16);
  });

  test('rejects a 200 response instead of treating it as media', () async {
    cdn.answerWith200 = true;
    await expectLater(
      downloader.downloadRange(const ByteRange(0, 65535), resolver),
      throwsA(isA<RipperHttpException>()),
    );
  });

  test('rejects a mismatched Content-Range', () async {
    cdn.wrongRange = true;
    await expectLater(
      downloader.downloadRange(const ByteRange(0, 65535), resolver),
      throwsA(isA<RipperHttpException>()),
    );
  });

  test('an abort signal cancels an in-flight range', () async {
    cdn.delay = const Duration(seconds: 5);
    final RipperAbortSignal signal = RipperAbortSignal();
    final Future<DownloadResult> pending = downloader.downloadRange(
      const ByteRange(0, 65535),
      resolver,
      signal: signal,
    );
    Timer(const Duration(milliseconds: 150), signal.abort);
    final Stopwatch watch = Stopwatch()..start();
    await expectLater(pending, throwsA(isA<RipperAbortException>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('semaphore keeps the limit and serves critical work first', () async {
    final RipperSemaphore semaphore = RipperSemaphore(1);
    final void Function() release = await semaphore.acquire();
    expect(semaphore.active, 1);

    final Completer<String> order = Completer<String>();
    unawaited(
      semaphore.acquire(queueClass: QueueClass.ordinary).then((
        void Function() releaseOrdinary,
      ) {
        if (!order.isCompleted) order.complete('ordinary');
        releaseOrdinary();
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    unawaited(
      semaphore.acquire(queueClass: QueueClass.critical).then((
        void Function() releaseCritical,
      ) {
        if (!order.isCompleted) order.complete('critical');
        releaseCritical();
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(semaphore.queued, 2);
    release();
    expect(await order.future, 'critical');
    expect(semaphore.active, lessThanOrEqualTo(1));
  });
}
