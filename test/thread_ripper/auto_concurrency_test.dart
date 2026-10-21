// Host tests for the auto-concurrency controller: pressure steps up, a
// comfortable buffer steps down, a stall jumps to the maximum, and a trial
// that brought no extra throughput rolls back with a rest period.

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:PiliPlus/services/thread_ripper/idm_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late int now;
  late RipperSemaphore semaphore;
  late AutoConcurrency auto;

  AutoConcurrency create({int maxConcurrency = 64, int initialThreads = 8}) {
    now = 0;
    semaphore = RipperSemaphore(initialThreads);
    auto = AutoConcurrency(
      semaphore: semaphore,
      maxConcurrency: maxConcurrency,
      initialThreads: initialThreads,
      now: () => now,
    );
    return auto;
  }

  tearDown(() => auto.close());

  test('starts at the requested level and keeps the semaphore in sync', () {
    create();
    expect(auto.threads, 8);
    expect(semaphore.limit, 8);
  });

  test('a low buffer held for a second steps the level up', () {
    create();
    auto.buffer(3, true);
    now = 1100;
    auto.buffer(3, true);
    expect(auto.threads, 12);
    expect(semaphore.limit, 12);
  });

  test('a growing buffer does not count as pressure', () {
    create();
    auto.buffer(3, true);
    now = 600;
    auto.buffer(3.5, true);
    now = 1700;
    auto.buffer(4, true);
    expect(auto.threads, 8);
  });

  test('a comfortable buffer steps a level down', () {
    create(initialThreads: 16);
    now = 2600;
    auto.buffer(20, true);
    expect(auto.threads, 12);
    now = 5200;
    auto.buffer(16, true);
    expect(auto.threads, 8);
  });

  test('a full mpv cache counts as comfortable even below 15 s', () {
    create(initialThreads: 16);
    now = 2600;
    auto.buffer(4, true, cacheFull: true);
    expect(auto.threads, 12);
  });

  test('a stall jumps to the configured maximum and clears the cooldown', () {
    create(maxConcurrency: 32);
    expect(auto.stall(), isTrue);
    expect(auto.threads, 32);
    expect(semaphore.limit, 32);
    expect(auto.inCooldown, isFalse);
  });

  test('a failed ten-second trial rolls back and rests', () {
    create();
    // Establish a baseline throughput of about 2 MB/s.
    auto.delivered(1000000);
    now = 1000;
    auto.delivered(1000000);
    // Pressure steps to 12 threads.
    now = 2000;
    auto.buffer(3, true);
    now = 3100;
    auto.buffer(3, true);
    expect(auto.threads, 12);
    // Ten seconds later the connections delivered almost nothing: roll back.
    now = 13100;
    auto.delivered(1000);
    expect(auto.threads, 8);
    expect(auto.inCooldown, isTrue);
    // While resting, another pressure sample must not step up.
    now = 14000;
    auto.buffer(3, true);
    now = 15200;
    auto.buffer(3, true);
    expect(auto.threads, 8);
  });

  test('a trial that did grow keeps the higher level', () {
    create();
    auto.delivered(1000000);
    now = 1000;
    auto.delivered(1000000);
    now = 2000;
    auto.buffer(3, true);
    now = 3100;
    auto.buffer(3, true);
    expect(auto.threads, 12);
    // Ten seconds later with much more throughput: keep it.
    now = 13100;
    auto.delivered(8000000);
    expect(auto.threads, 12);
    expect(auto.inCooldown, isFalse);
  });

  test('close stops reacting to signals', () {
    create();
    auto.close();
    auto.stall();
    expect(auto.threads, 8);
  });
}
