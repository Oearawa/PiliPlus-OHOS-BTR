// Decides whether the running build should be told about a newer release.
//
// Pure decision logic plus a small amount of state (last check, skipped
// version); the network lives in [GithubReleaseClient]. Everything is injected
// so the rules can be tested without GitHub, and so the future server-push
// design can reuse the same selection step.

import 'package:PiliPlus/core/update/app_version.dart';
import 'package:PiliPlus/core/update/github_release_client.dart';
import 'package:PiliPlus/core/update/github_update_config.dart';
import 'package:PiliPlus/core/update/release_info.dart';

/// Outcome of one check.
enum UpdateStatus {
  /// A newer release with an installable HAP exists.
  available,

  /// Already on the newest release of this channel.
  upToDate,

  /// A newer release exists but has no HAP attached.
  missingAsset,

  /// The network or the API failed.
  failed,

  /// A cached result is still fresh; no request was made.
  cached,
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    this.release,
    this.checkedAt,
    this.error,
    this.currentVersion,
  });

  final UpdateStatus status;
  final ReleaseInfo? release;
  final DateTime? checkedAt;
  final UpdateCheckException? error;
  final AppVersion? currentVersion;

  bool get hasUpdate => status == UpdateStatus.available && release != null;

  /// Message suitable for a toast when the user asked explicitly.
  String get message => switch (status) {
    UpdateStatus.available => '发现新版本 ${release?.version?.display ?? ''}',
    UpdateStatus.upToDate => '已是最新版本',
    UpdateStatus.missingAsset => '发现新版本 ${release?.version?.display ?? ''}，但该版本暂未提供安装包',
    UpdateStatus.failed => error?.message ?? '检查更新失败',
    UpdateStatus.cached => '已是最新版本',
  };
}

/// Persistence the checker needs. Implemented over app storage in production
/// and in memory in tests.
abstract class UpdateStateStore {
  DateTime? readLastCheckedAt();

  Future<void> writeLastCheckedAt(DateTime value);

  String? readSkippedVersion();

  Future<void> writeSkippedVersion(String? value);

  UpdateChannel readChannel();

  Future<void> writeChannel(UpdateChannel channel);
}

/// In-memory store, used by tests and as a safe default before storage loads.
class MemoryUpdateStateStore implements UpdateStateStore {
  MemoryUpdateStateStore({
    this.lastCheckedAt,
    this.skippedVersion,
    this.channel = UpdateChannel.beta,
  });

  DateTime? lastCheckedAt;
  String? skippedVersion;
  UpdateChannel channel;

  @override
  DateTime? readLastCheckedAt() => lastCheckedAt;

  @override
  Future<void> writeLastCheckedAt(DateTime value) async => lastCheckedAt = value;

  @override
  String? readSkippedVersion() => skippedVersion;

  @override
  Future<void> writeSkippedVersion(String? value) async =>
      skippedVersion = value;

  @override
  UpdateChannel readChannel() => channel;

  @override
  Future<void> writeChannel(UpdateChannel value) async => channel = value;
}

class UpdateChecker {
  UpdateChecker({
    required GithubReleaseClient client,
    required UpdateStateStore store,
    required AppVersion currentVersion,
    DateTime Function()? clock,
    Duration cacheTtl = GithubUpdateConfig.cacheTtl,
  }) : _client = client,
       _store = store,
       _current = currentVersion,
       _clock = clock ?? DateTime.now,
       _cacheTtl = cacheTtl;

  final GithubReleaseClient _client;
  final UpdateStateStore _store;
  final AppVersion _current;
  final DateTime Function() _clock;
  final Duration _cacheTtl;

  UpdateCheckResult? _last;

  AppVersion get currentVersion => _current;

  UpdateChannel get channel => _store.readChannel();

  /// True when an automatic check would hit the cache.
  bool get isFresh {
    final DateTime? last = _store.readLastCheckedAt();
    if (last == null) return false;
    return _clock().difference(last) < _cacheTtl;
  }

