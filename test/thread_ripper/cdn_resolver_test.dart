// Unit tests for the CDN resolver: host lists, relay handling, ban
// attribution, back-off, speed TTL and the smooth weighted round-robin.

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

Uri _media(String host, {String path = '/upgcxcode/00/00/1/1-1-30080.m4s'}) =>
    Uri.parse('https://$host$path?deadline=1&os=x');

void main() {
  group('CDN host lists', () {
    test('mainland list carries nine nodes including coso1', () {
      expect(mainlandHosts.length, 9);
      expect(mainlandHosts, contains('upos-sz-mirrorcoso1.bilivideo.com'));
      expect(overseasHosts.length, 4);
      expect(globalHosts.length, 13);
    });

    test('relay addresses are never moved to ordinary nodes', () {
      final Uri relay = Uri.parse(
        'https://xy1x2x3x4.mcdn.bilivideo.cn/v1/resource/a.m4s?os=mcdn',
      );
      expect(isRelayUrl(relay), isTrue);
      // The relay is not a donor: representationUrls synthesises nothing from
      // it and keeps the relay address itself.
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: relay,
      );
      expect(resolver.candidateUrls, <Uri>[relay]);
    });

    test('mainland candidates keep the signature and swap only the host', () {
      final Uri origin = _media('upos-sz-mirrorali.bilivideo.com');
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: origin,
      );
      expect(resolver.candidateUrls, isNotEmpty);
      expect(
        resolver.candidateUrls.map((Uri url) => url.host).toSet(),
        containsAll(mainlandHosts),
      );
      for (final Uri url in resolver.candidateUrls) {
        expect(url.path, origin.path);
        expect(url.query, origin.query);
      }
    });

    test('Akamai-only representations are still synthesised', () {
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: Uri.parse(
          'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/a.m4s?sig=1',
        ),
      );
      expect(resolver.candidateUrls.length, mainlandHosts.length);
      expect(
        resolver.candidateUrls
            .map((Uri url) => url.host)
            .every(mainlandHosts.contains),
        isTrue,
      );
    });

    test('a relay-only track is served from the relay itself', () {
      final Uri relay = Uri.parse(
        'https://xy1x2x3x4.mcdn.bilivideo.cn/v1/resource/abc.m4s?os=mcdn',
      );
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: relay,
      );
      expect(resolver.candidateUrls, <Uri>[relay]);
    });

    test('overseas mode never keeps mainland originals', () {
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: _media('upos-sz-mirrorali.bilivideo.com'),
        mode: CdnMode.overseas,
      );
      expect(
        resolver.candidateUrls
            .map((Uri url) => url.host)
            .any(mainlandHosts.contains),
        isFalse,
      );
      expect(
        resolver.candidateUrls.map((Uri url) => url.host).toSet(),
        containsAll(overseasHosts),
      );
    });

    test('custom mode only uses the picked servers', () {
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: _media('upos-sz-mirrorali.bilivideo.com'),
        mode: CdnMode.custom,
        customHosts: <String>['upos-sz-mirrorhw.bilivideo.com'],
      );
      expect(
        resolver.candidateUrls.map((Uri url) => url.host).toSet(),
        <String>{'upos-sz-mirrorhw.bilivideo.com'},
      );
    });
  });

  group('Ban attribution', () {
    test('a refused address is dropped, not the node that serves others', () {
      final CdnBanList bans = CdnBanList();
      final Uri good = _media('upos-sz-mirrorali.bilivideo.com');
      final Uri refused = good.replace(path: '/other.m4s');
      bans.success(good);
      bans.recordError(refused, status: 403);
      expect(bans.allows(refused), isTrue, reason: 'one strike is not a ban');
      bans.recordError(refused, status: 403);
      expect(bans.allows(refused), isFalse);
      expect(bans.allowsNode(refused), isTrue);
      expect(bans.allows(good), isTrue);
    });

    test('two empty replies without data ban the node', () {
      final CdnBanList bans = CdnBanList();
      final Uri url = _media('upos-sz-mirrorhw.bilivideo.com');
      bans.recordError(url);
      expect(bans.allows(url), isTrue);
      bans.recordError(url);
      expect(bans.allows(url), isFalse);
      expect(bans.allowsNode(url), isFalse);
    });

    test('a transfer that delivered bytes is not an empty reply', () {
      final CdnBanList bans = CdnBanList();
      final Uri url = _media('upos-sz-mirrorhw.bilivideo.com');
      bans.recordError(url, receivedBytes: 4096);
      bans.recordError(url, receivedBytes: 4096);
      expect(bans.allows(url), isTrue);
    });
  });

  group('Resolver scheduling', () {
    late DateTime now;
    late CdnResolver resolver;
    late List<Uri> urls;

    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      urls = <Uri>[
        _media('upos-sz-mirrorali.bilivideo.com'),
        _media('upos-sz-mirrorhw.bilivideo.com'),
        _media('upos-sz-mirrorcos.bilivideo.com'),
      ];
      resolver = CdnResolver(urls, now: () => now);
    });

    test('failure blocks a node for an exponentially growing window', () {
      final Uri url = urls.first;
      resolver.failure(url);
      expect(resolver.isAvailable(url), isFalse);
      now = now.add(const Duration(seconds: 7));
      expect(resolver.isAvailable(url), isTrue);
      resolver.failure(url);
      resolver.failure(url);
      resolver.failure(url);
      expect(resolver.isAvailable(url), isFalse);
    });

    test('speed expires after ninety seconds', () {
      final Uri url = urls.first;
      resolver.success(url, bytes: 200000, elapsed: const Duration(seconds: 1));
      expect(resolver.speed(url), greaterThan(0));
      now = now.add(const Duration(seconds: 89));
      expect(resolver.speed(url), greaterThan(0));
      now = now.add(const Duration(seconds: 2));
      expect(resolver.speed(url), 0);
    });

    test('banned and cooling nodes are filtered from assignment', () {
      final Uri banned = urls[0];
      final Uri cooling = urls[1];
      final Uri healthy = urls[2];
      resolver.bans.recordError(banned);
      resolver.bans.recordError(banned);
      resolver.failure(cooling);
      resolver.success(
        healthy,
        bytes: 300000,
        elapsed: const Duration(seconds: 1),
      );
      final CdnAssignments assignments = CdnAssignments();
      final List<Uri> assigned = assignments.assign(urls, resolver, 12);
      expect(assigned, isNotEmpty);
      expect(assigned, isNot(contains(banned)));
      expect(assigned, isNot(contains(cooling)));
      expect(assigned.every((Uri url) => url == healthy), isTrue);
    });

    test('smooth weighted round-robin favours the fast node', () {
      resolver.success(
        urls[0],
        bytes: 300000,
        elapsed: const Duration(seconds: 1),
      );
      resolver.success(
        urls[1],
        bytes: 200000,
        elapsed: const Duration(seconds: 1),
      );
      resolver.success(
        urls[2],
        bytes: 100000,
        elapsed: const Duration(seconds: 1),
      );
      final CdnAssignments assignments = CdnAssignments();
      final List<Uri> assigned = assignments.assign(urls, resolver, 60);
      expect(assigned.length, 60);
      final Map<Uri, int> counts = <Uri, int>{};
      for (final Uri url in assigned) {
        counts[url] = (counts[url] ?? 0) + 1;
      }
      expect(counts[urls[0]], greaterThan(counts[urls[1]]!));
      expect(counts[urls[1]], greaterThan(counts[urls[2]]!));
    });

    test('an unmeasured node still gets trial pieces', () {
      resolver.success(
        urls[0],
        bytes: 400000,
        elapsed: const Duration(seconds: 1),
      );
      final CdnAssignments assignments = CdnAssignments();
      final List<Uri> assigned = assignments.assign(urls, resolver, 20);
      expect(assigned, contains(urls[1]));
      expect(assigned, contains(urls[2]));
    });

    test('candidate ordering rotates and prefers measured nodes', () {
      resolver.success(
        urls[1],
        bytes: 300000,
        elapsed: const Duration(seconds: 1),
      );
      final List<Uri> first = resolver.rangeCandidates();
      expect(first, isNotEmpty);
      final List<Uri> orderedAgain = resolver.ordered();
      expect(orderedAgain.length, urls.length);
      expect(orderedAgain.toSet(), urls.toSet());
    });
  });
}
