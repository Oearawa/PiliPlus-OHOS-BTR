// Thin GitHub Releases client.
//
// The transport is injectable so unit tests never touch the network: the real
// implementation uses dio, tests pass a fake fetcher returning canned JSON.
// No token is embedded — this repository is public and anonymous reads are
// enough for a release list.

import 'package:PiliPlus/core/update/github_update_config.dart';
import 'package:PiliPlus/core/update/release_info.dart';
import 'package:dio/dio.dart';

/// Returns the decoded JSON body for [uri].
typedef GithubJsonFetcher =
    Future<Object?> Function(Uri uri, {required Duration timeout});

/// Why a check failed, at the granularity the UI can explain.
enum UpdateFailure {
  /// DNS, connection reset, TLS, proxy.
  network,

  /// The request exceeded [GithubUpdateConfig.requestTimeout].
  timeout,

  /// GitHub answered 403, usually the anonymous rate limit.
  rateLimited,

  /// Repository or endpoint not found.
  notFound,

  /// Non-2xx that is neither 403 nor 404.
  http,

  /// Body was not a JSON array of releases.
  badResponse,
}

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.failure, [this.detail]);

  final UpdateFailure failure;
  final String? detail;

  String get message => switch (failure) {
    UpdateFailure.network => '网络连接失败，请检查网络后重试',
    UpdateFailure.timeout => '连接 GitHub 超时，请稍后重试',
    UpdateFailure.rateLimited => 'GitHub 接口触发限流，请稍后再试',
    UpdateFailure.notFound => '未找到发布仓库，请检查更新配置',
    UpdateFailure.http => 'GitHub 返回异常状态，请稍后重试',
    UpdateFailure.badResponse => '更新信息格式异常',
  };

  @override
  String toString() => 'UpdateCheckException(${failure.name}): ${detail ?? message}';
}

class GithubReleaseClient {
  GithubReleaseClient({GithubJsonFetcher? fetcher}) : _fetcher = fetcher ?? _dioFetcher;

  final GithubJsonFetcher _fetcher;

  /// Fetches the release list, newest first as GitHub returns it.
  ///
  /// Drafts are dropped here: they are not visible to anyone but maintainers
  /// and must never be offered as an update.
  Future<List<ReleaseInfo>> fetchReleases() async {
    final Object? json;
    try {
      json = await _fetcher(
        GithubUpdateConfig.releasesUri,
        timeout: GithubUpdateConfig.requestTimeout,
      );
    } on DioException catch (error) {
      throw _mapDio(error);
    } on UpdateCheckException {
      rethrow;
    } on Object catch (error) {
      throw UpdateCheckException(UpdateFailure.network, '$error');
    }
    if (json is! List) {
      throw const UpdateCheckException(
        UpdateFailure.badResponse,
        'expected a JSON array of releases',
      );
    }
    final List<ReleaseInfo> releases = <ReleaseInfo>[];
    for (final Object? item in json) {
      final ReleaseInfo? release = ReleaseInfo.tryParse(item);
      if (release == null || release.draft) continue;
      releases.add(release);
    }
    return releases;
  }

  static UpdateCheckException _mapDio(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return UpdateCheckException(UpdateFailure.timeout, error.message);
      case DioExceptionType.badResponse:
        final int? status = error.response?.statusCode;
        if (status == 403) {
          return UpdateCheckException(UpdateFailure.rateLimited, 'HTTP 403');
        }
        if (status == 404) {
          return UpdateCheckException(UpdateFailure.notFound, 'HTTP 404');
        }
        return UpdateCheckException(UpdateFailure.http, 'HTTP $status');
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
        return UpdateCheckException(UpdateFailure.network, error.message);
    }
  }

  static Future<Object?> _dioFetcher(Uri uri, {required Duration timeout}) async {
    final Dio dio = Dio(
      BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
        responseType: ResponseType.json,
        headers: const <String, String>{
          // GitHub rejects requests without a user agent in some edge cases.
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'PiliPro',
        },
        // Let the caller inspect 403/404 instead of throwing for them.
        validateStatus: (int? status) => status != null && status < 500,
      ),
    );
    final Response<Object?> response = await dio.getUri<Object?>(uri);
    final int status = response.statusCode ?? 0;
    if (status == 403) {
      throw UpdateCheckException(UpdateFailure.rateLimited, 'HTTP 403');
    }
    if (status == 404) {
      throw UpdateCheckException(UpdateFailure.notFound, 'HTTP 404');
    }
    if (status < 200 || status >= 300) {
      throw UpdateCheckException(UpdateFailure.http, 'HTTP $status');
    }
    return response.data;
  }
}
