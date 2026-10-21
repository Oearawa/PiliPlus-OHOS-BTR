// Port of Bilibili-thread-ripper `src/idm-downloader.js` (MIT).
// Upstream: https://github.com/MrTangLuyao/Bilibili-thread-ripper
//
// The browser engine uses `fetch` + `AbortController`; here the same shape is
// built on `dart:io` `HttpClient` and a small abort signal. Only the parts the
// native range proxy needs are ported: the three-class semaphore, the
// piece-then-range scheduler, the 206/Content-Range validation, hedging with
// two copies and resuming from the verified prefix. The auto-concurrency
// controller lives in `auto_concurrency.dart` and only receives measurements
// from here, so this file stays independent from the player.
//
// Native additions on top of the upstream algorithm:
//   * `onActivity` reports bytes flowing on the wire (upstream `activity()`),
//     which lets the controller tell "few threads" from "nothing to download".
//   * first-byte timeouts and mid-body stalls are reported separately
//     (status -1 / -2) so a hard timeout lowers the thread count at once while
//     a late body only counts as a slow node.
//   * identical byte ranges asked for twice inside one track share a single
//     transfer (`_PieceFlight`); a duplicate never starts a second download of
//     the same bytes, and a caller that gives up does not cancel the winner.
//
// JS counterpart map:
//   Semaphore            -> RipperSemaphore
//   attempt              -> IdmDownloader.fetchPiece
//   readBody             -> IdmDownloader._readBody
//   downloadPiece        -> IdmDownloader._downloadPiece
//   downloadRange        -> IdmDownloader.downloadRange
//   abortError           -> RipperAbortException
//   performance.now()    -> RipperClock (Stopwatch based)

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';

/// Queue classes, served in this order: the startup probe and init/index,
/// then startup pieces, then everything else.
enum QueueClass { critical, startup, ordinary }

/// `abortError(reason)`.
class RipperAbortException implements Exception {
  const RipperAbortException([this.message = 'download cancelled']);

  final String message;

  @override
  String toString() => 'RipperAbortException: $message';
}

/// A CDN answered something that is not a valid partial response.
class RipperHttpException implements Exception {
  const RipperHttpException(this.message, {this.status = 0});

  final String message;
  final int status;

  @override
  String toString() => 'RipperHttpException($status): $message';
}

/// Minimal `AbortController`/`AbortSignal` replacement.
///
/// `abort()` is idempotent; listeners fire synchronously; [whenAborted] can be
/// raced against I/O. Child signals follow their parent.
class RipperAbortSignal {
  RipperAbortSignal();

  RipperAbortSignal._child(RipperAbortSignal parent) {
    void onParentAbort() => abort(parent.reason);
    parent.addListener(onParentAbort);
    _parentCleanup = () => parent.removeListener(onParentAbort);
  }

  /// A signal that aborts when [parent] aborts.
  factory RipperAbortSignal.linkedTo(RipperAbortSignal? parent) {
    if (parent == null) return RipperAbortSignal();
    return RipperAbortSignal._child(parent);
  }

  final List<void Function()> _listeners = <void Function()>[];
  final Completer<void> _done = Completer<void>();
  void Function()? _parentCleanup;
  bool _aborted = false;
  Object? _reason;

  bool get isAborted => _aborted;

  Object? get reason => _reason;

  Future<void> get whenAborted => _done.future;

  void abort([Object? reason]) {
    if (_aborted) return;
    _aborted = true;
    _reason = reason;
    _parentCleanup?.call();
    _parentCleanup = null;
    for (final void Function() listener in List<void Function()>.of(
      _listeners,
    )) {
      listener();
    }
    _listeners.clear();
    if (!_done.isCompleted) _done.complete();
  }

  void addListener(void Function() listener) {
    if (_aborted) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Throws [RipperAbortException] when already aborted.
  void throwIfAborted() {
    if (_aborted) throw const RipperAbortException();
  }
}

/// Monotonic clock replacing `performance.now()`.
class RipperClock {
  RipperClock() : _watch = Stopwatch()..start();

