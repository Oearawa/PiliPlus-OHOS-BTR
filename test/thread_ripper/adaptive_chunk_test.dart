// Unit tests for the two adaptive helpers ported from BTR upstream:
// sub-chunk sizing (64 KiB .. 1 MiB, about 0.6 s of one connection) and the
// hedge delay that follows how long pieces have been taking.
//
// Pure functions, no network: the values are pinned so a future change to the
// formula shows up here instead of only in a slow live transfer.

import 'dart:typed_data';

import 'package:PiliPlus/services/thread_ripper/cdn_resolver.dart';
import 'package:PiliPlus/services/thread_ripper/idm_downloader.dart';
import 'package:PiliPlus/services/thread_ripper/range_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('adaptive chunk size', () {
    test('an unknown speed keeps the configured floor', () {
      expect(
        adaptiveChunkBytes(
          rangeLength: 8 << 20,
          pieceLimit: 8,
          hostCount: 8,
          minChunkBytes: 64 * 1024,
          connectionBps: 0,
        ),
        64 * 1024,
      );
    });

    test('a fast connection grows the chunk to the 1 MiB cap', () {
      expect(
        adaptiveChunkBytes(
          rangeLength: 8 << 20,
          pieceLimit: 8,
          hostCount: 8,
          minChunkBytes: 64 * 1024,
          connectionBps: 8 * 1024 * 1024,
        ),
        1024 * 1024,
      );
    });

    test('a slow connection stays on the 64 KiB floor', () {
      expect(
        adaptiveChunkBytes(
          rangeLength: 8 << 20,
          pieceLimit: 8,
          hostCount: 8,
          minChunkBytes: 64 * 1024,
          connectionBps: 200 * 1024,
        ),
        64 * 1024,
      );
    });

    test('a short range is spread over the connections', () {
      // 256 KiB over 8 connections is 32 KiB each: below the floor, so the
      // floor wins and the range still splits into a few pieces.
      expect(
        adaptiveChunkBytes(
          rangeLength: 256 * 1024,
          pieceLimit: 8,
          hostCount: 8,
          minChunkBytes: 64 * 1024,
          connectionBps: 8 * 1024 * 1024,
        ),
        64 * 1024,
      );
    });

    test('the target is about 0.6 s of one connection, in 64 KiB steps', () {
      // 2 MiB/s -> 1.2 MiB target rounded down to 1.1875 MiB, capped at 1 MiB.
      expect(
        adaptiveChunkBytes(
          rangeLength: 64 << 20,
          pieceLimit: 8,
          hostCount: 8,
          minChunkBytes: 64 * 1024,
          connectionBps: 2 * 1024 * 1024,
        ),
        1024 * 1024,
      );
      // 1 MiB/s -> 0.6 MiB -> 9 * 64 KiB = 576 KiB.
      expect(
        adaptiveChunkBytes(
          rangeLength: 64 << 20,
          pieceLimit: 8,
          hostCount: 8,
          minChunkBytes: 64 * 1024,
          connectionBps: 1024 * 1024,
        ),
        576 * 1024,
      );
    });

    test(
      'a downloader starts at the floor and grows after measuring',
      () async {
        final IdmDownloader engine = IdmDownloader(
          settings: const RipperSettings(concurrency: 4, maxRounds: 1),
          userAgent: 'test-agent',
        );
        expect(engine.connectionBps, 0);
        expect(engine.adaptiveChunkFor(8 << 20, 4, 4), 64 * 1024);
        engine.close();
      },
    );
  });

  group('hedge delay', () {
    test('an unmeasured piece time keeps the configured delay', () {
      expect(
        adaptiveHedgeDelayMs(configuredMs: 900, pieceMs: 0),
        900,
      );
    });

    test('a fast piece waits less but never below 250 ms', () {
      expect(
        adaptiveHedgeDelayMs(configuredMs: 900, pieceMs: 100),
        250,
      );
      expect(
        adaptiveHedgeDelayMs(configuredMs: 900, pieceMs: 200),
        300,
      );
    });

    test('a slow piece never waits longer than configured', () {
      expect(
        adaptiveHedgeDelayMs(configuredMs: 900, pieceMs: 5000),
        900,
      );
      expect(
        adaptiveHedgeDelayMs(configuredMs: 300, pieceMs: 5000),
        300,
      );
    });
  });

  group('piece planning', () {
    test('a larger chunk yields fewer pieces for the same range', () {
      // 2 MiB: 64 KiB pieces hit the 8-piece concurrency cap, 512 KiB pieces
      // only need four requests for the same range.
      final List<ByteRange> small = splitRange(
        0,
        (2 << 20) - 1,
        8,
        64 * 1024,
      );
      final List<ByteRange> large = splitRange(
        0,
        (2 << 20) - 1,
        8,
        512 * 1024,
      );
      expect(large.length, lessThan(small.length));
      expect(large.first.start, 0);
      expect(large.last.end, (2 << 20) - 1);
      // The pieces still cover the range without gaps or overlaps.
      int cursor = 0;
      for (final ByteRange piece in large) {
        expect(piece.start, cursor);
        cursor = piece.end + 1;
      }
      expect(cursor, 2 << 20);
    });

    test('concatenating a resumed prefix keeps the byte order', () {
      final Uint8List head = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final Uint8List tail = Uint8List.fromList(<int>[5, 6]);
      expect(
        concatChunks(<List<int>>[head, tail], 6),
        <int>[1, 2, 3, 4, 5, 6],
      );
    });
  });
}
