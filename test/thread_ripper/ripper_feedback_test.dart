// Deterministic tests for the media_kit feedback helpers used by BTR.
//
// These do not pretend to be a player integration test: they verify the query
// coalescing/session checks and the restart guard state transitions that are
// hard to exercise through media_kit's event stream.

import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/utils/ripper_feedback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cache-full probe', () {
    test('coalesces reads and honors the minimum interval', () {
      int now = 0;
      final RipperCacheFullProbe probe = RipperCacheFullProbe(
        minInterval: const Duration(milliseconds: 500),
        now: () => now,
      );

      final int? first = probe.begin(session: 1);
      expect(first, isNotNull);
      expect(probe.inFlight, isTrue);
      expect(probe.begin(session: 1), isNull);

      probe.complete(first!, session: 1, value: 'yes');
      expect(probe.cacheFull, isTrue);
      expect(probe.inFlight, isFalse);

      now = 100;
      expect(probe.begin(session: 1), isNull);
      now = 600;
      final int? second = probe.begin(session: 1);
      expect(second, isNotNull);
      probe.complete(second!, session: 1, value: 'no');
      expect(probe.cacheFull, isFalse);
    });

    test('unknown and failed reads safely mean false', () {
      int now = 0;
      final RipperCacheFullProbe probe = RipperCacheFullProbe(now: () => now);
      final int? first = probe.begin(session: 1);
      probe.complete(first!, session: 1, value: '');
      expect(probe.cacheFull, isFalse);

      now = 600;
      final int? second = probe.begin(session: 1);
      probe.fail(second!, session: 1);
      expect(probe.cacheFull, isFalse);
      expect(probe.inFlight, isFalse);
      // A late result from the failed/timed-out read is ignored.
      probe.complete(second, session: 1, value: 'yes');
      expect(probe.cacheFull, isFalse);

      // The next interval can recover and query again.
      now = 1200;
      final int? third = probe.begin(session: 1);
      expect(third, isNotNull);
      probe.complete(third!, session: 1, value: 'yes');
      expect(probe.cacheFull, isTrue);
    });

    test('cacheFull expires instead of becoming a permanent state', () {
      int now = 0;
      final RipperCacheFullProbe probe = RipperCacheFullProbe(
        maxAge: const Duration(seconds: 1),
        now: () => now,
      );
      final int? token = probe.begin(session: 1);
      probe.complete(token!, session: 1, value: 'yes');
      expect(probe.cacheFull, isTrue);
      now = 1001;
      expect(probe.cacheFull, isFalse);
    });

    test(
      'a timed-out Future releases inFlight and ignores its late result',
      () async {
        int now = 0;
        final RipperCacheFullProbe probe = RipperCacheFullProbe(now: () => now);
        final int? token = probe.begin(session: 1);
        final Completer<String> pending = Completer<String>();

        try {
          await pending.future.timeout(const Duration(milliseconds: 10));
          fail('the pending property read should time out');
        } on TimeoutException {
          probe.fail(token!, session: 1);
        }
        expect(probe.inFlight, isFalse);
        expect(probe.cacheFull, isFalse);

        // The underlying future completing after the timeout must not revive it.
        pending.complete('yes');
        await Future<void>.delayed(Duration.zero);
        expect(probe.cacheFull, isFalse);
      },
    );

    test('a stale session result cannot overwrite a new source', () {
      int now = 0;
      final RipperCacheFullProbe probe = RipperCacheFullProbe(now: () => now);
      final int? old = probe.begin(session: 1);
      probe.invalidate();

      probe.complete(old!, session: 1, value: 'yes');
      expect(probe.cacheFull, isFalse);

      now = 600;
      final int? fresh = probe.begin(session: 2);
      expect(fresh, isNotNull);
      probe.complete(fresh!, session: 2, value: 'yes');
      expect(probe.cacheFull, isTrue);
    });
  });

  group('restart guard', () {
    test('buffering keeps the guard until the player reports recovery', () {
      final RipperRestartGuard guard = RipperRestartGuard();
      guard.begin();
      expect(guard.active, isTrue);
      expect(guard.observeBuffering(true), isTrue);
      expect(guard.active, isTrue);
      expect(guard.observeBuffering(false), isFalse);
      expect(guard.active, isFalse);

      // Once inactive the guard does not suppress a real stall.
      expect(guard.observeBuffering(true), isFalse);
    });

    test('a new transition remains guarded until its own recovery', () {
      final RipperRestartGuard guard = RipperRestartGuard();
      guard.begin();
      guard.clear();
      guard.begin(alreadyBuffering: true);
      expect(guard.active, isTrue);
      // This false may belong to the previous transition; ignore it.
      expect(guard.observeBuffering(false), isTrue);
      expect(guard.active, isTrue);
      expect(guard.observeBuffering(true), isTrue);
      expect(guard.observeBuffering(false), isFalse);
      expect(guard.active, isFalse);
    });

    test('watchdog expiry always clears the guard and restores stalls', () {
      final RipperRestartGuard guard = RipperRestartGuard();
      guard.begin();
      guard.expire();
      expect(guard.active, isFalse);
      // With the guard expired, a real buffering event is no longer suppressed.
      expect(guard.observeBuffering(true), isFalse);
    });
  });
}
