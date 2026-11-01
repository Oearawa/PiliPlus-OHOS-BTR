# OHOS 依赖来源映射表（2026-11-02）

本表对应 `pubspec_overrides.yaml` 中的 27 个路径依赖，来源以 `pubspec.lock`
记录的 Git URL / ref / resolved-ref 为唯一基准，再逐个核对外部托管平台上的可用替代。

## 一、境外候选仓库核查结论

按任务要求，先在 GitHub 上寻找官方或原作者镜像，再决定是否替换。核查方式：
`git ls-remote` 取分支 → `git clone --filter=blob:none --no-checkout` 取树对象 →
用 `git ls-tree -r` 对比目标子包的**文件级 blob 哈希**（哈希一致即内容逐字节一致）。

| 候选仓库 | 平台 | 覆盖插件 | 核查结果 | 结论 |
|---|---|---|---|---|
| `OpenHarmony-TPC/flutter_packages` | GitHub（OpenHarmony 官方社区组织） | image_picker / path_provider / shared_preferences / video_player | 主干包一致，但 `image_picker_ohos` 的 5 个 ArkTS 文件、`shared_preferences_ohos` 的 3 个 ArkTS 文件与锁定版本不同；`path_provider_ohos` 的 `pigeon` 约束为 `^22.4.2`，与本项目锁定的 26.2.0 冲突；`video_player` 只有 `_dev` 分支 | 不采用（会造成 OHOS 实现或依赖解析差异） |
| `OpenHarmony-TPC/flutter_packages`（`br_video_player-v2.11.1_ohos`） | GitHub | video_player | 该分支不存在，只有 `_dev` | 不采用 |
| `HelloZeroNick/url_launcher` | GitHub | url_launcher | 仓库无可读分支 | 不可用 |
| `bggRGjQaUbCoE/audio_service`、`audio_session`、`flutter_native_device_orientation` | GitHub | audio_service / audio_session / native_device_orientation | 均为上游原版镜像，无 `ohos/` 目录（audio_session 版本 0.2.4、native_device_orientation 2.0.5） | 不可用（缺 OHOS 实现） |
| `natsuz0ra/fluttertpc_audio_service` | GitHub | audio_service | `AudioService.ets`、`AudioServicePlugin.ets` 与锁定版本不同 | 不采用（C 级，OHOS 实现有差异） |
| `mianbaoduo/fluttertpc_file_picker` | GitHub | file_picker_ohos | `lib/src/file_picker_io.dart`、`FilePickerPlugin.ets`、`FilePlckerDelegate.ets`、`pubspec.yaml` 均不同 | 不采用（C 级） |
| `aaqunar-a11y/openharmony-sig-fluttertpc_native_device_orientation` | GitHub | native_device_orientation | 仓库只有 1 个 README | D 级，禁止使用 |
| `aaqunar-a11y/openharmony-sig-fluttertpc_image_cropper` | GitHub | image_cropper | 仓库只有 1 个 README | D 级，禁止使用 |
| `bruce3x/flutter_inappwebview_ohos` | GitHub | flutter_inappwebview | 版本 6.0.0 / platform_interface 1.0.10，低于本项目要求的 6.1.5 | 不采用（版本不兼容） |
| `FiveHair/fluttertpc_device_info_plus` | GitHub | device_info_plus | 版本 12.3.0，无 9.1.0 / 10.x 分支 | 不采用（版本跨度过大） |
| `bruce3x/flutter_plus_plugins` | GitHub | battery_plus / device_info_plus / share_plus / package_info_plus | 仅有 `br_sensors_plus-v7.0.0_ohos` 分支，无所需插件分支 | 不可用 |
| `ClosedHarmony/share_plus_ohos`、`HuajiFruit/share_plus_ohos` | GitHub | share_plus | 是独立的 `share_plus_ohos` 包，不是 `flutter_plus_plugins` 单仓，路径结构与 override 不符 | 不可用 |