  /// Runs a check.
  ///
  /// [force] is used by the "check now" button: it bypasses both the cache and
  /// the "skipped this version" marker. Automatic checks (startup, resume to
  /// foreground) must not pass it.
  Future<UpdateCheckResult> check({bool force = false}) async {
    if (!force && isFresh && _last != null) {
      return UpdateCheckResult(
        status: UpdateStatus.cached,
        release: _last!.release,
        checkedAt: _store.readLastCheckedAt(),
        currentVersion: _current,
      );
    }
    final String? skipped = _store.readSkippedVersion();
    try {
      final List<ReleaseInfo> releases = await _client.fetchReleases();
      final DateTime now = _clock();
      await _store.writeLastCheckedAt(now);
      final ReleaseInfo? candidate = selectCandidate(
        releases: releases,
        current: _current,
      );
      if (candidate == null) {
        _last = UpdateCheckResult(
          status: UpdateStatus.upToDate,
          checkedAt: now,
          currentVersion: _current,
        );
        return _last!;
      }
      final bool suppressed =
          !force &&
          skipped != null &&
          candidate.tagName == skipped &&
          candidate.version != null;
      final bool installable = candidate.hasInstallableHap;
      final UpdateCheckResult result = UpdateCheckResult(
        status: !installable
            ? UpdateStatus.missingAsset
            : (suppressed ? UpdateStatus.upToDate : UpdateStatus.available),
        release: candidate,
        checkedAt: now,
        currentVersion: _current,
      );
      _last = result;
      return result;
    } on UpdateCheckException catch (error) {
      final UpdateCheckResult result = UpdateCheckResult(
        status: UpdateStatus.failed,
        checkedAt: _clock(),
        error: error,
        currentVersion: _current,
      );
      _last = result;
      return result;
    }
  }

  /// Marks the given release as "not now", so an automatic check stays quiet
  /// until a newer version appears or the user checks manually.
  Future<void> skip(ReleaseInfo release) async {
    await _store.writeSkippedVersion(release.tagName);
    // The cached result still says "available"; drop it so the next automatic
    // check re-evaluates and stays quiet instead of re-prompting from cache.
    _last = null;
  }

  /// Clears the skip marker, e.g. when the user opens "check now".
  Future<void> clearSkip() => _store.writeSkippedVersion(null);

  Future<void> setChannel(UpdateChannel value) => _store.writeChannel(value);

  /// Picks the release this build should be offered, or null when there is
  /// nothing newer.
  ///
  /// Rules:
  ///  * drafts never reach this point (the client drops them);
  ///  * **pre-releases are never offered**: this project retired its beta
  ///    channel, so only full releases are updates. An older beta build still
  ///    upgrades to the first full release because the version comparison is
  ///    numeric, not lexical;
  ///  * the newest version wins;
  ///  * a newer release without a HAP still blocks an older one — offering a
  ///    downgrade to an older file would be misleading. The caller reports
  ///    [UpdateStatus.missingAsset] in that case.
  static ReleaseInfo? selectCandidate({
    required List<ReleaseInfo> releases,
    required AppVersion current,
  }) {
    ReleaseInfo? best;
    for (final ReleaseInfo release in releases) {
      final AppVersion? version = release.version;
      if (version == null) continue;
      if (release.draft || release.prerelease) continue;
      if (!AppVersion.isNewer(version, current)) continue;
      if (best == null || AppVersion.isNewer(version, best.version!)) {
        best = release;
      }
    }
    return best;
  }

  /// Full releases newer than [current], newest first. Exposed for the about
  /// page history list.
  static List<ReleaseInfo> newerReleases({
    required List<ReleaseInfo> releases,
    required AppVersion current,
  }) {
    final List<ReleaseInfo> result = releases.where((ReleaseInfo release) {
      final AppVersion? version = release.version;
      if (version == null || release.draft || release.prerelease) return false;
      return version > current;
    }).toList()
      ..sort(
        (ReleaseInfo a, ReleaseInfo b) => b.version!.compareTo(a.version!),
      );
    return result;
  }
}
