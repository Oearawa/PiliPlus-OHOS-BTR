// Settings migration tests.
//
// Older builds stored some BTR values in a different shape (booleans as 0/1,
// the CDN mode as a label, a thread count that is not on the ladder). These
// tests pin the normalization rules without touching Hive.

import 'package:PiliPlus/services/thread_ripper/prefs.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('defaults', () {
    test('an empty box uses the documented defaults', () {
      final RipperStoredSettings settings = normalizeStoredSettings(
        <String, Object?>{},
      );
      expect(settings.enabled, isFalse);
      expect(settings.autoConcurrency, isTrue);
      expect(settings.concurrency, 8);
      expect(settings.modeIndex, 1);
      expect(settings.customHosts, isEmpty);
      expect(settings.episodeEnabled, isTrue);
      expect(settings.changed, isFalse);
    });
  });

  group('booleans', () {
    test('accepts bool, 0/1 and the usual strings', () {
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.enabledKey: 1,
        }).enabled,
        isTrue,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.enabledKey: 'true',
        }).enabled,
        isTrue,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.autoConcurrencyKey: 0,
        }).autoConcurrency,
        isFalse,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.episodeEnabledKey: 'off',
        }).episodeEnabled,
        isFalse,
      );
      // An unreadable value falls back to the documented default.
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.autoConcurrencyKey: 'maybe',
        }).autoConcurrency,
        isTrue,
      );
    });

    test('a rewritten value reports a change', () {
      final RipperStoredSettings settings = normalizeStoredSettings(
        <String, Object?>{RipperPrefs.enabledKey: 1},
      );
      expect(settings.enabled, isTrue);
      expect(settings.changed, isTrue);
    });
  });

  group('concurrency', () {
    test('keeps a value that is already on the ladder', () {
      for (final int value in RipperSettings.allowedConcurrency) {
        expect(
          normalizeStoredSettings(<String, Object?>{
            RipperPrefs.concurrencyKey: value,
          }).concurrency,
          value,
        );
      }
    });

    test('snaps a legacy value to the nearest rung', () {
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.concurrencyKey: 10,
        }).concurrency,
        8,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.concurrencyKey: 14,
        }).concurrency,
        12,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.concurrencyKey: 44,
        }).concurrency,
        48,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.concurrencyKey: 1000,
        }).concurrency,
        64,
      );
      // A tie rounds down so a legacy value never doubles the connections.
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.concurrencyKey: 6,
        }).concurrency,
        4,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.concurrencyKey: '16',
        }).concurrency,
        16,
      );
    });
  });

  group('CDN mode and hosts', () {
    test('accepts numeric and labelled modes', () {
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.modeKey: 0,
        }).modeIndex,
        0,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.modeKey: 'mainland',
        }).modeIndex,
        0,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.modeKey: '海外',
        }).modeIndex,
        1,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.modeKey: '自定义',
        }).modeIndex,
        2,
      );
      expect(
        normalizeStoredSettings(<String, Object?>{
          RipperPrefs.modeKey: 9,
        }).modeIndex,
        1,
      );
    });

    test('keeps only whitelisted hosts, deduplicated', () {
      final RipperStoredSettings settings = normalizeStoredSettings(
        <String, Object?>{
          RipperPrefs.customHostsKey: <Object?>[
            'upos-sz-mirrorhw.bilivideo.com',
            'https://upos-sz-mirrorhw.bilivideo.com',
            'evil.example.com',
            'upos-sz-mirrorali.bilivideo.com',
            42,
          ],
        },
      );
      expect(settings.customHosts, <String>[
        'upos-sz-mirrorhw.bilivideo.com',
        'upos-sz-mirrorali.bilivideo.com',
      ]);
      expect(settings.changed, isTrue);
    });

    test('a non-list host value becomes an empty list', () {
      final RipperStoredSettings settings = normalizeStoredSettings(
        <String, Object?>{RipperPrefs.customHostsKey: 'upos-sz-mirrorhw'},
      );
      expect(settings.customHosts, isEmpty);
      expect(settings.changed, isTrue);
    });
  });
}
