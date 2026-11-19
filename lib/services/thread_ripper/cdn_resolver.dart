// Port of Bilibili-thread-ripper `src/cdn-resolver.js` (MIT).
// Upstream: https://github.com/MrTangLuyao/Bilibili-thread-ripper
//
// Pure Dart, no Flutter and no third-party packages. Host lists, ban
// attribution, health back-off, per-route speed measurement, candidate
// ordering and the smooth weighted round-robin assignment are kept close to
// the JavaScript so a future upstream change can be reviewed line by line.
//
// JS counterpart map:
//   MAINLAND_HOSTS / OVERSEAS_HOSTS -> mainlandHosts / overseasHosts
//   isAkamaiUrl / isRelayUrl        -> isAkamaiUrl / isRelayUrl
//   representationUrls              -> CdnResolver.fromRepresentation
//   createBanList                   -> CdnBanList
//   createResolver                  -> CdnResolver
//   assignPrimaries                 -> CdnAssignments.assign

import 'dart:math' as math;

import 'package:PiliPlus/services/thread_ripper/range_core.dart';

/// Where the signed media address may be sent.
enum CdnMode {
  /// Bilibili's mainland CDN nodes.
  mainland,

  /// Bilibili's overseas CDN nodes.
  overseas,

  /// Only the hosts picked in the settings.
  custom,
}

/// `MAINLAND_HOSTS` from `cdn-resolver.js:7-17` (nine nodes, including
/// `upos-sz-mirrorcoso1.bilivideo.com`, added in BTR 2026.10.17.1).
const List<String> mainlandHosts = <String>[
  'upos-sz-mirrorali.bilivideo.com',
  'upos-sz-mirrorhw.bilivideo.com',
  'upos-sz-mirrorbos.bilivideo.com',
  'upos-sz-mirror08c.bilivideo.com',
  'upos-sz-mirrorbd.bilivideo.com',
  'upos-sz-mirror14b.bilivideo.com',
  'upos-sz-estgoss.bilivideo.com',
  'upos-sz-mirrorcos.bilivideo.com',
  'upos-sz-mirrorcoso1.bilivideo.com',
];

/// `OVERSEAS_HOSTS` from `cdn-resolver.js:19-24`.
const List<String> overseasHosts = <String>[
  'upos-sz-mirrorcosov.bilivideo.com',
  'upos-sz-mirroraliov.bilivideo.com',
  'cn-hk-eq-01-01.bilivideo.com',
  'cn-hk-eq-01-03.bilivideo.com',
];

/// `GLOBAL_HOSTS`: overseas first, then mainland.
const List<String> globalHosts = <String>[...overseasHosts, ...mainlandHosts];

/// Speed measurements older than this are treated as absent.
const Duration measurementTtl = Duration(seconds: 90);

/// Only transfers of at least this many bytes update a speed measurement.
const int speedSampleMinBytes = 48 * 1024;

// Dart style keeps these lowerCamelCase; the aliases mirror the JavaScript
// names so a side-by-side diff with `cdn-resolver.js` stays obvious.
// ignore: constant_identifier_names
const List<String> MAINLAND_HOSTS = mainlandHosts;
// ignore: constant_identifier_names
const List<String> OVERSEAS_HOSTS = overseasHosts;

/// `isAkamaiUrl(value)`: an `*.akamaized.net` address.
bool isAkamaiUrl(Uri url) => url.host.toLowerCase().endsWith('.akamaized.net');

/// `isRelayUrl(value)`.
///
/// A P2P or edge-cache relay (an mcdn node, or the `mountaintoys.cn` caches
/// beside them) wraps the file in its own path and signature. Its address
/// works only on relays: every ordinary node refuses it.
///
/// Upstream recognises the relay by the `mcdn` host label, the
/// `/v1/resource/` path or an `os=mcdn` query. This port additionally treats
/// every `mountaintoys.cn` host as a relay even when it serves an ordinary
/// `upgcxcode` path: BTR 2026.10.17.1 saw HTTP 403 when such addresses were
/// moved to a normal node, and a host that is only a peer cache there is not
/// worth the risk of one more refused request.
bool isRelayUrl(Uri url) {
  final String host = url.host;
  if (RegExp(r'(?:^|\.)mcdn\.', caseSensitive: false).hasMatch(host)) {
    return true;
  }
  if (RegExp(
    r'(?:^|\.)mountaintoys\.cn$',
    caseSensitive: false,
  ).hasMatch(host)) {
    return true;
  }
  return RegExp(r'^/v1/resource/', caseSensitive: false).hasMatch(url.path) ||
      (url.queryParameters['os'] ?? '').toLowerCase() == 'mcdn';
}