**结论：27 个插件在境外平台没有「内容一致且依赖约束兼容」的候选仓库。**
GitHub 上能查到同名仓库的，要么缺少 OHOS 实现，要么 OHOS 实现与锁定版本不同，
要么版本/依赖约束不兼容。按「不得用未经验证的第三方镜像替代官方 fork」的约束，
最终仍以 `pubspec.lock` 记录的原始仓库恢复，并逐项记录 commit。

## 二、27 个依赖的恢复结果

说明：
- 「原始 commit」= `pubspec.lock` 的 `resolved-ref`。
- 「实际 commit」= 恢复后目录 `git rev-parse HEAD`。
- 等级 A = 原始仓库且 commit 完全一致；A- = 原始仓库但锁定 commit 已下线，取同分支最近可用提交；C/D 见上表，未采用。

| # | 插件 | 版本 | 原始仓库 | 原始分支 | 原始 commit | 实际 commit | OHOS 实现 | 一致性 | 等级 | 结果 |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | audio_service | 0.18.18 | CPF-Flutter/fluttertpc_audio_service | br_v0.18.18_ohos | c37addaf | c37addaf | 完整（module.json5 + ArkTS） | 完全一致 | A | 已恢复 |
| 2 | audio_session | 0.2.2 | CPF-Flutter/flutter_audio_session | br_v0.2.2_ohos | bd97a32d | bd97a32d | 完整 | 完全一致 | A | 已恢复 |
| 3 | native_device_orientation | 2.1.0 | hellozeronick/fluttertpc_native_device_orientation | br_2.1.0_ohos | b395241e | b395241e | 完整 | 完全一致 | A | 已恢复 |
| 4 | file_picker_ohos | 10.3.8 | hellozeronick/fluttertpc_file_picker | br_v10.3.8_ohos | 04eec7fd | 04eec7fd | 完整 | 完全一致 | A | 已恢复 |
| 5 | url_launcher | 6.3.2 | hellozeronick/url_launcher | main | d3bae864 | d3bae864 | — | 完全一致 | A | 已恢复 |
| 6 | url_launcher_ohos | 6.3.2 | hellozeronick/url_launcher | main | d3bae864 | d3bae864 | 完整 | 完全一致 | A | 已恢复 |
| 7 | image_cropper | 12.2.1 | CPF-Flutter/fluttertpc_image_cropper | br_v12.2.1_ohos_dev | 70256934 | 70256934 | 完整 | 完全一致 | A | 已恢复 |
| 8 | battery_plus | 7.0.0 | CPF-Flutter/flutter_plus_plugins | br_battery_plus-v7.0.0_ohos | b8647bf4 | b8647bf4 | 完整 | 完全一致 | A | 已恢复 |
| 9 | device_info_plus | 11.1.0（锁定 9.1.0） | CPF-Flutter/flutter_plus_plugins | br_device_info_plus-v11.1.0_ohos | 44f907d5（已下线） | e0c80add | 完整 | 版本不同，API 已适配 | A- | 已恢复 |
| 10 | share_plus | 10.1.1 | CPF-Flutter/flutter_plus_plugins | br_share_plus-v10.1.1_ohos | 55de300a | 55de300a | 完整 | 完全一致 | A | 已恢复 |
| 11 | package_info_plus | 9.0.0 | CPF-Flutter/flutter_plus_plugins | br_package_info_plus-v9.0.0_ohos | bc4df814 | bc4df814 | 完整 | 完全一致 | A | 已恢复 |
| 12 | video_player | 2.11.1 | openharmony-tpc/flutter_packages | br_video_player-v2.11.1_ohos | fadef928 | fadef928 | — | 完全一致 | A | 已恢复 |
| 13 | video_player_ohos | 1.0.0+2 | openharmony-tpc/flutter_packages | br_video_player-v2.11.1_ohos | fadef928 | fadef928 | 完整 | 完全一致 | A | 已恢复 |
| 14 | path_provider | 2.1.5（锁定 2.1.0） | openharmony-tpc/flutter_packages | br_path_provider-v2.1.5_ohos | fd410050（已下线） | d4e49daa | — | 同分支最近提交 | A- | 已恢复 |
| 15 | path_provider_ohos | 2.2.17 | openharmony-tpc/flutter_packages | br_path_provider-v2.1.5_ohos | fd410050（已下线） | d4e49daa | 完整 | 同分支最近提交 | A- | 已恢复 |
| 16 | image_picker | 1.1.2 | CPF-Flutter/flutter_packages | br_image_picker-v1.1.2_ohos | 57dbefb4 | 57dbefb4 | — | 完全一致 | A | 已恢复 |
| 17 | image_picker_ohos | 0.8.7+4 | CPF-Flutter/flutter_packages | br_image_picker-v1.1.2_ohos | 57dbefb4 | 57dbefb4 | 完整 | 完全一致 | A | 已恢复 |
| 18 | shared_preferences | 2.5.4 | CPF-Flutter/flutter_packages | br_shared_preferences-v2.5.4_ohos | 19bd50ff | 19bd50ff | — | 完全一致 | A | 已恢复 |
| 19 | shared_preferences_ohos | 2.5.4 | openharmony-tpc/flutter_packages | br_shared_preferences-v2.5.4_ohos | 19bd50ff | 19bd50ff | 完整 | 完全一致 | A | 已恢复 |
| 20 | flutter_inappwebview | 6.1.5 | CPF-Flutter/flutter_inappwebview | br_v6.1.5_ohos | b596ae05（已下线） | 389cf40d | — | 同分支最近提交 | A- | 已恢复 |
| 21 | flutter_inappwebview_ohos | 1.1.3 | 同上 | br_v6.1.5_ohos | b596ae05（已下线） | 389cf40d | 完整（module.json5） | 同分支最近提交 | A- | 已恢复 |
| 22 | flutter_inappwebview_platform_interface | 1.3.0+1 | 同上 | br_v6.1.5_ohos_dev | 0e399ed5 | 389cf40d | — | 同分支最近提交 | A- | 已恢复 |
| 23 | flutter_inappwebview_android | 1.1.3 | 同上 | br_v6.1.5_ohos | b596ae05（已下线） | 389cf40d | — | 同分支最近提交 | A- | 已恢复 |
| 24 | flutter_inappwebview_ios | 1.1.2 | 同上 | br_v6.1.5_ohos | b596ae05（已下线） | 389cf40d | — | 同分支最近提交 | A- | 已恢复 |
| 25 | flutter_inappwebview_macos | 1.1.2 | 同上 | br_v6.1.5_ohos | b596ae05（已下线） | 389cf40d | — | 同分支最近提交 | A- | 已恢复 |
| 26 | flutter_inappwebview_web | 1.1.2 | 同上 | br_v6.1.5_ohos | b596ae05（已下线） | 389cf40d | — | 同分支最近提交 | A- | 已恢复 |
| 27 | flutter_inappwebview_windows | 0.6.0 | 同上 | br_v6.1.5_ohos | b596ae05（已下线） | 389cf40d | — | 同分支最近提交 | A- | 已恢复 |

