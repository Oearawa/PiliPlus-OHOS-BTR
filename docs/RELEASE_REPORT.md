# Release Report — PiliPlus OHOS BTR v0.2.0-beta.1

本文件记录 2026-11-04 的首页重设计与 Beta 发布，内容均为实际执行结果。

## 1. 仓库

| 项目 | 值 |
| :--- | :--- |
| 仓库地址 | <https://github.com/Oearawa/PiliPlus-OHOS-BTR> |
| 可见性 | Public |
| 默认分支 | `main` |
| 发布提交（tag 指向） | `56137171323cffb2d9ebbf14d83a5b9bca1b8273` |
| 发布时工作分支 | `maintenance/upstream-sync-2026-11-01`（快进推送到 `main`，未强推） |
| 远端 | `btr` → 本仓库；`origin` 仍指向 `dev4harmony/PiliPlus`，本轮**未推送任何内容到 origin** |

## 2. README 修改内容

`README.md` 从「上游 README + 追加说明」改为独立项目首页：

- **头部**：Logo、项目名、一句话定位、6 个相关徽章（HarmonyOS / Flutter / Dart / BTR / License / Release），
  不再堆砌无关徽章。
- **下载区**：版本、发布日期、产物、大小、签名状态、直达资产链接、SHA-256。
- **这是什么**：说明与 `dev4harmony/PiliPlus` 的关系，以及 BTR 从浏览器脚本改为
  本地 127.0.0.1 Range 端点的原因。
- **功能**：拆成「继承自 PiliPlus 鸿蒙分支」与「BTR 下载增强」两块，
  后者用表格逐项给出实现文件与作用，并附 4 条边界规则（默认关闭、冷却、排除的源类型、回退直连）。
- **本次版本**：只列本轮真实完成的同步与移植内容。
- **截图**：4 张，明确标注为「继承自上游的 iOS 端界面预览，不是鸿蒙实机截图」，避免误导。
- **安装**：未签名 HAP 的签名与安装步骤。
- **使用 BTR**：设置路径与各开关默认值表。
- **编译**：工具链版本、三条命令、环境变量，以及三个真实踩过的坑（路径含空格、gitcode 依赖、Git Bash 调 ohpm）。
- **来源与版本**：三来源当前基线与许可证。
- **已知限制 / 许可证 / 致谢 / 免责声明**。

`docs/` 变更：

| 文件 | 状态 |
| :--- | :--- |
| `docs/BUILD.md` | 新增：工具链、环境变量、构建命令、依赖恢复、产物校验 |
| `docs/README.upstream.md` | 新增：原根目录里继承的上游 README 原样归档 |
| `docs/RELEASE_REPORT.md` | 新增：本文件 |

## 3. 中英文文档状态

| 文件 | 状态 |
| :--- | :--- |
| `README.md` | 已重写，与本次发布一致 |
| `README.en.md` | 已重写，章节结构与中文版一一对应（下载、功能表、截图、安装、BTR 开关、编译、来源、限制、许可） |

两版均指向同一份 HAP 资产与同一个 SHA-256，未出现版本漂移。

## 4. 本次 Release

| 项目 | 值 |
| :--- | :--- |
| 版本 | `v0.2.0-beta.1` |
| 标题 | `PiliPlus OHOS BTR v0.2.0-beta.1` |
| 类型 | GitHub **Prerelease**（非 draft） |
| 日期 | 2026-11-04 |
| Release 页面 | <https://github.com/Oearawa/PiliPlus-OHOS-BTR/releases/tag/v0.2.0-beta.1> |
| Tag 指向 | `56137171323cffb2d9ebbf14d83a5b9bca1b8273` |
| HAP 构建提交 | `ac8d5c332ed0602d26957fda09d4f58a22e71a73`（tag 的父提交，差异仅 README 校验值） |

上一版 `v0.1.0-beta.1` 未改动、未覆盖，仍可访问。

## 5. 产物

