# BTR 在鸿蒙播放链路中的适配说明

本文说明 [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)（下称 BTR）
的算法如何落到本项目的实际播放链路里。上游版本：`2026.10.19.2`，提交
`ee3adaa8cc1afbb29a3d7153e1295e09e42b29e2`，MIT。

## 1. 为什么不能直接用

BTR 是一个油猴脚本。它工作在两个前提下：

1. 浏览器里有 `fetch` / `XMLHttpRequest`，脚本可以替换它们来接管字节流；
2. 页面播放器用 MSE 播分片，脚本能把 `SourceBuffer` 的写入时机握在手里。

鸿蒙版没有这两个前提：播放器是 `media_kit` 里的 mpv，它直接对 URL 发 Range 请求，
既没有 JS 运行时可以劫持，也没有 MSE 可以接管。因此**不能**把脚本逻辑照搬过来。

## 2. 采用的形态：本地回环 Range 端点

```
mpv ──Range──▶ http://127.0.0.1:<随机端口>/<token>/0
                        │
                        ├─ 校验 Range / 探测总长
                        ├─ 拆分区间 → RipperSemaphore 限流 → 多连接并发
                        ├─ 206 + Content-Range 严格校验 → 按序拼接
                        └─ 边下边写回 mpv
```

- 只绑定 `127.0.0.1`，路径带随机 token，外部无法访问也无法猜。
- mpv 收到的是普通 HTTP 媒体地址，不需要任何播放器改动。
- 一个会话两条轨道（视频、音频），各自一个路径；共用同一个连接预算。
- 会话失败时上游 URL 仍然保留，播放器回退直连。

## 3. 文件对应关系

| 上游（JS） | 本项目（Dart） | 说明 |
|---|---|---|
| `src/range-core.js` | `lib/services/thread_ripper/range_core.dart` | Range/Content-Range 解析、区间拆分、拼接、URL 白名单 |
| `src/idm-downloader.js` | `lib/services/thread_ripper/idm_downloader.dart` | 分片调度、`RipperSemaphore`、hedge、轮次重试、单飞 |
| `src/cdn-resolver.js` | `lib/services/thread_ripper/cdn_resolver.dart` | 区域节点展开、relay 地址保护、签名 URL 换 host |
| `src/settings-panel.js` / 控制器 | `lib/services/thread_ripper/auto_concurrency.dart` | 自适应并发状态机 |
| `src/native-range-transport.js` | `lib/services/thread_ripper/range_proxy.dart` | 回环 HTTP 服务端 |
| （脚本无对应） | `lib/services/thread_ripper/player_bridge.dart` | 播放器生命周期、会话 generation |
| （脚本无对应） | `lib/services/thread_ripper/prefs.dart` | 设置持久化与旧值迁移 |
| （脚本无对应） | `lib/services/thread_ripper/media_demand.dart` | 由码率/分辨率/HDR 推初始档位 |

## 4. 播放链路接入点

1. `VideoDetailController` 在拿到 `PlayUrlModel` 后判断是否允许 BTR：
   `data.dash != null`，且 PGC 需要满足 `episodeEnabled && !isDrm && !isPreview`。
2. 允许时把 `firstVideo.playUrls`（主地址 + 备用节点）与当前音轨地址放进 `NetworkSource`。
3. `PLPlayerController._createVideoController` 在 `player.open()` 之前调用
   `RipperPlayerBridge.open()`；成功则把 video / audio 换成回环 URL，失败则保持原 URL。
4. 播放过程中把 buffering、position、buffer 反馈给 `AutoConcurrency`；
   seek / 换源会重置启动试探窗口，但保留同一个代理会话。
5. 切集、切清晰度、退出页面调用 `close()`，generation 自增，旧请求被 abort。

## 5. 与上游的刻意差异

| 项目 | 上游 | 本项目 | 原因 |
|---|---|---|---|
| 传输方式 | 替换 fetch / XHR | 回环 HTTP 端点 | 原生播放器没有 JS 可劫持 |
| 全接管节流 | 让 B 站内核以为缓冲已满 | 未实现 | 原生播放器不存在第二个下载内核 |
| 区间拆分 | 小于最小片时保持整段 | 仍按请求并发拆分 | 本项目的短片只出现在探测与小尾巴 |
| 首字节超时 | 统一 5.5 s | 5.5 s，且与传输卡顿分开上报 | 便于区分“连不上”和“节点慢” |
| 升档判定 | 缓冲 + 吞吐 | 追加 activity 门控与饱和占比 | 避免无数据到达时误判为连接不足 |
| 冷却 | 412/429 长冷却 | 412/429 180 s；首字节超时 90 s | 两类故障的恢复时间不同 |

## 6. 关键参数（代码中的实际值）

| 参数 | 值 | 位置 |
|---|---|---|
| 并发阶梯 | 4 / 8 / 12 / 16 / 24 / 32 / 48 / 64 | `AutoConcurrency.ladder` |
| 最小分片 | 64 KiB | `RipperSettings.minChunkBytes` |
| 单区窗口 | 4 MiB | `range_proxy.dart` `defaultWindowBytes` |
| 首字节超时 | 5.5 s | `RipperSettings.firstByteTimeout` |
| 传输卡顿阈值 | 4 s | `RipperSettings.stallTimeout` |
| 单次尝试上限 | 15 s | `RipperSettings.attemptTimeout` |
| hedge 延迟 | 900 ms | `RipperSettings.hedgeDelay` |
| 重试轮次 | 3 | `RipperSettings.maxRounds` |
| 试探窗口 | 10 s | `AutoConcurrency.trialMs` |
| 退档冷却 | 90 s | `AutoConcurrency.restMs` |
| 412/429 冷却 | 180 s | `AutoConcurrency.pushbackRestMs` |
| 饱和判定 | active ≥ limit 且 queued > 0，占比 ≥ 60% | `AutoConcurrency.saturatedShare` |
| activity 有效窗 | 1.5 s | `AutoConcurrency.activityMs` |

## 7. 明确排除的输入

- 直播流、HLS、FLV：不进入 BTR。
- 本地文件播放：不进入 BTR。
- DRM 与试看集数：不进入 BTR。
- 非 http/https 候选地址：在 `RipperPlayerBridge._sanitize` 中被过滤。
- 非 B 站媒体域名的地址：不做 CDN 节点替换（避免把签名地址发给陌生主机）。