  final Stopwatch _watch;

  int get nowMs => _watch.elapsedMilliseconds;

  Duration get elapsed => _watch.elapsed;
}

final RipperClock ripperClock = RipperClock();

class _Waiter {
  _Waiter({
    required this.priority,
    required this.queueClass,
    required this.deadlineMs,
    required this.ages,
    required this.sequence,
    required this.queuedAt,
    required this.resolve,
    required this.reject,
    required this.signal,
  });

  final int priority;
  final QueueClass queueClass;
  final int? deadlineMs;
  final bool ages;
  final int sequence;
  final int queuedAt;
  final void Function(void Function() release) resolve;
  final void Function(Object error) reject;
  final RipperAbortSignal? signal;
  void Function()? cancel;
  bool released = false;
}

/// Port of the upstream `Semaphore`.
///
/// One global limit for every connection of the page/session. The three queue
/// classes are strict; inside a class the rank is
/// `priority + deadline urgency + queue aging`, then arrival order.
class RipperSemaphore {
  RipperSemaphore(int limit, {this.onChange, RipperClock? clock})
    : _limit = math.max(1, math.min(512, limit)),
      _clock = clock ?? ripperClock;

  /// 20 points per 900 ms of waiting, like `QUEUE_AGING_PER_MS`.
  static const double agingPerMs = 20 / 900;

  final RipperClock _clock;
  final List<_Waiter> _queue = <_Waiter>[];
  int _limit;
  int _active = 0;
  int _peakActive = 0;
  int _sequence = 0;
  bool _closed = false;

  /// Called with `(active, limit, queued)` whenever the pool changes.
  final void Function(int active, int limit, int queued)? onChange;

  int get limit => _limit;

  int get active => _active;

  /// Highest number of slots held at once since construction (tests/diagnostics).
  int get peakActive => _peakActive;

  int get queued => _queue.length;

  void setLimit(int limit) {
    if (_closed) return;
    _limit = math.max(1, math.min(512, limit));
    _drain();
  }

  /// Reject all queued work. In-flight requests are aborted by their signals.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final _Waiter waiter in _queue) {
      waiter.signal?.removeListener(waiter.cancel!);
      waiter.reject(const RipperAbortException());
    }
    _queue.clear();
    onChange?.call(_active, _limit, 0);
  }

  /// Resolves with a release callback once a slot is held.
  Future<void Function()> acquire({
    RipperAbortSignal? signal,
    int priority = 0,
    QueueClass queueClass = QueueClass.critical,
    int? deadlineMs,
    bool ages = false,
  }) {
    if (_closed || (signal?.isAborted ?? false)) {
      return Future<void Function()>.error(const RipperAbortException());
    }
    final Completer<void Function()> completer = Completer<void Function()>();
    final _Waiter waiter = _Waiter(
      priority: priority,
      queueClass: queueClass,
      deadlineMs: deadlineMs,
      ages: ages,
      sequence: _sequence++,
      queuedAt: _clock.nowMs,
      resolve: completer.complete,
      reject: completer.completeError,
      signal: signal,
    );
    void cancel() {
      final int index = _queue.indexOf(waiter);
      if (index < 0) return;
      _queue.removeAt(index);
      signal?.removeListener(cancel);
      if (!completer.isCompleted) {
        completer.completeError(const RipperAbortException());
      }
    }

    waiter.cancel = cancel;
    signal?.addListener(cancel);
    _queue.add(waiter);
    _drain();
    onChange?.call(_active, _limit, _queue.length);
    return completer.future;
  }

  int _urgency(_Waiter waiter, int now) {
    final int? deadlineAt = waiter.deadlineMs;
    if (deadlineAt == null) return 0;
    final int remaining = deadlineAt - now;
    if (remaining <= 0) return 12;
    if (remaining <= 750) return 9;
    if (remaining <= 2000) return 6;
    return 0;
  }

  void _drain() {
    try {
      while (_active < _limit && _queue.isNotEmpty) {
        final int now = _clock.nowMs;
        _queue.sort((_Waiter a, _Waiter b) {
          final int byClass = a.queueClass.index.compareTo(b.queueClass.index);
          if (byClass != 0) return byClass;
          final double agingA = a.ages ? (now - a.queuedAt) * agingPerMs : 0;
          final double agingB = b.ages ? (now - b.queuedAt) * agingPerMs : 0;
          final double rankA = a.priority + _urgency(a, now) + agingA;
          final double rankB = b.priority + _urgency(b, now) + agingB;
          final int byRank = rankB.compareTo(rankA);
          return byRank != 0 ? byRank : a.sequence.compareTo(b.sequence);
        });
        final _Waiter waiter = _queue.removeAt(0);
        waiter.signal?.removeListener(waiter.cancel!);
        if (waiter.signal?.isAborted ?? false) {
          waiter.reject(const RipperAbortException());
          continue;
        }
        _active += 1;
        if (_active > _peakActive) _peakActive = _active;
        waiter.resolve(() {
          if (waiter.released) return;
          waiter.released = true;
          _active = math.max(0, _active - 1);
          _drain();
        });
      }
    } finally {
      onChange?.call(_active, _limit, _queue.length);
    }
  }
}

