// Adaptive concurrency controller for the native range proxy.
//
// The upstream BTR controller changes a page-wide thread count in response to
// player stalls, buffer pressure and measured throughput. This port keeps the
// same feedback ideas, but exposes them as an explicit state machine and makes
// the chosen limit flow into the one shared [RipperSemaphore] used by both the
// video and audio range requests.
//
// Important distinction:
//   * `maxConcurrency` is a hard upper bound (normally 64).
//   * the current rung is the real limit written into the semaphore.
//   * `active`/`queued` come from that semaphore; they are measurements, not
//     copies of the configured number.
//
// The clock is injectable; all windows and cooldowns are deterministic in
// tests.
//
// Signals that drive a transition, and where they come from:
//   * buffer ahead / playing  -> `buffer()`, sampled by the player listener
//   * bytes flowing           -> `activity()`, called per downloaded chunk
//   * slot saturation         -> sampled from the shared semaphore
//   * completed pieces        -> `delivered()`, winning copies only
//   * HTTP 412/429            -> `pushback()`
//   * first-byte timeout      -> `firstByteTimeout()`
//   * repeated 5xx/stalls     -> `slow()`
//   * player stall            -> `stall()`
//
// A low buffer alone does not raise the thread count: upstream also requires
// that bytes are actually arriving. Without that gate a player that is stuck
// for an unrelated reason (a dead node, a paused decoder) would ratchet the
// thread count up to the maximum for no benefit.

import 'dart:math' as math;

import 'package:PiliPlus/services/thread_ripper/idm_downloader.dart';
import 'package:PiliPlus/services/thread_ripper/media_demand.dart';

enum AutoConcurrencyState { idle, startup, stable, probingUp, backoff }

/// Automatic thread-count controller shared by one player session.
class AutoConcurrency {
  AutoConcurrency({
    required this.semaphore,
    int maxConcurrency = 64,
    int? initialThreads,
    int Function()? now,
  }) : _now = now ?? _defaultNow,
       _maxLevel = _levelFor(maxConcurrency) {
    _level = _levelFor(initialThreads ?? 8);
    if (_level > _maxLevel) _level = _maxLevel;
    // Old tests and non-player callers start in a neutral steady state.
    // The player calls [startSession] before the first request; that is the
    // only path that enables startup acceleration.
    _changedAt = -1000000;
    _state = AutoConcurrencyState.idle;
    semaphore.setLimit(threads);
  }

  /// The upstream ladder is [8,12,16,24,32,48,64]. The native port has kept a
  /// 4 rung for explicit low-bandwidth/manual use. UI, tests and executor all
  /// read this one list.
  static const List<int> ladder = <int>[4, 8, 12, 16, 24, 32, 48, 64];

  static const int minThreads = 4;
  static const int maxSupportedThreads = 64;

  /// A low buffer must stay low this long before it counts as pressure.
  static const int pressureMs = 1000;

  /// A comfortable buffer must remain comfortable before steady-state down.
  static const int steadyComfortMs = 15000;

  /// A probe is judged after this long.
  static const int trialMs = 10000;

  /// A failed trial rests this long before that rung is retried.
  static const int restMs = 90000;

  /// HTTP 412/429 blocks the rejected and higher rungs.
  static const int pushbackRestMs = 180000;

  /// Normal changes are no closer than this.
  static const int stepCooldownMs = 2500;

  /// The forced startup phase ends after this long.
  static const int startupMaxMs = 30000;

  static const int windowMs = 8000;
  static const int trendWindowMs = 5000;
  static const int bucketMs = 250;

  /// No body byte for this long means nothing is being downloaded; a low
  /// buffer then is not a thread-count problem.
  static const int activityMs = 1500;

  /// A trial is only judged "no gain" while the extra slots were really used.
  /// Below this share of the window the transfer was not limited by threads.
  static const double saturatedShare = 0.6;

  static int _defaultNow() => DateTime.now().microsecondsSinceEpoch ~/ 1000;

  final RipperSemaphore semaphore;
  final int Function() _now;
  final int _maxLevel;

