// Thread-ripper preferences for the native player stage.
//
// This file is the Hive-facing half: it reads and writes the values and runs
// the one-time migration. The normalization rules themselves live in
// `settings_model.dart` so they can be tested without Hive.

import 'dart:async';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:PiliPlus/services/thread_ripper/settings_model.dart';
import 'package:PiliPlus/utils/storage.dart';

/// Read/write the thread-ripper settings.
abstract final class RipperPrefs {
  static const String enabledKey = kRipperEnabledKey;
  static const String concurrencyKey = kRipperConcurrencyKey;
  static const String customHostsKey = kRipperCustomHostsKey;
  static const String modeKey = kRipperModeKey;
  static const String autoConcurrencyKey = kRipperAutoConcurrencyKey;
  static const String episodeEnabledKey = kRipperEpisodeEnabledKey;

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
    return asRipperModeIndex(GStorage.setting.get(modeKey, defaultValue: 1));
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
    return asRipperBool(
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
    return asRipperRung(GStorage.setting.get(concurrencyKey, defaultValue: 8));
  }

  static set concurrency(int value) {
    unawaited(
      GStorage.setting.put(concurrencyKey, asRipperRung(value)),
    );
  }

  /// Automatic controller. When true, [concurrency] is only the manual-mode
  /// budget; the automatic controller may climb to 64.
  static bool get autoConcurrency {
    ensureMigrated();
    return asRipperBool(
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
    return asRipperBool(
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
    return asRipperHosts(
      GStorage.setting.get(customHostsKey, defaultValue: const <String>[]),
    );
  }

  static set customHosts(List<String> value) {
    unawaited(
      GStorage.setting.put(customHostsKey, asRipperHosts(value)),
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
