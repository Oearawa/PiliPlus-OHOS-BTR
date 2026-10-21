// Deterministic tests for the signals the adaptive scheduler reacts to.
//
// Everything is driven by an injected clock and a real [RipperSemaphore], so a
// level change is verified at the executor (the semaphore limit and the queued
// work it releases), not only in the controller's own counter.

import 'dart:async';

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:PiliPlus/services/thread_ripper/idm_downloader.dart';
import 'package:PiliPlus/services/thread_ripper/media_demand.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness {
  _Harness() {
    now = 0;
    semaphore = RipperSemaphore(8);
    auto = AutoConcurrency(
      semaphore: semaphore,
      maxConcurrency: 64,
      initialThreads: 8,
      now: () => now,
    );
  }

  late int now;
  late RipperSemaphore semaphore;
  late AutoConcurrency auto;
  final List<void Function()> releases = <void Function()>[];

  void start({
    int initial = 8,
    bool startup = false,
    RipperMediaDemand? demand,
  }) {
    auto.startSession(
      demand: demand,
      initialThreads: initial,
      startup: startup,
    );
  }

  /// Holds [held] slots and queues [queued] more.
  ///
  /// [held] must not exceed the current limit, otherwise this would block.
  Future<void> occupy(int held, {int queued = 0}) async {
    for (int i = 0; i < held; i += 1) {
      releases.add(await semaphore.acquire());
    }
    for (int i = 0; i < queued; i += 1) {
      unawaited(semaphore.acquire());
    }
  }

  void releaseAll() {
    for (final void Function() release in releases) {
      release();
    }
    releases.clear();
  }
}