/// `{ bytes, total, url }` returned by `attempt`.
class DownloadPiece {
  const DownloadPiece(this.bytes, this.total, this.url);

  final Uint8List bytes;
  final int? total;
  final Uri url;
}

/// One in-flight byte range shared by every caller that asks for it.
///
/// The downloader splits a window deterministically, so the only way the same
/// range is requested twice is a probe overlapping a window or the player
/// re-opening a track. Sharing the transfer keeps the connection count honest
/// and guarantees the bytes are only fetched once.
class _PieceFlight {
  final Completer<DownloadPiece> _completer = Completer<DownloadPiece>();

  Future<DownloadPiece> get future => _completer.future;

  bool get completed => _completer.isCompleted;

  void succeed(DownloadPiece piece) {
    if (!_completer.isCompleted) _completer.complete(piece);
  }

  void fail(Object error, StackTrace stack) {
    if (!_completer.isCompleted) _completer.completeError(error, stack);
  }
}

/// Result of [IdmDownloader.downloadRange].
class DownloadResult {
  const DownloadResult({
    required this.byteLength,
    required this.pieceCount,
    required this.total,
    required this.streamed,
    required this.hosts,
  });

  final int byteLength;
  final int pieceCount;
  final int? total;
  final bool streamed;
  final List<String> hosts;
}

/// Port of `createDownloader(options)` for one session.
class IdmDownloader {
  IdmDownloader({
    required this.settings,
    HttpClient Function()? clientFactory,
    this.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/120.0.0.0 Safari/537.36',
    this.referer = 'https://www.bilibili.com/',
    CdnAssignments? assignments,
    RipperClock? clock,
  }) : _client = (clientFactory ?? _defaultClientFactory)(),
       assignments = assignments ?? CdnAssignments(),
       _clock = clock ?? ripperClock,
       semaphore = RipperSemaphore(
         settings.concurrency,
         clock: clock ?? ripperClock,
       );

  static HttpClient _defaultClientFactory() => HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(milliseconds: 5500);

  final RipperSettings settings;
  final String userAgent;
  final String referer;
  final CdnAssignments assignments;
  final HttpClient _client;
  final RipperSemaphore semaphore;
  final RipperClock _clock;

  /// Byte ranges currently in flight, keyed by track and absolute range.
  final Map<String, _PieceFlight> _flights = <String, _PieceFlight>{};

  /// Last time a body chunk arrived, on the same clock as the controller.
  int _lastActivityAt = -1;

  /// Milliseconds since the last delivered body chunk, or null when nothing
  /// has been transferred yet in this downloader's life.
  int? get activityAgeMs {
    if (_lastActivityAt < 0) return null;
    return math.max(0, _clock.nowMs - _lastActivityAt);
  }

