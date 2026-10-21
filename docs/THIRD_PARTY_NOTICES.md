# 第三方代码与许可证声明

本项目（PiliPlus-OHOS-BTR）自身以 **GPL-3.0** 发布，见仓库根目录 `LICENSE`。
下面是项目中直接引入或改写的第三方代码，以及各自的许可条件。

## 1. PiliPlus 鸿蒙分支（本项目基线）

- 仓库：https://github.com/dev4harmony/PiliPlus
- 审计提交：`0aba2c6db94ba9b4cf9c076b1d39179ee3d860b4`（分支 `ohos`，2026-10-18，`Release 2.1.6.2-ohos again`）
- 许可证：GPL-3.0
- 使用方式：整个应用主体直接继承该分支，本项目在其上叠加 BTR 下载与调度层。

该分支自身是 [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 的鸿蒙适配分支，
上游链为 `guozhigq/pilipala` → `orz12/PiliPalaX` → `bggRGjQaUbCoE/PiliPlus`。
所有继承代码保持原有版权与 GPL-3.0 条款。

## 2. PiliPlus 参考实现（选择性参考，非整包合并）

- 仓库：https://github.com/lemonteaau/PiliPlus
- 审计提交：`f368e92a800d2c5530277a5acf064462e2f6bcd0`（分支 `thread-ripper-2026.9.29.2`，2026-10-02）
- 许可证：GPL-3.0（与本项目一致，兼容）
- 使用方式：用于核对 BTR 在 PiliPlus 内的接入形态、自动并发的调档判据、
  首字节超时合并、以及设置项只暴露受支持档位等修复点。本项目未直接复制该分支的
  文件，`lib/services/thread_ripper/` 下的实现是按第 3 节的上游算法重写的，
  行为对齐处在 `docs/BTR.md` 中逐条记录。

## 3. Bilibili-thread-ripper（下载与调度算法来源）

- 仓库：https://github.com/MrTangLuyao/Bilibili-thread-ripper
- 审计提交：`ee3adaa8cc1afbb29a3d7153e1295e09e42b29e2`（分支 `main`，2026-10-19，release `2026.10.19.2`）
- 许可证：MIT
- 许可证全文：`third_party/bilibili-thread-ripper/LICENSE`
- 使用方式：`lib/services/thread_ripper/` 下的 `range_core.dart`、`idm_downloader.dart`、
  `cdn_resolver.dart`、`auto_concurrency.dart`、`range_proxy.dart` 是对该仓库
  `src/range-core.js`、`src/idm-downloader.js`、`src/cdn-resolver.js` 等文件算法逻辑的
  Dart 重写，运行环境从浏览器（`fetch` / `XHR` / MSE 接管）改为 Flutter + mpv 的
  本地回环 HTTP 端点。原始 MIT 版权声明与许可文本随源码保留，并在此单独归档。

MIT 与 GPL-3.0 兼容：MIT 代码可以并入 GPL-3.0 作品，但 MIT 的版权与许可声明必须保留，
且不得因此对 MIT 部分附加额外限制。

## 4. 其他依赖

Flutter 依赖项的许可证在构建时汇总为 `NOTICES`（Flutter 自动生成），
各 package 的原始许可证随 pub 缓存分发。本项目未修改这些依赖的许可条款。