  AutoConcurrencyState _state = AutoConcurrencyState.idle;
  int _level = 0;
  int _session = 0;
  bool _sessionActive = false;
  int _baseLevel = 0;
  int _startupBaseLevel = 0;
  int _startupUntil = 0;
  int _changedAt = 0;
  int _cooldownUntil = 0;
  int _pressureSince = -1;
  int _comfortableSince = -1;
  double? _lastAhead;
  int _lastAheadAt = -1;

  final List<({int at, double ahead})> _aheadSamples = [];
  final List<({int at, int bytes})> _buckets = [];
  final List<String> _events = <String>[];

  RipperMediaDemand? _demand;
  _Trial? _trial;
  int _trialBytes = 0;
  int _http412 = 0;
  int _http429 = 0;
  int _timeouts = 0;
  int _failures = 0;
  int _consecutiveFailures = 0;
  int _lastFailureAt = 0;
  int _steps = 0;
  int _firstByteTimeouts = 0;

  /// Last time a body chunk arrived; -1 when the session has not transferred
  /// anything yet.
  int _lastActivityAt = -1;

  /// Intervals during which every slot was busy and work was queued. This is
  /// upstream's `saturation()`, and it is what makes a "no gain" verdict
  /// meaningful: unused extra slots prove nothing.
  bool _saturated = false;
  int _saturatedSince = 0;
  final List<({int from, int to})> _saturatedSpans = <({int from, int to})>[];

  /// level -> absolute time until which it must not be selected.
  final Map<int, int> _blockedUntil = <int, int>{};

  String _lastReason = '初始';
  bool _closed = false;

  int get threads => ladder[_level];
  int get level => _level;
  int get maxThreads => ladder[_maxLevel];
  int get sessionId => _session;
  int get activeRequests => semaphore.active;
  int get pendingRequests => semaphore.queued;
  AutoConcurrencyState get state => _state;
  String get lastReason => _lastReason;
  bool get inCooldown => _now() < _cooldownUntil;
  RipperMediaDemand? get demand => _demand;
  int get steps => _steps;

  /// Milliseconds since the last body byte, or null before the first one.
  int? get activityAgeMs {
    if (_lastActivityAt < 0) return null;
    return math.max(0, _now() - _lastActivityAt);
  }

  /// Whether bytes are arriving right now.
  ///
  /// Before the first report the semaphore's own occupancy is used: a slot
  /// held means a transfer is in progress, which is the same conclusion the
  /// upstream `activity()` timestamp gives.
  bool get downloading {
    final int? age = activityAgeMs;
    if (age == null) return semaphore.active > 0;
    return age < activityMs;
  }

  /// Share of the last window during which every slot was busy and work was
  /// queued, 0..1.
  double saturation([int? at]) {
    final int now = at ?? _now();
    final int from = now - windowMs;
    _pruneSaturation(now);
    int busy = 0;
    for (final ({int from, int to}) span in _saturatedSpans) {
      busy += math.max(0, span.to - math.max(span.from, from));
    }
    if (_saturated) {
      busy += math.max(0, now - math.max(_saturatedSince, from));
    }
    return math.min(1, busy / windowMs);
  }

  double? get bufferTrend {
    if (_aheadSamples.isEmpty) return null;
    final int now = _now();
    final ({int at, double ahead}) first = _aheadSamples.firstWhere(
      (sample) => now - sample.at <= trendWindowMs,
      orElse: () => _aheadSamples.last,
    );
    return _aheadSamples.last.ahead - first.ahead;
  }

  double get goodputBps => throughputBps();
  double? get estimatedDemandMbps => _demand?.estimatedDemandMbps;
  double? get throughputRatio {
    final double? demand = estimatedDemandMbps;
    if (demand == null || demand <= 0) return null;
    return goodputBps / (demand * 1000000);
  }

  static int _levelFor(int threads) {
    int best = 0;
    for (int i = 0; i < ladder.length; i += 1) {
      if (ladder[i] <= threads) best = i;
    }
    return best;
  }

  int _levelForThreads(int threads) {
    final int level = _levelFor(threads);
    return math.min(level, _maxLevel);
  }

