// Thread-ripper preferences for the native player stage.
//
// The keys live here instead of `lib/utils/storage_key.dart` on purpose: that
// file is touched by upstream every few releases, and keeping the accelerator
// keys separate keeps the merge surface small. Values are stored in the same
// Hive `setting` box the rest of the app uses.
//
// `enabled` is deliberately false by default: the proxy is opt-in until the
// devices that matter have been verified.
//
// Older builds wrote some of these keys with a different shape (a boolean as
// 0/1, a mode as a string, a thread count that is not on the ladder). Every
// read therefore goes through [normalizeStoredSettings], and
// [RipperPrefs.ensureMigrated] writes the normalized values back once per
// launch so the stored data and the UI agree.

import 'dart:async';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:PiliPlus/utils/storage.dart';

/// Settings after normalization, independent of Hive so it can be tested.
class RipperStoredSettings {
  const RipperStoredSettings({
    required this.enabled,
    required this.autoConcurrency,
    required this.concurrency,
    required this.modeIndex,
    required this.customHosts,
    required this.episodeEnabled,
    required this.changed,
  });

  final bool enabled;
  final bool autoConcurrency;

  /// One of [RipperSettings.allowedConcurrency].
  final int concurrency;

  /// 0 = mainland, 1 = overseas, 2 = custom.
  final int modeIndex;
  final List<String> customHosts;
  final bool episodeEnabled;

  /// True when at least one value had to be rewritten.
  final bool changed;
}

bool _asBool(Object? value, {required bool fallback}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'on':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'off':
      case 'no':
        return false;
    }
  }
  return fallback;
}

/// The nearest rung on the ladder; a tie prefers the lower rung so a legacy
/// value never silently doubles the connection count.
int _asRung(Object? value) {
  final int? requested = value is num
      ? value.toInt()
      : value is String
      ? int.tryParse(value.trim())
      : null;
  if (requested == null) return 8;
  if (RipperSettings.allowedConcurrency.contains(requested)) return requested;
  int best = RipperSettings.allowedConcurrency.first;
  int bestDistance = (requested - best).abs();
  for (final int candidate in RipperSettings.allowedConcurrency) {
    final int distance = (requested - candidate).abs();
    if (distance < bestDistance) {
      best = candidate;
      bestDistance = distance;
    }
  }
  return best;
}

/// Accepts the integer form and the labels older builds may have stored.
int _asModeIndex(Object? value) {
  if (value is num) {
    final int index = value.toInt();
    return index >= 0 && index <= 2 ? index : 1;
  }
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case '0':
      case 'mainland':
      case 'cn':
      case '大陆':
      case '大陆节点':
        return 0;
      case '1':
      case 'overseas':
      case 'global':
      case '海外':
      case '海外节点':
        return 1;
      case '2':
      case 'custom':
      case '自定义':
      case '自定义节点':
        return 2;
    }
  }
  return 1;
}

List<String> _asHosts(Object? value) {
  if (value is! List) return const <String>[];
  final List<String> hosts = <String>[];
  for (final Object? item in value) {
    if (item is! String) continue;
    final String? host = normalizeCdnHost(item);
    if (host != null && !hosts.contains(host)) hosts.add(host);
  }
  return List<String>.unmodifiable(hosts);
}

/// Normalizes whatever is stored under the BTR keys.
///
/// Missing keys keep the documented defaults: BTR off, auto concurrency on,
/// 8 threads, overseas nodes, episodes enabled.
RipperStoredSettings normalizeStoredSettings(Map<String, Object?> raw) {
  final Object? rawEnabled = raw[RipperPrefs.enabledKey];
  final Object? rawAuto = raw[RipperPrefs.autoConcurrencyKey];
  final Object? rawConcurrency = raw[RipperPrefs.concurrencyKey];
  final Object? rawMode = raw[RipperPrefs.modeKey];
  final Object? rawHosts = raw[RipperPrefs.customHostsKey];
  final Object? rawEpisode = raw[RipperPrefs.episodeEnabledKey];

  final bool enabled = _asBool(rawEnabled, fallback: false);
  final bool auto = _asBool(rawAuto, fallback: true);
  final int concurrency = _asRung(rawConcurrency);
  final int modeIndex = _asModeIndex(rawMode);
  final List<String> hosts = _asHosts(rawHosts);
  final bool episode = _asBool(rawEpisode, fallback: true);

  // Only a stored value can be wrong: a missing key keeps the default without
  // counting as a migration.
  bool differs(Object? raw, Object? normalized) =>
      raw != null && raw != normalized;
  final bool changed =
      differs(rawEnabled, enabled) ||
      differs(rawAuto, auto) ||
      differs(rawConcurrency, concurrency) ||
      differs(rawMode, modeIndex) ||
      (rawHosts != null &&
          (rawHosts is! List || rawHosts.length != hosts.length)) ||
      differs(rawEpisode, episode);

  return RipperStoredSettings(
    enabled: enabled,
    autoConcurrency: auto,
    concurrency: concurrency,
    modeIndex: modeIndex,
    customHosts: hosts,
    episodeEnabled: episode,
    changed: changed,
  );
}

