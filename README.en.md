<div align="center">
  <img src="assets/images/logo/logo.png" width="110" alt="PiliPlus OHOS BTR" />

  <h1>PiliPlus OHOS BTR</h1>

  <p>A HarmonyOS client built on the PiliPlus OHOS port, with Bilibili Thread Ripper download scheduling</p>

  <p>
    <img alt="HarmonyOS" src="https://img.shields.io/badge/HarmonyOS-API%2026-000000?logo=harmonyos&logoColor=white" />
    <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.44.9-02569B?logo=flutter&logoColor=white" />
    <img alt="Dart" src="https://img.shields.io/badge/Dart-3.12.2-0175C2?logo=dart&logoColor=white" />
    <img alt="BTR" src="https://img.shields.io/badge/BTR-2026.11.1.1-FF6699" />
    <img alt="License" src="https://img.shields.io/badge/License-GPL--3.0-blue" />
    <img alt="Release" src="https://img.shields.io/github/v/release/Oearawa/PiliPlus-OHOS-BTR?include_prereleases&label=release&color=orange" />
  </p>

  <p><a href="README.md">中文</a> | English</p>
</div>

> [!IMPORTANT]
> This is an **independently maintained** project. It is not an official branch of
> `dev4harmony/PiliPlus`, and nothing is pushed back to that repository.

## Download

| Version | Date | Artifact | Size | Signed |
| :--- | :--- | :--- | :--- | :--- |
| **v0.2.0-beta.1** | 2026-11-04 | HAP (arm64-v8a) | 31,427,949 bytes (30.0 MB) | No |

