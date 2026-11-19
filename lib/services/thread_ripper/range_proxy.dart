// Native range transport for Bilibili-thread-ripper.
//
// The browser script replaces `fetch`/`XMLHttpRequest` (`native-range-transport.js`)
// or the whole MSE pipeline; a native player cannot be patched that way, so the
// same download engine is exposed as a loopback HTTP endpoint and mpv opens it
// like any other media URL. Only 127.0.0.1 is bound, the path carries a random
// token, and only registered tracks are served.
//
// JS counterpart map:
//   planRequest          -> _serve / _parseRange
//   download             -> _streamRange
//   response headers     -> _writeHead
//   AbortController      -> RipperAbortSignal
//
// This file is deliberately independent from the player: it never imports
// Flutter or PiliPlus pages.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/idm_downloader.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';

/// How many bytes one video window asks for before the next one starts.
///
/// Upstream has no such window (the web player asks by SIDX segment); mpv asks
/// with open-ended ranges, so a bounded window keeps the proxy from buffering
/// a whole movie in memory.
const int defaultWindowBytes = 4 * 1024 * 1024;

/// One registered media track.
class RipperTrack {
  RipperTrack(this.resolver, {required this.isAudio});

  final CdnResolver resolver;
  final bool isAudio;
  int? total;

  /// The request currently serving this track; a new one replaces it.
  ProxyJob? request;
  bool opened = false;
}

/// A local HTTP Range proxy backed by [IdmDownloader].
class RipperRangeProxy {
  RipperRangeProxy({
    RipperSettings? settings,
    int concurrency = 8,
    this.mode = CdnMode.mainland,
    List<String> customHosts = const <String>[],
    required this.userAgent,
    this.referer = 'https://www.bilibili.com/',
    HttpClient Function()? clientFactory,
    RipperClock? clock,
  }) : settings = settings ?? RipperSettings(concurrency: concurrency),
       customHosts = List<String>.unmodifiable(customHosts),
       _clientFactory = clientFactory,
       _clock = clock ?? ripperClock;

  final RipperSettings settings;
  final CdnMode mode;
  final List<String> customHosts;
  final String userAgent;
  final String referer;
  final HttpClient Function()? _clientFactory;
  final RipperClock _clock;

  final String _token = _randomToken();
  final Map<String, RipperTrack> _tracks = <String, RipperTrack>{};
  final Set<ProxyJob> _jobs = <ProxyJob>{};
  HttpServer? _server;
  late final IdmDownloader _downloader = IdmDownloader(
    settings: settings,
    clientFactory: _clientFactory,
    userAgent: userAgent,
    referer: referer,
    clock: _clock,
  );
  bool _closed = false;