  /// Begin a new media/quality session.
  ///
  /// The first rung is a bitrate-derived hint. In automatic mode the actual
  /// limit is allowed to climb to [maxThreads] (normally 64); a manual setting
  /// is only used when the player does not create this controller at all.
  int startSession({
    RipperMediaDemand? demand,
    int? initialThreads,
    bool startup = true,
  }) {
    _session += 1;
    _sessionActive = true;
    _demand = demand;
    _baseLevel = _levelForThreads(
      initialThreads ?? demand?.suggestedInitialThreads() ?? 8,
    );
    _clearWindow();
    _consecutiveFailures = 0;
    _lastFailureAt = 0;
    _failures = 0;
    _timeouts = 0;
    _firstByteTimeouts = 0;
    _http412 = 0;
    _http429 = 0;
    _steps = 0;
    _lastActivityAt = -1;
    _saturated = false;
    _saturatedSince = _now();
    _saturatedSpans.clear();
    _state = startup
        ? AutoConcurrencyState.startup
        : AutoConcurrencyState.stable;
    _startupBaseLevel = _baseLevel;
    _startupUntil = startup ? _now() + startupMaxMs : 0;
    final int target = startup
        ? _allowedLevel(math.max(_baseLevel, _levelForThreads(16)))
        : _allowedLevel(_baseLevel);
    _setLevel(
      target,
      reason: startup
          ? '新会话启动：${_demand?.describe() ?? '码率未知'}'
          : '新会话：${_demand?.describe() ?? '码率未知'}',
      state: _state,
    );
    _changedAt = _now();
    return _session;
  }

  /// A seek into an unbuffered area starts a short startup probe for the same
  /// session, without inventing a new media demand.
  void seekStarted({int? session}) {
    if (_closed || (session != null && session != _session)) return;
    if (!_sessionActive) return;
    _clearWindow();
    _state = AutoConcurrencyState.startup;
    _startupBaseLevel = _baseLevel;
    _startupUntil = _now() + startupMaxMs;
    _setLevel(
      _allowedLevel(math.max(_level, _levelForThreads(16))),
      reason: '拖动到未缓冲区域，重新启动探测',
      state: _state,
    );
    _changedAt = _now();
  }

  void _clearWindow() {
    _aheadSamples.clear();
    _buckets.clear();
    _pressureSince = -1;
    _comfortableSince = -1;
    _lastAhead = null;
    _lastAheadAt = -1;
    _trial = null;
    _trialBytes = 0;
    _saturatedSpans.clear();
    _saturated = false;
    _saturatedSince = _now();
  }

  int _allowedLevel(int level) {
    int result = math.min(level, _maxLevel);
    while (result > 0 && _isBlocked(result)) {
      result -= 1;
    }
    return result;
  }

  bool _isBlocked(int level) {
    final int? until = _blockedUntil[level];
    return until != null && until > _now();
  }

  void _setLevel(
    int level, {
    required String reason,
    AutoConcurrencyState? state,
    int? trialFrom,
  }) {
    _level = math.max(0, math.min(level, _maxLevel));
    _changedAt = _now();
    _lastReason = reason;
    _steps += 1;
    if (state != null) _state = state;
    semaphore.setLimit(threads);
    if (trialFrom != null && _level > trialFrom) {
      _trial = _Trial(
        from: trialFrom,
        at: _now(),
        baselineBps: throughputBps(),
        baselineTrend: bufferTrend ?? 0,
      );
      _trialBytes = 0;
    } else if (trialFrom == null) {
      _trial = null;
    }
    _record(reason);
  }

  void _record(String reason) {
    _events.add(reason);
    if (_events.length > 40) _events.removeAt(0);
  }

  void _stepDown(String reason, {bool force = false}) {
    if (_level <= 0) {
      _lastReason = reason;
      return;
    }
    if (!force && _now() - _changedAt < stepCooldownMs) return;
    _setLevel(
      _level - 1,
      reason: reason,
      state: AutoConcurrencyState.stable,
    );
  }

