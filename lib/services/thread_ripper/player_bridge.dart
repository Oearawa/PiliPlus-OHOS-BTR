// Player-facing lifecycle for the local range proxy.
//
// This is the only file the player controller talks to. It owns one
// `RipperRangeProxy` session at a time, registers the video and (optional)
// audio tracks, and exposes the loopback URLs the player hands to mpv. It
// never imports Flutter or any page code, so it can be tested on the host.
//
// The switch itself lives in `prefs.dart`; callers check `RipperPrefs.enabled`
// before calling [open]. With no session active the getters stay empty and the
// player keeps its direct URLs.

import 'package:PiliPlus/services/thread_ripper/auto_concurrency.dart';
import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/idm_downloader.dart';
import 'package:PiliPlus/services/thread_ripper/media_demand.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:PiliPlus/services/thread_ripper/range_proxy.dart';

/// Owns the download session used by the player.
///
/// A single instance is enough because the app has one media player; every
/// new source closes the previous session first.
class RipperPlayerBridge {
  RipperPlayerBridge._();

  static final RipperPlayerBridge instance = RipperPlayerBridge._();

  /// Used when the caller does not pass the app's current browser UA.
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  RipperRangeProxy? _proxy;
  AutoConcurrency? _autoConcurrency;
  String _videoUrl = '';
  String _audioUrl = '';

  /// Generation guard: an `open` that finishes after a newer `close`/`open`
  /// must not publish its URLs. It is also the session token used to reject
  /// late player samples from the previous source.
  int _generation = 0;

  int get sessionId => _generation;

  bool get isActive => _proxy != null;

  bool get hasAudio => _audioUrl.isNotEmpty;

  String get proxiedVideoUrl => _videoUrl;

  String get proxiedAudioUrl => _audioUrl;

  /// Controller active for the current session, or null.
  AutoConcurrency? get autoConcurrency => _autoConcurrency;

  /// Starts a session and registers the given tracks.
  ///
  /// Returns false when the proxy could not be started (the caller must fall
  /// back to the direct URL) or when [videoUrls] contains no http(s) URL.
  Future<bool> open({
    required List<Uri> videoUrls,
    required List<Uri> audioUrls,
    RipperSettings? settings,
    CdnMode mode = CdnMode.mainland,
    List<String> customHosts = const <String>[],
    String userAgent = defaultUserAgent,
    RipperMediaDemand? media,
    bool auto = true,
  }) async {
    final int generation = ++_generation;
    await _closeProxy();

    final List<Uri> videos = _sanitize(videoUrls);
    if (videos.isEmpty) return false;
    final List<Uri> audios = _sanitize(audioUrls);
    final RipperSettings effectiveSettings = settings ?? const RipperSettings();

    // In auto mode the settings.concurrency is a manual-mode budget, not an
    // auto cap. The upstream controller is allowed to climb to 64 regardless
    // of the manual 4/8/16/32/64 value. The larger proxy budget also splits
    // the 4 MiB range window into enough queued pieces that a later level-up
    // can immediately use the new slots.
    final RipperSettings proxySettings = auto
        ? effectiveSettings.copyWith(
            concurrency: AutoConcurrency.maxSupportedThreads,
          )
        : effectiveSettings;

    final RipperRangeProxy proxy = RipperRangeProxy(
      settings: proxySettings,
      mode: mode,
      customHosts: customHosts,
      userAgent: userAgent,
    );
    try {
      await proxy.start();
      if (generation != _generation) {
        await proxy.close();
        return false;
      }
      AutoConcurrency? autoConcurrency;
      if (auto) {
        autoConcurrency = AutoConcurrency(
          semaphore: proxy.semaphore,
          maxConcurrency: AutoConcurrency.maxSupportedThreads,
        );
        autoConcurrency.startSession(
          demand: media,
          initialThreads: media?.suggestedInitialThreads() ?? 8,
          startup: true,
        );
        final AutoConcurrency controller = autoConcurrency;
        proxy
          ..setDeliveryListener(
            (int bytes) => controller.delivered(bytes, session: generation),
          )
          ..setActivityListener(
            (int bytes) => controller.activity(session: generation),
          )
          ..setHttpStatusListener((int status) {
            if (status == 412 || status == 429) {
              controller.pushback(status, session: generation);
            } else if (status == -1) {
              // No first byte at all: the current thread count is not being
              // served, back off at once instead of waiting for three strikes.
              controller.firstByteTimeout(session: generation);
            } else if (status == -2) {
              // Bytes stopped mid-body: a slow node, not necessarily too many
              // connections.
              controller.slow(session: generation, timeout: true);
            } else if (status >= 500) {
              controller.slow(session: generation);
            }
            // 403/404/416/other 4xx stay in the existing URL/error path.
          });
      }
      final Uri video = proxy.register(videos);
      final Uri? audio = audios.isEmpty
          ? null
          : proxy.register(audios, isAudio: true);
      _proxy = proxy;
      _autoConcurrency = autoConcurrency;
      _videoUrl = video.toString();
      _audioUrl = audio?.toString() ?? '';
      return true;
    } on Object {
      await proxy.close();
      return false;
    }
  }

