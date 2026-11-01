# 上游同步与 BTR 更新报告（2026-11-01）

## 一、上游信息

| 项目 | 仓库 | 分支 | 更新前 | 更新后 | 时间 |
| --- | --- | --- | --- | --- | --- |
| PiliPlus 鸿蒙 | dev4harmony/PiliPlus | `ohos` | `0aba2c6d`（与本地分叉的共同祖先） | `a84314126`（`Release 2.1.6.2-ohos-2`） | 2026-11-01 17:51 +0800 |
| BTR | MrTangLuyao/Bilibili-thread-ripper | `main` | `ee3adaa8`（上次审计基线，2026-10-19） | `3e715f5f`（`canary 2026.11.1.1`） | 2026-11-01 07:44 +0800 |
| 本地项目 | — | `ohos` | `068a52f06` | 见文末 | — |

- 实际合并范围：`0aba2c6d..a84314126`，共 9 个上游提交。
- 本地分叉自 `0aba2c6d` 起有 5 个本地提交（BTR 融合、README、构建标签等）。
- 拉取方式：`git fetch origin ohos`（GitHub 官方仓库），未使用任何 GitCode 镜像。

## 二、更新内容

### 2.1 PiliPlus 上游（已合并）

| 上游提交 | 内容 | 处理 |
| --- | --- | --- |
| `8ce6cad5d` | file_picker 改为仓库内封装，移除 `_ohos` 后缀 | 采纳；`packages/file_picker` 随合并进入仓库，其依赖 `file_picker_ohos` 仍指向本地路径（见 2.3） |
| `e8c9c7f20` `e42d1baf7` `de4d46df3` `3d982179c` `e9b1e7672` | 自由窗口自绘标题栏、PC 窗口接续、安全区去重、一镜到底返回动画、顶栏模糊 | 采纳；新增 `lib/harmony/window/{window_facts,window_bridge,system_bars,title_bar_color,content_fullscreen}.dart` 与 `ohos/entry/src/main/ets/window/*` |
| `41a74d172` | 分身应用下载路径修复 | 采纳 |
| `162cf35a0` | media_kit 适配胶水移入 media-kit 包 | **本地兼容处理**，见 2.3 |
| `a84314126` | 版本号 2.1.6+6334 | 采纳（`version`），应用内标签仍走本线 `0.1.0-beta.1` |

合并冲突：仅 `.vscode/build_env.dart` 一处（版本标签），保留本地 `0.1.0-beta.1` 并注明已并入上游 `2.1.6.2-ohos-2`。

### 2.2 BTR 上游（已移植到 Dart）

对照 `ee3adaa8..3e715f5f` 的 `src/idm-downloader.js`（+112 行）、`src/cdn-resolver.js`（+20）、`src/range-core.js`（+17）：

| 上游机制 | 本地实现 | 说明 |
| --- | --- | --- |
| `adaptiveMinChunk` 动态子块 | `adaptiveChunkBytes()` / `IdmDownloader.adaptiveChunkFor()` | 目标 ≈ 单连接 0.6 秒的字节数，按 64 KiB 取整，范围 64 KiB–1 MiB，且不超过 `range/并发`；速度未知时退回配置下限 |
| `meter`（连接速率/分块耗时 EWMA） | `_connectionBps` / `_pieceMs`，每完成一份拷贝按 0.7/0.3 更新 | 供子块与 hedge 使用，诊断可读 |
| `hedgeDelayMs` 自适应 | `adaptiveHedgeDelayMs()` | `min(配置值, 分块耗时×1.5)`，下限 250 ms；开播阶段仍为 0 |
| `keepProgress` 断点续传 | `RipperPartialException` + `_downloadPiece` 前缀保留 | 卡顿后只请求剩余字节并与已验证前缀拼接；前缀 < 32 KiB 或已满则丢弃 |
| `Semaphore.acquire` 重复通知 | 删除多余的 `onChange`（`_drain` 已上报） | 与上游一致 |