  bool _stepUp(String reason) {
    if (_closed || _trial != null) return false;
    final int now = _now();
    if (now < _cooldownUntil) return false;
    if (now - _changedAt < stepCooldownMs) return false;
    final int next = _level + 1;
    if (next > _maxLevel || _isBlocked(next)) return false;
    final int before = _level;
    _setLevel(
      next,
      reason: reason,
      state: AutoConcurrencyState.probingUp,
      trialFrom: before,
    );
    return true;
  }

  /// Successful, unique media bytes. Duplicate hedge copies must not call
  /// this (the downloader only calls it for the winning piece).
  void delivered(int bytes, {int? session}) {
    if (_closed || bytes <= 0) return;
    if (session != null && session != _session) return;
    final int now = _now();
    if (_buckets.isNotEmpty && now - _buckets.last.at < bucketMs) {
      final last = _buckets.removeLast();
      _buckets.add((at: last.at, bytes: last.bytes + bytes));
    } else {
      _buckets.add((at: now, bytes: bytes));
    }
    _trialBytes += bytes;
    _prune(now);
    _sampleDemand();
    _judgeTrial(now);
  }

  /// Bytes arrived on some connection (upstream `activity()`).
  ///
  /// This is the difference between "few threads" and "nothing to fetch": a
  /// low buffer only justifies more connections while bytes keep coming.
  void activity({int? session}) {
    if (_closed) return;
    if (session != null && session != _session) return;
    _lastActivityAt = _now();
    _sampleDemand();
  }

  /// Samples whether every slot is busy with work still queued, and keeps the
  /// spans so [saturation] can describe the recent window.
  void _sampleDemand() {
    final int now = _now();
    final bool saturated =
        semaphore.active >= semaphore.limit && semaphore.queued > 0;
    if (saturated != _saturated) {
      if (_saturated) {
        _saturatedSpans.add((from: _saturatedSince, to: now));
      }
      _saturated = saturated;
      _saturatedSince = now;
    }
    _pruneSaturation(now);
  }

  void _pruneSaturation(int at) {
    final int from = at - windowMs;
    _saturatedSpans.removeWhere(
      (({int from, int to}) span) => span.to <= from,
    );
  }

  double throughputBps([int? at]) {
    final int now = at ?? _now();
    _prune(now);
    if (_buckets.isEmpty) return 0;
    final int bytes = _buckets.fold(
      0,
      (int sum, ({int at, int bytes}) bucket) => sum + bucket.bytes,
    );
    final int span = math.max(
      1000,
      _buckets.last.at - _buckets.first.at + bucketMs,
    );
    return bytes * 1000 / span;
  }

  void _prune(int at) {
    while (_buckets.isNotEmpty && at - _buckets.first.at > windowMs) {
      _buckets.removeAt(0);
    }
    while (_aheadSamples.isNotEmpty && at - _aheadSamples.first.at > windowMs) {
      _aheadSamples.removeAt(0);
    }
  }

  bool _lowPressure({
    required double ahead,
    required bool playing,
    required bool waiting,
  }) {
    if (!playing && !waiting) return false;
    if (ahead >= 6) return false;
    final int now = _now();
    final double? previous = _lastAhead;
    final int previousAt = _lastAheadAt;
    _lastAhead = ahead;
    _lastAheadAt = now;
    if (previous == null) {
      // Start the pressure clock on the first low sample. Requiring a second
      // sample before starting it made the one-second window take ~2 s.
      _pressureSince = now;
      return false;
    }
    if (now - previousAt < 1000) {
      if (_pressureSince < 0) _pressureSince = now;
      return false;
    }
    // A rising buffer means the current threads are still making progress.
    if (ahead > previous + 0.05) {
      _pressureSince = -1;
      return false;
    }
    if (_pressureSince < 0) {
      _pressureSince = now;
      return false;
    }
    if (now - _pressureSince < pressureMs) return false;
    _pressureSince = -1;
    // In a real player session an idle downloader is not evidence that more
    // threads are needed: if nothing is arriving, more connections would only
    // queue behind whatever is stuck. The legacy direct-controller tests do
    // not create a session or report activity, so they keep the original
    // pressure-only behavior.
    if (!_sessionActive) return true;
    return downloading;
  }

  bool _bufferDropping(double trend) => trend <= -0.5;

