// Release payloads parsed from the GitHub REST API.
//
// Only the fields the app actually uses are kept. Parsing is defensive: GitHub
// may add fields, and a malformed entry must not break the whole check.

import 'package:PiliPlus/core/update/app_version.dart';
import 'package:PiliPlus/core/update/github_update_config.dart';

/// One uploaded file of a release.
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    this.digest,
  });

  final String name;
  final String downloadUrl;
  final int size;

  /// Server-provided `sha256:<hex>` when GitHub computes one, else null.
  final String? digest;

  bool get isHap => name.toLowerCase().endsWith(GithubUpdateConfig.hapExtension);

  /// The hex part of [digest], or null when it is absent or not a SHA-256.
  String? get sha256 {
    final String? value = digest;
    if (value == null) return null;
    const String prefix = 'sha256:';
    if (!value.toLowerCase().startsWith(prefix)) return null;
    final String hex = value.substring(prefix.length).trim().toLowerCase();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
  }

  static ReleaseAsset? tryParse(Object? json) {
    if (json is! Map) return null;
    final Object? name = json['name'];
    final Object? url = json['browser_download_url'];
    if (name is! String || name.isEmpty) return null;
    if (url is! String || url.isEmpty) return null;
    final Object? size = json['size'];
    return ReleaseAsset(
      name: name,
      downloadUrl: url,
      size: size is num ? size.toInt() : 0,
      digest: json['digest'] is String ? json['digest'] as String : null,
    );
  }
}

/// One entry of `GET /repos/{owner}/{repo}/releases`.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.draft,
    required this.prerelease,
    required this.publishedAt,
    required this.assets,
    required this.version,
  });

  final String tagName;
  final String name;
  final String body;
  final String htmlUrl;
  final bool draft;
  final bool prerelease;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;

  /// Parsed tag, or null when the tag is not a version this app understands.
  final AppVersion? version;

  /// The installable HAP, if the release uploaded one.
  ///
  /// A release may attach several files (checksums, notes); only a `.hap` with
  /// a non-zero size counts. A source archive is never treated as a HAP.
  ReleaseAsset? get hapAsset {
    for (final ReleaseAsset asset in assets) {
      if (asset.isHap && asset.size > 0) return asset;
    }
    return null;
  }

  bool get hasInstallableHap => hapAsset != null;

  String get displayName => name.trim().isEmpty ? tagName : name.trim();

  static ReleaseInfo? tryParse(Object? json) {
    if (json is! Map) return null;
    final Object? tag = json['tag_name'];
    if (tag is! String || tag.isEmpty) return null;
    final Object? assets = json['assets'];
    final List<ReleaseAsset> parsed = <ReleaseAsset>[];
    if (assets is List) {
      for (final Object? item in assets) {
        final ReleaseAsset? asset = ReleaseAsset.tryParse(item);
        if (asset != null) parsed.add(asset);
      }
    }
    final Object? published = json['published_at'];
    return ReleaseInfo(
      tagName: tag,
      name: json['name'] is String ? json['name'] as String : '',
      body: json['body'] is String ? json['body'] as String : '',
      htmlUrl: json['html_url'] is String ? json['html_url'] as String : '',
      draft: json['draft'] == true,
      prerelease: json['prerelease'] == true,
      publishedAt: published is String ? DateTime.tryParse(published) : null,
      assets: List<ReleaseAsset>.unmodifiable(parsed),
      version: AppVersion.tryParse(tag),
    );
  }
}
