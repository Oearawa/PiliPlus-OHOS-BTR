// App-wide update state: one checker, one place that decides when to look.
//
// Startup calls [UpdateService.maybeAutoCheck]; the about page calls
// [UpdateService.checkManually]. Both share the same cache, so opening the app
// never hammers the GitHub API and a manual check always sees fresh data.

import 'dart:async';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/core/update/app_version.dart';
import 'package:PiliPlus/core/update/github_release_client.dart';
import 'package:PiliPlus/core/update/github_update_config.dart';
import 'package:PiliPlus/core/update/update_checker.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/foundation.dart';

/// Hive-backed state. Missing keys fall back to the documented defaults.
class HiveUpdateStateStore implements UpdateStateStore {
  static const String _lastCheckKey = 'updateLastCheckAt';
  static const String _skippedKey = 'updateSkippedVersion';
  static const String _channelKey = 'updateChannel';

  @override
  DateTime? readLastCheckedAt() {
    final Object? raw = GStorage.setting.get(_lastCheckKey);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  @override
  Future<void> writeLastCheckedAt(DateTime value) => GStorage.setting.put(
    _lastCheckKey,
    value.millisecondsSinceEpoch,
  );

  @override
  String? readSkippedVersion() {
    final Object? raw = GStorage.setting.get(_skippedKey);
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  @override
  Future<void> writeSkippedVersion(String? value) async {
    if (value == null) {
      await GStorage.setting.delete(_skippedKey);
    } else {
      await GStorage.setting.put(_skippedKey, value);
    }
  }

  @override
  UpdateChannel readChannel() {
    final Object? raw = GStorage.setting.get(_channelKey);
    // The beta channel is retired: every build now tracks full releases.
    // The stored value is still read so an old install does not keep a stale
    // beta preference, but anything that is not "stable" is ignored.
    if (raw is int && raw == UpdateChannel.stable.index) {
      return UpdateChannel.stable;
    }
    return UpdateChannel.stable;
  }

  @override
  Future<void> writeChannel(UpdateChannel channel) =>
      GStorage.setting.put(_channelKey, channel.index);

  static AppVersion currentVersionOrDefault() =>
      AppVersion.tryParse(BuildConfig.versionName) ??
      const AppVersion(core: <int>[0, 0, 0], raw: '0.0.0');
}

abstract final class UpdateService {
  static const String autoCheckKey = 'updateAutoCheck';

  static final UpdateChecker _checker = UpdateChecker(
    client: GithubReleaseClient(),
    store: _store,
    currentVersion: currentVersion,
  );

  static final HiveUpdateStateStore _store = HiveUpdateStateStore();

  /// Version of the running build, parsed from the injected version name.
  static final AppVersion currentVersion =
      AppVersion.tryParse(BuildConfig.versionName) ??
      const AppVersion(core: <int>[0, 0, 0], raw: '0.0.0');

  /// The last version a prompt was shown for, so reopening the app does not
  /// nag about the same release.
  static String? _promptedTag;

  static UpdateChannel get channel => _checker.channel;

  static Future<void> setChannel(UpdateChannel value) => _checker.setChannel(value);

  static DateTime? get lastCheckedAt => _store.readLastCheckedAt();

  /// Shares the existing "auto update" switch (Settings → Other), so there is
  /// only one place that turns startup checks on or off.
  static bool get autoCheckEnabled {
    final Object? raw = GStorage.setting.get(
      SettingBoxKey.autoUpdate,
      defaultValue: true,
    );
    return raw is bool ? raw : true;
  }

  static Future<void> setAutoCheckEnabled(bool value) =>
      GStorage.setting.put(autoCheckKey, value);

  /// True when this release was already prompted and the user chose "later".
  static bool isSkipped(String tag) => _store.readSkippedVersion() == tag;

  static Future<void> skip(String tag) => _store.writeSkippedVersion(tag);

  static Future<void> clearSkip() => _checker.clearSkip();

  /// Called after the first frame and when the app returns to the foreground.
  ///
  /// Never throws and never blocks: the caller does not await a dialog.
  static Future<UpdateCheckResult?> maybeAutoCheck() async {
    if (!autoCheckEnabled) return null;
    if (_checker.isFresh) return null;
    try {
      final UpdateCheckResult result = await _checker.check();
      if (!result.hasUpdate) return result;
      if (_promptedTag == result.release!.tagName) return result;
      _promptedTag = result.release!.tagName;
      return result;
    } on Object catch (error) {
      if (kDebugMode) debugPrint('auto update check failed: $error');
      return null;
    }
  }

  /// The "check now" button: bypasses the cache and the skip marker.
  static Future<UpdateCheckResult> checkManually() async {
    await _checker.clearSkip();
    final UpdateCheckResult result = await _checker.check(force: true);
    if (result.hasUpdate) _promptedTag = result.release!.tagName;
    return result;
  }

  /// Remembers "later" for this tag.
  static Future<void> markSkipped(UpdateCheckResult result) async {
    final String? tag = result.release?.tagName;
    if (tag == null) return;
    await _store.writeSkippedVersion(tag);
  }

  /// Resets the in-process prompt memory, so the next manual check can prompt
  /// again even for the same version.
  static void resetPromptMemory() => _promptedTag = null;
}
