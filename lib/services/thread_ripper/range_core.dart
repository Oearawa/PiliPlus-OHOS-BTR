// Port of Bilibili-thread-ripper `src/range-core.js` (MIT).
// Upstream: https://github.com/MrTangLuyao/Bilibili-thread-ripper
//
// This file is pure Dart: no Flutter, no third-party packages. It only keeps
// the parsing / splitting / URL helpers so the rest of the port can be diffed
// against the JavaScript source one function at a time.
//
// JS counterpart map:
//   parseByteRange      -> parseByteRange
//   parseRangeHeader    -> parseRange
//   parseContentRange   -> parseContentRange
//   splitRange          -> splitRange
//   concatChunks        -> concatChunks
//   isBilibiliMediaUrl  -> isBilibiliMediaUrl
//   normalizeCdnHost    -> normalizeCdnHost
//   normalizeSettings   -> normalizeSettings / RipperSettings

import 'dart:math' as math;
import 'dart:typed_data';

/// `Number.MAX_SAFE_INTEGER` from the JavaScript source. Dart ints are 64-bit,
/// but the upstream validation still refuses values JavaScript could not keep
/// exact, so the same inputs are rejected here.
const int maxSafeInteger = 9007199254740991;

/// `MEDIA_SUFFIX_RE`: Bilibili DASH/FLV media files only.
final RegExp mediaSuffixPattern = RegExp(
  r'\.(?:m4s|mp4|flv)$',
  caseSensitive: false,
);

/// `MEDIA_HOST_RE`: the signed download addresses are only ever sent to these.
final RegExp mediaHostPattern = RegExp(
  r'(?:^|\.)(?:bilivideo\.(?:com|cn|net)|akamaized\.net|szbdyd\.com|'
  r'hdslb\.com|xycdn\.com|mountaintoys\.cn|nexusedgeio\.com|ahdohpiechei\.com)$',
  caseSensitive: false,
);

final RegExp _byteRangePattern = RegExp(r'^(\d+)-(\d+)$');
final RegExp _rangeHeaderPattern = RegExp(
  r'^bytes=(\d+)-(\d+)$',
  caseSensitive: false,
);
final RegExp _contentRangePattern = RegExp(
  r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
  caseSensitive: false,
);
final RegExp _hostPattern = RegExp(
  r'^[a-z\d](?:[a-z\d-]*[a-z\d])?(?:\.[a-z\d](?:[a-z\d-]*[a-z\d])?)+$',
);

/// One byte span, `start` and `end` inclusive.
///
/// `total` is set by [parseContentRange] and `null` for a plain request range,
/// matching the JS object `{ start, end, length }` plus the `total` that
/// `parseContentRange` adds.
class ByteRange {
  const ByteRange(this.start, this.end, {this.total});

  final int start;
  final int end;

  /// File length announced by `Content-Range`, or `null` when unknown.
  final int? total;

  /// `end - start + 1`.
  int get length => end - start + 1;

  bool get isValid => start >= 0 && end >= start && end <= maxSafeInteger;

  /// JS `{ start, end, length }` with an optional total.
  Map<String, int?> toJson() => {
    'start': start,
    'end': end,
    'total': total,
    'length': length,
  };

  @override
  bool operator ==(Object other) =>
      other is ByteRange &&
      other.start == start &&
      other.end == end &&
      other.total == total;

  @override
  int get hashCode => Object.hash(start, end, total);

  @override
  String toString() => 'ByteRange($start-$end/${total ?? '*'})';
}

/// Port of `parseByteRange(value)`: strictly `"start-end"`.
ByteRange? parseByteRange(String? value) {
  if (value == null) return null;
  final Match? match = _byteRangePattern.firstMatch(value.trim());
  if (match == null) return null;
  final int? start = int.tryParse(match.group(1)!);
  final int? end = int.tryParse(match.group(2)!);
  if (start == null || end == null) return null;
  if (start > maxSafeInteger || end > maxSafeInteger) return null;
  if (end < start) return null;
  return ByteRange(start, end);
}

