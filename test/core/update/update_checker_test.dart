import 'package:PiliPlus/core/update/app_version.dart';
import 'package:PiliPlus/core/update/github_release_client.dart';
import 'package:PiliPlus/core/update/github_update_config.dart';
import 'package:PiliPlus/core/update/update_checker.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const String kRepoPage = 'https://github.com/Oearawa/PiliPro';

Map<String, Object?> release({
  required String tag,
  bool draft = false,
  bool prerelease = false,
  List<Map<String, Object?>>? assets,
  String name = '',
  String body = '',
  String? htmlUrl,
}) => <String, Object?>{
  'tag_name': tag,
  'name': name,
  'body': body,
  'html_url': htmlUrl ?? '$kRepoPage/releases/tag/$tag',
  'draft': draft,
  'prerelease': prerelease,
  'published_at': '2026-11-16T10:00:00Z',
  'assets':
      assets ??
      <Map<String, Object?>>[
        <String, Object?>{
          'name': 'PiliPro-$tag.hap',
          'browser_download_url':
              '$kRepoPage/releases/download/$tag/PiliPro-$tag.hap',
          'size': 32653224,
          'digest': null,
        },
      ],
};

GithubReleaseClient clientReturning(Object? json) => GithubReleaseClient(
  fetcher: (Uri uri, {required Duration timeout}) async => json,
);

GithubReleaseClient clientThrowing(Object error) => GithubReleaseClient(
  fetcher: (Uri uri, {required Duration timeout}) async => throw error,
);

UpdateChecker checkerWith(
  GithubReleaseClient client, {
  String current = '0.3.0-beta.1',
  MemoryUpdateStateStore? store,
  DateTime? now,
}) => UpdateChecker(
  client: client,
  store: store ?? MemoryUpdateStateStore(channel: UpdateChannel.stable),
  currentVersion: AppVersion.tryParse(current)!,
  clock: () => now ?? DateTime(2026, 11, 16, 12),
);