  /// Called after a piece is fully validated and accepted; the auto
  /// concurrency controller uses it for its throughput window. It is called
  /// once per winning piece, not once per hedge copy.
  void Function(int bytes)? onDelivered;

  /// Called for every body chunk that arrives (upstream `activity()`), so the
  /// controller can tell "the connections are too few" from "there is nothing
  /// to download right now".
  void Function(int bytes)? onActivity;

  /// Called for an HTTP status observed on a media request. The player uses
  /// 412/429 to trigger a hard concurrency backoff; other statuses stay in the
  /// existing retry/fallback path. `-1` is a first-byte timeout, `-2` a stall
  /// in the middle of a body.
  void Function(int status)? onHttpStatus;

  /// `downloadRange(range, resolver, options)`.
  ///
  /// Splits the range, assigns primaries, downloads pieces in parallel and
  /// flushes them to [onOrderedChunk] in file order. Without a callback the
  /// whole range is returned by [DownloadResult.byteLength] being ignored and
  /// no bytes are kept (the proxy always streams).
  Future<DownloadResult> downloadRange(
    ByteRange range,
    CdnResolver resolver, {
    RipperAbortSignal? signal,
    bool parallel = true,
    int? maxConcurrency,
    FutureOr<void> Function(Uint8List bytes, ByteRange piece, int? total)?
    onOrderedChunk,
    bool startup = false,
    bool audio = false,
    String trackKey = '',
  }) async {
    signal?.throwIfAborted();
    final int globalConcurrency = parallel ? settings.concurrency : 1;
    final int requested = maxConcurrency ?? globalConcurrency;
    final int effective = math.max(1, math.min(globalConcurrency, requested));
    // Do not reset the semaphore from here. In automatic mode its limit is
    // owned by AutoConcurrency and changes while requests are queued; resetting
    // it to the static settings value silently capped every later window at
    // the initial/max UI value (often 8), defeating the controller.
    final List<Uri> preferred = parallel
        ? resolver.rangeCandidates()
        : resolver.urls();
    final List<ByteRange> pieces = splitRange(
      range.start,
      range.end,
      effective,
      settings.minChunkBytes,
    );
    final List<Uri> primaries = parallel
        ? assignments.assign(preferred, resolver, pieces.length)
        : <Uri>[];
    final List<Uint8List?> ordered = List<Uint8List?>.filled(
      pieces.length,
      null,
    );
    int nextOrdered = 0;
    int? knownTotal;
    Future<void> flushOperation = Future<void>.value();

    void enqueueFlush() {
      flushOperation = flushOperation.then((_) async {
        while (nextOrdered < ordered.length && ordered[nextOrdered] != null) {
          final Uint8List bytes = ordered[nextOrdered]!;
          ordered[nextOrdered] = null;
          await onOrderedChunk?.call(bytes, pieces[nextOrdered], knownTotal);
          nextOrdered += 1;
        }
      });
    }

    final List<DownloadPiece> results = await Future.wait(
      List<Future<DownloadPiece>>.generate(pieces.length, (int index) async {
        final ByteRange piece = pieces[index];
        final Uri? primary = parallel && index < primaries.length
            ? primaries[index]
            : null;
        final List<Uri> piecePreferred = <Uri>[
          ?primary,
          ...preferred.where((Uri url) => url != primary),
        ];
        final DownloadPiece result = await _downloadPieceShared(
          piece,
          resolver,
          signal: signal,
          preferred: piecePreferred,
          pieceIndex: index,
          startup: startup,
          audio: audio,
          trackKey: trackKey,
        );
        knownTotal ??= result.total;
        if (onOrderedChunk != null) {
          ordered[index] = result.bytes;
          enqueueFlush();
        }
        return result;
      }),
    );
    await flushOperation;
    final List<int> totals = results
        .map((DownloadPiece piece) => piece.total)
        .whereType<int>()
        .toList();
    if (totals.isNotEmpty && totals.any((int total) => total != totals.first)) {
      throw const RipperHttpException('CDN total length mismatch');
    }
    return DownloadResult(
      byteLength: range.length,
      pieceCount: pieces.length,
      total: totals.isEmpty ? null : totals.first,
      streamed: onOrderedChunk != null,
      hosts: results.map((DownloadPiece p) => p.url.host).toSet().toList(),
    );
  }