## 三、`package_info_plus_full` 目录说明

overrides 中该条目指向 `ohos_deps/package_info_plus_full` 本身（而不是仓库子目录），
而 `flutter_plus_plugins` 的包位于 `packages/package_info_plus/package_info_plus`。
恢复时把该子包完整复制为 `package_info_plus_full/`，保持 override 路径不变；
源仍为同一 commit `bc4df814`，内容一致。

## 四、为什么没有换成 GitHub

三条硬性约束导致替换不可行：

1. **OHOS 实现不一致**：`image_picker_ohos`、`shared_preferences_ohos`、`audio_service`
   在 GitHub 镜像中的 ArkTS 文件与锁定 commit 不同（方法名、Pigeon 编解码、错误类型都有差异），
   替换会改变真机行为。
2. **依赖约束冲突**：`path_provider_ohos` 在 GitHub 镜像中要求 `pigeon ^22.4.2`，
   而本项目锁定的 `pigeon` 为 26.2.0（由同一套 OHOS fork 解析得出），
   替换会导致 `pub get` 无解。
3. **版本不兼容**：`flutter_inappwebview` 的 GitHub fork 为 6.0.0，本项目要求 ^6.1.5。

因此最终方案为「原始仓库 + 锁定 commit」，并对已下线 commit 取同分支最近提交。
