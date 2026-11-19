// Host tests for the player-facing bridge: it must start a loopback session,
// expose the proxied URLs, replace a previous session and stay inactive when
// it gets no usable candidates.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/media_demand.dart';
import 'package:PiliPlus/services/thread_ripper/player_bridge.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockCdn {
  _MockCdn(this.source);

  final Uint8List source;
  late HttpServer server;

  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/media.m4s');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final HttpResponse response = request.response;
      try {
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
    });
  }

  Future<void> close() => server.close(force: true);
}

Future<Uint8List> _get(HttpClient client, String url) async {
  final HttpClientRequest request = await client.getUrl(Uri.parse(url));
  final HttpClientResponse response = await request.close();
  final BytesBuilder builder = BytesBuilder(copy: false);
  await for (final List<int> chunk in response) {
    builder.add(chunk);
  }
  expect(response.statusCode, HttpStatus.ok);
  return builder.takeBytes();
}

void main() {
  late Uint8List source;
  late _MockCdn cdn;
  late _MockCdn audioCdn;
  late HttpClient client;

  setUp(() async {
    source = Uint8List.fromList(
      List<int>.generate(320000, (int i) => (i * 29 + 3) % 251),
    );
    cdn = _MockCdn(source);
    audioCdn = _MockCdn(source);
    await cdn.start();
    await audioCdn.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await RipperPlayerBridge.instance.close();
    await cdn.close();
    await audioCdn.close();
  });

  test('opens a session and serves video and audio tracks', () async {
    final bool started = await RipperPlayerBridge.instance.open(
      videoUrls: <Uri>[cdn.uri],
      audioUrls: <Uri>[audioCdn.uri],
      settings: const RipperSettings(concurrency: 8),
      userAgent: 'bridge-test',
    );
    expect(started, isTrue);
    expect(RipperPlayerBridge.instance.isActive, isTrue);
    expect(RipperPlayerBridge.instance.hasAudio, isTrue);
    expect(
      RipperPlayerBridge.instance.proxiedVideoUrl,
      startsWith('http://127.0.0.1:'),
    );
    expect(
      RipperPlayerBridge.instance.proxiedAudioUrl,
      startsWith('http://127.0.0.1:'),
    );
    expect(
      await _get(client, RipperPlayerBridge.instance.proxiedVideoUrl),
      source,
    );
    expect(
      await _get(client, RipperPlayerBridge.instance.proxiedAudioUrl),
      source,
    );
    expect(RipperPlayerBridge.instance.autoConcurrency, isNotNull);
    final int threads = RipperPlayerBridge.instance.autoConcurrency!.threads;
    RipperPlayerBridge.instance.onStall();
    expect(
      RipperPlayerBridge.instance.autoConcurrency!.threads,
      greaterThanOrEqualTo(threads),
    );
  });

  test('auto mode uses the media prior up to 64', () async {
    final bool started = await RipperPlayerBridge.instance.open(
      videoUrls: <Uri>[cdn.uri],
      audioUrls: const <Uri>[],
      settings: const RipperSettings(concurrency: 8),
      userAgent: 'bridge-test',
      media: const RipperMediaDemand(
        videoBandwidth: 60000000,
        width: 3840,
        height: 2160,
        frameRate: 60,
        isHdr: true,
        isDolbyVision: true,
      ),
      auto: true,
    );
    expect(started, isTrue);
    final auto = RipperPlayerBridge.instance.autoConcurrency!;
    expect(auto.maxThreads, 64);
    expect(auto.threads, greaterThanOrEqualTo(24));
  });

  test('manual mode has no automatic controller', () async {
    final bool started = await RipperPlayerBridge.instance.open(
      videoUrls: <Uri>[cdn.uri],
      audioUrls: const <Uri>[],
      settings: const RipperSettings(concurrency: 8),
      userAgent: 'bridge-test',
      auto: false,
    );
    expect(started, isTrue);
    expect(RipperPlayerBridge.instance.autoConcurrency, isNull);
  });

  test('empty candidates keep the bridge inactive', () async {
    expect(
      await RipperPlayerBridge.instance.open(
        videoUrls: const <Uri>[],
        audioUrls: const <Uri>[],
      ),
      isFalse,
    );
    expect(RipperPlayerBridge.instance.isActive, isFalse);
  });

  test('a second open replaces the previous session', () async {
    expect(
      await RipperPlayerBridge.instance.open(
        videoUrls: <Uri>[cdn.uri],
        audioUrls: const <Uri>[],
        settings: const RipperSettings(concurrency: 8),
      ),
      isTrue,
    );
    final String first = RipperPlayerBridge.instance.proxiedVideoUrl;
    expect(
      await RipperPlayerBridge.instance.open(
        videoUrls: <Uri>[cdn.uri],
        audioUrls: const <Uri>[],
        settings: const RipperSettings(concurrency: 8),
      ),
      isTrue,
    );
    expect(RipperPlayerBridge.instance.proxiedVideoUrl, isNot(first));
    expect(
      await _get(client, RipperPlayerBridge.instance.proxiedVideoUrl),
      source,
    );
  });

  test('close is idempotent', () async {
    await RipperPlayerBridge.instance.close();
    await RipperPlayerBridge.instance.close();
    expect(RipperPlayerBridge.instance.isActive, isFalse);
    expect(RipperPlayerBridge.instance.proxiedVideoUrl, isEmpty);
  });
}