  /// Buffer state from the player, forwarded to the auto-concurrency
  /// controller. No-op while no session is active.
  void onBuffer(
    double aheadSeconds,
    bool playing, {
    bool cacheFull = false,
    bool waiting = false,
    int? session,
  }) {
    if (session != null && session != _generation) return;
    _autoConcurrency?.buffer(
      aheadSeconds,
      playing,
      cacheFull: cacheFull,
      waiting: waiting,
      session: session,
    );
  }

  /// Playback stalled; the controller tries one more rung, not an
  /// unconditional jump to 64.
  void onStall({int? session}) {
    if (session != null && session != _generation) return;
    _autoConcurrency?.stall(session: session);
  }

  /// Seek/new source boundary: restart startup probing without replacing the
  /// proxy session.
  void onSeek({int? session}) {
    if (session != null && session != _generation) return;
    _autoConcurrency?.seekStarted(session: session);
  }

  /// Stops the session; safe to call when none is running.
  Future<void> close() async {
    _generation += 1;
    await _closeProxy();
  }

  Future<void> _closeProxy() async {
    final RipperRangeProxy? proxy = _proxy;
    final AutoConcurrency? auto = _autoConcurrency;
    _proxy = null;
    _autoConcurrency = null;
    _videoUrl = '';
    _audioUrl = '';
    auto?.close();
    proxy
      ?..setDeliveryListener(null)
      ..setActivityListener(null)
      ..setHttpStatusListener(null);
    try {
      await proxy?.close();
    } on Object {
      // Tearing the session down must never break playback or navigation.
    }
  }

  /// Snapshot for the settings page. Real measurements only: when no session
  /// is running the caller gets null instead of invented numbers, and a manual
  /// session reports `null` throughput because it has no controller window.
  Map<String, Object?>? diagnostics() {
    final RipperRangeProxy? proxy = _proxy;
    if (proxy == null) return null;
    final AutoConcurrency? auto = _autoConcurrency;
    if (auto != null) {
      return <String, Object?>{
        ...auto.status(),
        'mode': 'auto',
        'tracks': proxy.trackCount,
        'port': proxy.port,
      };
    }
    final RipperSemaphore semaphore = proxy.semaphore;
    return <String, Object?>{
      'mode': 'manual',
      'state': 'manual',
      'session': _generation,
      'threads': semaphore.limit,
      'maxThreads': semaphore.limit,
      'active': semaphore.active,
      'limit': semaphore.limit,
      'queued': semaphore.queued,
      'goodputMbps': null,
      'reason': '手动模式：固定 ${semaphore.limit} 个连接',
      'events': const <String>[],
      'tracks': proxy.trackCount,
      'port': proxy.port,
    };
  }

  static List<Uri> _sanitize(Iterable<Uri> urls) {
    final List<Uri> result = <Uri>[];
    final Set<Uri> seen = <Uri>{};
    for (final Uri url in urls) {
      if (url.scheme != 'http' && url.scheme != 'https') continue;
      if (seen.add(url)) result.add(url);
    }
    return result;
  }
}