/// `safeMediaUrl(value)`: keep only URLs the media whitelist accepts.
Uri? safeMediaUrl(Object? value) {
  if (value == null) return null;
  final Uri? uri = value is Uri ? value : Uri.tryParse(value.toString());
  if (uri == null) return null;
  return isBilibiliMediaUrl(uri) ? uri : null;
}

/// `hostOf(value)`.
String hostOf(Uri url) => url.host.toLowerCase();

/// `addressOf(value)`: path + query, the signed address without its node.
String addressOf(Uri url) => '${url.path}?${url.query}';

/// `swapOrdinaryHost(rawUrl, targetHost, allowAkamai)`.
///
/// Keeps the signed path and query, replaces the host and clears any
/// non-standard port. Returns `null` when the host is not on the media
/// whitelist, or when an Akamai address may not be used as a donor.
Uri? swapOrdinaryHost(
  Uri donor,
  String targetHost, {
  bool allowAkamai = false,
}) {
  if (!allowAkamai && isAkamaiUrl(donor)) return null;
  final String host = targetHost.toLowerCase();
  if (normalizeCdnHost(host) != host) return null;
  try {
    return donor.replace(host: host, port: 0);
  } on ArgumentError {
    return null;
  }
}

List<String> _customServers(CdnMode mode, List<String> customHosts) {
  if (mode != CdnMode.custom) return const <String>[];
  return customHosts.map(normalizeCdnHost).whereType<String>().toSet().toList();
}

/// `createBanList()`.
///
/// A CDN node that twice fails without sending a single byte is skipped for
/// the rest of the current video. `AbortError` and transfers that delivered
/// bytes do not count. HTTP 4xx means the node answered and refused the signed
/// address; what has delivered data decides whether the node or the address is
/// blamed. Banned entries are exposed for diagnostics and reset per video.
class CdnBanList {
  CdnBanList({this.limit = 2, this.onBan});

  /// Strikes before an entry is banned.
  final int limit;

  /// Called once per newly banned node/address/pair.
  final void Function(String key, int strikes, String? host, bool isNode)?
  onBan;

  final Map<String, int> _emptyReplies = <String, int>{};
  final Set<String> _goodNodes = <String>{};
  final Set<String> _goodAddresses = <String>{};
  final Set<String> _reported = <String>{};
  Set<String> _banned = <String>{};

  bool recordError(Uri url, {int status = 0, int receivedBytes = 0}) {
    if (receivedBytes > 0) return false;
    final String node = hostOf(url);
    if (node.isEmpty) return false;
    final bool refused = status >= 400 && status < 500;
    final String key = '$node\n${addressOf(url)}\n${refused ? 'refused' : ''}';
    _emptyReplies.update(key, (int value) => value + 1, ifAbsent: () => 1);
    return _judge(url);
  }

  void success(Uri url) {
    final String node = hostOf(url);
    final String address = addressOf(url);
    if (node.isEmpty ||
        (_goodNodes.contains(node) && _goodAddresses.contains(address))) {
      return;
    }
    _goodNodes.add(node);
    _goodAddresses.add(address);
    _judge(url);
  }

  bool _judge(Uri url) {
    final Map<String, int> strikes = <String, int>{};
    for (final MapEntry<String, int> entry in _emptyReplies.entries) {
      final List<String> parts = entry.key.split('\n');
      final String node = parts[0];
      final String address = parts[1];
      final bool refused = parts[2] == 'refused';
      final String blamed;
      if (!refused) {
        blamed = 'node:$node';
      } else if (_goodNodes.contains(node)) {
        blamed = _goodAddresses.contains(address)
            ? 'pair:$node $address'
            : 'address:$address';
      } else if (_goodAddresses.contains(address)) {
        blamed = 'node:$node';
      } else {
        continue;
      }
      strikes.update(
        blamed,
        (int value) => value + entry.value,
        ifAbsent: () => entry.value,
      );
    }
    final Set<String> banned = strikes.entries
        .where((MapEntry<String, int> entry) => entry.value >= limit)
        .map((MapEntry<String, int> entry) => entry.key)
        .toSet();
    bool added = false;
    for (final String key in banned) {
      if (_reported.add(key)) {
        added = true;
        final bool isNode = key.startsWith('node:');
        onBan?.call(
          key,
          strikes[key] ?? 0,
          isNode ? key.substring(5) : hostOf(url),
          isNode,
        );
      }
    }
    _banned = banned;
    return added;
  }