| 项目 | 值 |
| :--- | :--- |
| 文件名 | `PiliPlus-OHOS-BTR-v0.2.0-beta.1-unsigned.hap` |
| 大小 | 31,427,949 字节（29.97 MiB） |
| SHA-256 | `6d0076258db5e8f01b909da547beffab1e378b41ea9f757ad5c1234a31ee9c57` |
| 签名 | **未签名**（包内无 `.p7b`/`.p7s`） |
| bundleName | `com.example.piliplus` |
| 打包版本 | `versionName 2.1.6` / `versionCode 6352` |
| 应用内版本 | `0.2.0-beta.1`（`libapp.so` 内可检索到，同时含构建提交 `ac8d5c332`） |
| API | min `60002022` / target `260000026`，compileSdk `26.0.0.105` |
| 设备类型 | phone、tablet、2in1 |
| 下载地址 | <https://github.com/Oearawa/PiliPlus-OHOS-BTR/releases/download/v0.2.0-beta.1/PiliPlus-OHOS-BTR-v0.2.0-beta.1-unsigned.hap> |
| 校验文件 | <https://github.com/Oearawa/PiliPlus-OHOS-BTR/releases/download/v0.2.0-beta.1/SHA256SUMS.txt> |

发布后已从 GitHub 下载该资产并用 `sha256sum -c` 复核：**OK**；资产链接 HEAD 请求返回 **200**。

### 关于「本地已有的旧产物」

工作区内另有一份 11-02 构建的 HAP（`6f1fc5d7…`，31,427,980 字节），内嵌版本为
`0.1.0-beta.1`、构建提交 `8e7c1b5`。该版本号已被 `v0.1.0-beta.1` 占用，
若直接发布会出现「Release 是 0.2.0、应用内显示 0.1.0」的不一致。
因此本轮以当前 HEAD 重新构建，并把 `build_env.dart` 的版本标签一并升到 `0.2.0-beta.1`，
使 HAP 内部版本与新 Release 对齐。旧 HAP **未上传**到任何 Release。

## 6. 提交记录（本轮）

| 提交 | 内容 |
| :--- | :--- |
| `e3a3342b3` | 清理两处未使用导入；同步 `GeneratedPluginRegistrant` 的插件类名 |
| `ac8d5c332` | 重写中英文首页、新增 `docs/BUILD.md` 与 `docs/README.upstream.md`、版本标签升到 `0.2.0-beta.1` |
| `561371713` | 填入 HAP 大小与 SHA-256，下载链接指向实际资产 |
| 本文件所在提交 | 新增 `docs/RELEASE_REPORT.md`（发布完成后补入，不改变 tag 指向的代码） |

## 7. 实际完成的测试与构建

| 项目 | 命令 | 结果 |
| :--- | :--- | :--- |
| BTR 专项 | `flutter test test/thread_ripper` | 133 项通过，0 失败 |
| 全量测试 | `flutter test` | 174 项通过，0 失败 |
| 静态分析 | `dart analyze lib test` | 0 error，2 warning，223 info |
| 格式 | `dart format` | 未重跑全量格式化（本轮未改 Dart 业务代码，仅删两处导入） |
| HAP 构建 | `flutter build hap --release --no-codesign --no-pub` | 成功，产物 31,427,949 字节 |
| 资产复核 | 下载后用 `sha256sum -c` | OK |
| 下载链接 | `curl -I` 资产地址 | HTTP 200 |

2 条 warning 的位置：`lib/pages/main/controller.dart:186`，
`dead_code` 与 `dead_null_aware_expression`，原因是本地补丁后的 `device_info_plus`
使 `ohosInfo.sdkApiVersion` 变为非空，`?? 0` 成为死代码。属依赖侧问题，本轮未改动该文件。

## 8. 未完成的验证

- **未签名**，未做安装验证；Release 中的 HAP 需自行签名。
- **未在鸿蒙真机运行**：没有验证安装、启动、播放、拖动、切集、切清晰度下 BTR 的行为。
- **无性能数据**：没有真机带宽/功耗对比，README 与 Release Notes 均未给出提速百分比。
- 未验证 HDR、超分辨率、投屏等组合场景与 BTR 的相互影响。
- 未验证从 `v0.1.0-beta.1` 覆盖升级的实机路径（两者包名与 versionCode 递增，理论上可覆盖）。

## 9. 执行约束核对

- 未修改 `dev4harmony/PiliPlus` 与 `MrTangLuyao/Bilibili-thread-ripper` 任何内容。
- 未向 `dev4harmony/PiliPlus` 推送；`origin/ohos` 仍为 `0aba2c6d` 之前的状态，仅做过 fetch。
- 未删除任何已有 Tag / Release；未覆盖 `v0.1.0-beta.1`。
- 未强推，`main` 为快进更新（`068a52f0..5613717`）。
- 未修改 BTR 核心逻辑（`lib/services/thread_ripper/` 本轮零改动）。
- 未上传日志、缓存、调试文件或旧版 HAP。
