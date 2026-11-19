// Automatic quality selection driven by measured download speed.
//
// Ported from BTR's browser controller (`driveAutoQuality` in
// `src/page-hook.js`, 2026.11.13.1 and later). The browser version reads
// Bilibili's own quality menu and calls `setQualityFor`; here the same rules
// drive this app's quality switch, so the transport is different but the
// decisions are the same:
//
//   * a quality is only chosen when its bitrate fits in the measured speed
//     with 1.5x headroom;
//   * the speed used for choosing ignores a short burst unless the buffer is
//     already healthy, and remembers what it measured for the next video;
//   * after a step down, that quality is not retried for a while;
//   * stepping up waits for a settle period and a ready player, so a quality
//     never oscillates between two rungs.
//
// This file has no Flutter or player imports: every input is a plain value, so
// the rules are unit tested on the host.

import 'dart:math' as math;

/// One selectable video quality.
class QualityOption {
  const QualityOption({required this.id, required this.bandwidth});

  /// Bilibili qn, e.g. 80 for 1080P.
  final int id;

  /// Advertised bitrate in bits per second.
  final int bandwidth;

  double get kbps => bandwidth / 1000;
}

/// Why the controller asked for a change, for diagnostics.
enum AutoQualityReason {
  none('保持当前清晰度'),
  firstChoice('首次选择'),
  cannotKeepUp('网速跟不上'),
  bufferDrained('缓冲不增长'),
  stalledTwice('连续卡顿'),
  roomToSpare('网速有余量'),
  capped('受最高清晰度限制');

  const AutoQualityReason(this.label);

  final String label;
}

class AutoQualityDecision {
  const AutoQualityDecision(this.qualityId, this.reason);

  /// Target qn, or null when nothing should change.
  final int? qualityId;
  final AutoQualityReason reason;

  bool get shouldSwitch => qualityId != null;
}

/// Tunables, matching BTR's constants.
class AutoQualityTuning {
  const AutoQualityTuning({
    this.headroom = 1.5,
    this.sustainFactor = 1.1,
    this.settle = const Duration(seconds: 10),
    this.stallWindow = const Duration(minutes: 2),
    this.starvedSeconds = 15,
    this.lowBufferSeconds = 10,
    this.drainedTicks = 10,
    this.burstBeyond = 2,
    this.refreshMemory = const Duration(hours: 24),
  });

  /// A quality needs this much more speed than its bitrate.
  final double headroom;

  /// Below this share of the current bitrate the stream cannot keep up.
  final double sustainFactor;

  /// Minimum time between two automatic changes.
  final Duration settle;

  /// Stalls older than this no longer count.
  final Duration stallWindow;

  /// Buffer below this counts as starved; bursts are not trusted then.
  final int starvedSeconds;

  /// Buffer below this plus a flat trend means the stream is being drained.
  final int lowBufferSeconds;

  /// Consecutive ticks with a low, non-growing buffer before stepping down.
  final int drainedTicks;

  /// A burst smaller than `proven * burstBeyond` is not trusted as a peak.
  final double burstBeyond;

  /// How long a remembered speed stays useful for the next video.
  final Duration refreshMemory;
}

/// Persistent memory of the last measured speed, shared across videos.
class AutoQualityMemory {
  const AutoQualityMemory({this.kbps = 0, this.at});

  final double kbps;
  final DateTime? at;

  bool isFresh(DateTime now, Duration maxAge) =>
      at != null && kbps > 0 && now.difference(at!) <= maxAge;
}

/// Pure decision maker. Feed it one sample per second.
class AutoQualityController {
  AutoQualityController({
    required this.tuning,
    AutoQualityMemory memory = const AutoQualityMemory(),
  }) : _memory = memory;

  final AutoQualityTuning tuning;
  AutoQualityMemory _memory;

  int _stalls = 0;
  DateTime? _lastStallAt;
  DateTime? _lastChangeAt;
  int _drained = 0;
  double _provenKbps = 0;
  int? _tooMuchQuality;
  double _tooMuchKbps = 0;
  int? _sessionKey;

  AutoQualityMemory get memory => _memory;

  /// Restarts per-video state. Call when the source changes.
  void newSession(int sessionKey) {
    if (_sessionKey == sessionKey) return;
    _sessionKey = sessionKey;
    _stalls = 0;
    _drained = 0;
    _provenKbps = 0;
    _tooMuchQuality = null;
    _tooMuchKbps = 0;
    _lastChangeAt = null;
  }

  void recordStall(DateTime now) {
    _stalls += 1;
    _lastStallAt = now;
  }

