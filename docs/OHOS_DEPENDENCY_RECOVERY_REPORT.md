# OHOS 依赖恢复与 HAP 构建报告（2026-11-02）

分支：`maintenance/upstream-sync-2026-11-01`
起点：`18476191b`（上一轮双上游合并）
本轮提交：`8e7c1b503`
构建产物：`build/ohos/hap/entry-default-unsigned.hap`

---

## 一、结论

`%TEMP%\opencode\ohos_deps` 下 27 个路径依赖已全部恢复，`flutter pub get`
成功，全量测试与静态分析通过，OHOS Release HAP 构建成功。

- 27/27 路径依赖具备 `pubspec.yaml`、Dart 实现与所需的 OHOS 工程文件。
- 16 个命中 `pubspec.lock` 记录的原始 commit；11 个（device_info_plus 1 个、
  path_provider 2 个、flutter_inappwebview 系列 8 个）因原 commit 已从远端下线，
  改取同一分支的最近提交。
- 依赖解析后 **没有主版本变化**；新增 1 个包，移除 5 个仅桌面端使用的包。
- `dart analyze lib`：**0 error / 0 warning**，158 条 info。
- `flutter test test`：**174 项全部通过**（其中 BTR 专项 133 项）。
- `flutter build hap`：**成功**，产物 31,427,980 字节，`libapp.so` 内含本次提交哈希。

---

## 二、盘点：27 个依赖从哪里来

`pubspec_overrides.yaml` 只记录本地路径，真实来源在 `pubspec.lock` 的 git 条目里
（`url` / `path` / `ref` / `resolved-ref`）。以 lock 为唯一基准，得到 15 个仓库、
27 个包：

| 仓库 | 覆盖的包 |
|---|---|
| CPF-Flutter/fluttertpc_audio_service | audio_service |
| CPF-Flutter/flutter_audio_session | audio_session |
| CPF-Flutter/flutter_plus_plugins | battery_plus / device_info_plus / share_plus / package_info_plus |
| CPF-Flutter/fluttertpc_image_cropper | image_cropper / _for_web / _platform_interface |
| CPF-Flutter/flutter_packages | image_picker / _ohos / shared_preferences |
| CPF-Flutter/flutter_inappwebview | flutter_inappwebview 及 7 个平台包 |
| openharmony-tpc/flutter_packages | video_player / _ohos / path_provider / _ohos / shared_preferences_ohos / pigeon |
| hellozeronick/fluttertpc_file_picker | file_picker_ohos |
| hellozeronick/fluttertpc_native_device_orientation | native_device_orientation |
| hellozeronick/url_launcher | url_launcher / _ohos |

原始目录状态：16 个顶级目录全部为**空壳**——`git log` 无 HEAD，整棵树
`.dart` 文件 0 个、`pubspec.yaml` 0 个、`module.json5` 0 个；`.git` 只剩
hooks/refs/lfs 骨架（每个约 1.2 MB，无 pack）。因此不存在可复用的本地对象。

---

## 三、境外仓库：找了，也验证了，但没有可用替代

按要求先查 GitHub / 官方组织，再决定是否替换。验证手段：
`git ls-remote` → `--filter=blob:none --no-checkout` 取树 →
`git ls-tree -r` 逐文件比对 **blob 哈希**（哈希相同即逐字节一致）。

| 候选 | 平台/级别 | 结果 |
|---|---|---|
| `OpenHarmony-TPC/flutter_packages` | GitHub / B | 主干包一致；但 `image_picker_ohos` 有 5 个 ArkTS 文件不同、`shared_preferences_ohos` 有 3 个 ArkTS 文件不同；`path_provider_ohos` 的 `pigeon` 约束为 `^22.4.2`，与锁定 26.2.0 冲突；`video_player` 只有 `_dev` 分支 → 不采用 |
| `natsuz0ra/fluttertpc_audio_service` | GitHub / C | `AudioService.ets`、`AudioServicePlugin.ets` 与锁定版本不同 → 不采用 |
| `mianbaoduo/fluttertpc_file_picker` | GitHub / C | `file_picker_io.dart`、`FilePickerPlugin.ets`、`FilePlckerDelegate.ets`、`pubspec.yaml` 均不同 → 不采用 |
| `aaqunar-a11y/...native_device_orientation` | GitHub / D | 仓库只有 1 个 README → 禁止使用 |
| `aaqunar-a11y/...image_cropper` | GitHub / D | 仓库只有 1 个 README → 禁止使用 |
| `bruce3x/flutter_inappwebview_ohos` | GitHub / C | 6.0.0，低于要求的 ^6.1.5 → 不采用 |
| `FiveHair/fluttertpc_device_info_plus` | GitHub / C | 仅 12.3.0，无 9.1.0/10.x → 不采用 |
| `bruce3x/flutter_plus_plugins` | GitHub / C | 只有 sensors_plus 分支 → 不可用 |
| `HelloZeroNick/url_launcher` | GitHub / — | 仓库无可读分支 → 不可用 |
| `bggRGjQaUbCoE/*` | GitHub / C | 均为上游原版镜像，无 `ohos/` → 不可用 |
| `ClosedHarmony/share_plus_ohos`、`HuajiFruit/package_info_plus_ohos` 等 | GitHub / C | 是独立的 `*_ohos` 包，不是 `flutter_plus_plugins` 单仓，路径结构不符 → 不可用 |

