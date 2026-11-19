// Small, dependency-free state helpers for BTR feedback from media_kit.
//
// The player integration is intentionally not mocked here: these classes cover
// the two pieces that are easy to get wrong in an async event stream:
//   * coalescing/throttling `demuxer-cache-idle` reads and rejecting results
//     from a previous source session;
//   * suppressing the first buffering transition after a seek/reopen while
//     still providing a bounded, event-independent way to release the guard.

/// Coalesces async mpv property reads and keeps one cached boolean per player.
///
/// `getProperty` in the OHOS media_kit fork is async. The position listener is
/// hot, so a read is started at most once per [minInterval] and never while a
/// previous read is still in flight. A result is accepted only when both its
/// token and its session still match; [invalidate] is called on every new
/// source/seek/rebuild.
class RipperCacheFullProbe {
  RipperCacheFullProbe({
    this.minInterval = const Duration(milliseconds: 500),
    this.maxAge = const Duration(seconds: 1),
    int Function()? now,
  }) : _now = now ?? _defaultNow;

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

  final Duration minInterval;

  /// `demuxer-cache-idle` is a transient signal. The next read is at most
  /// 500 ms away; a value older than this is not used to end startup.
  final Duration maxAge;
  final int Function() _now;

  bool _cacheFull = false;
  bool _inFlight = false;
  int _token = 0;
  int _lastStartedAt = -1000000;
  int _observedAt = -1000000;
  int _session = 0;

  bool get cacheFull =>
      _cacheFull && _now() - _observedAt <= maxAge.inMilliseconds;
  bool get inFlight => _inFlight;

  /// Returns a token for a new read, or null when throttled/in-flight/invalid.
  int? begin({required int session}) {
    if (session == 0 || _inFlight) return null;
    final int now = _now();
    if (now - _lastStartedAt < minInterval.inMilliseconds) return null;
    _lastStartedAt = now;
    _inFlight = true;
    _token += 1;
    _session = session;
    return _token;
  }

  /// Accepts an mpv flag value; unknown/empty values safely mean false.
  void complete(int token, {required int session, required String value}) {
    if (token != _token || session != _session) return;
    _cacheFull = value.trim().toLowerCase() == 'yes';
    _observedAt = _now();
    _inFlight = false;
  }

  /// A failed/timeout/unknown read is treated as not full and can be retried.
  /// The token is invalidated so a late completion from the same timed-out
  /// Future cannot overwrite the reset value.
  void fail(int token, {required int session}) {
    if (token != _token || session != _session) return;
    _token += 1;
    _cacheFull = false;
    _observedAt = -1000000;
    _inFlight = false;
  }

  /// Drops the cached value and invalidates every read already in flight.
  void invalidate() {
    _token += 1;
    _session = 0;
    _cacheFull = false;
    _observedAt = -1000000;
    _inFlight = false;
    _lastStartedAt = -1000000;
  }
}

/// Suppresses stall/buffer feedback while a seek, source reopen or player
/// rebuild is settling.
///
/// The primary release is the player's `buffering == false` event. If that
/// event never arrives (the player is disposed, the source fails, or mpv
/// leaves the flag asserted), the controller's bounded watchdog calls
/// [expire]. No position-based fallback is used: a position event can arrive
/// before the first buffering transition and would reintroduce the false
/// stall this guard is meant to prevent.
class RipperRestartGuard {
  bool _active = false;
  bool _requireNewBuffering = false;

  bool get active => _active;

  /// [alreadyBuffering] is true when a new seek starts while the previous
  /// transition's buffering event is still current. In that case a stale
  /// `buffering=false` must not release the new guard; wait for a new true
  /// transition or the watchdog.
  void begin({bool alreadyBuffering = false}) {
    _active = true;
    _requireNewBuffering = alreadyBuffering;
  }

  /// Returns true while the guard is still active.
  bool observeBuffering(bool buffering) {
    if (!_active) return false;
    if (!buffering) {
      if (_requireNewBuffering) return true;
      clear();
      return false;
    }
    _requireNewBuffering = false;
    return true;
  }

  /// Bounded safety net for a player that never emits the expected event.
  void expire() => clear();

  void clear() {
    _active = false;
    _requireNewBuffering = false;
  }
}