/// Read/write the thread-ripper settings.
abstract final class RipperPrefs {
  static const String enabledKey = 'threadRipperEnabled';
  static const String concurrencyKey = 'threadRipperConcurrency';
  static const String customHostsKey = 'threadRipperCustomHosts';
  static const String modeKey = 'threadRipperMode';
  static const String autoConcurrencyKey = 'threadRipperAutoConcurrency';
  static const String episodeEnabledKey = 'threadRipperEpisodeEnabled';

  static bool _migrated = false;

  /// Normalizes the stored values once per launch.
  ///
  /// Every getter funnels through this, so a value written by an older build
  /// is corrected before it reaches the downloader.
  static void ensureMigrated() {
    if (_migrated) return;
    _migrated = true;
    final RipperStoredSettings current = normalizeStoredSettings(
      <String, Object?>{
        enabledKey: GStorage.setting.get(enabledKey),
        autoConcurrencyKey: GStorage.setting.get(autoConcurrencyKey),
        concurrencyKey: GStorage.setting.get(concurrencyKey),
        modeKey: GStorage.setting.get(modeKey),
        customHostsKey: GStorage.setting.get(customHostsKey),
        episodeEnabledKey: GStorage.setting.get(episodeEnabledKey),
      },
    );
    if (!current.changed) return;
    unawaited(GStorage.setting.put(concurrencyKey, current.concurrency));
    unawaited(GStorage.setting.put(modeKey, current.modeIndex));
    unawaited(GStorage.setting.put(enabledKey, current.enabled));
    unawaited(
      GStorage.setting.put(autoConcurrencyKey, current.autoConcurrency),
    );
    unawaited(GStorage.setting.put(episodeEnabledKey, current.episodeEnabled));
    unawaited(GStorage.setting.put(customHostsKey, current.customHosts));
  }

  /// 0 = mainland, 1 = overseas, 2 = custom.
  ///
  /// Defaults to overseas: the users this fork targets watch from outside
  /// mainland China, where the overseas CDN edge is the better first hop.
  static int get modeIndex {
    ensureMigrated();
    return _asModeIndex(GStorage.setting.get(modeKey, defaultValue: 1));
  }

  static set modeIndex(int value) {
    unawaited(GStorage.setting.put(modeKey, value.clamp(0, 2)));
  }

  /// Whether the local range proxy may take over media requests.
  ///
  /// Defaults to false: with the switch off the player keeps using the direct
  /// URL and nothing in this directory runs.
  static bool get enabled {
    ensureMigrated();
    return _asBool(
      GStorage.setting.get(enabledKey, defaultValue: false),
      fallback: false,
    );
  }

  static set enabled(bool value) {
    unawaited(GStorage.setting.put(enabledKey, value));
  }

  /// Thread budget, one of [RipperSettings.allowedConcurrency].
  static int get concurrency {
    ensureMigrated();
    return _asRung(GStorage.setting.get(concurrencyKey, defaultValue: 8));
  }

  static set concurrency(int value) {
    unawaited(
      GStorage.setting.put(concurrencyKey, _asRung(value)),
    );
  }

  /// Automatic controller. When true, [concurrency] is only the manual-mode
  /// budget; the automatic controller may climb to 64.
  static bool get autoConcurrency {
    ensureMigrated();
    return _asBool(
      GStorage.setting.get(autoConcurrencyKey, defaultValue: true),
      fallback: true,
    );
  }

  static set autoConcurrency(bool value) {
    unawaited(GStorage.setting.put(autoConcurrencyKey, value));
  }

  /// Episode (PGC) acceleration, like upstream's `episodeEnabled`.
  /// DRM and preview-only episodes are still excluded in the video controller.
  static bool get episodeEnabled {
    ensureMigrated();
    return _asBool(
      GStorage.setting.get(episodeEnabledKey, defaultValue: true),
      fallback: true,
    );
  }

  static set episodeEnabled(bool value) {
    unawaited(GStorage.setting.put(episodeEnabledKey, value));
  }

  /// Extra CDN hosts picked by the user; empty means mainland/overseas mode.
  static List<String> get customHosts {
    ensureMigrated();
    return _asHosts(
      GStorage.setting.get(customHostsKey, defaultValue: const <String>[]),
    );
  }

  static set customHosts(List<String> value) {
    unawaited(
      GStorage.setting.put(customHostsKey, _asHosts(value)),
    );
  }

  /// Settings handed to the download engine.
  static RipperSettings get currentSettings =>
      RipperSettings(enabled: enabled, concurrency: concurrency);

  /// Resolver mode. Custom hosts are only used when the mode is custom and at
  /// least one host was saved; otherwise the overseas default applies.
  static CdnMode get mode {
    final int index = modeIndex;
    if (index == 0) return CdnMode.mainland;
    if (index == 2 && customHosts.isNotEmpty) return CdnMode.custom;
    return CdnMode.overseas;
  }

  static set mode(CdnMode value) {
    modeIndex = switch (value) {
      CdnMode.mainland => 0,
      CdnMode.overseas => 1,
      CdnMode.custom => 2,
    };
  }
}