  /// `downloadPiece(piece, resolver, ...)` with duplicate suppression.
  ///
  /// One byte range is downloaded once. A probe that overlaps a running
  /// window, or a player that re-opens the same track, waits for the transfer
  /// already in progress instead of opening more connections for the same
  /// bytes. [trackKey] keeps the video and audio tracks apart: byte 0 of the
  /// video is not byte 0 of the audio.
  Future<DownloadPiece> _downloadPieceShared(
    ByteRange piece,
    CdnResolver resolver, {
    required RipperAbortSignal? signal,
    required List<Uri> preferred,
    required int pieceIndex,
    required bool startup,
    required bool audio,
    required String trackKey,
  }) {
    final String key = '$trackKey\u0000${piece.start}-${piece.end}';
    final _PieceFlight? running = _flights[key];
    if (running != null) return _joinFlight(running, signal);
    final _PieceFlight flight = _PieceFlight();
    _flights[key] = flight;
    unawaited(() async {
      try {
        flight.succeed(
          await _downloadPiece(
            piece,
            resolver,
            signal: signal,
            preferred: preferred,
            pieceIndex: pieceIndex,
            startup: startup,
            audio: audio,
          ),
        );
      } on Object catch (error, stack) {
        flight.fail(error, stack);
      } finally {
        if (identical(_flights[key], flight)) _flights.remove(key);
      }
    }());
    return _joinFlight(flight, signal);
  }