  bool _atCapacity() {
    final int active = semaphore.active;
    final int limit = semaphore.limit;
    return active >= math.max(1, (limit * .8).ceil()) && semaphore.queued > 0;
  }

  /// Player buffer sample. [waiting] is true while the player is in its
  /// waiting/buffering event; startup and seeks are handled by their own
  /// explicit transition.
  void buffer(
    double aheadSeconds,
    bool playing, {
    bool cacheFull = false,
    bool waiting = false,
    int? session,
  }) {
    if (_closed) return;
    if (session != null && session != _session) return;
    final int now = _now();
    if (!playing && !waiting) {
      _pressureSince = -1;
      _comfortableSince = -1;
      return;
    }
    // The player reports a few times per second: that is also the cadence at
    // which slot occupancy is sampled for the saturation window.
    _sampleDemand();
    // Compatibility for the original host tests that exercise the low-level
    // controller without a player session. The production path always calls
    // startSession and uses the full state machine.
    if (!_sessionActive) {
      if (_level > 0 &&
          (cacheFull || aheadSeconds >= 15) &&
          now - _changedAt >= stepCooldownMs &&
          semaphore.queued == 0) {
        _stepDown('缓冲充足，降一档', force: true);
      } else if (_lowPressure(
        ahead: aheadSeconds,
        playing: playing,
        waiting: waiting,
      )) {
        _stepUp('缓冲低于 6 秒且持续无增长，下载未跟上');
      }
      return;
    }
    _aheadSamples.add((at: now, ahead: aheadSeconds));
    _prune(now);
    // A probe can expire while the player is paused and no piece completes.
    // Without this, a stalled/idle trial would keep _stepUp blocked forever.
    _judgeTrial(now);
    final double trend = bufferTrend ?? 0;
    final double? ratio = throughputRatio;
    final bool dropping = _bufferDropping(trend);
    final bool capacity = _atCapacity();

    if (_state == AutoConcurrencyState.startup) {
      final bool comfortable = cacheFull || aheadSeconds >= 15;
      if (comfortable) {
        if (_comfortableSince < 0) _comfortableSince = now;
        if (now - _comfortableSince >= stepCooldownMs &&
            _level > _startupBaseLevel) {
          _stepDown('启动缓冲已达到 15 秒，降一档', force: true);
          if (_level > _startupBaseLevel) {
            _state = AutoConcurrencyState.startup;
          } else {
            _state = AutoConcurrencyState.stable;
            _startupUntil = 0;
          }
          _comfortableSince = now;
        } else if (_level <= _startupBaseLevel) {
          _state = AutoConcurrencyState.stable;
          _lastReason = '启动完成，进入稳态';
          _startupUntil = 0;
        }
      } else {
        _comfortableSince = -1;
      }

      if (now >= _startupUntil) {
        _state = AutoConcurrencyState.stable;
        _startupUntil = 0;
        _lastReason = '启动探测达到 30 秒上限，保留当前档位';
      }

      final bool pressure = _lowPressure(
        ahead: aheadSeconds,
        playing: playing,
        waiting: waiting,
      );
      if (pressure) {
        _stepUp('启动阶段缓冲 ${aheadSeconds.toStringAsFixed(1)} 秒且无增长');
        if (_state == AutoConcurrencyState.startup) {
          _state = AutoConcurrencyState.probingUp;
        }
      }
      return;
    }

    // A hard 412/429 backoff must not be escaped by a buffer emergency. The
    // request layer still has lower rungs available; once the cooldown ends
    // normal probing resumes.
    if (_state == AutoConcurrencyState.backoff && now < _cooldownUntil) {
      return;
    }

    bool stepped = false;
    final bool pressure = _lowPressure(
      ahead: aheadSeconds,
      playing: playing,
      waiting: waiting,
    );
    if (pressure) {
      stepped = _stepUp('缓冲低于 6 秒且持续无增长，下载未跟上');
    } else if (dropping && (ratio == null || ratio < 1.5) && capacity) {
      stepped = _stepUp('缓冲 5 秒内下降，活动请求接近上限且仍有排队任务');
    }

    if (stepped) {
      _comfortableSince = -1;
      return;
    }

    // Idle/failed downloads must not be interpreted as "more threads will
    // help"; avoid stepping while the player is paused.
    if (!playing) return;

    final bool enoughAhead = cacheFull || aheadSeconds >= 15;
    final bool surplus = ratio != null && ratio >= 2.0;
    final bool noBacklog = semaphore.queued == 0;
    if (!enoughAhead || !surplus || !noBacklog) {
      _comfortableSince = -1;
      return;
    }
    if (_comfortableSince < 0) {
      _comfortableSince = now;
      return;
    }
    if (now - _comfortableSince < steadyComfortMs) return;
    if (_trial != null) return;
    _stepDown('缓冲充足且吞吐超过需求约 2 倍，稳态降一档', force: true);
    _comfortableSince = now;
  }

