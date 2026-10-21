// Deterministic host tests for the adaptive range-download controller.
//
// No real Bilibili network is used here. The tests inject the clock and use a
// real RipperSemaphore, so they verify that a level change reaches the
// executor's actual limit instead of only changing a displayed number.

import 'dart:async';

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:PiliPlus/services/thread_ripper/idm_downloader.dart';
import 'package:PiliPlus/services/thread_ripper/media_demand.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness {
  _Harness({int max = 64, int initial = 8}) {
    now = 0;
    semaphore = RipperSemaphore(initial);
    auto = AutoConcurrency(
      semaphore: semaphore,
      maxConcurrency: max,
      initialThreads: initial,
      now: () => now,
    );
  }

  late int now;
  late RipperSemaphore semaphore;
  late AutoConcurrency auto;

  void start({
    RipperMediaDemand? demand,
    int? initialThreads,
    bool startup = false,
  }) {
    auto.startSession(
      demand: demand,
      initialThreads: initialThreads,
      startup: startup,
    );
  }

  Future<List<void Function()>> occupy(int count) async {
    final List<void Function()> releases = <void Function()>[];
    for (int i = 0; i < count; i += 1) {
      releases.add(await semaphore.acquire(priority: 0));
    }
    return releases;
  }

  void queueOne() {
    unawaited(semaphore.acquire(priority: 0));
  }

  void lowBufferAt(int at, {double ahead = 3}) {
    now = at;
    auto.buffer(ahead, true, waiting: true);
  }

  void growTo64() {
    int guard = 0;
    while (auto.threads < 64 && guard < 20) {
      guard += 1;
      now += 3000;
      auto.stall();
      now += 10000;
      // A real completed piece makes the trial measurable; baseline 0 means a
      // gain is accepted, so this test is about reaching the hard maximum.
      auto.delivered(2 * 1024 * 1024);
    }
  }
}