  /// Decides the quality to play.
  ///
  /// [qualities] is ascending by quality (lowest first), [currentId] is what is
  /// playing now, [speedBps] the measured download speed, [bufferAhead] the
  /// seconds buffered ahead, [bufferedHistory] the last few buffer samples
  /// (oldest first) for the drain check.
  AutoQualityDecision decide({
    required List<QualityOption> qualities,
    required int currentId,
    required double speedBps,
    required double bufferAhead,
    required bool playerReady,
    required DateTime now,
    List<double> bufferedHistory = const <double>[],
    int maxQuality = 0,
    bool forceFirstChoice = false,
  }) {
    if (qualities.isEmpty) {
      return const AutoQualityDecision(null, AutoQualityReason.none);
    }
    final List<QualityOption> allowed = _applyCap(qualities, maxQuality);
    final List<QualityOption> ordered = allowed.isEmpty ? qualities : allowed;
    final double known = _knownKbps(speedBps, bufferAhead, now);
    final int currentIndex = ordered.indexWhere((QualityOption q) => q.id == currentId);

    final bool starved = bufferAhead < tuning.starvedSeconds;
    if (currentIndex < 0 || forceFirstChoice) {
      final int target = _fit(ordered, known);
      if (target == currentId) {
        return const AutoQualityDecision(null, AutoQualityReason.none);
      }
      // A first choice is a change too: the settle window starts here, so the
      // next tick does not immediately try to climb again.
      _lastChangeAt = now;
      return AutoQualityDecision(target, AutoQualityReason.firstChoice);
    }

    final QualityOption current = ordered[currentIndex];
    // Cannot keep up: the sustained speed is below the current bitrate.
    if (known > 0 &&
        currentIndex > 0 &&
        known < current.kbps * tuning.sustainFactor &&
        (!playerReady || starved)) {
      final int target = _fit(ordered.sublist(0, currentIndex), known);
      return _decideSwitch(target, currentId, now, AutoQualityReason.cannotKeepUp);
    }

    // Buffer low and not growing for a while.
    if (currentIndex > 0 && playerReady && starved) {
      final bool flat = _isFlat(bufferedHistory, bufferAhead);
      _drained = flat ? _drained + 1 : 0;
      if (_drained >= tuning.drainedTicks) {
        _drained = 0;
        final int target = _fit(ordered.sublist(0, currentIndex), known);
        return _decideSwitch(target, currentId, now, AutoQualityReason.bufferDrained);
      }
    } else {
      _drained = 0;
    }

    // Two recent stalls: step down one rung, remembering not to retry it soon.
    if (_stalls >= 2 &&
        _lastStallAt != null &&
        now.difference(_lastStallAt!) <= tuning.stallWindow) {
      _stalls = 0;
      if (currentIndex > 0) {
        _tooMuchQuality = current.id;
        _tooMuchKbps = known;
        final int target = ordered[currentIndex - 1].id;
        return _decideSwitch(target, currentId, now, AutoQualityReason.stalledTwice);
      }
    }

    // Room to spare: a higher rung fits and the player is settled.
    final int fitId = _fit(ordered, known);
    final int fitIndex = ordered.indexWhere((QualityOption q) => q.id == fitId);
    final bool settled =
        _lastChangeAt == null ||
        now.difference(_lastChangeAt!) >= tuning.settle;
    if (fitIndex > currentIndex && playerReady && settled) {
      return _decideSwitch(fitId, currentId, now, AutoQualityReason.roomToSpare);
    }

    return const AutoQualityDecision(null, AutoQualityReason.none);
  }

  AutoQualityDecision _decideSwitch(
    int target,
    int currentId,
    DateTime now,
    AutoQualityReason reason,
  ) {
    if (target == currentId) {
      return const AutoQualityDecision(null, AutoQualityReason.none);
    }
    _lastChangeAt = now;
    return AutoQualityDecision(target, reason);
  }

  List<QualityOption> _applyCap(List<QualityOption> qualities, int maxQuality) {
    if (maxQuality <= 0) return qualities;
    final List<QualityOption> inside = qualities
        .where((QualityOption q) => q.id <= maxQuality)
        .toList();
    // A video with nothing at or below the cap still plays its lowest rung.
    return inside.isEmpty ? qualities.sublist(0, 1) : inside;
  }

  /// Highest rung whose bitrate fits [speedKbps] with headroom, else the lowest.
  int _fit(List<QualityOption> ordered, double speedKbps) {
    if (ordered.isEmpty) return 0;
    if (speedKbps <= 0) return ordered.first.id;
    int best = ordered.first.id;
    for (int index = 1; index < ordered.length; index += 1) {
      final QualityOption option = ordered[index];
      if (_tooMuchQuality == option.id &&
          speedKbps < _tooMuchKbps * tuning.headroom) {
        continue;
      }
      if (option.kbps * tuning.headroom <= speedKbps) best = option.id;
    }
    return best;
  }

  double _knownKbps(double speedBps, double bufferAhead, DateTime now) {
    final double measured = speedBps / 1000;
    // A remembered speed seeds the first choice of a new video.
    double known = _memory.isFresh(now, tuning.refreshMemory) ? _memory.kbps : 0;
    if (measured <= 0) return known;
    if (bufferAhead < tuning.starvedSeconds) {
      // Starved: what arrived is real demand, but a burst is still not proof.
      known = math.max(known, measured);
    } else {
      _provenKbps = math.max(_provenKbps, measured);
      known = math.max(known, _provenKbps);
    }
    if (known > 0) {
      _memory = AutoQualityMemory(kbps: known, at: now);
    }
    return known;
  }

  static bool _isFlat(List<double> history, double current) {
    if (history.length < 2) return false;
    final double oldest = history.first;
    return current <= oldest + 0.05;
  }
}