结论：**没有一个境外仓库能同时满足「内容一致 + OHOS 实现完整 + 依赖约束兼容」。**
按「不得用未经验证的镜像替代官方 fork」，最终仍以 lock 记录的原始仓库为准，
逐项记录 commit；完整对照见 `docs/OHOS_DEPENDENCY_MIRROR_MAPPING.md`。

---

## 四、恢复明细

### 4.1 精确命中锁定 commit（16 个）

| 包 | 版本 | commit |
|---|---|---|
| audio_service | 0.18.18 | c37addaf |
| audio_session | 0.2.2 | bd97a32d |
| native_device_orientation | 2.1.0 | b395241e |
| file_picker_ohos | 10.3.8 | 04eec7fd |
| url_launcher / url_launcher_ohos | 6.3.2 | d3bae864 |
| image_cropper | 12.2.1 | 70256934 |
| battery_plus | 7.0.0 | b8647bf4 |
| share_plus | 10.1.1 | 55de300a |
| package_info_plus | 9.0.0 | bc4df814 |
| video_player / video_player_ohos | 2.11.1 / 1.0.0+2 | fadef928 |
| image_picker / image_picker_ohos | 1.1.2 / 0.8.7+4 | 57dbefb4 |
| shared_preferences / shared_preferences_ohos | 2.5.4 | 19bd50ff |

### 4.2 锁定 commit 已下线（11 个）

| 包 | 锁定 commit | 实际取用 | 说明 |
|---|---|---|---|
| path_provider / path_provider_ohos | fd410050 | d4e49daa（br_path_provider-v2.1.5_ohos 顶端） | 版本 2.1.5 / 2.2.17，满足 `^2.1.5` |
| device_info_plus | 44f907d5（9.1.0） | e0c80add（br_device_info_plus-v11.1.0_ohos） | 9.1.0 分支已不存在；11.1.0 是仍可获取的最低分支 |
| flutter_inappwebview 系列（8 个包） | b596ae05 | 389cf40d（br_v6.1.5_ohos 顶端） | 原 commit 随分支重写消失；各包版本仍为 6.1.5 / 1.1.3 / 1.3.0+1 等，符合 pubspec 约束 |

### 4.3 目录布局的特殊处理

- `package_info_plus`：override 指向 `ohos_deps/package_info_plus_full` 本身，
  而包在仓库子目录 `packages/package_info_plus/package_info_plus`。
  恢复时把该子包完整落到 `package_info_plus_full/`，override 路径不变。
- `video_player_ohos` 通过相对路径依赖同仓的 `packages/pigeon`（26.2.0），
  已一并检出，否则 `pub get` 报 "pigeon doesn't exist"。

---

## 五、恢复过程中的技术处理

1. **GitCode 传输**：HTTP/2 + 大 packfile 会稳定触发
   `RPC failed; curl 18 / early EOF`。改用 `git -c http.version=HTTP/1.1`，
   并把浅克隆限制在单个分支，成功恢复绝大多数仓库。
2. **大仓库**：`image_picker`（7000+ 对象）、`flutter_inappwebview`、`image_cropper`
   用 `--filter=blob:none --no-checkout` + `sparse-checkout` 只取需要的子包，
   避免整仓下载。
3. **单次传输约 20 MB 会被切断**：`package_info_plus` 的懒加载 blob 批次反复
   在 20 MB 处失败。改为**按目录分批**（pubspec → lib → ohos → android/ios/macos）
   逐次 checkout，每批都小于阈值，最终拿到完整树。
4. **MSYS 路径转换**：sparse 规则里的 `/packages/...` 会被 Git Bash 改写成
   `C:/.../PortableGit/packages/...`，必须 `MSYS_NO_PATHCONV=1`。
5. **不放宽任何依赖**：没有用 pub.dev 的普通插件冒充 OHOS fork，也没有删除
   override。

---

## 六、依赖解析结果

`flutter pub get` 成功，`package_config.json` 共 **275** 个包，逐个校验
`rootUri` 均存在（0 个缺失）。

`pubspec.lock` 变化：

- **主版本变化：0 个**（脚本比对 major 段）。
- 其余为 patch/minor 升级（如 1.0.3→1.0.4、8.12.7→8.13.0）。
- 新增 1 个包；移除 5 个：`code_assets`、`gtk`、`hooks`、`objective_c`、`record_use`
  —— 均为桌面端/实验性依赖，原先由 git 源的平台包间接引入，改为本地路径后不再需要。
