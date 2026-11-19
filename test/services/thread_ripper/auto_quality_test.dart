import 'package:PiliPlus/services/thread_ripper/auto_quality.dart';
import 'package:flutter_test/flutter_test.dart';

// qn 32/64/80 with clearly separated bitrates so the fit rule is unambiguous.
const List<QualityOption> qualities = <QualityOption>[
  QualityOption(id: 32, bandwidth: 400000), // 400 kbit/s
  QualityOption(id: 64, bandwidth: 1500000), // 1.5 Mbit/s
  QualityOption(id: 80, bandwidth: 4000000), // 4 Mbit/s
];

AutoQualityController controller({DateTime? now}) => AutoQualityController(
  tuning: const AutoQualityTuning(),
);

void main() {
  final DateTime t0 = DateTime(2026, 11, 15, 12);

  test('first choice picks the highest rung that fits with headroom', () {
    final AutoQualityController c = controller();
    // 6 Mbit/s: 4 Mbit/s * 1.5 = 6 → exactly fits.
    final AutoQualityDecision d = c.decide(
      qualities: qualities,
      currentId: 32,
      speedBps: 6000000,
      bufferAhead: 20,
      playerReady: true,
      now: t0,
      forceFirstChoice: true,
    );
    expect(d.qualityId, 80);
    expect(d.reason, AutoQualityReason.firstChoice);
  });

  test('slow speed falls back to the lowest rung', () {
    final AutoQualityController c = controller();
    final AutoQualityDecision d = c.decide(
      qualities: qualities,
      currentId: 80,
      speedBps: 500000,
      bufferAhead: 20,
      playerReady: true,
      now: t0,
      forceFirstChoice: true,
    );
    expect(d.qualityId, 32);
  });

  test('cannot keep up steps down when the buffer is starved', () {
    final AutoQualityController c = controller();
    final AutoQualityDecision d = c.decide(
      qualities: qualities,
      currentId: 80,
      // Below 4 Mbit/s * 1.1 and the buffer is starving.
      speedBps: 2000000,
      bufferAhead: 5,
      playerReady: true,
      now: t0.add(const Duration(seconds: 12)),
    );
    expect(d.shouldSwitch, isTrue);
    expect(d.qualityId, lessThan(80));
    expect(d.reason, AutoQualityReason.cannotKeepUp);
  });

  test('a healthy buffer keeps the current quality', () {
    final AutoQualityController c = controller();
    final AutoQualityDecision d = c.decide(
      qualities: qualities,
      currentId: 64,
      speedBps: 2000000,
      bufferAhead: 25,
      playerReady: true,
      now: t0,
    );
    expect(d.shouldSwitch, isFalse);
  });

  test('room to spare steps up after the settle period', () {
    final AutoQualityController c = controller();
    // Establish the current quality and a change timestamp in the past.
    c.decide(
      qualities: qualities,
      currentId: 64,
      speedBps: 2000000,
      bufferAhead: 20,
      playerReady: true,
      now: t0,
      forceFirstChoice: true,
    );
    final AutoQualityDecision d = c.decide(
      qualities: qualities,
      currentId: 64,
      speedBps: 9000000,
      bufferAhead: 30,
      playerReady: true,
      now: t0.add(const Duration(seconds: 30)),
    );
    expect(d.shouldSwitch, isTrue);
    expect(d.qualityId, 80);
    expect(d.reason, AutoQualityReason.roomToSpare);
  });

  test('stepping up respects the settle window', () {
    final AutoQualityController c = controller();
    c.decide(
      qualities: qualities,
      currentId: 64,
      speedBps: 9000000,
      bufferAhead: 30,
      playerReady: true,
      now: t0,
      forceFirstChoice: true,
    );
    final AutoQualityDecision d = c.decide(
      qualities: qualities,
      currentId: 64,
      speedBps: 9000000,
      bufferAhead: 30,
      playerReady: true,
      now: t0.add(const Duration(seconds: 2)),
    );
    expect(d.shouldSwitch, isFalse);
  });

  test('the quality cap is honoured', () {
    final AutoQualityController c = controller();
    final AutoQualityDecision d = c.decide(
      qualities: qualities,
      currentId: 32,
      speedBps: 20000000,
      bufferAhead: 30,
      playerReady: true,
      now: t0,
      maxQuality: 64,
      forceFirstChoice: true,
    );
    expect(d.qualityId, 64);
  });

  test('a cap below every rung still plays the lowest quality', () {
    final AutoQualityController c = controller();
    final AutoQualityDecision d = c.decide(
      qualities: qualities,
      currentId: 32,
      speedBps: 20000000,
      bufferAhead: 30,
      playerReady: true,
      now: t0,
      maxQuality: 16,
      forceFirstChoice: true,
    );
    // Already on the lowest rung, so nothing changes.
    expect(d.shouldSwitch, isFalse);
  });

  test('two stalls step down one rung and remember the bad quality', () {
    final AutoQualityController c = controller();
    c.decide(
      qualities: qualities,
      currentId: 80,
      speedBps: 9000000,
      bufferAhead: 30,
      playerReady: true,
      now: t0,
      forceFirstChoice: true,
    );
    c.recordStall(t0.add(const Duration(seconds: 5)));
    c.recordStall(t0.add(const Duration(seconds: 6)));
    final AutoQualityDecision d = c.decide(
      qualities: qualities,
      currentId: 80,
      speedBps: 9000000,
      bufferAhead: 30,
      playerReady: true,
      now: t0.add(const Duration(seconds: 7)),
    );
    expect(d.reason, AutoQualityReason.stalledTwice);
    expect(d.qualityId, 64);
  });

  test('a flat low buffer steps down after enough ticks', () {
    final AutoQualityController c = controller();
    c.decide(
      qualities: qualities,
      currentId: 80,
      speedBps: 9000000,
      bufferAhead: 30,
      playerReady: true,
      now: t0,
      forceFirstChoice: true,
    );
    AutoQualityDecision d = const AutoQualityDecision(null, AutoQualityReason.none);
    for (int i = 0; i < 12; i += 1) {
      d = c.decide(
        qualities: qualities,
        currentId: 80,
        speedBps: 9000000,
        bufferAhead: 4,
        bufferedHistory: const <double>[5, 4.5, 4.2, 4],
        playerReady: true,
        now: t0.add(Duration(seconds: 10 + i)),
      );
      if (d.shouldSwitch) break;
    }
    expect(d.reason, AutoQualityReason.bufferDrained);
    expect(d.qualityId, lessThan(80));
  });

  test('remembered speed seeds the first choice of the next video', () {
    final AutoQualityController c = controller();
    c.decide(
      qualities: qualities,
      currentId: 32,
      speedBps: 9000000,
      bufferAhead: 30,
      playerReady: true,
      now: t0,
      forceFirstChoice: true,
    );
    final AutoQualityController next = AutoQualityController(
      tuning: const AutoQualityTuning(),
      memory: c.memory,
    );
    final AutoQualityDecision d = next.decide(
      qualities: qualities,
      currentId: 32,
      speedBps: 0,
      bufferAhead: 0,
      playerReady: false,
      now: t0.add(const Duration(minutes: 1)),
      forceFirstChoice: true,
    );
    expect(d.qualityId, 80);
  });

  test('an expired memory does not influence the choice', () {
    final AutoQualityController next = AutoQualityController(
      tuning: const AutoQualityTuning(),
      memory: AutoQualityMemory(kbps: 9000, at: t0),
    );
    final AutoQualityDecision d = next.decide(
      qualities: qualities,
      currentId: 32,
      speedBps: 0,
      bufferAhead: 0,
      playerReady: false,
      now: t0.add(const Duration(days: 3)),
      forceFirstChoice: true,
    );
    // Nothing is remembered, so the lowest rung is kept - and it is current.
    expect(d.shouldSwitch, isFalse);
  });

  test('empty quality list is a no-op', () {
    final AutoQualityDecision d = controller().decide(
      qualities: const <QualityOption>[],
      currentId: 80,
      speedBps: 9000000,
      bufferAhead: 30,
      playerReady: true,
      now: t0,
    );
    expect(d.shouldSwitch, isFalse);
  });
}
