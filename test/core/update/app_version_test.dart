import 'package:PiliPlus/core/update/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

AppVersion v(String s) => AppVersion.tryParse(s)!;

void main() {
  group('parse', () {
    test('stable ohos tags with a four-part core', () {
      final AppVersion parsed = v('2.1.6.2-ohos-4');
      expect(parsed.core, <int>[2, 1, 6, 2]);
      expect(parsed.display, '2.1.6.2-ohos-4');
      expect(parsed.hasSuffix, isTrue);
    });

    test('legacy beta tag', () {
      final AppVersion parsed = v('0.3.0-beta.1');
      expect(parsed.core, <int>[0, 3, 0]);
      expect(parsed.display, '0.3.0-beta.1');
    });

    test('three-part and v-prefixed tags', () {
      expect(v('2.1.6').display, '2.1.6');
      expect(v('v2.1.6').display, '2.1.6');
      expect(v('V2.1.6').raw, '2.1.6');
    });

    test('build metadata is ignored, suffix kept', () {
      expect(v('2.1.6.2-ohos-4+6420').display, '2.1.6.2-ohos-4');
      expect(v('2.1.6+6420').display, '2.1.6');
    });

    test('garbage is rejected instead of throwing', () {
      expect(AppVersion.tryParse(null), isNull);
      expect(AppVersion.tryParse(''), isNull);
      expect(AppVersion.tryParse('release-4'), isNull);
      expect(AppVersion.tryParse('ohos-4'), isNull);
      expect(AppVersion.tryParse('-4'), isNull);
    });
  });

  group('ordering', () {
    test('numeric core, not lexicographic', () {
      expect(v('2.10.0') > v('2.9.0'), isTrue);
      expect(v('2.1.6.2-ohos-4') > v('2.1.6-ohos-4'), isTrue);
    });

    test('legacy beta is older than the stable release', () {
      expect(v('2.1.6.2-ohos-4') > v('0.3.0-beta.1'), isTrue);
      expect(v('0.3.0-beta.1') < v('2.1.6.2-ohos-4'), isTrue);
    });

    test('ohos build numbers compare numerically', () {
      expect(v('2.1.6.2-ohos-4.1') > v('2.1.6.2-ohos-4'), isTrue);
      expect(v('2.1.6.2-ohos-4.2') > v('2.1.6.2-ohos-4.1'), isTrue);
      expect(v('2.1.6.2-ohos-5') > v('2.1.6.2-ohos-4.2'), isTrue);
      // The case string comparison gets wrong:
      expect(v('2.1.6.2-ohos-10') > v('2.1.6.2-ohos-9'), isTrue);
    });

    test('a full release outranks a suffixed build of the same core', () {
      expect(v('2.1.6.2') > v('2.1.6.2-ohos-4'), isTrue);
      expect(v('2.1.6.2-ohos-4') < v('2.1.6.2'), isTrue);
    });

    test('a later core always wins over a suffix', () {
      expect(v('2.1.6.3-ohos-1') > v('2.1.6.2-ohos-9'), isTrue);
    });

    test('equality matches comparison', () {
      expect(v('2.1.6.2-ohos-4') == v('v2.1.6.2-ohos-4'), isTrue);
      expect(v('2.1.6.2-ohos-4').hashCode, v('2.1.6.2-ohos-4').hashCode);
      expect(v('2.1.6.2-ohos-4') == v('2.1.6.2-ohos-4.1'), isFalse);
      expect(v('2.1.6.2-ohos-4') == v('2.1.6.2-ohos-5'), isFalse);
    });

    test('isNewer ignores equal versions', () {
      expect(AppVersion.isNewer(v('2.1.6.2-ohos-4'), v('2.1.6.2-ohos-4')), isFalse);
      expect(AppVersion.isNewer(v('2.1.6.2-ohos-4.1'), v('2.1.6.2-ohos-4')), isTrue);
    });
  });
}
