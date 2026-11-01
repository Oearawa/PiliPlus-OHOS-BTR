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
// 0/1, a mode as a string, a thread count that is not on the ladder). The
// normalization lives in `settings_model.dart` (no Hive import, so it is unit
// tested on the host); `RipperPrefs.ensureMigrated` writes the normalized
// values back once per launch so the stored data and the UI agree.

import 'package:PiliPlus/services/thread_ripper/range_core.dart';

/// Storage keys. They live here instead of `lib/utils/storage_key.dart` on
/// purpose: that file is touched by upstream every few releases, and keeping
/// the accelerator keys separate keeps the merge surface small.
const String kRipperEnabledKey = 'threadRipperEnabled';
const String kRipperConcurrencyKey = 'threadRipperConcurrency';
const String kRipperCustomHostsKey = 'threadRipperCustomHosts';
const String kRipperModeKey = 'threadRipperMode';
const String kRipperAutoConcurrencyKey = 'threadRipperAutoConcurrency';
const String kRipperEpisodeEnabledKey = 'threadRipperEpisodeEnabled';

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

bool asRipperBool(Object? value, {required bool fallback}) {
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
int asRipperRung(Object? value) {
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
int asRipperModeIndex(Object? value) {
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

List<String> asRipperHosts(Object? value) {
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
  final Object? rawEnabled = raw[kRipperEnabledKey];
  final Object? rawAuto = raw[kRipperAutoConcurrencyKey];
  final Object? rawConcurrency = raw[kRipperConcurrencyKey];
  final Object? rawMode = raw[kRipperModeKey];
  final Object? rawHosts = raw[kRipperCustomHostsKey];
  final Object? rawEpisode = raw[kRipperEpisodeEnabledKey];

  final bool enabled = asRipperBool(rawEnabled, fallback: false);
  final bool auto = asRipperBool(rawAuto, fallback: true);
  final int concurrency = asRipperRung(rawConcurrency);
  final int modeIndex = asRipperModeIndex(rawMode);
  final List<String> hosts = asRipperHosts(rawHosts);
  final bool episode = asRipperBool(rawEpisode, fallback: true);

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