  /// Awaits a shared transfer while still honouring the caller's own abort.
  ///
  /// The abort only detaches this caller: the download that the first caller
  /// started keeps running, because its own signal owns it.
  Future<DownloadPiece> _joinFlight(
    _PieceFlight flight,
    RipperAbortSignal? signal,
  ) {
    if (signal == null) return flight.future;
    final Completer<DownloadPiece> waiter = Completer<DownloadPiece>();
    void onAbort() {
      if (!waiter.isCompleted) {
        waiter.completeError(const RipperAbortException());
      }
    }

    signal.addListener(onAbort);
    flight.future.then(
      (DownloadPiece value) {
        if (!waiter.isCompleted) waiter.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!waiter.isCompleted) waiter.completeError(error, stack);
      },
    );
    if (signal.isAborted) onAbort();
    return waiter.future.whenComplete(() => signal.removeListener(onAbort));
  }

  /// `downloadPiece(piece, resolver, ...)`.
  Future<DownloadPiece> _downloadPiece(
    ByteRange piece,
    CdnResolver resolver, {
    required RipperAbortSignal? signal,
    required List<Uri> preferred,
    required int pieceIndex,
    required bool startup,
    required bool audio,
  }) async {
    Object lastError = const RipperHttpException('no available CDN');
    final Stopwatch started = Stopwatch()..start();
    for (int round = 0; round < settings.maxRounds; round += 1) {
      signal?.throwIfAborted();
      if (round > 0) {
        if (started.elapsed > const Duration(seconds: 25)) break;
        await _pause(
          Duration(milliseconds: math.min(2000, 500 * (1 << (round - 1)))),
          signal,
        );
      }
      final List<Uri> candidates = resolver.pieceCandidates(
        preferred,
        pieceIndex,
        round,
      );
      final int limit = math.min(8, candidates.length);
      final Set<Uri> tried = <Uri>{};
      while (tried.length < limit) {
        signal?.throwIfAborted();
        final List<Uri> untried = candidates
            .where((Uri url) => !tried.contains(url))
            .toList();
        final List<Uri> allowed = untried.where(resolver.allows).toList();
        final List<Uri> pair = (allowed.isEmpty ? untried : allowed)
            .take(startup ? limit : 2)
            .toList();
        if (pair.isEmpty) break;
        tried.addAll(pair);
        try {
          final DownloadPiece winner = await _race(
            piece,
            pair,
            resolver,
            signal: signal,
            startup: startup,
            audio: audio,
          );
          // Count only the winning copy. A hedge loser may have completed in
          // the same event-loop turn and must not inflate goodput.
          onDelivered?.call(winner.bytes.length);
          return winner;
        } on Object catch (error) {
          lastError = error;
        }
      }
    }
    throw lastError;
  }

  /// Two copies of one piece; the first to finish wins and the other is
  /// aborted (upstream hedges media pieces for the same reason).
  Future<DownloadPiece> _race(
    ByteRange piece,
    List<Uri> urls,
    CdnResolver resolver, {
    required RipperAbortSignal? signal,
    required bool startup,
    required bool audio,
  }) async {
    final Completer<DownloadPiece> completer = Completer<DownloadPiece>();
    final List<RipperAbortSignal> children = <RipperAbortSignal>[];
    final List<Timer> timers = <Timer>[];
    int failures = 0;

    void launch(int index) {
      if (completer.isCompleted) return;
      final RipperAbortSignal child = RipperAbortSignal.linkedTo(signal);
      children.add(child);
      fetchPiece(
        piece,
        urls[index],
        resolver,
        signal: child,
        priority: audio ? 90 : (index == 0 ? 50 : 70),
        queueClass: startup
            ? QueueClass.startup
            : audio
            ? QueueClass.critical
            : QueueClass.ordinary,
      ).then(
        (DownloadPiece value) {
          if (!completer.isCompleted) completer.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          failures += 1;
          if (failures == urls.length && !completer.isCompleted) {
            completer.completeError(error, stack);
          }
        },
      );
    }

    launch(0);
    for (int index = 1; index < urls.length; index += 1) {
      final int delayMs = startup
          ? 0
          : math.min(250, settings.hedgeDelay.inMilliseconds);
      if (delayMs <= 0) {
        launch(index);
      } else {
        timers.add(Timer(Duration(milliseconds: delayMs), () => launch(index)));
      }
    }
    try {
      return await completer.future;
    } finally {
      for (final Timer timer in timers) {
        timer.cancel();
      }
      for (final RipperAbortSignal child in children) {
        if (!child.isAborted) child.abort();
      }
    }
  }

  /// `attempt(piece, url, ...)`.
  ///
  /// Strictly validates HTTP 206 and `Content-Range` against the requested
  /// piece, streams the body with a stall timeout and returns the bytes.
  Future<DownloadPiece> fetchPiece(
    ByteRange piece,
    Uri url,
    CdnResolver resolver, {
    RipperAbortSignal? signal,
    int priority = 0,
    QueueClass queueClass = QueueClass.critical,
  }) async {
    final void Function() release = await semaphore.acquire(
      signal: signal,
      priority: priority,
      queueClass: queueClass,
    );
    final Stopwatch elapsed = Stopwatch()..start();
    HttpClientRequest? request;
    Timer? attemptTimer;
    int received = 0;
    bool completed = false;
    bool headersReceived = false;
    bool timedOut = false;
    // `AbortController` in the browser cancels the fetch itself; here the
    // listener has to abort the underlying request, otherwise a signal only
    // takes effect between explicit checkpoints.
    void abortRequest() {
      try {
        request?.abort(const RipperAbortException());
      } on Object {
        // The request is already finished or aborted.
      }
    }

    signal?.addListener(abortRequest);
    try {
      signal?.throwIfAborted();
      request = await _client.getUrl(url).timeout(settings.firstByteTimeout);
      signal?.throwIfAborted();
      attemptTimer = Timer(settings.attemptTimeout, () {
        timedOut = true;
        request?.abort(const RipperHttpException('CDN attempt timeout'));
      });
      request.headers
        ..set(HttpHeaders.rangeHeader, 'bytes=${piece.start}-${piece.end}')
        ..set(HttpHeaders.acceptEncodingHeader, 'identity')
        ..set(HttpHeaders.userAgentHeader, userAgent)
        ..set(HttpHeaders.refererHeader, referer);
      final Duration remaining = settings.firstByteTimeout - elapsed.elapsed;
      final HttpClientResponse response = await request.close().timeout(
        remaining.isNegative ? Duration.zero : remaining,
      );
      headersReceived = true;
      final int status = response.statusCode;
      final ByteRange? contentRange = parseContentRange(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (status != HttpStatus.partialContent ||
          contentRange == null ||
          contentRange.start != piece.start ||
          contentRange.end != piece.end) {
        throw RipperHttpException(
          'invalid CDN Range response: HTTP $status',
          status: status,
        );
      }
      final int? total = contentRange.total;
      if (total != null && total <= piece.end) {
        throw const RipperHttpException('inconsistent CDN resource length');
      }
      final Uint8List bytes = await _readBody(
        response,
        signal,
        settings.stallTimeout,
        onChunk: (int length) {
          received += length;
          _lastActivityAt = _clock.nowMs;
          onActivity?.call(length);
        },
      );
      if (bytes.length != piece.length) {
        throw RipperHttpException(
          'CDN piece length mismatch: ${bytes.length}/${piece.length}',
        );
      }
      completed = true;
      resolver.success(url, bytes: bytes.length, elapsed: elapsed.elapsed);
      return DownloadPiece(bytes, total, url);
    } on Object catch (error) {
      final bool aborted =
          (signal?.isAborted ?? false) || error is RipperAbortException;
      if (!aborted) {
        final int status = error is RipperHttpException ? error.status : 0;
        if (status > 0) onHttpStatus?.call(status);
        resolver.failure(
          url,
          status: status,
          receivedBytes: received,
          aborted: aborted,
          error: error,
        );
        if (received >= speedSampleMinBytes) {
          resolver.sample(
            url,
            received * 1000000 / math.max(1, elapsed.elapsedMicroseconds),
          );
        }
      } else {
        throw const RipperAbortException();
      }
      // A timeout before the first body byte means the node or the signature
      // is not answering: the controller lowers the thread count at once. A
      // stall after bytes arrived is a slow node, which only counts as one
      // failure in the retry path.
      if (error is TimeoutException || timedOut) {
        onHttpStatus?.call(received > 0 || headersReceived ? -2 : -1);
        throw RipperHttpException(
          headersReceived ? 'CDN body stalled' : 'CDN response timeout',
        );
      }
      rethrow;
    } finally {
      attemptTimer?.cancel();
      signal?.removeListener(abortRequest);
      if (!completed) request?.abort();
      release();
    }
  }

  /// `readBody(response, ...)`: only the stall timeout differs from plain
  /// reading, plus a hard length ceiling on the caller side.
  Future<Uint8List> _readBody(
    HttpClientResponse response,
    RipperAbortSignal? signal,
    Duration stallTimeout, {
    required void Function(int length) onChunk,
  }) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(stallTimeout)) {
      signal?.throwIfAborted();
      builder.add(chunk);
      onChunk(chunk.length);
    }
    return builder.takeBytes();
  }

  Future<void> _pause(Duration delay, RipperAbortSignal? signal) {
    if (signal == null) return Future<void>.delayed(delay);
    final Completer<void> completer = Completer<void>();
    final Timer timer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete();
    });
    void onAbort() {
      timer.cancel();
      if (!completer.isCompleted) {
        completer.completeError(const RipperAbortException());
      }
    }

    signal.addListener(onAbort);
    if (signal.isAborted) onAbort();
    return completer.future.whenComplete(() => signal.removeListener(onAbort));
  }

  /// Closes the underlying client and fails any queued request.
  void close() {
    semaphore.close();
    _flights.clear();
    _client.close(force: true);
  }
}