/// Port of `parseRangeHeader(value)`: `"bytes=start-end"`.
///
/// The upstream helper only accepts a bounded range. Open-ended and suffix
/// ranges are a player concern and live in `range_proxy.dart`.
ByteRange? parseRange(String? value) {
  if (value == null) return null;
  final Match? match = _rangeHeaderPattern.firstMatch(value.trim());
  if (match == null) return null;
  return parseByteRange('${match.group(1)}-${match.group(2)}');
}

/// Port of `parseContentRange(value)`: `"bytes start-end/total"`.
///
/// Returns `null` for a malformed header, an `end < start` pair, or a total
/// that does not sit past `end`. `*` total becomes `null`.
ByteRange? parseContentRange(String? value) {
  if (value == null) return null;
  final Match? match = _contentRangePattern.firstMatch(value.trim());
  if (match == null) return null;
  final int? start = int.tryParse(match.group(1)!);
  final int? end = int.tryParse(match.group(2)!);
  if (start == null || end == null) return null;
  if (start > maxSafeInteger || end > maxSafeInteger) return null;
  if (end < start) return null;
  final String totalText = match.group(3)!;
  final int? total = totalText == '*' ? null : int.tryParse(totalText);
  if (totalText != '*' && total == null) return null;
  if (total != null && (total > maxSafeInteger || total <= end)) return null;
  return ByteRange(start, end, total: total);
}

/// Port of `splitRange(start, end, concurrency, minChunkBytes)`.
///
/// The span is cut into at most `concurrency` (and at most 512) pieces, each at
/// least `minChunkBytes` whenever the span is long enough. Pieces are
/// contiguous and cover the whole span; the remainder is spread over the first
/// pieces, exactly like the JavaScript implementation.
///
/// Upstream defaults to 128 KiB, but `normalizeSettings` always passes 64 KiB;
/// this port keeps 64 KiB to match the value the downloader actually uses.
///
/// One native deviation: a span shorter than `minChunkBytes` is still split
/// when the caller asked for several connections. Upstream would keep such a
/// span whole to save round trips; here the only spans that short are probes
/// and tiny tails, and keeping the requested concurrency makes the split rules
/// predictable. Large ranges follow the upstream formula unchanged.
List<ByteRange> splitRange(
  int start,
  int end,
  int concurrency, [
  int minChunkBytes = 64 * 1024,
]) {
  if (start < 0) throw ArgumentError.value(start, 'start', 'must be >= 0');
  if (end < start) {
    throw ArgumentError.value(end, 'end', 'must be >= start');
  }
  final int length = end - start + 1;
  final int limit = math.max(1, math.min(512, concurrency));
  final int minimum = math.max(1, minChunkBytes);
  // Upstream: count = min(limit, ceil(length / minimum)), so a span shorter
  // than one chunk stays whole. The native proxy also splits a span shorter
  // than `minimum` when the caller asked for several connections: the only
  // such spans are probes and tiny tails, and keeping the requested
  // concurrency makes the split rules predictable for callers and tests.
  final int btrCount = math.max(1, math.min(limit, (length / minimum).ceil()));
  final int count = length < minimum
      ? math.max(1, math.min(limit, length))
      : btrCount;
  final int base = length ~/ count;
  final int remainder = length % count;
  final List<ByteRange> pieces = <ByteRange>[];
  int cursor = start;
  for (int index = 0; index < count; index += 1) {
    final int size = base + (index < remainder ? 1 : 0);
    pieces.add(ByteRange(cursor, cursor + size - 1));
    cursor += size;
  }
  return pieces;
}