未移植（并说明原因）：

- **播放截止时间 hedge / 备用请求预算**：需要播放器的可信截止时间，media_kit 未提供等价信号，盲目移植会制造无效连接。
- **`bufferAheadSeconds`、`secondaryBuffer`**：MSE 全接管架构专用；本项目用固定 4 MiB 窗口 + 播放器缓存，语义不同。
- **`blockInternational`、`guideDone`、悬浮按钮位置**：网页脚本/站点级设置，无对应原生入口。
- **URL 过期主动刷新（quota refresh）**：上游在页面内重新取 playurl；本项目要接 `VideoDetailController` 的取流链路，改动面大且缺乏可靠触发点，本轮未做，列为后续项。
- **直播模块、`native-mse-player.js`**：依赖 MSE/SourceBuffer，不适用于 media_kit。

### 2.3 鸿蒙兼容性处理（本地保留项）

1. **media_kit 适配层**：本地 media_kit fork 未提供 `Player.getProperty`、`MPV.setHeader`、`Char` 版 `name`，因此
   - 恢复 `lib/media_kit_adapt/media_kit_adapt.dart`，`mpv_convert_webp.dart` 继续用 `MediaKitAdapt.setPlayerHeader` 与 `prop.name.toDartString()`；
   - `header_control.dart` 继续经 `player.platform!.maybeAsNativePlayer.getProperty(...)` 读取 mpv 属性。
   这是 OHOS 适配层兼容，不是回退上游功能。
2. **file_picker**：采纳上游 `packages/file_picker` 封装；`pubspec_overrides.yaml`（本地文件，不入库）把 `file_picker` 指向 `packages/file_picker`、`file_picker_ohos` 指向本地依赖目录，避免解析时拉 GitCode。
3. `lib/plugin/pl_player/controller.dart` 合并后缺少 `window_facts.dart` 导入，已补齐（合并工具未自动加回）。
4. 其余鸿蒙依赖（material_ui / cupertino_ui shim、media_kit OHOS + HDR、path_provider/share_plus/image_picker 等 override、`ohos/` 构建配置、`.vscode` 任务）全部原样保留，未降级、未删除。

## 三、测试与验证

| 项目 | 更新前 | 更新后 |
| --- | --- | --- |
| BTR 单元测试 | 121 项通过 | **133 项通过，0 失败** |
| 应用其它测试（video_card / harmony / utils 等） | 41 项通过 | 本轮**无法运行**（依赖源码缺失，见第五节） |
| `dart analyze lib/services/thread_ripper` | 0 error / 0 warning | **0 error / 0 warning**（2 条 info） |
| `dart analyze lib`（全量） | 0 error | 238 error，**全部**为 `Target of URI doesn't exist` 类依赖缺失，无逻辑错误 |
| `dart format` 检查 | — | 4 个文件重排后通过 |

新增测试 12 项：

- `test/thread_ripper/adaptive_chunk_test.dart`（11 项）：子块下限/上限、0.6 秒目标、短区间按并发摊分、hedge 延迟钳制、分块数随子块增大而减少、前缀拼接顺序。
- `test/thread_ripper/download_safety_test.dart` +1：卡顿后从已验证前缀续传（断言第二次请求从 `32768` 开始，且整段字节完全一致）。

覆盖面（对照任务 B 节）：单节点单分块、多线程 Range、多 CDN 并发与分配、动态线程档位与 64 上限、412/429 回退、断点续传、失败分块补齐、重复数据控制（单飞）、节点失效恢复、旧任务取消、视频/音频数据完整性均有对应测试；**URL 过期刷新、真机播放、切换清晰度/分P 的运行时行为未验证**。

## 四、HAP 构建

**本轮未能产出新的 HAP。**

执行 `flutter build hap --no-pub --no-codesign`（Flutter 3.44.9 / Dart 3.12.2，DevEco 26.0，SDK 26）在 Flutter 任务之前即失败：