  static String _randomToken() {
    final math.Random random = math.Random.secure();
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 24; i += 1) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// `HttpServer.bind(InternetAddress.loopbackIPv4, 0)`.
  Future<void> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    if (_closed) {
      await server.close(force: true);
      throw StateError('download session closed');
    }
    _server = server;
    server.listen(
      (HttpRequest request) => _serve(request).catchError((Object _) {}),
    );
  }

  int get port => _server?.port ?? 0;

  String get token => _token;

  /// Shared connection budget, used by the auto-concurrency controller.
  RipperSemaphore get semaphore => _downloader.semaphore;

  /// Number of registered tracks (video, optional audio). Diagnostics only.
  int get trackCount => _tracks.length;

  /// Forward validated byte counts to the auto-concurrency controller.
  void setDeliveryListener(void Function(int bytes)? listener) {
    _downloader.onDelivered = listener;
  }

  /// Forward body-chunk arrivals (`activity()` upstream).
  void setActivityListener(void Function(int bytes)? listener) {
    _downloader.onActivity = listener;
  }

  /// Forward HTTP statuses (412/429, -1 first byte, -2 stall) to the
  /// controller.
  void setHttpStatusListener(void Function(int status)? listener) {
    _downloader.onHttpStatus = listener;
  }

  /// Registers a track and returns its loopback URL.
  Uri register(Iterable<Uri> candidates, {bool isAudio = false}) {
    if (_closed || _server == null) {
      throw StateError('no download session');
    }
    final List<Uri> urls = candidates
        .where((Uri uri) => uri.scheme == 'http' || uri.scheme == 'https')
        .toSet()
        .toList();
    if (urls.isEmpty) throw StateError('no media candidates');
    final List<String> normalized = customHosts
        .map(normalizeCdnHost)
        .whereType<String>()
        .toList();
    final String id = '/$_token/${_tracks.length}';
    // Real Bilibili media URLs are re-expanded for the selected region: the
    // playurl list may name mainland nodes even when the user picked overseas.
    // Tests and non-Bilibili fixtures keep their explicit addresses.
    final CdnResolver resolver = urls.any(isBilibiliMediaUrl)
        ? CdnResolver.fromRepresentation(
            baseUrl: urls.first,
            backupUrls: urls.skip(1).toList(),
            mode: mode,
            customHosts: normalized,
            now: DateTime.now,
          )
        : CdnResolver(
            urls,
            mode: mode,
            customHosts: normalized,
            now: DateTime.now,
          );
    _tracks[id] = RipperTrack(resolver, isAudio: isAudio);
    return Uri.parse('http://127.0.0.1:$port$id');
  }

  /// Stops every request and closes the listener.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final ProxyJob job in _jobs.toList()) {
      job.cancel();
    }
    _jobs.clear();
    _tracks.clear();
    _downloader.close();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _serve(HttpRequest request) async {
    final RipperTrack? track = _tracks[request.uri.path];
    if (track == null || _closed) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    final ProxyJob job = ProxyJob();
    _jobs.add(job);
    if (request.method == 'GET') {
      // mpv opens one connection per track and sends the next request before
      // closing the old one; a seek/reopen therefore replaces the old job.
      track.request?.cancel();
      track
        ..request = job
        ..opened = true;
    }

    _Connection? connection;
    try {
      connection = await _Connection.detach(request, job);
      final String? rangeHeader = request.headers.value(
        HttpHeaders.rangeHeader,
      );
      track.total ??= await _probeTotal(track, job);
      final int total = track.total!;
      final (int start, int end) = _parseRange(rangeHeader, total);
      final int status = rangeHeader == null
          ? HttpStatus.ok
          : HttpStatus.partialContent;
      final String? contentRange = rangeHeader == null
          ? null
          : 'bytes $start-$end/$total';
      if (request.method == 'HEAD') {
        connection.writeHead(
          status,
          end - start + 1,
          contentRange: contentRange,
        );
        await connection.close();
        return;
      }
      connection.writeHead(status, end - start + 1, contentRange: contentRange);
      await _streamRange(track, job, connection, start, end, total);
      await connection.close();
    } on FormatException {
      if (connection != null && !connection.headersSent) {
        connection.writeHead(
          HttpStatus.requestedRangeNotSatisfiable,
          0,
          contentRange: 'bytes */${track.total}',
        );
        await connection.close();
      } else {
        await connection?.destroy();
      }
    } on Object {
      if (job.cancelled) {
        // The player went away (seek/close): reset the socket instead of
        // pretending the request failed for a server-side reason.
        await connection?.destroy();
      } else if (connection != null && !connection.headersSent) {
        // A truncated byte stream must stay visible to the player, so headers
        // already sent are followed by a reset instead of a clean close.
        try {
          connection.writeHead(HttpStatus.badGateway, 0);
          await connection.close();
        } on Object {
          await connection.destroy();
        }
      } else {
        await connection?.destroy();
      }
    } finally {
      job.cancel();
      _jobs.remove(job);
      if (identical(track.request, job)) track.request = null;
      await connection?.destroy();
    }
  }

  /// Learns the file length with a one-byte request (`0-0`).
  Future<int> _probeTotal(RipperTrack track, ProxyJob job) async {
    final DownloadResult result = await _downloader.downloadRange(
      const ByteRange(0, 0),
      track.resolver,
      signal: job.signal,
      maxConcurrency: 1,
      startup: true,
      trackKey: track.isAudio ? 'audio' : 'video',
    );
    final int? total = result.total;
    if (total == null || total <= 0) {
      throw const RipperHttpException('CDN did not report a file length');
    }
    return total;
  }

  Future<void> _streamRange(
    RipperTrack track,
    ProxyJob job,
    _Connection connection,
    int start,
    int end,
    int total,
  ) async {
    int cursor = start;
    final String trackKey = track.isAudio ? 'audio' : 'video';
    while (cursor <= end) {
      job.check();
      final int windowEnd = math.min(end, cursor + defaultWindowBytes - 1);
      await _downloader.downloadRange(
        ByteRange(cursor, windowEnd),
        track.resolver,
        signal: job.signal,
        // Audio keeps two pieces in flight so one round trip overlaps the
        // other transfer; video uses the remaining shared budget.
        maxConcurrency: track.isAudio ? 2 : null,
        audio: track.isAudio,
        trackKey: trackKey,
        onOrderedChunk:
            (Uint8List bytes, ByteRange piece, int? fileTotal) async {
              job.check();
              if (fileTotal != null && fileTotal != total) {
                throw const RipperHttpException('resource changed');
              }
              await connection.add(bytes);
            },
      );
      cursor = windowEnd + 1;
    }
  }

  /// `parseRangeHeader` plus the two player forms the JS helper does not take:
  /// open-ended (`bytes=100-`) and suffix (`bytes=-100`).
  static (int, int) _parseRange(String? value, int total) {
    if (value == null) return (0, total - 1);
    final RegExpMatch? match = RegExp(
      r'^bytes=(\d*)-(\d*)$',
    ).firstMatch(value.trim());
    if (match == null) throw const FormatException('invalid range');
    final String rawStart = match.group(1)!;
    final String rawEnd = match.group(2)!;
    if (rawStart.isEmpty && rawEnd.isEmpty) {
      throw const FormatException('invalid range');
    }
    final int start;
    final int end;
    if (rawStart.isEmpty) {
      final int suffix = int.parse(rawEnd);
      if (suffix <= 0) throw const FormatException('invalid suffix');
      start = math.max(0, total - suffix);
      end = total - 1;
    } else {
      start = int.parse(rawStart);
      end = rawEnd.isEmpty ? total - 1 : math.min(int.parse(rawEnd), total - 1);
    }
    if (start >= total || end < start) {
      throw const FormatException('unsatisfiable range');
    }
    return (start, end);
  }
}