  bool allows(Uri url) =>
      !_banned.contains('node:${hostOf(url)}') &&
      !_banned.contains('address:${addressOf(url)}') &&
      !_banned.contains('pair:${hostOf(url)} ${addressOf(url)}');

  bool allowsNode(Uri url) => !_banned.contains('node:${hostOf(url)}');

  bool allowsAddress(Uri url) => !_banned.contains('address:${addressOf(url)}');

  Set<String> get hosts => _banned
      .where((String key) => key.startsWith('node:'))
      .map((String key) => key.substring(5))
      .toSet();

  Set<String> get banned => Set<String>.unmodifiable(_banned);

  void reset() {
    _emptyReplies.clear();
    _goodNodes.clear();
    _goodAddresses.clear();
    _reported.clear();
    _banned = <String>{};
  }
}

class _Health {
  int failures = 0;
  DateTime blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
}

class _Measurement {
  double bps = 0;
  DateTime? lastSuccessAt;
  DateTime? lastMeasuredAt;
}

/// `createResolver(representation, getMode, bans)` for native use.
class CdnResolver {
  CdnResolver(
    this.candidateUrls, {
    CdnBanList? bans,
    this.mode = CdnMode.mainland,
    List<Uri>? originals,
    List<String> customHosts = const <String>[],
    DateTime Function()? now,
  }) : bans = bans ?? CdnBanList(),
       originals = originals ?? candidateUrls,
       customHosts = List<String>.unmodifiable(customHosts),
       _now = now ?? DateTime.now;

  /// Builds the candidate list exactly like `representationUrls(...)`.
  ///
  /// [baseUrl] is `baseUrl`/`base_url`, [backupUrls] is `backupUrl` /
  /// `backup_url` / `backup_url_list` from a DASH representation.
  factory CdnResolver.fromRepresentation({
    required Uri? baseUrl,
    List<Uri> backupUrls = const <Uri>[],
    CdnMode mode = CdnMode.mainland,
    List<String> customHosts = const <String>[],
    CdnBanList? bans,
    DateTime Function()? now,
  }) {
    final List<Uri> originals = <Uri>[
      ?baseUrl,
      ...backupUrls,
    ].map(safeMediaUrl).whereType<Uri>().toSet().toList();
    final List<String> custom = _customServers(mode, customHosts);
    final List<String> hosts = custom.isNotEmpty
        ? custom
        : mode == CdnMode.overseas
        ? overseasHosts
        : mainlandHosts;
    final List<Uri> ordinary = originals
        .where((Uri url) => !isRelayUrl(url))
        .toList();
    final Uri? donor = ordinary
        .where((Uri url) => !isAkamaiUrl(url))
        .firstOrNull;

    final List<Uri> synthetic = <Uri?>[
      if (donor != null)
        ...hosts.map((String host) => swapOrdinaryHost(donor, host))
      else
        ...hosts.expand(
          (String host) => ordinary.map(
            (Uri url) => swapOrdinaryHost(url, host, allowAkamai: true),
          ),
        ),
    ].whereType<Uri>().toList();

    final List<Uri> allowedOriginals;
    if (custom.isNotEmpty) {
      allowedOriginals = originals
          .where((Uri url) => custom.contains(hostOf(url)))
          .toList();
    } else if (mode == CdnMode.overseas) {
      allowedOriginals = originals
          .where((Uri url) => !mainlandHosts.contains(hostOf(url)))
          .toList();
    } else {
      allowedOriginals = originals
          .where((Uri url) => mainlandHosts.contains(hostOf(url)))
          .toList();
    }

    // Bilibili sometimes hands a track out only through relays. No other node
    // can serve it then, so the relays are used whatever the mode.
    final List<Uri> relays = ordinary.isEmpty ? originals : const <Uri>[];

    final List<Uri> urls = <Uri>{
      ...allowedOriginals,
      ...synthetic,
      ...relays,
    }.toList();

    return CdnResolver(
      urls,
      bans: bans,
      mode: mode,
      originals: originals,
      customHosts: customHosts,
      now: now,
    );
  }