void main() {
  final DateTime now = DateTime(2026, 11, 16, 12);

  group('detection', () {
    test('1. a beta installation upgrades to the first stable release', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[release(tag: '2.1.6.2-ohos-4')]),
        current: '0.3.0-beta.1',
        now: now,
      ).check();
      expect(r.status, UpdateStatus.available);
      expect(r.release!.version!.display, '2.1.6.2-ohos-4');
      expect(r.currentVersion!.display, '0.3.0-beta.1');
    });

    test('2. the same version is up to date', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[release(tag: '2.1.6.2-ohos-4')]),
        current: '2.1.6.2-ohos-4',
        now: now,
      ).check();
      expect(r.status, UpdateStatus.upToDate);
    });

    test('3. a higher build is offered', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[
          release(tag: '2.1.6.2-ohos-4.1'),
          release(tag: '2.1.6.2-ohos-4'),
        ]),
        current: '2.1.6.2-ohos-4',
        now: now,
      ).check();
      expect(r.release!.tagName, '2.1.6.2-ohos-4.1');
    });

    test('ohos-5 beats ohos-4.2', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[
          release(tag: '2.1.6.2-ohos-4.2'),
          release(tag: '2.1.6.2-ohos-5'),
        ]),
        current: '2.1.6.2-ohos-4',
        now: now,
      ).check();
      expect(r.release!.tagName, '2.1.6.2-ohos-5');
    });

    test('4. drafts are ignored', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[release(tag: '2.1.6.3-ohos-1', draft: true)]),
        current: '2.1.6.2-ohos-4',
        now: now,
      ).check();
      expect(r.status, UpdateStatus.upToDate);
    });

    test('5. pre-releases are ignored, even when newer', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[
          release(tag: '2.1.6.3-ohos-1', prerelease: true),
        ]),
        current: '2.1.6.2-ohos-4',
        now: now,
      ).check();
      expect(r.status, UpdateStatus.upToDate);
    });

    test('a draft above a valid release does not hide it', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[
          release(tag: '2.9.0', draft: true),
          release(tag: '2.1.6.2-ohos-4.1'),
        ]),
        current: '2.1.6.2-ohos-4',
        now: now,
      ).check();
      expect(r.release!.tagName, '2.1.6.2-ohos-4.1');
    });
  });

  group('assets', () {
    test('6. a release without a HAP reports a missing installer', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[
          release(tag: '2.1.6.2-ohos-5', assets: <Map<String, Object?>>[]),
        ]),
        current: '2.1.6.2-ohos-4',
        now: now,
      ).check();
      expect(r.status, UpdateStatus.missingAsset);
      expect(r.hasUpdate, isFalse);
      expect(r.message, contains('暂未提供安装包'));
    });

    test('source archives are never treated as the installer', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[
          release(
            tag: '2.1.6.2-ohos-5',
            assets: <Map<String, Object?>>[
              <String, Object?>{
                'name': 'source.zip',
                'browser_download_url': '$kRepoPage/x.zip',
                'size': 100,
              },
              <String, Object?>{
                'name': 'SHA256SUMS.txt',
                'browser_download_url': '$kRepoPage/x.txt',
                'size': 100,
              },
            ],
          ),
        ]),
        current: '2.1.6.2-ohos-4',
        now: now,
      ).check();
      expect(r.status, UpdateStatus.missingAsset);
    });

    test('the HAP is picked among several assets', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[
          release(
            tag: '2.1.6.2-ohos-5',
            assets: <Map<String, Object?>>[
              <String, Object?>{
                'name': 'SHA256SUMS.txt',
                'browser_download_url': '$kRepoPage/x.txt',
                'size': 100,
              },
              <String, Object?>{
                'name': 'PiliPro-2.1.6.2-ohos-5.hap',
                'browser_download_url': '$kRepoPage/app.hap',
                'size': 32653224,
              },
            ],
          ),
        ]),
        current: '2.1.6.2-ohos-4',
        now: now,
      ).check();
      expect(r.release!.hapAsset!.name, endsWith('.hap'));
      expect(r.release!.hapAsset!.size, 32653224);
    });
  });

  group('failures never break the app', () {
    test('7a. 403 rate limit', () async {
      final UpdateCheckResult r = await checkerWith(
        clientThrowing(const UpdateCheckException(UpdateFailure.rateLimited)),
        now: now,
      ).check();
      expect(r.status, UpdateStatus.failed);
      expect(r.error!.failure, UpdateFailure.rateLimited);
      expect(r.message, contains('限流'));
    });

    test('7b. 404', () async {
      final UpdateCheckResult r = await checkerWith(
        clientThrowing(const UpdateCheckException(UpdateFailure.notFound)),
        now: now,
      ).check();
      expect(r.error!.failure, UpdateFailure.notFound);
    });

    test('7c. timeout', () async {
      final UpdateCheckResult r = await checkerWith(
        clientThrowing(
          DioException(
            requestOptions: RequestOptions(path: '/releases'),
            type: DioExceptionType.receiveTimeout,
          ),
        ),
        now: now,
      ).check();
      expect(r.error!.failure, UpdateFailure.timeout);
    });

    test('7d. connection error', () async {
      final UpdateCheckResult r = await checkerWith(
        clientThrowing(
          DioException(
            requestOptions: RequestOptions(path: '/releases'),
            type: DioExceptionType.connectionError,
          ),
        ),
        now: now,
      ).check();
      expect(r.error!.failure, UpdateFailure.network);
    });

    test('7e. malformed JSON', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<String, Object?>{'message': 'Not Found'}),
        now: now,
      ).check();
      expect(r.status, UpdateStatus.failed);
      expect(r.error!.failure, UpdateFailure.badResponse);
    });
  });

  group('release page link', () {
    test('8. the API html_url is carried through unchanged', () async {
      const String url = '$kRepoPage/releases/tag/2.1.6.2-ohos-4';
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[
          release(tag: '2.1.6.2-ohos-4', htmlUrl: url),
        ]),
        current: '0.3.0-beta.1',
        now: now,
      ).check();
      expect(r.release!.htmlUrl, url);
    });

    test('9. the link belongs to this repository', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[release(tag: '2.1.6.2-ohos-4')]),
        current: '0.3.0-beta.1',
        now: now,
      ).check();
      expect(r.release!.htmlUrl, startsWith(kRepoPage));
      expect(r.release!.htmlUrl, contains('/releases/tag/'));
    });

    test('10. upstream repositories are never the update source', () async {
      expect(GithubUpdateConfig.owner, 'Oearawa');
      expect(GithubUpdateConfig.repository, 'PiliPro');
      expect(
        GithubUpdateConfig.releasesApi,
        contains('/Oearawa/PiliPro/'),
      );
      expect(GithubUpdateConfig.homepage, isNot(contains('dev4harmony')));
      expect(
        GithubUpdateConfig.homepage,
        isNot(contains('Bilibili-thread-ripper')),
      );
    });
  });

  group('scheduling', () {
    test('a fresh cache short-circuits the next automatic check', () async {
      int calls = 0;
      final GithubReleaseClient client = GithubReleaseClient(
        fetcher: (Uri uri, {required Duration timeout}) async {
          calls += 1;
          return <Object?>[];
        },
      );
      final UpdateChecker c = checkerWith(
        client,
        store: MemoryUpdateStateStore(),
        now: now,
      );
      await c.check();
      await c.check();
      expect(calls, 1);
      await c.check(force: true);
      expect(calls, 2);
    });

    test('a skipped version stays quiet until something newer appears', () async {
      final MemoryUpdateStateStore store = MemoryUpdateStateStore();
      final GithubReleaseClient client = clientReturning(<Object?>[
        release(tag: '2.1.6.2-ohos-4'),
      ]);
      final UpdateChecker c = checkerWith(
        client,
        current: '0.3.0-beta.1',
        store: store,
        now: now,
      );
      final UpdateCheckResult first = await c.check(force: true);
      expect(first.hasUpdate, isTrue);
      await c.skip(first.release!);

      final UpdateChecker later = checkerWith(
        client,
        current: '0.3.0-beta.1',
        store: store,
        now: now.add(const Duration(hours: 13)),
      );
      expect((await later.check()).hasUpdate, isFalse);
      // A manual check may prompt again.
      expect((await later.check(force: true)).hasUpdate, isTrue);

      final UpdateChecker newer = checkerWith(
        clientReturning(<Object?>[release(tag: '2.1.6.2-ohos-4.1')]),
        current: '0.3.0-beta.1',
        store: store,
        now: now.add(const Duration(hours: 13)),
      );
      final UpdateCheckResult third = await newer.check();
      expect(third.hasUpdate, isTrue);
      expect(third.release!.tagName, '2.1.6.2-ohos-4.1');
    });

    test('an empty list means up to date', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[]),
        now: now,
      ).check();
      expect(r.status, UpdateStatus.upToDate);
    });

    test('unparseable tags are skipped', () async {
      final UpdateCheckResult r = await checkerWith(
        clientReturning(<Object?>[
          release(tag: 'nightly'),
          release(tag: '2.1.6.2-ohos-4'),
        ]),
        current: '0.3.0-beta.1',
        now: now,
      ).check();
      expect(r.release!.tagName, '2.1.6.2-ohos-4');
    });
  });
}
