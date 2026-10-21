// Media properties used to choose an initial download concurrency.
//
// Bilibili DASH reports `bandwidth` in bits per second. The values are hints,
// not measurements: the feedback controller may move above or below the
// initial rung. This file is pure Dart so the policy is deterministic in tests.

/// The selected DASH video/audio and its playback labels.
class RipperMediaDemand {
  const RipperMediaDemand({
    this.videoBandwidth,
    this.audioBandwidth,
    this.width,
    this.height,
    this.frameRate,
    this.codec,
    this.isHdr = false,
    this.isDolbyVision = false,
  });

  /// DASH video `bandwidth`, bits/s.
  final int? videoBandwidth;

  /// DASH audio `bandwidth`, bits/s. Audio is added to the video demand.
  final int? audioBandwidth;

  final int? width;
  final int? height;
  final double? frameRate;
  final String? codec;
  final bool isHdr;
  final bool isDolbyVision;

  static bool _plausibleBandwidth(int? value) {
    // A few bits/s is a sentinel/placeholder, not a real DASH bitrate. The
    // upper bound also rejects values that were already converted to bytes or
    // accidentally supplied in kbit/s.
    return value != null && value >= 8000 && value <= 2000000000;
  }

  /// Total DASH bitrate in Mbit/s, or null when the video bitrate is unusable.
  ///
  /// A missing audio bitrate does not invalidate the video estimate.
  double? get estimatedDemandMbps {
    if (!_plausibleBandwidth(videoBandwidth)) return null;
    final int audio = _plausibleBandwidth(audioBandwidth)
        ? audioBandwidth!
        : 0;
    return (videoBandwidth! + audio) / 1000000.0;
  }

  /// Initial rung on [AutoConcurrency.ladder].
  ///
  /// The first branch follows the upstream bitrate mapping. If bandwidth is
  /// absent or implausible, resolution/frame-rate is only a weak fallback;
  /// HDR/DV labels never by themselves select the highest rung. The feedback
  /// controller is still allowed to probe up to 64 afterwards.
  int suggestedInitialThreads() {
    final double? mbps = estimatedDemandMbps;
    if (mbps != null) {
      if (mbps <= 5) return 8;
      if (mbps <= 12) return 12;
      if (mbps <= 25) return 16;
      if (mbps <= 50) return 24;
      return 32;
    }

    final int h = height ?? 0;
    final double fps = frameRate ?? 0;
    if (h >= 4320) return 32;
    if (h >= 2160) return fps >= 50 ? 32 : 24;
    if (h >= 1440) return fps >= 50 ? 24 : 16;
    if (h >= 1080) return fps >= 50 ? 12 : 8;
    return 8;
  }

  /// Short diagnostic description; never contains signed URLs.
  String describe() {
    final double? mbps = estimatedDemandMbps;
    final String rate = mbps == null
        ? '码率未知'
        : '${mbps.toStringAsFixed(1)} Mbps';
    final String dimensions = width != null && height != null
        ? '${width}x$height'
        : '分辨率未知';
    final String hdr = isDolbyVision
        ? 'Dolby Vision'
        : isHdr
        ? 'HDR'
        : 'SDR';
    return '$rate, $dimensions, $hdr, ${codec ?? 'codec 未知'}';
  }
}