**[⬇ Download PiliPlus-OHOS-BTR-v0.2.0-beta.1-unsigned.hap](https://github.com/Oearawa/PiliPlus-OHOS-BTR/releases/download/v0.2.0-beta.1/PiliPlus-OHOS-BTR-v0.2.0-beta.1-unsigned.hap)**

```text
SHA-256  6d0076258db5e8f01b909da547beffab1e378b41ea9f757ad5c1234a31ee9c57
```

> The HAP is **unsigned** and cannot be installed as-is. Sign it with your own
> certificate in DevEco Studio first — see [Install](#install).
> This build has not been verified on a real HarmonyOS device.

## What this is

PiliPlus is a third-party Bilibili client written in Flutter. `dev4harmony/PiliPlus` ports it to
HarmonyOS; this project uses that branch as its base and does two things:

1. **Follow the HarmonyOS baseline** — screens, accounts, danmaku, the player shell and the OHOS
   build setup all come from upstream and stay in sync.
2. **Add a BTR download layer** — the multi-threaded Range downloading and adaptive concurrency
   scheduling of [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)
   are rewritten in Dart and wired into the real mpv playback path of the OHOS build.

Upstream BTR runs inside a browser (it replaces `fetch`/`XHR` and takes over MSE). The OHOS build
has none of that, so the shape is different: the app starts a loopback Range endpoint on
`127.0.0.1`, mpv opens it like any other media URL, and the bytes are fetched over several
connections. **The player itself needs no changes.**

Main language: Dart. Built into a HAP with the Flutter OHOS toolchain.

## Features

### Inherited from the PiliPlus OHOS branch

These are upstream capabilities; this project only follows them:

- Video browsing and playback, playlist and quality/audio selection
- Home recommendations, trending, search, bangumi and live entries
- User profiles, dynamics, comments, messages, favourites and watch later
- Danmaku (including advanced), subtitles, speed control, gestures
- Multi-account, offline caching, casting, WebDAV backup
- OHOS-specific work: immersive top bar, self-drawn title bar for free-form windows,
  safe-area handling, HDR output

### BTR download enhancements (ported here)

Implemented under `lib/services/thread_ripper/`, each with unit tests:

| Capability | Implementation | Notes |
| :--- | :--- | :--- |
| **Adaptive concurrency** | `auto_concurrency.dart` | Eight rungs `4/8/12/16/24/32/48/64`, driven by buffer, throughput and pushback |
| **Dynamic sub-chunk size** | `adaptiveChunkBytes()` | Targets ~0.6 s of one connection, rounded to 64 KiB, clamped to 64 KiB–1 MiB |
| **Multi-CDN scheduling** | `cdn_resolver.dart` | Mainland/overseas node pools, sorted by measured speed, exponential back-off per node |
| **EWMA speed estimation** | `_connectionBps` / `_pieceMs` | Connection rate and piece time smoothed at 0.7/0.3, feeding chunk sizing and hedging |
| **Hedged requests** | `adaptiveHedgeDelayMs()` | Starts a second node when the first stalls; delay follows measured piece time (floor 250 ms) |
| **Resume after stall** | `RipperPartialException`, `keepProgress` | Re-requests only the remaining bytes; keeps a verified prefix of ≥32 KiB |
| **Failed-chunk recovery** | `maxRounds` retry rounds | Failed pieces move to the next round; nodes are demoted by failure count |
| **Task coordination** | `RipperSemaphore` + `trackKey` single-flight | Video and audio share one connection budget; identical byte ranges are fetched once |

Boundary rules that are actually enforced in code:

- **Off by default.** With the master switch off, playback behaves exactly like the baseline.
- `412 / 429` steps down immediately and rests 180 s; a first-byte timeout steps down one rung and
  rests 60 s; mid-body stalls are reported separately from first-byte timeouts.
- Live streams, local files, HLS/FLV, DRM and preview-only episodes **never** enter BTR.
- If the loopback endpoint fails to open, playback falls back to the direct URL.

### In this release (v0.2.0-beta.1)

- Synced PiliPlus OHOS upstream `a8431412` (`Release 2.1.6.2-ohos-2`, 9 commits): self-drawn title
  bar for free-form windows, PC window continuation, deduplicated safe areas, one-shot back
  animation, top-bar blur, download path fix for cloned apps.
- Ported BTR upstream `3e715f5f` (`2026.11.1.1`): dynamic sub-chunks, EWMA metering, adaptive
  hedge delay, resume support, semaphore notification fix.
- Restored 27 OHOS plugin sources on the dependency side so the HAP builds reproducibly.

## Screenshots

<div align="center">
  <img src="assets/screenshots/home.png" width="24%" alt="Home" />
  <img src="assets/screenshots/bangumi_detail.png" width="24%" alt="Bangumi detail" />
  <img src="assets/screenshots/dynamic.png" width="24%" alt="Dynamics" />
  <img src="assets/screenshots/set.png" width="24%" alt="Settings" />
  <p><sub>UI preview: client screenshots inherited from PiliPlus upstream (iOS captures, 2024).
  These are <b>not</b> HarmonyOS device screenshots; the OHOS build differs mainly in window,
  status bar and HDR handling.</sub></p>
</div>

## Install

The release artifact is **unsigned**, so the system will refuse to install it directly:

1. Download `PiliPlus-OHOS-BTR-v0.2.0-beta.1-unsigned.hap` and verify the SHA-256 above.
2. Open `ohos/` in DevEco Studio and configure your own certificate under
   **Project Structure → Signing Configs** (a Huawei developer account and a debug certificate
   for your device are required).
3. Build again with signing enabled, or re-package the existing project:

   ```bash
   hvigorw assembleHap --mode module -p product=default
   ```

4. Install via `hdc install` or DevEco Studio.

The package name stays `com.example.piliplus`, so upgrading from the PiliPlus OHOS build keeps
your data. Builds that changed the package name must be uninstalled first.

## Using BTR

Path: **Settings → Video → Enable multi-threaded video acceleration (BTR)**.

| Toggle | Default | Effect |
| :--- | :--- | :--- |
| Enable BTR | Off | Master switch; when off, playback matches the baseline |
| Auto concurrency | On | Scheduler moves between 4 and 64; when off, the fixed rung is used |
| Manual rung | 8 | Fixed connection count when auto is off |
| CDN region | Overseas | Node pool selection, custom nodes supported |
| Episode acceleration | On | Lets playable PGC episodes use BTR (DRM/preview still direct) |

The same page shows **diagnostics**: current rung, saturation share, the last adjustment reason,
rungs in cooldown and measured throughput. These come from a live session; with no session they
stay empty rather than showing invented numbers.

## Build

### Requirements

| Component | Version |
| :--- | :--- |
| Flutter OHOS SDK | **3.44.9** (Dart 3.12.2) |
| DevEco Studio | **26.0** |
| HarmonyOS SDK | API **26** (compileSdk 26.0.0.105) |
| Node.js / ohpm / hvigor | Bundled with DevEco Studio |

Flutter must be the HarmonyOS branch:
<https://gitcode.com/CPF-Flutter/flutter_flutter/tree/oh-3.44.9-dev>

### Steps

```bash
flutter pub get

dart .vscode/build_env.dart

flutter build hap --release --no-codesign \
  --dart-define-from-file=.vscode/env.json
```

Output: `build/ohos/hap/entry-default-unsigned.hap`

Three pitfalls worth knowing:

1. **The project path must not contain spaces.** hvigor splits `--target_path` on spaces and
   `ohpm install` fails with `Invalid "--target_path" value`. A directory junction does not help:
   hvigor resolves the real path.
2. **gitcode.com git dependencies are flaky** (`RPC failed; curl 18`). Clone them locally and use an
   uncommitted `pubspec_overrides.yaml` if `flutter pub get` fails.
3. **Do not run `ohpm` from Git Bash** — it recurses through `ohpm.bat`
   (`BATCH RECURSION exceeds STACK limits`). Use PowerShell or cmd.

Full details: [docs/BUILD.md](docs/BUILD.md).

### Tests

```bash
flutter test test/thread_ripper   # BTR suite
flutter test                      # full suite
dart analyze lib test
```

## Sources

| Source | Role | Pinned revision | License |
| :--- | :--- | :--- | :--- |
| [dev4harmony/PiliPlus](https://github.com/dev4harmony/PiliPlus) | HarmonyOS baseline, app body | `a8431412` (`ohos`, `2.1.6.2-ohos-2`) | GPL-3.0 |
| [lemonteaau/PiliPlus](https://github.com/lemonteaau/PiliPlus) | Reference for integration shape (no wholesale merge) | `f368e92a` | GPL-3.0 |
| [MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) | Download and scheduling algorithms | `3e715f5f` (`2026.11.1.1`) | MIT |

The JS → Dart mapping, deliberate deviations from upstream and every threshold are documented in
[docs/BTR.md](docs/BTR.md).

## Known limitations

- **Unsigned**: the release HAP cannot be installed without signing it yourself.
- **No device validation**: this round only proves that dependencies resolve, the code analyses
  cleanly, tests pass and the HAP builds. Nothing was installed or played on a HarmonyOS device,
  so no performance numbers are claimed.
- Adaptive parameters (10 s probe, 60/90/180 s cooldowns, 60 % saturation share) come from upstream
  experience and have not been retuned per HarmonyOS device.
- BTR is only enabled on the DASH path (`data.dash != null`).
- Later commits of both upstreams are not tracked yet.

## License

Released under **GPL-3.0**, inherited from the PiliPlus OHOS branch. The BTR portion is MIT, which
may be combined into a GPL-3.0 work provided its notices are kept. See [LICENSE](LICENSE),
[docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md) and
[third_party/bilibili-thread-ripper/LICENSE](third_party/bilibili-thread-ripper/LICENSE).

## Credits

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) and its upstreams `orz12/PiliPalaX`, `guozhigq/pilipala`
- The [dev4harmony/PiliPlus](https://github.com/dev4harmony/PiliPlus) HarmonyOS team
- [MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) for the algorithms
- [lemonteaau/PiliPlus](https://github.com/lemonteaau/PiliPlus) for the BTR integration practice
- [ErBW_s](https://github.com/ErBWs) and everyone who worked on media_kit for HarmonyOS

## Disclaimer

For study and technical research only. Delete within 24 hours of downloading.
All APIs are collected from official endpoints; no cracking content is provided.

---

<sub>The app body comes from the GPL-3.0 PiliPlus OHOS branch. The upstream README is archived at
[docs/README.upstream.md](docs/README.upstream.md).</sub>
