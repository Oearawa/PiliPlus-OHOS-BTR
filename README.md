<div align="center">
  <img src="assets/images/logo/logo.png" width="110" alt="PiliPlus OHOS BTR" />

  <h1>PiliPlus OHOS BTR</h1>

  <p>基于 PiliPlus 鸿蒙适配版，融合 Bilibili Thread Ripper 下载调度技术的 HarmonyOS 客户端</p>

  <p>
    <img alt="HarmonyOS" src="https://img.shields.io/badge/HarmonyOS-API%2026-000000?logo=harmonyos&logoColor=white" />
    <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.44.9-02569B?logo=flutter&logoColor=white" />
    <img alt="Dart" src="https://img.shields.io/badge/Dart-3.12.2-0175C2?logo=dart&logoColor=white" />
    <img alt="BTR" src="https://img.shields.io/badge/BTR-2026.11.1.1-FF6699" />
    <img alt="License" src="https://img.shields.io/badge/License-GPL--3.0-blue" />
    <img alt="Release" src="https://img.shields.io/github/v/release/Oearawa/PiliPlus-OHOS-BTR?include_prereleases&label=release&color=orange" />
  </p>
</div>

> [!IMPORTANT]
> 本项目**独立维护**，不属于 `dev4harmony/PiliPlus` 官方分支，也不向其回推任何代码。
> 所有改动仅发布在本仓库。

## 下载

| 最新版本 | 发布日期 | 产物 | 大小 | 签名 |
| :--- | :--- | :--- | :--- | :--- |
| **v0.2.0-beta.1** | 2026-11-04 | HAP（arm64-v8a） | 31,427,949 字节（30.0 MB） | 未签名 |

