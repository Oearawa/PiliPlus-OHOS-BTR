// Unit tests for the pure range helpers (host-only, no Flutter bindings).
//
// Mirrors the checks upstream keeps in `dev/shared-core-test.js` for
// `parseRangeHeader`, `parseContentRange`, `splitRange` and `concatChunks`.

import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Range Core Tests', () {
    test('Should parse Content-Range correctly', () {
      final ByteRange? range = parseContentRange('bytes 0-100/1000');
      expect(range, isNotNull);
      expect(range!.start, 0);
      expect(range.end, 100);
      expect(range.total, 1000);
      expect(range.length, 101);
    });

    test('Should parse a bounded Range header', () {
      final ByteRange? range = parseRange('bytes=10-19');
      expect(range, isNotNull);
      expect(range!.start, 10);
      expect(range.end, 19);
      expect(range.total, isNull);
      expect(range.length, 10);
    });

    test('Should reject malformed or inconsistent ranges', () {
      expect(parseRange('bytes=10-'), isNull);
      expect(parseRange('bytes=-10'), isNull);
      expect(parseRange('bytes=20-10'), isNull);
      expect(parseRange('items=0-10'), isNull);
      expect(parseContentRange('bytes 10-20/15'), isNull);
      expect(parseContentRange('bytes 20-10/100'), isNull);
      expect(parseContentRange('bytes 0-10/*')?.total, isNull);
      expect(parseContentRange('bytes x-y/100'), isNull);
    });

    test('Should split range based on concurrency', () {
      final List<ByteRange> pieces = splitRange(0, 1000, 4);
      expect(pieces.length, 4);
      expect(pieces.first.start, 0);
      expect(pieces.last.end, 1000);
      int expectedStart = 0;
      int covered = 0;
      for (final ByteRange piece in pieces) {
        expect(piece.start, expectedStart, reason: 'pieces must not overlap');
        expect(piece.end, greaterThanOrEqualTo(piece.start));
        expectedStart = piece.end + 1;
        covered += piece.length;
      }
      expect(covered, 1001, reason: 'pieces must not leave a gap');
    });

    test('Should keep the upstream minimum-chunk rule for larger spans', () {
      // Four full 64 KiB chunks fill exactly four pieces.
      final List<ByteRange> pieces = splitRange(0, 4 * 65536 - 1, 4);
      expect(pieces.length, 4);
      expect(pieces.map((ByteRange p) => p.length), everyElement(65536));
      // A span ten chunks long and a 4-way split gives four equal-ish pieces.
      expect(splitRange(0, 10 * 65536 - 1, 4).length, 4);
    });

    test('Should cap the piece count and clamp the inputs', () {
      final List<ByteRange> pieces = splitRange(0, 1000000, 10000);
      expect(pieces.length, lessThanOrEqualTo(512));
      expect(() => splitRange(10, 9, 4), throwsArgumentError);
      expect(() => splitRange(-1, 9, 4), throwsArgumentError);
    });

    test('Should concatenate chunks and reject a wrong length', () {
      final Uint8List bytes = concatChunks(<List<int>>[
        <int>[1, 2],
        <int>[3],
        <int>[4, 5],
      ], 5);
      expect(bytes, <int>[1, 2, 3, 4, 5]);
      expect(
        () => concatChunks(<List<int>>[
          <int>[1, 2],
        ], 3),
        throwsRangeError,
      );
      expect(
        () => concatChunks(<List<int>>[
          <int>[1, 2, 3],
        ], 2),
        throwsRangeError,
      );
    });

    test('Should only accept Bilibili media URLs', () {
      expect(
        isBilibiliMediaUrl(
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1.m4s?deadline=1',
        ),
        isTrue,
      );
      expect(
        isBilibiliMediaUrl(
          'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/1.m4s',
        ),
        isTrue,
      );
      expect(
        isBilibiliMediaUrl('http://upos-sz-mirrorcos.bilivideo.com/a.m4s'),
        isFalse,
      );
      expect(isBilibiliMediaUrl('https://example.com/a.m4s'), isFalse);
      expect(
        isBilibiliMediaUrl('https://upos-sz-mirrorcos.bilivideo.com/a.html'),
        isFalse,
      );
      expect(normalizeCdnHost('UPOS-sz-mirrorcos.bilivideo.com'), isNotNull);
      expect(normalizeCdnHost('evil.example.com'), isNull);
    });

    test('Should normalise settings like upstream', () {
      expect(normalizeSettings().concurrency, 8);
      expect(
        normalizeSettings(<String, Object?>{'concurrency': 32}).concurrency,
        32,
      );
      expect(
        normalizeSettings(<String, Object?>{'concurrency': 7}).concurrency,
        8,
      );
      expect(
        normalizeSettings(<String, Object?>{'concurrency': 999}).concurrency,
        8,
      );
      expect(normalizeSettings().minChunkBytes, 64 * 1024);
    });
  });
}