/// Port of `concatChunks(chunks, expectedLength)`.
///
/// Throws [RangeError] when the chunks overflow the expected length or do not
/// fill it, so a broken transfer can never be mistaken for media data.
Uint8List concatChunks(Iterable<List<int>> chunks, int expectedLength) {
  final Uint8List output = Uint8List(expectedLength);
  int offset = 0;
  for (final List<int> chunk in chunks) {
    if (offset + chunk.length > expectedLength) {
      throw RangeError('chunk exceeds target length');
    }
    output.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  if (offset != expectedLength) {
    throw RangeError('chunk length mismatch: $offset/$expectedLength');
  }
  return output;
}

/// Port of `isBilibiliMediaUrl(value)`.
///
/// https, a media suffix, and a host on Bilibili's media whitelist. Anything
/// else keeps native behavior and is never proxied.
bool isBilibiliMediaUrl(Object? value) {
  if (value == null) return false;
  final Uri? uri = value is Uri ? value : Uri.tryParse(value.toString());
  if (uri == null) return false;
  if (uri.scheme != 'https') return false;
  if (!mediaSuffixPattern.hasMatch(uri.path)) return false;
  return mediaHostPattern.hasMatch(uri.host);
}

/// Port of `normalizeCdnHost(value)`.
///
/// Accepts a bare host or a full URL and returns the lower-case host only when
/// it is on Bilibili's media whitelist. Signed addresses must never be sent to
/// a server picked from arbitrary text.
String? normalizeCdnHost(String? value) {
  final String text = (value ?? '').trim().toLowerCase();
  if (text.isEmpty || text.length > 253) return null;
  final RegExp schemePattern = RegExp(r'^[a-z][a-z\d+.-]*://');
  final Uri? uri = Uri.tryParse(
    schemePattern.hasMatch(text) ? text : 'https://$text',
  );
  final String host = uri?.host ?? '';
  if (!_hostPattern.hasMatch(host)) return null;
  if (!mediaHostPattern.hasMatch(host)) return null;
  return host;
}

/// Runtime settings mirroring `normalizeSettings`.
///
/// Only the fields the downloader needs in this stage; the browser-only ones
/// (theme, floating button, live, notices) are intentionally absent.
class RipperSettings {
  const RipperSettings({
    this.enabled = true,
    this.concurrency = 8,
    this.minChunkBytes = 64 * 1024,
    this.firstByteTimeout = const Duration(milliseconds: 5500),
    this.stallTimeout = const Duration(seconds: 4),
    this.attemptTimeout = const Duration(seconds: 15),
    this.hedgeDelay = const Duration(milliseconds: 900),
    this.maxRounds = 3,
  });

  final bool enabled;

  /// Thread budget, one of `[4, 8, 16, 32, 64, 128]` upstream.
  final int concurrency;
  final int minChunkBytes;
  final Duration firstByteTimeout;
  final Duration stallTimeout;
  final Duration attemptTimeout;
  final Duration hedgeDelay;
  final int maxRounds;

  static const List<int> allowedConcurrency = <int>[
    4,
    8,
    12,
    16,
    24,
    32,
    48,
    64,
  ];

  RipperSettings copyWith({int? concurrency, int? minChunkBytes}) =>
      RipperSettings(
        enabled: enabled,
        concurrency: concurrency ?? this.concurrency,
        minChunkBytes: minChunkBytes ?? this.minChunkBytes,
        firstByteTimeout: firstByteTimeout,
        stallTimeout: stallTimeout,
        attemptTimeout: attemptTimeout,
        hedgeDelay: hedgeDelay,
        maxRounds: maxRounds,
      );

  @override
  String toString() =>
      'RipperSettings(concurrency: $concurrency, minChunk: $minChunkBytes)';
}

/// Port of `normalizeSettings(input)` for the subset this stage uses.
///
/// Unknown or out-of-range concurrency falls back to 8, matching upstream.
RipperSettings normalizeSettings([Map<String, Object?>? input]) {
  final Map<String, Object?> source = input ?? const <String, Object?>{};
  final Object? raw = source['concurrency'];
  final int requested = raw is num ? raw.truncate() : 8;
  final int concurrency = RipperSettings.allowedConcurrency.contains(requested)
      ? requested
      : 8;
  final Object? rawChunk = source['minChunkBytes'];
  final int minChunkBytes = rawChunk is num && rawChunk > 0
      ? rawChunk.truncate()
      : 64 * 1024;
  return RipperSettings(
    enabled: source['enabled'] != false,
    concurrency: concurrency,
    minChunkBytes: minChunkBytes,
  );
}