  /// A player stall is a strong signal for one more rung, not a command to
  /// jump to 64. In the legacy direct-test mode it keeps the old "jump to
  /// configured maximum" behavior.
  bool stall({int? session}) {
    if (_closed) return false;
    if (session != null && session != _session) return false;
    if (!_sessionActive) {
      final int before = _level;
      _setLevel(
        _maxLevel,
        reason: '播放卡顿',
        state: AutoConcurrencyState.probingUp,
        trialFrom: _level < _maxLevel ? _level : null,
      );
      _trial?.stalled = true;
      return _level != before;
    }
    final bool stepped = _stepUp('播放器报告卡顿');
    if (stepped) _trial?.stalled = true;
    return stepped;
  }

  /// Called for actual HTTP 412/429 responses from media requests.
  void pushback(int status, {int? session}) {
    if (_closed) return;
    if (session != null && session != _session) return;
    if (status != 412 && status != 429) return;
    final int now = _now();
    if (status == 412) {
      _http412 += 1;
    } else {
      _http429 += 1;
    }
    _cooldownUntil = now + pushbackRestMs;
    for (int i = _level; i <= _maxLevel; i += 1) {
      _blockedUntil[i] = now + pushbackRestMs;
    }
    _state = AutoConcurrencyState.backoff;
    _trial = null;
    _trialBytes = 0;
    _stepDown('HTTP $status 限流，退回一档并冷却 180 秒', force: true);
    _state = AutoConcurrencyState.backoff;
  }

  /// A first-byte timeout is immediate evidence that the current thread count
  /// is not being served: the node (or its signature) is not answering. One
  /// rung back and a short cooldown, without waiting for three strikes, and
  /// unlike a 412/429 the higher rungs are only rested for a minute.
  void firstByteTimeout({int? session}) {
    if (_closed) return;
    if (session != null && session != _session) return;
    final int now = _now();
    _timeouts += 1;
    _failures += 1;
    _firstByteTimeouts += 1;
    _lastFailureAt = now;
    _consecutiveFailures = 0;
    _trial = null;
    _trialBytes = 0;
    const int firstByteRestMs = 60000;
    _cooldownUntil = now + firstByteRestMs;
    final int failedLevel = _level;
    if (failedLevel > 0) _blockedUntil[failedLevel] = now + firstByteRestMs;
    _stepDown('首个字节超时（$failedLevel 档），退回一档并冷却 60 秒', force: true);
    _state = AutoConcurrencyState.backoff;
  }

  /// Repeated timeouts/5xx lower the probe frequency and, when sustained,
  /// take one rung back. A single failure never drops to thread 1.
  void slow({int? session, bool timeout = false}) {
    if (_closed) return;
    if (session != null && session != _session) return;
    final int now = _now();
    if (timeout) _timeouts += 1;
    _failures += 1;
    _consecutiveFailures = now - _lastFailureAt <= 30000
        ? _consecutiveFailures + 1
        : 1;
    _lastFailureAt = now;
    if (_consecutiveFailures >= 3) {
      _cooldownUntil = math.max(_cooldownUntil, now + 15000);
      _stepDown(
        '连续超时/网络失败 $_consecutiveFailures 次，降一档',
        force: true,
      );
      _state = AutoConcurrencyState.stable;
      _consecutiveFailures = 0;
    }
  }

