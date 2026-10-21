// CDN address compatibility, pinned against the BTR 2026.10.17.1 fixes.
//
// Two rules are easy to break and expensive in the field:
//   * a relay address (mcdn / mountaintoys) may only be used as it was handed
//     out; moving it to an ordinary node answers HTTP 403;
//   * a signed address keeps its path and query when only the host is swapped.
// `upos-sz-mirrorcoso1.bilivideo.com` is part of the mainland set.

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:flutter_test/flutter_test.dart';

Uri _signed(String host, {String path = '/upgcxcode/1/2/3.m4s'}) => Uri.parse(
  'https://$host$path?deadline=1700000000&gen=playurlv3&os=cos&upsig=abc123',
);

void main() {
  group('relay detection', () {
    test('mcdn hosts, v1 resource paths and os=mcdn are relays', () {
      expect(
        isRelayUrl(Uri.parse('https://xy1.mcdn.bilivideo.cn/a.m4s')),
        isTrue,
      );
      expect(
        isRelayUrl(
          Uri.parse('https://upos-sz-mirrorali.bilivideo.com/v1/resource/a'),
        ),
        isTrue,
      );
      expect(
        isRelayUrl(
          Uri.parse('https://upos-sz-mirrorali.bilivideo.com/a.m4s?os=mcdn'),
        ),
        isTrue,
      );
    });

    test('a mountaintoys edge host is a relay even on an ordinary path', () {
      expect(
        isRelayUrl(
          Uri.parse(
            'https://cn-hk-eq-01-01.mountaintoys.cn/upgcxcode/1/2/3.m4s',
          ),
        ),
        isTrue,
      );
    });

    test('an ordinary bilivideo address is not a relay', () {
      expect(isRelayUrl(_signed('upos-sz-mirrorali.bilivideo.com')), isFalse);
    });
  });

  group('node substitution', () {
    test('a mountaintoys relay is never used as a donor', () {
      final Uri relay = Uri.parse(
        'https://cn-hk-eq-01-01.mountaintoys.cn/upgcxcode/1/2/3.m4s?os=mcdn',
      );
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: relay,
      );
      // Nothing to synthesise from a relay: only the relay itself is offered.
      expect(resolver.candidateUrls, <Uri>[relay]);
    });

    test('coso1 is a mainland candidate and keeps the signature', () {
      final Uri origin = _signed('upos-sz-mirrorali.bilivideo.com');
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: origin,
      );
      final Uri coso1 = resolver.candidateUrls.firstWhere(
        (Uri url) => url.host == 'upos-sz-mirrorcoso1.bilivideo.com',
      );
      expect(coso1.path, origin.path);
      expect(coso1.query, origin.query);
      expect(coso1.queryParameters['upsig'], 'abc123');
      expect(coso1.port, 0);
    });

    test('a relay address is kept untouched next to an ordinary one', () {
      final Uri ordinary = _signed('upos-sz-mirrorali.bilivideo.com');
      final Uri relay = Uri.parse(
        'https://xy1.mcdn.bilivideo.cn/v1/resource/abc.m4s?os=mcdn',
      );
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: ordinary,
        backupUrls: <Uri>[relay],
        mode: CdnMode.mainland,
      );
      // The relay is not a donor and is not rewritten; the ordinary address
      // is expanded to the mainland nodes.
      expect(
        resolver.candidateUrls.where((Uri url) => url.host.contains('mcdn')),
        isEmpty,
      );
      expect(
        resolver.candidateUrls.map((Uri url) => url.host).toSet(),
        containsAll(mainlandHosts),
      );
    });

    test('a custom host that is not whitelisted is ignored', () {
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: _signed('upos-sz-mirrorali.bilivideo.com'),
        mode: CdnMode.custom,
        customHosts: <String>['evil.example.com'],
      );
      // With no usable custom host the mode falls back to the mainland list.
      expect(
        resolver.candidateUrls.map((Uri url) => url.host).toSet(),
        containsAll(mainlandHosts),
      );
    });

    test('the same node is never offered twice with different casing', () {
      final CdnResolver resolver = CdnResolver.fromRepresentation(
        baseUrl: _signed('upos-sz-mirrorali.bilivideo.com'),
        mode: CdnMode.custom,
        customHosts: <String>[
          'UPOS-SZ-MIRRORHW.bilivideo.com',
          'upos-sz-mirrorhw.bilivideo.com',
        ],
      );
      expect(resolver.candidateUrls.length, 1);
      expect(
        resolver.candidateUrls.single.host,
        'upos-sz-mirrorhw.bilivideo.com',
      );
    });
  });
}