  final List<Uri> candidateUrls;
  final List<Uri> originals;
  final List<String> customHosts;
  final CdnBanList bans;
  final CdnMode mode;
  final DateTime Function() _now;

  final Map<String, _Health> _health = <String, _Health>{};
  final Map<String, _Measurement> _routes = <String, _Measurement>{};
  int _cursor = 0;
  int _rangeCursor = 0;
  int _mediaRangeCount = 0;

  DateTime get now => _now();

  /// `host + pathname` of a URL: a fresh signature is the same route.
  static String routeOf(Uri url) => '${url.authority}${url.path}';

  bool isAvailable(Uri url) {
    final DateTime? until = _health[url.toString()]?.blockedUntil;
    return until == null || !until.isAfter(_now());
  }

  bool allows(Uri url) => bans.allows(url);

  /// `resolver.speed(url)`: 0 when absent or stale.
  double speed(Uri url) {
    final _Measurement? measurement = _routes[routeOf(url)];
    final DateTime? at = measurement?.lastMeasuredAt;
    if (measurement == null || at == null) return 0;
    if (_now().difference(at) >= measurementTtl) return 0;
    return measurement.bps;
  }

  bool _measuredNow(Uri url) => speed(url) > 0;

  List<Uri> _unbanned(List<Uri> list) {
    final List<Uri> allowed = list.where(bans.allows).toList();
    return allowed.isEmpty ? List<Uri>.of(list) : allowed;
  }

  /// `resolver.urls()`: candidates, banned nodes left out.
  List<Uri> urls() => _unbanned(candidateUrls);

  List<Uri> _available(List<Uri> list) => list.where(isAvailable).toList();

  int _bySpeed(Uri a, Uri b) {
    final _Measurement? am = _routes[routeOf(a)];
    final _Measurement? bm = _routes[routeOf(b)];
    final int success =
        (bm?.lastSuccessAt != null ? 1 : 0) -
        (am?.lastSuccessAt != null ? 1 : 0);
    if (success != 0) return success;
    return (bm?.bps ?? 0).compareTo(am?.bps ?? 0);
  }

  /// `resolver.ordered(pieceIndex)`: rotated candidate list.
  List<Uri> ordered([int pieceIndex = 0]) {
    final List<Uri> candidates = urls();
    final List<Uri> available = _available(candidates);
    final List<Uri> pool = available.isEmpty ? candidates : available;
    if (pool.isEmpty) return pool;
    final int offset = (_cursor + pieceIndex) % pool.length;
    _cursor = (_cursor + 1) % pool.length;
    return <Uri>[...pool.skip(offset), ...pool.take(offset)];
  }

  /// `resolver.rescueCandidates()`: usable nodes, fastest first.
  List<Uri> rescueCandidates() {
    final List<Uri> list = _available(urls())..sort(_bySpeed);
    return list;
  }

  /// `resolver.rangeCandidates()`.
  ///
  /// Warm-up rounds (one on mainland, four overseas) let every node answer
  /// once. After that the measured nodes carry the segments in speed order and
  /// one unmeasured/stale node rides along as the exploration slot.
  List<Uri> rangeCandidates() {
    final List<Uri> pool = _available(urls())..sort(_bySpeed);
    if (pool.isEmpty) return urls();
    final bool firstRange = _mediaRangeCount == 0;
    final int width = math.min(firstRange ? pool.length : 6, pool.length);
    final int warmupRanges = mode == CdnMode.mainland ? 1 : 4;
    final List<Uri> selected;
    if (_mediaRangeCount < warmupRanges) {
      selected = pool.take(width).toList();
      _rangeCursor = width % pool.length;
    } else {
      final List<Uri> measured = pool.where(_measuredNow).toList();
      final List<Uri> rest = pool
          .where((Uri url) => !_measuredNow(url))
          .toList();
      final int places = math.min(
        rest.length,
        math.max(1, width - measured.length),
      );
      final List<Uri> explore = List<Uri>.generate(
        places,
        (int index) => rest[(_rangeCursor + index) % rest.length],
      );
      _rangeCursor = (_rangeCursor + places) % pool.length;
      selected = <Uri>[...measured.take(width - explore.length), ...explore];
      for (final Uri url in pool) {
        if (selected.length >= math.min(3, pool.length)) break;
        if (!selected.contains(url)) selected.add(url);
      }
    }
    _mediaRangeCount += 1;
    return selected;
  }