  /// Judges the running trial after [trialMs].
  ///
  /// Three outcomes, in order:
  ///   * the throughput really grew -> keep the rung;
  ///   * it actually *fell* -> the extra connections made things worse, go
  ///     back and rest that level;
  ///   * in between ("no gain"): only go back when the extra slots were
  ///     really being used ([saturation]); if they sat idle the transfer was
  ///     not limited by the thread count, and stepping back would just cause
  ///     another probe later.
  void _judgeTrial(int at) {
    final _Trial? trial = _trial;
    if (trial == null || at - trial.at < trialMs) return;
    _trial = null;
    final double current = throughputBps(at);
    final double trend = bufferTrend ?? 0;
    // Not enough real transfer in the probe: do not call it a failed rung.
    // The legacy direct-controller tests intentionally use tiny transfers; the
    // production session path is the one that needs the sample guard.
    if (_sessionActive && (_trialBytes < 128 * 1024 || current <= 0)) {
      _lastReason = '升档探测样本不足，保持当前档位';
      _state = AutoConcurrencyState.stable;
      return;
    }
    final bool noBaseline = trial.baselineBps <= 0;
    final bool throughputGain =
        noBaseline || current >= trial.baselineBps * 1.10;
    final bool bufferGain = trend >= trial.baselineTrend + 0.25;
    if (throughputGain || bufferGain || trial.stalled) {
      _lastReason = throughputGain && !noBaseline
          ? '升档有效：有效吞吐提升 ${((current / trial.baselineBps - 1) * 100).clamp(0, 999).toStringAsFixed(0)}%'
          : '升档有效：缓冲趋势改善';
      _state = AutoConcurrencyState.stable;
      return;
    }
    final bool regressed = current < trial.baselineBps * 0.95;
    if (!regressed && saturation(at) < saturatedShare) {
      _lastReason = '升档无明显收益，但连接未饱和，保留 $threads 线程';
      _state = AutoConcurrencyState.stable;
      return;
    }
    _blockedUntil[_level] = at + restMs;
    _cooldownUntil = at + restMs;
    _stepDown(
      regressed ? '升档 10 秒吞吐反而下降，退回并冷却 90 秒' : '升档 10 秒无收益，退回并冷却 90 秒',
      force: true,
    );
    _state = AutoConcurrencyState.stable;
  }

  /// Test/UI diagnostics. No URLs, cookies or account data.
  Map<String, Object?> status() => <String, Object?>{
    'state': _state.name,
    'session': _session,
    'threads': threads,
    'level': _level,
    'maxThreads': maxThreads,
    'active': semaphore.active,
    'limit': semaphore.limit,
    'queued': semaphore.queued,
    'goodputMbps': (goodputBps / 1000000).toStringAsFixed(2),
    'demandMbps': estimatedDemandMbps?.toStringAsFixed(2),
    'bufferTrend': bufferTrend?.toStringAsFixed(2),
    'saturation': saturation().toStringAsFixed(2),
    'downloading': downloading,
    'activityAgeMs': activityAgeMs,
    'steps': _steps,
    'trial': _trial == null ? null : ladder[_trial!.from],
    'resting': _blockedUntil.entries
        .where((MapEntry<int, int> entry) => entry.value > _now())
        .map((MapEntry<int, int> entry) => ladder[entry.key])
        .toList(),
    'http412': _http412,
    'http429': _http429,
    'timeouts': _timeouts,
    'firstByteTimeouts': _firstByteTimeouts,
    'failures': _failures,
    'reason': _lastReason,
    'events': List<String>.unmodifiable(_events),
  };

  void close() {
    _closed = true;
    _state = AutoConcurrencyState.idle;
    _trial = null;
    _buckets.clear();
    _aheadSamples.clear();
    _saturatedSpans.clear();
    _saturated = false;
    _pressureSince = -1;
    _comfortableSince = -1;
    _lastActivityAt = -1;
  }
}

class _Trial {
  _Trial({
    required this.from,
    required this.at,
    required this.baselineBps,
    required this.baselineTrend,
  });

  final int from;
  final int at;
  final double baselineBps;
  final double baselineTrend;
  bool stalled = false;
}