void main() {
  group('activity gate', () {
    test('a low buffer does not raise threads while nothing is arriving', () async {
      final _Harness h = _Harness();
      h.start(startup: false);
      await h.occupy(1);
      h.auto.activity();
      // The player is starved, but the downloader delivered nothing for over
      // a second: the thread count is not what is missing.
      h.now = 3000;
      h.auto.buffer(3, true);
      h.now = 4100;
      h.auto.buffer(3, true);
      h.now = 5200;
      h.auto.buffer(3, true);
      expect(h.auto.threads, 8);
      expect(h.auto.downloading, isFalse);

      // Bytes flow again: the same low buffer is now evidence.
      h.auto.activity();
      h.now = 6400;
      h.auto.buffer(3, true);
      expect(h.auto.threads, 12);
      expect(h.semaphore.limit, 12);
      h.releaseAll();
    });

    test('activity ages out after one and a half seconds', () {
      final _Harness h = _Harness();
      h.start(startup: false);
      h.auto.activity();
      h.now = 1499;
      expect(h.auto.downloading, isTrue);
      h.now = 1501;
      expect(h.auto.downloading, isFalse);
      expect(h.auto.activityAgeMs, 1501);
    });
  });

  group('first byte timeout', () {
    test('lowers one rung at once and rests that rung', () async {
      final _Harness h = _Harness();
      h.start(initial: 16, startup: false);
      h.now = 3000;
      h.auto.firstByteTimeout();
      expect(h.auto.threads, 12);
      expect(h.semaphore.limit, 12);
      expect(h.auto.state, AutoConcurrencyState.backoff);
      expect(h.auto.inCooldown, isTrue);
      expect(h.auto.lastReason, contains('首个字节超时'));

      // A buffer emergency cannot escape the cooldown.
      h.now = 4000;
      h.auto.activity();
      h.auto.buffer(2, true, waiting: true);
      h.now = 5200;
      h.auto.buffer(2, true, waiting: true);
      expect(h.auto.threads, 12);

      // After the minute the refused rung may be probed again.
      h.now = 70000;
      h.auto.activity();
      h.auto.buffer(2, true, waiting: true);
      h.now = 71200;
      h.auto.buffer(2, true, waiting: true);
      h.now = 72400;
      h.auto.buffer(2, true, waiting: true);
      expect(h.auto.threads, 16);
      h.releaseAll();
    });

    test('never drops below the lowest rung', () {
      final _Harness h = _Harness();
      h.start(initial: 4, startup: false);
      h.now = 3000;
      h.auto.firstByteTimeout();
      expect(h.auto.threads, 4);
      expect(h.auto.state, AutoConcurrencyState.backoff);
    });
  });

  group('trial verdict', () {
    /// Raises 8 -> 12 at 4100 with a 1 MB/s baseline, then samples the window.
    Future<_Harness> pumpToTrial({
      required int held,
      required int queued,
    }) async {
      final _Harness h = _Harness();
      h.start(startup: false);
      await h.occupy(held, queued: queued);
      h.now = 3000;
      h.auto.buffer(3, true);
      h.now = 4000;
      h.auto.delivered(1024 * 1024);
      h.now = 4100;
      h.auto.buffer(3, true);
      expect(h.auto.threads, 12);
      for (int at = 4600; at <= 13500; at += 500) {
        h.now = at;
        h.auto.buffer(3, true);
      }
      // One megabyte inside the trial window, at the same rate as the
      // baseline: neither a gain nor a regression. The second delivery
      // triggers the verdict without a buffer sample that could step up
      // again right after it.
      h.now = 14000;
      h.auto.delivered(1024 * 1024);
      h.now = 14500;
      h.auto.delivered(1);
      return h;
    }

    test('no gain with saturated slots steps back', () async {
      // 8 slots held and 5 queued: after the step-up the limit is 12, so the
      // slots stay saturated for the whole window.
      final _Harness h = await pumpToTrial(held: 8, queued: 5);
      expect(h.auto.saturation(), greaterThanOrEqualTo(0.6));
      expect(h.auto.threads, 8);
      expect(h.auto.inCooldown, isTrue);
      h.releaseAll();
    });

    test('no gain while the slots sat idle keeps the rung', () async {
      final _Harness h = await pumpToTrial(held: 1, queued: 0);
      expect(h.auto.saturation(), lessThan(0.6));
      expect(h.auto.threads, 12);
      expect(h.auto.lastReason, contains('连接未饱和'));
      h.releaseAll();
    });
  });

  group('executor responsiveness', () {
    test('a level change releases queued work immediately', () async {
      final _Harness h = _Harness();
      h.start(initial: 8, startup: true);
      // Startup opens at 16; the semaphore must have been raised with it.
      expect(h.auto.threads, 16);
      expect(h.semaphore.limit, 16);
      await h.occupy(16, queued: 6);
      expect(h.semaphore.active, 16);
      expect(h.semaphore.queued, 6);

      h.now = 3000;
      h.auto.stall();
      // 16 -> 24: the queued waiters get the new slots without waiting for a
      // new request to arrive.
      expect(h.auto.threads, 24);
      expect(h.semaphore.limit, 24);
      expect(h.semaphore.active, 22);
      expect(h.semaphore.queued, 0);
      h.releaseAll();
    });

    test('the ladder never exceeds 64 threads', () {
      int now = 0;
      final RipperSemaphore semaphore = RipperSemaphore(8);
      final AutoConcurrency auto = AutoConcurrency(
        semaphore: semaphore,
        maxConcurrency: 512,
        initialThreads: 512,
        now: () => now,
      );
      expect(auto.maxThreads, AutoConcurrency.maxSupportedThreads);
      expect(auto.threads, 64);
      // A new session restarts from the media hint, but never above the
      // supported maximum.
      auto.startSession(startup: true);
      expect(auto.threads, lessThanOrEqualTo(64));

      int guard = 0;
      while (auto.threads < 64 && guard < 20) {
        guard += 1;
        now += 3000;
        auto.stall();
        now += 11000;
        // Enough bytes for the trial to be judged as "no gain, not idle".
        auto.delivered(2 * 1024 * 1024);
      }
      expect(auto.threads, 64);
      expect(semaphore.limit, 64);
      auto.close();
    });

    test('a limit change is clamped to the supported range', () {
      final RipperSemaphore semaphore = RipperSemaphore(16);
      expect(semaphore.limit, 16);
      semaphore.setLimit(0);
      expect(semaphore.limit, 1);
      semaphore.setLimit(9999);
      expect(semaphore.limit, 512);
    });
  });

  group('session reset', () {
    test('a new session clears saturation, activity and counters', () async {
      final _Harness h = _Harness();
      h.start(startup: false);
      await h.occupy(8, queued: 2);
      h.now = 4000;
      h.auto.buffer(3, true);
      h.now = 5000;
      h.auto.buffer(3, true);
      expect(h.auto.saturation(), greaterThan(0));
      h.auto.activity();
      h.auto.firstByteTimeout();
      expect(h.auto.status()['firstByteTimeouts'], 1);

      h.now = 5000;
      h.start(
        initial: 16,
        startup: true,
        demand: const RipperMediaDemand(videoBandwidth: 30000000),
      );
      expect(h.auto.saturation(), 0);
      expect(h.auto.activityAgeMs, isNull);
      expect(h.auto.status()['firstByteTimeouts'], 0);
      expect(h.auto.steps, lessThanOrEqualTo(1));
      h.releaseAll();
    });
  });
}
