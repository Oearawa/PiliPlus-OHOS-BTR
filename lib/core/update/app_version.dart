// Version parsing for release tags.
//
// This project tags releases as `2.1.6.2-ohos-4`, `2.1.6.2-ohos-4.1`,
// `2.1.6.2-ohos-5`, and older builds ran `0.3.0-beta.1`. None of these are
// strict SemVer (the core has four numeric parts, the suffix is a hyphenated
// pair), and comparing them as strings puts `2.1.6.2-ohos-10` before
// `2.1.6.2-ohos-4`. So parsing and ordering live here, in one place.

/// A parsed release version.
///
/// [core] holds every numeric segment before the suffix (`2.1.6.2` -> four
/// parts). [suffix] holds the tail split into tokens (`-ohos-4.1` ->
/// `['ohos', 4, 1]`); it is null when the tag has no suffix.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion({
    required this.core,
    required this.raw,
    this.suffix,
  });

  /// Numeric segments, most significant first. Never empty.
  final List<int> core;

  /// Suffix tokens: [int] for numeric parts, [String] otherwise.
  final List<Object>? suffix;

  /// The tag as published, without a leading `v`.
  final String raw;

  /// True when the tag carries any suffix (`-beta.1`, `-ohos-4`, ...).
  ///
  /// This is a *shape* fact, not a channel decision: this project ships
  /// `-ohos-N` tags as full releases. Channel filtering uses the `prerelease`
  /// flag GitHub returns, never this getter.
  bool get hasSuffix => suffix != null;

  /// The tag as published, minus a leading `v` and any `+build` metadata.
  ///
  /// This is [raw] rather than a rebuilt string: the suffix uses hyphens
  /// (`-ohos-4`) and rebuilding it from tokens would print `ohos.4`.
  String get display => raw;

  static final RegExp _pattern = RegExp(
    r'^[vV]?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  /// Returns null for anything that is not `digits[.digits][-suffix]`.
  static AppVersion? tryParse(String? text) {
    if (text == null) return null;
    final String trimmed = text.trim();
    final Match? match = _pattern.firstMatch(trimmed);
    if (match == null) return null;
    final List<int> core = <int>[];
    for (final String part in match.group(1)!.split('.')) {
      final int? value = int.tryParse(part);
      if (value == null) return null;
      core.add(value);
    }
    if (core.isEmpty) return null;
    final String? tail = match.group(2);
    List<Object>? suffix;
    if (tail != null && tail.isNotEmpty) {
      suffix = <Object>[];
      for (final String token in tail.split(RegExp(r'[.-]'))) {
        if (token.isEmpty) continue;
        suffix.add(int.tryParse(token) ?? token.toLowerCase());
      }
    }
    return AppVersion(
      core: List<int>.unmodifiable(core),
      suffix: suffix == null ? null : List<Object>.unmodifiable(suffix),
      raw: trimmed
          .replaceFirst(RegExp('^[vV]'), '')
          .split('+')
          .first,
    );
  }

  /// True when [candidate] is strictly newer than [current].
  static bool isNewer(AppVersion candidate, AppVersion current) =>
      candidate.compareTo(current) > 0;

  @override
  int compareTo(AppVersion other) {
    final int coreLength = core.length > other.core.length
        ? core.length
        : other.core.length;
    for (int i = 0; i < coreLength; i += 1) {
      final int left = i < core.length ? core[i] : 0;
      final int right = i < other.core.length ? other.core[i] : 0;
      if (left != right) return left.compareTo(right);
    }
    // Same core: a full release outranks any suffixed build of it.
    final List<Object>? left = suffix;
    final List<Object>? right = other.suffix;
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    final int shared = left.length < right.length ? left.length : right.length;
    for (int i = 0; i < shared; i += 1) {
      final int byToken = _compareToken(left[i], right[i]);
      if (byToken != 0) return byToken;
    }
    // `ohos-4` < `ohos-4.1`: the longer tail is the later build.
    return left.length.compareTo(right.length);
  }

  /// Numeric tokens compare numerically and outrank text tokens, matching the
  /// usual pre-release ordering; text compares case-insensitively.
  static int _compareToken(Object a, Object b) {
    if (a is int && b is int) return a.compareTo(b);
    if (a is int) return -1;
    if (b is int) return 1;
    return a.toString().compareTo(b.toString());
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  bool operator <(AppVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && other.compareTo(this) == 0;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(core),
    suffix == null ? null : Object.hashAll(suffix!),
  );

  @override
  String toString() => display;
}