  /// `resolver.startupCandidates()`: the first bytes race original and
  /// synthesized addresses, at most eight.
  List<Uri> startupCandidates() {
    final List<Uri> merged = <Uri>{...originals, ...candidateUrls}.toList();
    return _available(_unbanned(merged)).take(8).toList();
  }

  /// `resolver.pieceCandidates(preferred, index, round)`.
  List<Uri> pieceCandidates(List<Uri> preferred, int index, int round) {
    final List<Uri> rotated = preferred.isEmpty
        ? const <Uri>[]
        : <Uri>[
            ...preferred.skip(round % preferred.length),
            ...preferred.take(round % preferred.length),
          ];
    final List<Uri> rescue = rescueCandidates()
        .where((Uri url) => !rotated.contains(url))
        .toList();
    final List<Uri> rest = <Uri>[...rotated.skip(1), ...rescue];
    // Dart's sort is not stable; keep the upstream JS tie order explicitly.
    final Map<Uri, int> positions = <Uri, int>{
      for (int i = 0; i < rest.length; i += 1) rest[i]: i,
    };
    rest.sort((Uri a, Uri b) {
      final int bySpeed = speed(b).compareTo(speed(a));
      return bySpeed != 0 ? bySpeed : positions[a]!.compareTo(positions[b]!);
    });
    return <Uri>{
      if (rotated.isNotEmpty) rotated.first,
      ...rest,
      ...ordered(index),
    }.toList();
  }

  /// `resolver.success(url, bps)`.
  void success(Uri url, {int bytes = 0, Duration elapsed = Duration.zero}) {
    bans.success(url);
    final double bps =
        bytes >= speedSampleMinBytes && elapsed.inMicroseconds > 0
        ? bytes * 1000000 / elapsed.inMicroseconds
        : 0;
    _health[url.toString()] = _Health();
    final _Measurement measurement = _routes.putIfAbsent(
      routeOf(url),
      _Measurement.new,
    )..lastSuccessAt = _now();
    if (bps > 0) {
      measurement
        ..bps = measurement.bps == 0 ? bps : measurement.bps * 0.65 + bps * 0.35
        ..lastMeasuredAt = _now();
    }
  }

  /// `resolver.sample(url, bps)`: a cut-off transfer still measures the node.
  void sample(Uri url, double bps) {
    if (!(bps > 0)) return;
    final _Measurement measurement = _routes.putIfAbsent(
      routeOf(url),
      _Measurement.new,
    );
    measurement
      ..bps = measurement.bps == 0 ? bps : measurement.bps * 0.65 + bps * 0.35
      ..lastMeasuredAt = _now();
  }

  /// `resolver.failure(url, error, receivedBytes)`.
  ///
  /// 3 s, doubling per failure up to 60 s, on the node; the ban list decides
  /// whether the node or the address is to blame.
  void failure(
    Uri url, {
    int status = 0,
    int receivedBytes = 0,
    bool aborted = false,
    Object? error,
  }) {
    if (aborted) return;
    bans.recordError(url, status: status, receivedBytes: receivedBytes);
    final _Health health = _health.putIfAbsent(url.toString(), _Health.new)
      ..failures += 1;
    final int exponent = math.min(health.failures, 4);
    final int delayMs = math.min(60000, 3000 * (1 << exponent));
    health.blockedUntil = _now().add(Duration(milliseconds: delayMs));
  }

  /// Diagnostics for the settings panel / logs.
  List<Map<String, Object?>> status() {
    final List<Uri> all = candidateUrls;
    final List<Uri> usable = all.where(bans.allowsAddress).toList();
    return (usable.isEmpty ? all : usable).map((Uri url) {
      final _Health? health = _health[url.toString()];
      final bool blocked =
          health != null && health.blockedUntil.isAfter(_now());
      final bool measured = _measuredNow(url);
      return <String, Object?>{
        'host': url.host,
        'state': !bans.allowsNode(url)
            ? 'banned'
            : blocked
            ? 'blocked'
            : measured
            ? 'healthy'
            : 'untested',
        'bps': speed(url).round(),
      };
    }).toList();
  }