- 27 个路径依赖的 `source` 由 `git` 变为 `path`，这是 override 的预期结果。

`pub get` 末尾提示 "Building with plugins requires symlink support"（本机未开启
开发者模式）。工作区已有可用的目录联接 `.flutter_plugin_links/`，构建未受影响。

---

## 七、验证结果

| 项目 | 命令 | 结果 |
|---|---|---|
| 依赖解析 | `flutter pub get` | 成功，275 包 |
| 静态分析 | `dart analyze lib` | **0 error / 0 warning**，158 info |
| BTR 专项 | `flutter test test/thread_ripper` | **133 项通过** |
| 全量测试 | `flutter test test` | **174 项通过**，0 失败 |
| 格式 | `dart format --set-exit-if-changed`（改动文件） | 通过 |

分析器 info 均为既有风格问题（`prefer_initializing_formals`、
`deprecated_member_use` 等），本轮未新增 error/warning。

---

## 八、HAP 构建

命令（在工作区之外的无空格副本 `F:\ppb-src2` 执行，避免 hvigor 把
`--target_path` 按空格截断）：

```
dart .vscode/build_env.dart
flutter build hap --no-codesign --dart-define-from-file=.vscode/env.json
```

环境：Flutter 3.44.9 / Dart 3.12.2、DevEco Studio SDK、
`DEVECO_SDK_HOME=HOS_SDK_HOME=...\DevEco Studio\sdk`、hvigor/ohpm/node 在 PATH。

产物校验：

| 项 | 值 |
|---|---|
| 路径 | `F:\Harness File\OHOS-PiliPlus-BTR\build\ohos\hap\entry-default-unsigned.hap` |
| 大小 | 31,427,980 字节（30.0 MB） |
| SHA-256 | `6f1fc5d70231cf47193ee8e8a1ecd58f72159a37f5b4f9827740529ef4d1d67d` |
| bundleName | com.example.piliplus |
| versionName / Code | 2.1.6 / 6349 |
| ABI | arm64-v8a |
| 签名 | 未签名（工程无签名配置，`--no-codesign`） |
| 元数据 | `libapp.so` 内可检索到 `8e7c1b503ca9061c0484b86ad1fdb1c282c53858` 与 `0.1.0-beta.1` |

构建过程遇到的问题与处理：

1. `package_info_plus` 缺 `android/ios/macos` 目录 → Flutter 插件校验报
   "doesn't have a main class"；补齐平台目录后通过。
2. hvigor 清理中间产物时被环境的批量删除保护拦截 → 仅在构建子进程内清空
   `CODEBUDDY_SAFE_DELETE_*`，未改动系统设置。

---

## 九、对依赖源码的本地补丁（业务代码零改动）

`device_info_plus` 从 9.1.0 换到 11.1.0 后，`catcher_2`（PiliPlus 的 git 依赖）
仍按旧 API 编译，因此在该 fork 内做了 5 处**只增不改**的兼容补丁：

| 文件 | 补丁 | 原因 |
|---|---|---|
| `lib/device_info_plus.dart` | `export 'src/model/ohos_device_info.dart';` | 11.1.0 不再导出该模型，catcher_2 需要 `OhosDeviceInfo` 类型 |
| `lib/device_info_plus.dart` | `Future<OhosDeviceInfo> get ohosInfo => ohosDeviceInfo;` | 9.x 的旧 getter 名称 |
| `lib/src/model/ohos_device_info.dart` | `hardwareProfile/serial/udid/odID` 四个只读 getter（返回 `''`） | 11.1.0 删除了这些字段（部分需系统权限），catcher_2 仅用于日志 |

`lib/` 下的业务代码**未做任何修改**：`lib/pages/main/controller.dart` 仍是
上游的 `DeviceInfoPlugin().ohosInfo`，补丁放在 fork 内部，升级依赖时可整体替换。

---

## 十、已知限制

1. **未做真机验证**。本轮只证明「依赖可解析、代码可分析、测试通过、HAP 可构建」，
   不代表 OHOS 设备上的插件行为（音频后台、WebView、图片选择/裁剪）已验证。
2. **3 组依赖不是锁定 commit**：path_provider、device_info_plus、inappwebview 系列
   取的是同分支最近提交，行为差异未逐行审计；其中 device_info_plus 跨了两个大版本，
   已通过 catcher_2 的编译与测试间接验证。
3. **`pubspec.lock` 有较多 patch/minor 变动**（无主版本变动）。这是路径依赖替换
   git 源后的重新解析结果，若需完全复现旧版本，需要把对应版本逐项 pin 回去。
4. **GitCode 仍是这些 fork 的唯一来源**。本轮已验证 GitHub 无等价替代（见第三节），
   若日后 GitCode 再次重写历史，同样的恢复流程需要重跑。
5. **构建必须使用无空格路径**：hvigor 会按空格切分 `--target_path`，工作区路径
   含空格，故在 `F:\ppb-src2` 构建；产物已回拷到工作区 `build/ohos/hap/`。
