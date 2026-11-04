# 构建指南

本文记录本项目当前可用的构建方式与踩过的坑。README 只保留最短路径，细节都在这里。

## 1. 工具链

| 组件 | 版本 | 说明 |
| :--- | :--- | :--- |
| Flutter OHOS SDK | 3.44.9（Dart 3.12.2） | 必须用鸿蒙分支，官方 Flutter 不带 `ohos` 设备 |
| DevEco Studio | 26.0 | 提供 hvigor、ohpm、node 与 HarmonyOS SDK |
| HarmonyOS SDK | API 26（compileSdk 26.0.0.105） | `compatibleSdkVersion 6.0.2(22)`，`targetSdkVersion 26.0.0` |

Flutter 鸿蒙分支：<https://gitcode.com/CPF-Flutter/flutter_flutter/tree/oh-3.44.9-dev>

## 2. 环境变量

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:HOS_SDK_HOME    = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:NODE_HOME       = 'C:\Program Files\Huawei\DevEco Studio\tools\node'
$env:PATH = 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin;' +
            'C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin;' +
            'C:\Program Files\Huawei\DevEco Studio\tools\node;' + $env:PATH
```

`DEVECO_SDK_HOME` 必须指向含 `default/` 的 `sdk` 目录，而不是 `sdk/default`。
`flutter doctor` 里 HarmonyOS toolchain 一栏应当显示 `Ohpm` 与 `Hvigorw` 都能找到。

## 3. 构建步骤

```bash
# 1. 依赖
flutter pub get

# 2. 注入版本、构建时间与提交哈希（写入 .vscode/env.json）
dart .vscode/build_env.dart

# 3. 构建未签名 HAP
flutter build hap --release --no-codesign \
  --dart-define-from-file=.vscode/env.json
```

产物固定落在：

```
build/ohos/hap/entry-default-unsigned.hap
```

工程没有配置签名（`ohos/build-profile.json5` 里 `signingConfigs: []`），所以必须带
`--no-codesign`；要安装到设备需自行配置证书后重新构建。

VS Code 用户可以直接跑 `.vscode/tasks.json` 里的 `build_hap` 任务，内容与上面三步一致。

## 4. 三个必须知道的坑

### 4.1 工程路径不能含空格

hvigor 会把 `--target_path` 按空格切分。路径含空格时 `ohpm install` 直接失败：

```
Error: 00633001 Target Path UnExist Error
Error Message: Invalid "--target_path" value, the filePath: "F:\Harness" does not exist.
```

- 把仓库放到无空格路径，或复制一份到无空格目录再构建。
- **目录联接（junction）无效**：hvigor 与 npm 会解析到真实路径，仍然报同样的错。
  必须做真实复制。

### 4.2 gitcode.com 依赖不稳定

`pubspec.yaml` 里有若干 OHOS 插件指向 `gitcode.com`。国内网络下经常中断：

```
error: RPC failed; curl 18 transfer closed with outstanding read data remaining
fatal: early EOF
```

处理方式：先把这些仓库克隆到本地（可以 `--filter=blob:none` + sparse 分批取），
再写一个**不提交**的 `pubspec_overrides.yaml` 指向本地路径：

```yaml
dependency_overrides:
  battery_plus:
    path: <local>/battery_plus/packages/battery_plus/battery_plus
  # ...
```

`pubspec_overrides.yaml` 已在 `.gitignore` 中：它通常含本机绝对路径，提交会污染仓库。
依赖恢复的完整清单见 [OHOS_DEPENDENCY_MIRROR_MAPPING.md](OHOS_DEPENDENCY_MIRROR_MAPPING.md)
与 [OHOS_DEPENDENCY_RECOVERY_REPORT.md](OHOS_DEPENDENCY_RECOVERY_REPORT.md)。

### 4.3 不要在 Git Bash 里调 ohpm

Git Bash 下 `ohpm` 会解析到无扩展名的 shell 脚本，进而与 `ohpm.bat` 互相调用：

```
****** B A T C H   R E C U R S I O N  exceeds STACK limits ******
```

构建请在 PowerShell 或 cmd 中执行。

## 5. 依赖解析产物

构建目录除了 Flutter 的 `.dart_tool/`，还需要 hvigor 侧的这些生成物：

| 路径 | 作用 |
| :--- | :--- |
| `.flutter_plugin_links/` | 插件源码的稳定路径，供 ArkTS 解析插件模块 |
| `ohos/oh_modules/` | ohpm 安装的 HAR 依赖 |
| `ohos/node_modules/flutter-hvigor-plugin` | 指向 Flutter SDK `packages/flutter_tools/hvigor` 的链接 |
| `ohos/.hvigor/dependencyMap/` | hvigor 生成的依赖映射 |

复制工程时注意 `ohos/node_modules/flutter-hvigor-plugin` 是符号链接，`tar` 会报
`Cannot stat`；复制后需单独重建：

```bash
cp -r <flutter-sdk>/packages/flutter_tools/hvigor ohos/node_modules/flutter-hvigor-plugin
```

## 6. 验证

```bash
# BTR 专项（下载、调度、代理、设置迁移）
flutter test test/thread_ripper

# 全量
flutter test

# 静态分析（该 SDK 的 flutter analyze 会因缺 dev/ 失败，直接用 dart）
<flutter-sdk>/bin/cache/dart-sdk/bin/dart.exe analyze lib test
```

`flutter test` 需要 `HOS_SDK_HOME`，并且建议设置 `NO_PROXY=127.0.0.1,localhost`，
否则 flutter_tester 的本地 websocket 会走代理导致超时。

## 7. 产物校验

```bash
sha256sum build/ohos/hap/entry-default-unsigned.hap
# 包内元数据
unzip -p build/ohos/hap/entry-default-unsigned.hap module.json | head -c 400
```

`module.json` 里应能看到 `bundleName`、`versionName`、`versionCode`、`minAPIVersion`
与 `targetAPIVersion`；包内不含 `.p7b`/`.p7s` 即为未签名。