  void resetBans() => bans.reset();
}

class _TrialState {
  int waited = 0;
  int cursor = 0;
}

/// `assignPrimaries(urls, resolver, count)`.
///
/// Smooth weighted round-robin: a fast node gets more pieces, and pieces are
/// handed out in turns so ranges in flight together do not all open on the
/// same node. Nodes banned by [CdnBanList] or inside their exponential
/// back-off window are filtered out first. A node measured at under a twelfth
/// of the best is left out; unmeasured nodes get a trial piece or two.
class CdnAssignments {
  int _turn = 0;
  final Expando<_TrialState> _trials = Expando<_TrialState>('btr-trials');

  List<Uri> assign(List<Uri> urls, CdnResolver resolver, int count) {
    if (urls.isEmpty || count <= 0) return <Uri>[];
    final List<Uri> eligible = urls
        .where((Uri url) => resolver.allows(url) && resolver.isAvailable(url))
        .toList();
    final List<Uri> pool = eligible.isEmpty ? List<Uri>.of(urls) : eligible;
    if (pool.length == 1) {
      return List<Uri>.filled(count, pool.first);
    }
    final int turn = _turn;
    _turn = (_turn + 1) % 4096;
    final List<double> known = pool
        .map((Uri url) => math.max(0, resolver.speed(url)).toDouble())
        .toList();
    final double top = known.reduce((double a, double b) => a > b ? a : b);
    if (top <= 0) {
      return List<Uri>.generate(
        count,
        (int index) => pool[(index + turn) % pool.length],
      );
    }
    List<Uri> working = pool;
    List<double> speeds = known;
    final List<Uri> speedFiltered = <Uri>[
      for (int i = 0; i < working.length; i += 1)
        if (speeds[i] == 0 || speeds[i] >= top / 12) working[i],
    ];
    if (speedFiltered.isNotEmpty && speedFiltered.length < working.length) {
      working = speedFiltered;
      speeds = working
          .map((Uri url) => math.max(0, resolver.speed(url)).toDouble())
          .toList();
    }
    final List<Uri> unknown = <Uri>[
      for (int i = 0; i < working.length; i += 1)
        if (speeds[i] == 0) working[i],
    ];
    int trials = math.min(unknown.length * 2, count ~/ 4);
    final _TrialState state = _trials[resolver] ??= _TrialState();
    if (trials == 0 && unknown.isNotEmpty && count >= 2) {
      state.waited += 1;
      if (state.waited >= 4) trials = 1;
    }
    if (trials > 0) state.waited = 0;
    final List<Uri> measured = <Uri>[
      for (int i = 0; i < working.length; i += 1)
        if (speeds[i] > 0) working[i],
    ];
    final List<double> measuredSpeeds = <double>[
      for (int i = 0; i < working.length; i += 1)
        if (speeds[i] > 0) speeds[i],
    ];
    final int regular = math.max(0, count - trials);
    final List<Uri> result = <Uri>[];
    if (measured.isNotEmpty && regular > 0) {
      final List<double> weights = measuredSpeeds
          .map((double value) => math.max(value, top * 0.05).toDouble())
          .toList();
      final double total = weights.reduce((double a, double b) => a + b);
      final List<double> credit = List<double>.filled(measured.length, 0);
      final List<int> order = List<int>.generate(
        measured.length,
        (int index) => (index + turn) % measured.length,
      );
      for (int i = 0; i < regular; i += 1) {
        int best = order.first;
        for (final int index in order) {
          credit[index] += weights[index];
          if (credit[index] > credit[best]) best = index;
        }
        credit[best] -= total;
        result.add(measured[best]);
      }
    }
    for (int i = 0; i < trials && unknown.isNotEmpty; i += 1) {
      result.add(unknown[(i + state.cursor) % unknown.length]);
    }
    state.cursor = (state.cursor + trials) % 4096;
    // Keep the promised count even when every node is unmeasured.
    while (result.length < count) {
      result.add(pool[result.length % pool.length]);
    }
    return result.take(count).toList();
  }
}