```
Parse ohos module.json5 error: Can not found module.json5 at
...\ohos_deps\audio_service\audio_service\ohos\src\main\module.json5
```

原因：本机 OHOS 依赖缓存 `%TEMP%\opencode\ohos_deps` 已被破坏（非本次改动造成）：

- `pubspec_overrides.yaml` 引用的 **27 个本地路径全部缺少 `pubspec.yaml`**；
- 整个依赖树中 **`.dart` 文件数为 0**（`lib/` 只剩目录骨架）；
- **`module.json5` 数为 0**（OHOS 插件元数据全丢）；
- 这些 fork 只托管在 GitCode；`flutter pub get` 克隆 `gitcode.com/CPF-Flutter/flutter_plus_plugins` 在 8 分钟内反复 `RPC failed; curl 18`，GitHub 上不存在同名镜像（`openharmony-sig/*`、`CPF-Flutter/*` 均 404，仅有零散第三方镜像且缺少所需分支）。

因此：`flutter pub get` 无法完成 → Dart 依赖缺失 → ArkTS 插件模块缺失。**没有**采用「把 OHOS 插件换成 pub.dev 版本」的做法，那会让 WebView、后台音频、图片裁剪等在鸿蒙上失去实现，属于破坏现有功能。

上一轮的产物仍在，但**不对应本次代码**：`F:\Harness File\OHOS-PiliPlus-BTR\build\ohos\hap\entry-default-unsigned.hap`（2026-10-21，31,379,746 B，sha256 `7a1f9b73…`）。

恢复构建所需的操作（需外部条件）：修复 `ohos_deps`（重新获取 27 个 OHOS fork 的完整源码），或让 GitCode 可稳定克隆后删除对应 path override 由 pub 拉取。

## 五、交付信息

- 备份分支：`backup/before-upstream-sync-2026-11-01`（`068a52f06`）
- 工作分支：`maintenance/upstream-sync-2026-11-01`
- 主要修改文件：
  - 合并进来的上游文件（`lib/harmony/window/*`、`ohos/entry/src/main/ets/window/*`、`packages/file_picker`、`lib/main.dart` 等，共 43 个文件，+2675/−873）
  - `lib/services/thread_ripper/idm_downloader.dart`：自适应子块、meter、自适应 hedge、断点续传
  - `lib/services/thread_ripper/settings_model.dart`（新增）：纯设置归一化，脱离 Hive 以便测试
  - `lib/services/thread_ripper/prefs.dart`：只保留 Hive 读写与迁移
  - `lib/services/thread_ripper/cdn_resolver.dart`：relay 判定注释与上游对齐
  - `lib/media_kit_adapt/media_kit_adapt.dart`（恢复）、`lib/plugin/pl_player/widgets/mpv_convert_webp.dart`、`lib/pages/video/widgets/header_control.dart`：OHOS 适配层兼容
  - `test/thread_ripper/adaptive_chunk_test.dart`（新增）、`download_safety_test.dart`、`prefs_migration_test.dart`
- HAP：**无**（见第四节）；未推送、未打 Tag、未创建 Release、未改 CI。

## 六、已知问题与后续

1. **依赖缓存修复是下一步前提**：否则无法解析、无法全量分析、无法构建。建议把 27 个 OHOS fork 固化到仓库外的稳定目录并纳入备份。
2. **未做真机验证**：上游新增的自由窗口标题栏/安全区改动、BTR 自适应子块与续传，只在单元测试层面验证。
3. **未移植项**：URL 过期刷新、播放截止时间 hedge、二级缓冲——需要先有可靠的播放器信号或取流回调。
4. **应用级测试缺口**：`test/video_card`、`test/harmony`、`test/utils` 本轮无法运行，恢复依赖后必须补跑。
5. `packages/file_picker` 依赖的 `file_picker_ohos` 仍是本地路径 override，属于环境特定配置，不应提交到仓库。