void main() {
  group('media prior', () {
    test('maps the upstream bandwidth bands to initial rungs', () {
      expect(
        const RipperMediaDemand(
          videoBandwidth: 4000000,
        ).suggestedInitialThreads(),
        8,
      );
      expect(
        const RipperMediaDemand(
          videoBandwidth: 8000000,
        ).suggestedInitialThreads(),
        12,
      );
      expect(
        const RipperMediaDemand(
          videoBandwidth: 20000000,
        ).suggestedInitialThreads(),
        16,
      );
      expect(
        const RipperMediaDemand(
          videoBandwidth: 40000000,
        ).suggestedInitialThreads(),
        24,
      );
      expect(
        const RipperMediaDemand(
          videoBandwidth: 80000000,
        ).suggestedInitialThreads(),
        32,
      );
    });

    test('adds audio bandwidth and falls back to resolution when absent', () {
      expect(
        const RipperMediaDemand(
          videoBandwidth: 22000000,
          audioBandwidth: 4000000,
        ).suggestedInitialThreads(),
        24,
      );
      expect(
        const RipperMediaDemand(
          width: 1920,
          height: 1080,
          frameRate: 60,
        ).suggestedInitialThreads(),
        12,
      );
      expect(
        const RipperMediaDemand(
          width: 3840,
          height: 2160,
          frameRate: 60,
        ).suggestedInitialThreads(),
        32,
      );
      // HDR/DV alone must not manufacture a high bitrate.
      expect(
        const RipperMediaDemand(
          width: 1920,
          height: 1080,
          isHdr: true,
          isDolbyVision: true,
        ).suggestedInitialThreads(),
        8,
      );
    });

    test('rejects implausible metadata and accepts 64 via feedback', () {
      const RipperMediaDemand bad = RipperMediaDemand(
        videoBandwidth: 0,
        audioBandwidth: 1,
      );
      expect(bad.estimatedDemandMbps, isNull);
      expect(bad.suggestedInitialThreads(), 8);

      final _Harness h = _Harness();
      h.start(initialThreads: 8, startup: false);
      h.growTo64();
      expect(h.auto.threads, 64);
      expect(h.semaphore.limit, 64);
    });
  });

  group('state machine', () {
    test('startup starts at 16 and steps back with a full buffer', () {
      final _Harness h = _Harness();
      h.start(
        demand: const RipperMediaDemand(videoBandwidth: 4000000),
        startup: true,
      );
      expect(h.auto.state, AutoConcurrencyState.startup);
      expect(h.auto.threads, 16);

      h.now = 2600;
      h.auto.buffer(20, true);
      expect(h.auto.threads, 16);
      h.now = 5200;
      h.auto.buffer(20, true);
      expect(h.auto.threads, 12);
      h.now = 7800;
      h.auto.buffer(20, true);
      expect(h.auto.threads, 8);
      expect(h.auto.state, AutoConcurrencyState.stable);
    });

    test('cacheFull finishes startup before the 15 second threshold', () {
      final _Harness h = _Harness();
      h.start(initialThreads: 8, startup: true);
      expect(h.auto.threads, 16);

      h.now = 0;
      h.auto.buffer(10, true, cacheFull: true);
      h.now = 2500;
      h.auto.buffer(10, true, cacheFull: true);
      expect(h.auto.threads, 12);
      h.now = 5000;
      h.auto.buffer(10, true, cacheFull: true);
      expect(h.auto.threads, 8);
      expect(h.auto.state, AutoConcurrencyState.stable);
    });

    test('cacheFull false keeps waiting for the ordinary threshold', () {
      final _Harness h = _Harness();
      h.start(initialThreads: 8, startup: true);
      h.now = 0;
      h.auto.buffer(10, true, cacheFull: false);
      h.now = 2500;
      h.auto.buffer(10, true, cacheFull: false);
      h.now = 5000;
      h.auto.buffer(10, true, cacheFull: false);
      expect(h.auto.threads, 16);
      expect(h.auto.state, AutoConcurrencyState.startup);
    });

    test('startup timeout keeps the current rung and enters stable', () {
      final _Harness h = _Harness();
      h.start(initialThreads: 8, startup: true);
      expect(h.auto.threads, 16);
      h.now = 31000;
      h.auto.buffer(10, true);
      expect(h.auto.state, AutoConcurrencyState.stable);
      expect(h.auto.threads, 16);
    });

    test(
      'low buffer with active work steps up after the pressure window',
      () async {
        final _Harness h = _Harness();
        h.start(initialThreads: 8, startup: false);
        final List<void Function()> releases = await h.occupy(7);
        h.queueOne();

        h.lowBufferAt(3000);
        h.lowBufferAt(4100);
        h.lowBufferAt(5200);
        expect(h.auto.threads, 12);
        expect(h.semaphore.limit, 12);
        for (final void Function() release in releases) {
          release();
        }
      },
    );

    test('dropping buffer at capacity steps up without metadata', () async {
      final _Harness h = _Harness();
      h.start(initialThreads: 8, startup: false);
      final List<void Function()> releases = await h.occupy(7);
      h.queueOne();
      h.now = 0;
      h.auto.buffer(10, true);
      h.now = 4000;
      h.auto.buffer(3, true);
      h.now = 5000;
      h.auto.buffer(3, true);
      expect(h.auto.threads, greaterThan(8));
      for (final void Function() release in releases) {
        release();
      }
    });

    test('a probe with enough gain keeps the higher rung', () async {
      final _Harness h = _Harness();
      h.start(initialThreads: 8, startup: false);
      final List<void Function()> releases = await h.occupy(1);
      h.lowBufferAt(3000);
      h.lowBufferAt(4100);
      h.lowBufferAt(5200);
      expect(h.auto.threads, 12);
      h.now = 15200;
      h.auto.delivered(2 * 1024 * 1024);
      expect(h.auto.threads, 12);
      expect(h.auto.state, AutoConcurrencyState.stable);
      releases.single();
    });

    test('insufficient probe samples do not roll back', () async {
      final _Harness h = _Harness();
      h.start(initialThreads: 8, startup: false);
      final List<void Function()> releases = await h.occupy(1);
      h.lowBufferAt(3000);
      h.lowBufferAt(4100);
      h.lowBufferAt(5200);
      expect(h.auto.threads, 12);
      h.now = 15200;
      h.auto.delivered(1);
      expect(h.auto.threads, 12);
      expect(h.auto.lastReason, contains('样本不足'));
      releases.single();
    });

    test('a failed probe rolls back and cools down', () async {
      final _Harness h = _Harness();
      h.start(initialThreads: 8, startup: false);
      h.now = 0;
      h.auto.delivered(1024 * 1024);
      h.now = 1000;
      h.auto.delivered(1024 * 1024);
      final List<void Function()> releases = await h.occupy(1);
      h.lowBufferAt(3000);
      h.lowBufferAt(4100);
      h.lowBufferAt(5200);
      expect(h.auto.threads, 12);
      h.now = 15200;
      h.auto.delivered(150 * 1024);
      expect(h.auto.threads, 8);
      expect(h.auto.inCooldown, isTrue);
      h.now = 16200;
      h.auto.buffer(2, true, waiting: true);
      expect(h.auto.threads, 8);
      releases.single();
    });

    test('comfortable buffer and throughput surplus step down', () {
      final _Harness h = _Harness();
      h.start(
        demand: const RipperMediaDemand(videoBandwidth: 1000000),
        initialThreads: 8,
        startup: false,
      );
      h.now = 0;
      h.auto.delivered(4 * 1024 * 1024);
      h.auto.buffer(20, true);
      h.now = 1000;
      h.auto.buffer(20, true);
      h.now = 16000;
      h.auto.delivered(4 * 1024 * 1024);
      h.auto.buffer(20, true);
      expect(h.auto.threads, 4);
    });
  });

  group('failure and session isolation', () {
    test('HTTP 412 backs off, lowers one rung and blocks probing', () {
      final _Harness h = _Harness();
      h.start(initialThreads: 16, startup: false);
      h.now = 3000;
      h.auto.pushback(412);
      expect(h.auto.threads, 12);
      expect(h.auto.state, AutoConcurrencyState.backoff);
      expect(h.auto.inCooldown, isTrue);
      h.now = 4000;
      h.auto.buffer(2, true, waiting: true);
      expect(h.auto.threads, 12);
    });

    test('403/404 are not treated as concurrency pushback', () {
      final _Harness h = _Harness();
      h.start(initialThreads: 16, startup: false);
      h.now = 3000;
      h.auto.pushback(403);
      h.auto.pushback(404);
      expect(h.auto.threads, 16);
      expect(h.auto.inCooldown, isFalse);
    });

    test('three timeouts lower one rung, one does not', () {
      final _Harness h = _Harness();
      h.start(initialThreads: 16, startup: false);
      h.now = 1000;
      h.auto.slow(timeout: true);
      expect(h.auto.threads, 16);
      h.now = 2000;
      h.auto.slow(timeout: true);
      expect(h.auto.threads, 16);
      h.now = 3000;
      h.auto.slow(timeout: true);
      expect(h.auto.threads, 12);
    });

    test('new session resets media stats and ignores stale callbacks', () {
      final _Harness h = _Harness();
      h.start(initialThreads: 8, startup: false);
      final int old = h.auto.sessionId;
      h.now = 3000;
      h.auto.stall();
      expect(h.auto.threads, 12);

      h.start(
        demand: const RipperMediaDemand(videoBandwidth: 60000000),
        initialThreads: 32,
        startup: false,
      );
      final int fresh = h.auto.sessionId;
      expect(fresh, isNot(old));
      expect(h.auto.threads, 32);
      h.auto.buffer(1, true, session: old);
      h.auto.delivered(9999999, session: old);
      expect(h.auto.threads, 32);
      expect(h.auto.sessionId, fresh);
    });

    test('seek restarts startup and pause does not ratchet', () async {
      final _Harness h = _Harness();
      h.start(initialThreads: 8, startup: false);
      final List<void Function()> releases = await h.occupy(1);
      h.now = 3000;
      h.auto.buffer(3, true);
      h.now = 4100;
      h.auto.buffer(3, true);
      expect(h.auto.threads, greaterThan(8));
      h.auto.seekStarted();
      expect(h.auto.state, AutoConcurrencyState.startup);
      expect(h.auto.threads, greaterThanOrEqualTo(16));

      final int beforePause = h.auto.threads;
      h.now = 6000;
      h.auto.buffer(1, false);
      h.now = 8000;
      h.auto.buffer(1, false);
      expect(h.auto.threads, beforePause);
      releases.single();
    });

    test('HDR/DV high-bitrate stream selects a high initial rung', () {
      const RipperMediaDemand dv = RipperMediaDemand(
        videoBandwidth: 60000000,
        audioBandwidth: 3000000,
        width: 3840,
        height: 2160,
        frameRate: 60,
        isHdr: true,
        isDolbyVision: true,
      );
      final _Harness h = _Harness();
      h.start(demand: dv, startup: true);
      expect(h.auto.threads, greaterThanOrEqualTo(24));
      expect(h.auto.threads, lessThanOrEqualTo(32));
      expect(h.auto.demand?.isDolbyVision, isTrue);
    });
  });
}