**[⬇ 下载 PiliPlus-OHOS-BTR-v0.2.0-beta.1-unsigned.hap](https://github.com/Oearawa/PiliPlus-OHOS-BTR/releases/download/v0.2.0-beta.1/PiliPlus-OHOS-BTR-v0.2.0-beta.1-unsigned.hap)**

```text
SHA-256  6d0076258db5e8f01b909da547beffab1e378b41ea9f757ad5c1234a31ee9c57
```

> HAP 未签名，不能直接安装。先用 DevEco Studio 配置自己的证书签名，详见 [安装](#安装)。

## 这是什么

PiliPlus 是用 Flutter 编写的 B 站第三方客户端。`dev4harmony/PiliPlus` 把它适配到了 HarmonyOS，
本项目以该分支为基线，做两件事：

1. **跟随鸿蒙基线**——页面、账号、弹幕、播放器外壳、鸿蒙构建配置全部继承自上游，保持同步；
2. **叠加 BTR 下载层**——把 [Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)
   的多线程 Range 下载与自适应并发调度，从浏览器脚本改写成 Dart，接进鸿蒙版真实的 mpv 播放链路。

上游 BTR 工作在浏览器里（替换 `fetch`/`XHR`、接管 MSE）。鸿蒙版没有这些对象，所以这里换了一种形态：
应用在 `127.0.0.1` 上起一个本地 Range 端点，mpv 把它当普通媒体地址打开，字节由多条连接并发取回。
**播放器本身不需要任何改动。**

主要开发语言是 Dart，通过 Flutter OHOS 工具链编译为 HAP。

## 功能

### 继承自 PiliPlus 鸿蒙分支

这些是上游能力，本项目只跟随同步，没有额外改造：

- 视频浏览、播放、选集与画质/音质切换
- 首页推荐、热门、搜索、番剧与直播入口
- 用户主页、动态、评论、私信、收藏与稍后再看
- 弹幕（含高级弹幕）、字幕、倍速、手势调节
- 多账号、离线缓存、投屏、WebDAV 备份
- 鸿蒙侧适配：沉浸光感顶栏、自由窗口自绘标题栏、安全区避让、HDR 输出

### BTR 下载增强（本项目移植）

以下能力在 `lib/services/thread_ripper/` 中实现，并有对应单元测试：

| 能力 | 实现 | 说明 |
| :--- | :--- | :--- |
| **自适应并发控制** | `auto_concurrency.dart` | 八档阶梯 `4/8/12/16/24/32/48/64`，按缓冲、吞吐与限流反馈调档 |
| **动态子块大小** | `idm_downloader.dart` `adaptiveChunkBytes()` | 目标约单连接 0.6 秒的字节量，按 64 KiB 取整，范围 64 KiB–1 MiB |
| **多 CDN 下载调度** | `cdn_resolver.dart` | 大陆/海外节点池，按实测速度排序，失败节点指数退避 |
| **EWMA 速度估算** | `_connectionBps` / `_pieceMs` | 连接速率与分块耗时按 0.7/0.3 平滑，供子块与 hedge 使用 |
| **Hedge 请求** | `adaptiveHedgeDelayMs()` | 首请求迟迟不回时并发第二个节点，延迟随实测分块耗时自适应（下限 250 ms） |
| **断点续传** | `RipperPartialException` + `keepProgress` | 中途卡顿只重取剩余字节，已收前缀直接复用（≥32 KiB 才保留） |
| **失败分块恢复** | `maxRounds` 轮次重试 | 失败分片进入下一轮，节点按失败次数降权后重排 |
| **下载任务协调** | `RipperSemaphore` + `trackKey` 单飞 | 视频与音频共用连接预算，同轨道同字节区间只下载一次 |


## 安装

当前 Release 提供的是**未签名** HAP，系统不允许直接安装。步骤：

1. 下载 `PiliPlus-OHOS-BTR-v0.2.0-beta.1-unsigned.hap`，核对上面的 SHA-256。
2. 用 DevEco Studio 打开 `ohos/` 工程，在 **Project Structure → Signing Configs** 配置你自己的证书
   （需要华为开发者账号与对应设备的调试证书）。
3. 签名后重新构建，或对已有工程重新打包：

   ```bash
   hvigorw assembleHap --mode module -p product=default
   ```

4. 通过 `hdc install` 或 DevEco Studio 安装到设备。

覆盖安装沿用基线包名 `com.example.piliplus`，从 PiliPlus 鸿蒙版升级时数据保留；
如果你之前装的是其他改包名的版本，需要先卸载。

## 使用 BTR

路径：**设置 → 视频 → 启用多线程视频加速 (BTR)**。

| 开关 | 默认 | 作用 |
| :--- | :--- | :--- |
| 启用多线程视频加速 | 关 | 总开关。关闭时播放链路与基线一致 |
| 自动并发 | 开 | 由调度器在 4–64 之间自动调档；关闭后使用下方固定档位 |
| 手动并发档位 | 8 | 自动关闭时固定使用的连接数 |
| CDN 区域 | 海外 | 节点池选择，支持自定义节点 |
| 剧集加速 | 开 | 允许可播的 PGC 集数走 BTR（DRM/试看仍直连） |

打开后可在同一页面查看**诊断信息**：当前档位、饱和占比、最近一次调档原因、冷却中的档位与实测吞吐。

## 编译

### 环境

| 组件 | 版本 |
| :--- | :--- |
| Flutter OHOS SDK | **3.44.9**（Dart 3.12.2） |
| DevEco Studio | **26.0** |
| HarmonyOS SDK | API **26**（compileSdk 26.0.0.105） |
| Node.js / ohpm / hvigor | DevEco Studio 自带 |

Flutter 需使用鸿蒙分支：<https://gitcode.com/CPF-Flutter/flutter_flutter/tree/oh-3.44.9-dev>

### 构建

```bash
# 1. 依赖
flutter pub get

# 2. 注入版本与提交信息（生成 .vscode/env.json）
dart .vscode/build_env.dart

# 3. 构建未签名 HAP
flutter build hap --release --no-codesign \
  --dart-define-from-file=.vscode/env.json
```

产物：`build/ohos/hap/entry-default-unsigned.hap`

环境变量（PowerShell 示例）：

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:HOS_SDK_HOME    = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:NODE_HOME       = 'C:\Program Files\Huawei\DevEco Studio\tools\node'
$env:PATH = 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin;' +
            'C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin;' +
            'C:\Program Files\Huawei\DevEco Studio\tools\node;' + $env:PATH
```


更多构建与依赖细节见 [docs/BUILD.md](docs/BUILD.md) 与
[docs/OHOS_DEPENDENCY_RECOVERY_REPORT.md](docs/OHOS_DEPENDENCY_RECOVERY_REPORT.md)。

## 来源与版本

| 来源 | 用途 | 当前基线 | 许可证 |
| :--- | :--- | :--- | :--- |
| [dev4harmony/PiliPlus](https://github.com/dev4harmony/PiliPlus) | 鸿蒙基线，应用主体 | `a8431412`（`ohos`，`2.1.6.2-ohos-2`） | GPL-3.0 |
| [lemonteaau/PiliPlus](https://github.com/lemonteaau/PiliPlus) | 接入形态参考（未整包合并） | `f368e92a` | GPL-3.0 |
| [MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) | 下载与调度算法 | `3e715f5f`（`2026.11.1.1`） | MIT |

BTR 的 JS → Dart 对应关系、与上游的刻意差异、全部阈值参数，记录在 [docs/BTR.md](docs/BTR.md)。
上游同步过程见 [docs/UPSTREAM_SYNC_REPORT_2026-11-01.md](docs/UPSTREAM_SYNC_REPORT_2026-11-01.md)。


## 许可证

以 **GPL-3.0** 发布，继承自 PiliPlus 鸿蒙分支。BTR 部分为 MIT，可并入 GPL-3.0 作品但须保留声明。
全文见 [LICENSE](LICENSE)、[docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md)、
[third_party/bilibili-thread-ripper/LICENSE](third_party/bilibili-thread-ripper/LICENSE)。

## 致谢

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 及上游 `orz12/PiliPalaX`、`guozhigq/pilipala`
- [dev4harmony/PiliPlus](https://github.com/dev4harmony/PiliPlus) 鸿蒙适配
- [MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) 的下载与调度算法
- [lemonteaau/PiliPlus](https://github.com/lemonteaau/PiliPlus) 的 BTR 接入实践
- media_kit 鸿蒙适配者 [ErBW_s](https://github.com/ErBWs) 及所有贡献者

## 免责声明

本项目仅用于学习和技术研究，请于下载后 24 小时内删除。
所有 API 均来自官方网站，不提供任何破解内容。请支持正版，尊重创作者。

---

<sub>应用主体来自 GPL-3.0 的 PiliPlus 鸿蒙分支；原样保留的上游 README 见
[docs/README.upstream.md](docs/README.upstream.md)。</sub>