/// One player request being served; cancellation is per request.
class ProxyJob {
  final RipperAbortSignal signal = RipperAbortSignal();
  bool cancelled = false;

  void check() {
    if (cancelled) throw const RipperAbortException();
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    signal.abort();
  }

  /// Races an I/O operation against cancellation, like `job.race(...)`.
  Future<T> race<T>(Future<T> operation) {
    final Completer<T> completer = Completer<T>();
    void onAbort() {
      if (!completer.isCompleted) {
        completer.completeError(const RipperAbortException());
      }
    }

    signal.addListener(onAbort);
    operation.then(
      (T value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
    );
    if (signal.isAborted) onAbort();
    return completer.future.whenComplete(() => signal.removeListener(onAbort));
  }
}

/// A response channel that survives the player closing its side.
abstract class _Connection {
  static Future<_Connection> detach(HttpRequest request, ProxyJob job) async {
    try {
      final Socket socket = await request.response.detachSocket(
        writeHeaders: false,
      );
      final _SocketConnection connection = _SocketConnection(socket, job);
      socket.listen(
        (List<int> _) {},
        onDone: job.cancel,
        onError: (Object _) => job.cancel(),
        cancelOnError: true,
      );
      unawaited(socket.done.then((_) {}, onError: (Object _) => job.cancel()));
      return connection;
    } on Object {
      // `detachSocket` is not available on every platform; fall back to the
      // normal response object (backpressure and close still work, only the
      // early disconnect detection is weaker).
      return _ResponseConnection(request.response, job);
    }
  }

  bool get headersSent;

  void writeHead(int status, int length, {String? contentRange});

  Future<void> add(List<int> bytes);

  Future<void> close();

  Future<void> destroy();
}

class _SocketConnection implements _Connection {
  _SocketConnection(this._socket, this._job);

  final Socket _socket;
  final ProxyJob _job;
  bool _headersSent = false;

  @override
  bool get headersSent => _headersSent;

  @override
  void writeHead(int status, int length, {String? contentRange}) {
    final String reason = switch (status) {
      HttpStatus.ok => 'OK',
      HttpStatus.partialContent => 'Partial Content',
      HttpStatus.requestedRangeNotSatisfiable => 'Range Not Satisfiable',
      HttpStatus.badGateway => 'Bad Gateway',
      _ => 'Error',
    };
    final String head =
        'HTTP/1.1 $status $reason\r\n'
        'Content-Type: application/octet-stream\r\n'
        'Accept-Ranges: bytes\r\n'
        'Content-Length: $length\r\n'
        '${contentRange == null ? '' : 'Content-Range: $contentRange\r\n'}'
        'Connection: close\r\n'
        '\r\n';
    _socket.add(ascii.encode(head));
    _headersSent = true;
  }

  @override
  Future<void> add(List<int> bytes) async {
    if (_job.cancelled) throw const RipperAbortException();
    _socket.add(bytes);
    await _job.race(_socket.flush());
  }

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } on Object {
      // The player may have closed first; that is not an error for the proxy.
    }
  }

  @override
  Future<void> destroy() async {
    try {
      _socket.destroy();
    } on Object {
      // Already closed.
    }
  }
}

class _ResponseConnection implements _Connection {
  _ResponseConnection(this._response, this._job);

  final HttpResponse _response;
  final ProxyJob _job;
  bool _headersSent = false;

  @override
  bool get headersSent => _headersSent;

  @override
  void writeHead(int status, int length, {String? contentRange}) {
    _response
      ..statusCode = status
      ..headers.contentType = ContentType.binary
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.contentLength = length;
    if (contentRange != null) {
      _response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    _headersSent = true;
  }

  @override
  Future<void> add(List<int> bytes) async {
    if (_job.cancelled) throw const RipperAbortException();
    _response.add(bytes);
    await _job.race(_response.flush());
  }

  @override
  Future<void> close() async {
    try {
      await _response.close();
    } on Object {
      // Client already gone.
    }
  }

  @override
  Future<void> destroy() async {
    try {
      await _response.close();
    } on Object {
      // Client already gone.
    }
  }
}
