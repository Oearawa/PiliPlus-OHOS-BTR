// Single source of truth for the app's own GitHub repository.
//
// Nothing else in the app may hard-code an owner/repository pair for update
// checks: the about page, the update dialog and the release client all read
// these values. The owner is taken from the project's git remote
// (origin -> https://github.com/Oearawa/PiliPro.git); it is never
// inferred from an upstream project.

/// Which release stream the installation follows.
///
/// The beta channel is retired: this project ships full releases only, and the
/// checker never offers a pre-release. [beta] is kept so a value written by an
/// older build can still be read back without breaking storage.
enum UpdateChannel {
  beta,

  stable;

  String get label => switch (this) {
    UpdateChannel.beta => 'Beta',
    UpdateChannel.stable => '正式版',
  };
}

abstract final class GithubUpdateConfig {
  /// Owner of this project's repository (from `git remote -v`), not an upstream.
  static const String owner = 'Oearawa';

  /// Repository name of this project.
  static const String repository = 'PiliPro';

  static const String homepage = 'https://github.com/$owner/$repository';

  static const String releasesUrl = '$homepage/releases';

  static const String issuesUrl = '$homepage/issues';

  static const String apiRoot = 'https://api.github.com';

  /// Release list endpoint. `/releases/latest` is deliberately not used: it
  /// never returns a pre-release, and this project ships betas.
  static const String releasesApi =
      '$apiRoot/repos/$owner/$repository/releases';

  /// Package name the HAP must carry to be installable over this build.
  static const String bundleName = 'com.oearawa.pilipro';

  /// A cached result is reused for this long before an automatic check runs.
  static const Duration cacheTtl = Duration(hours: 12);

  /// Never let a slow network block startup or the about page.
  static const Duration requestTimeout = Duration(seconds: 15);

  static const int releasesPerPage = 20;

  /// Only files with this extension are offered as installable updates.
  static const String hapExtension = '.hap';

  static Uri get releasesUri =>
      Uri.parse('$releasesApi?per_page=$releasesPerPage');
}
