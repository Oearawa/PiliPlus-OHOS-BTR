<div align="center">
    <img width="160" height="160" src="assets/images/logo/logo.png">
    <h1>PiliPlus OHOS BTR</h1>
    <p>PiliPlus 鸿蒙分支 + BTR 多线程下载与自适应并发调度</p>
    <p><code>v0.1.0-beta.1</code> · 首个测试版</p>
</div>

> [!WARNING]
> 这是**独立维护**的融合项目，不是 `dev4harmony/PiliPlus` 的官方分支，也不向该仓库回推。
>
> 当前版本为非签名的测试版 HAP，**未做真机安装验证**，请只在你愿意承担风险的情况下安装。
> 首次启动后 BTR 处于**关闭**状态，不改变原有播放行为。

## 项目定位

PiliPlus 的鸿蒙适配版把播放链路交给 `media_kit` + mpv，视频与音频各自是一条 DASH 分片流。
默认情况下 mpv 对每条流串行 Range 请求，单连接带宽和高延迟节点下的启动速度都不理想。

本项目在这条真实播放链路上加一层本地回环 HTTP 端点，把 BTR
（[Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper)）的
多线程 Range 下载与自适应并发调度搬进 Dart，让 mpv 照常播放，而字节由多连接并发取回。

目标只有一个：**在鸿蒙真机的播放链路里把 BTR 跑通，并且默认不影响原有播放**。

## 来源与职责

三个来源的定位严格区分，审计时间 2026-10-21：

| 来源 | 职责 | 审计提交 | 许可证 | 处理方式 |
|---|---|---|---|---|
| [dev4harmony/PiliPlus](https://github.com/dev4harmony/PiliPlus) | 鸿蒙基线 | `0aba2c6db94ba9b4cf9c076b1d39179ee3d860b4`（`ohos`，2026-10-18） | GPL-3.0 | 保留，作为应用主体 |
| [lemonteaau/PiliPlus](https://github.com/lemonteaau/PiliPlus) | PiliPlus 功能参考 | `f368e92a800d2c5530277a5acf064462e2f6bcd0`（`thread-ripper-2026.9.29.2`，2026-10-02） | GPL-3.0 | 选择性参考，未整包合并 |
| [MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) | 下载与调度算法 | `ee3adaa8cc1afbb29a3d7153e1295e09e42b29e2`（`main`，2026-10-19，`2026.10.19.2`） | MIT | 按鸿蒙架构重写适配 |

- **基线继承**：页面、账号、弹幕、播放器外壳、鸿蒙构建配置全部来自基线，本项目不修改它们的语义。
- **参考实现**：只核对接入形态与已修复的坑（首字节超时合并、只暴露受支持档位、relay 地址不外移等），
  没有复制该分支的文件。
- **BTR 算法适配**：`lib/services/thread_ripper/` 是对上游 JS 的 Dart 重写。上游是浏览器脚本，
  通过替换 `fetch`/`XHR` 或接管 MSE 工作；鸿蒙侧没有这些对象，所以改成
  **本地 127.0.0.1 端点 + mpv 当作普通媒体 URL 打开**。对应关系见 [docs/BTR.md](docs/BTR.md)。

## 已实现

以下功能在代码中均有对应实现与测试，不是规划项。

### 下载核心

- 多范围拆分：按并发把区间切成至少 64 KiB 的片，上限 512 片；分片乱序返回后按序拼接。
- 严格校验：只接受 HTTP 206，且 `Content-Range` 的起止与请求一致、总长与首次探测一致；
  200、越界、长度漂移都会被判为失败而不是当作媒体数据。
- 并发探测（hedge）：首个请求 900 ms 未响应时并发第二个节点请求，谁先回用谁。
- 轮次重试：失败分片进入下一轮（最多 3 轮），节点按失败次数与延迟排序。
- 单飞（single-flight）：同一轨道、同一字节区间只下载一次；等待方取消不会中断已开始的传输；
  视频与音频的相同偏移**不**共享，避免两轨串流。

### 自适应并发

- 八档阶梯 `4 / 8 / 12 / 16 / 24 / 32 / 48 / 64`，受 `RipperSemaphore` 单点限流。
- 升档需要同时满足：缓冲不足、最近的窗口内确实有字节到达（activity 门控，1.5 s）、
  连接饱和占比 ≥ 60%。缓冲低但完全没有数据到达时不升档，因为那是节点问题不是连接数问题。
- 升档后做 10 s 试探：吞吐有效提升则保留；吞吐回退立即退档；没有增益时，只有连接确实饱和才退档，
  否则保持不动，避免来回振荡。
- 退档与冷却：`412 / 429` 立即退档并冷却 180 s；首字节超时退一档并冷却 90 s；
  传输中卡顿（`-2`）与首字节超时（`-1`）分开上报，前者属于慢节点，不当作连接过多。
- 手动模式：不创建自适应控制器，`RipperSemaphore` 固定为用户选择的档位。

### 资源与生命周期

- 视频与音频共用同一个连接预算；音频每轮固定最多 2 片在飞，其余额度留给视频。
- 队列按等待时长做 aging，长时间排队的请求优先，避免一条轨道饿死另一条。
- 会话隔离：每次打开源生成新的 generation；切集、切清晰度、退出页面都会关闭旧会话并中断在飞请求，
  旧会话的迟到回调和播放器事件被 generation / listenerEpoch 丢弃。
- 代理启动失败、候选地址为空、或回环地址打开失败时**回退直连**，BTR 不会让视频放不出来。

### 接入与设置

- DASH 链路：`VideoDetailController` 把主地址与备用节点一起交给播放器，`PLPlayerController`
  在 `open()` 前决定是否换成回环 URL；直播、本地文件、HLS/FLV、DRM 与试看集数**不**进入 BTR。
- 设置项：总开关（默认关闭）、自动并发（默认开启）、手动档位、CDN 区域、自定义节点、
  剧集加速、诊断对话框（实时档位、饱和占比、调档原因、冷却档位、真实吞吐）。
- 旧配置迁移：布尔/字符串等历史写法会被归一化，非法自定义节点会被丢弃。

## 未实现与不适用

明确说明，避免误解：

- 上游浏览器脚本的**全接管**能力（让 B 站内核以为缓冲已满、暂停它自己的下载）在原生播放器下
  没有对应机制，本项目**没有**实现，也不需要实现。
- 直播、HLS、FLV、本地文件不走 BTR。
- DRM 与试看集数不走 BTR。
- 没有做码率/画质的自动切换，BTR 只影响“怎么把已选清晰度的字节取回来”。

## 构建

环境（本项目实测通过的组合，未升级依赖）：

- Flutter OHOS SDK **3.44.9**（[oh-3.44.9-dev](https://gitcode.com/CPF-Flutter/flutter_flutter/tree/oh-3.44.9-dev)）
- DevEco Studio **26.0**，HarmonyOS SDK API **26**
- 目标设备：HarmonyOS 手机 / 平板

```bash
# 1. 依赖
flutter pub get

# 2. 注入版本与提交信息（生成 .vscode/env.json）
dart .vscode/build_env.dart

# 3. 构建未签名 HAP
flutter build hap --release --no-codesign \
  --dart-define-from-file=.vscode/env.json
```

产物路径：`ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`

> [!IMPORTANT]
> hvigor 会把 `--target_path` 按空格切分，**工程路径不能包含空格**。
> 如果仓库放在含空格的目录下，请先 `git clone` 到无空格路径再构建。

签名：本仓库不提供签名配置。要安装到真机，请用 DevEco Studio 配置你自己的证书后重新签名。

## 已知限制

- **未签名**：Release 中的 HAP 为 `unsigned`，**未通过安装验证**，需要自行签名。
- **未真机验证**：本版本在 Windows 构建机上完成编译与单元测试，没有在鸿蒙设备上跑过播放回归。
- 只在 DASH（`data.dash != null`）链路启用；其它源形态保持原样。
- 代理监听 `127.0.0.1` 的随机端口；端口无法绑定时回退直连，此时没有加速。
- 自适应调度的参数（试探 10 s、冷却 90/180 s、饱和占比 60%）来自上游经验值，
  没有在鸿蒙设备上按机型重新标定。
- 上游 `2026.10.19.2` 之后的新提交尚未跟进。

## 下载

见本仓库的 [Releases](../../releases)。当前只有 `v0.1.0-beta.1`，附未签名 HAP、
`SHA256SUMS.txt` 与构建说明。

## 许可证

本项目以 **GPL-3.0** 发布，继承自 PiliPlus 鸿蒙分支。BTR 部分为 MIT，MIT 允许并入 GPL-3.0
作品但要求保留版权与许可声明，全文见 [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md)
与 [third_party/bilibili-thread-ripper/LICENSE](third_party/bilibili-thread-ripper/LICENSE)。

## 声明

此项目仅用于学习和测试，请于下载后 24 小时内删除。所用 API 皆从官方网站收集，不提供任何破解内容。
请支持正版，尊重创作者。

## 致谢

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 及其上游 `orz12/PiliPalaX`、`guozhigq/pilipala`
- [dev4harmony/PiliPlus](https://github.com/dev4harmony/PiliPlus) 鸿蒙适配团队
- [lemonteaau/PiliPlus](https://github.com/lemonteaau/PiliPlus) 的 BTR 接入实践
- [MrTangLuyao/Bilibili-thread-ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper) 的下载与调度算法
- media_kit 鸿蒙适配者 [ErBW_s](https://github.com/ErBWs) 及所有贡献者

---

# 以下是继承的基线 README

> 以下内容来自 `dev4harmony/PiliPlus` 的 `ohos` 分支与原上游 PiliPlus，
> 用于说明本项目的应用主体能力与历史来源，原样保留。

## PiliPlus鸿蒙版分支

此分支目前主要由[dev4harmony/flutter-dev](https://github.com/orgs/dev4harmony/teams/flutter-dev)维护

> [!WARNING]
> 此分支只是将PiliPlus适配到鸿蒙
>
> 几乎所有与鸿蒙平台无关的功能都是上游实现的

### 提issue注意事项：

- [issues看板](https://github.com/users/qinshah/projects/1)

- 请查看是否已存在类似issue并确保属于鸿蒙版特有问题

- 分支需要同步上游，一般不增加新功能或改变特性

### 编译运行

> [!TIP]
> 当前项目编译API已经提升到了26.0.0，请在华为官网下载最新的配套IDE和SDK使用，防止编译异常

- 1、配置鸿蒙flutter3.44.9环境，参考[鸿蒙flutter3.44.9](https://gitcode.com/CPF-Flutter/flutter_flutter/tree/oh-3.44.9-dev)

- 2、通过vscode运行启动配置或是build_hap任务以确保应用内所需环境变量正确写入

若遇到类似 **Package not available (the pubspec for image_picker 1.1.2 from git has version 1.0.2).** 这样的报错，可参考[这篇掘金](https://juejin.cn/post/7602936997175132212)

### 欢迎参与开发适配，让鸿蒙PiliPlus更完善

### 感谢

- PiliPlus[上游](https://github.com/bggRGjQaUbCoE/PiliPlus)

- [dev4harmony/flutter-dev](https://github.com/orgs/dev4harmony/teams/flutter-dev)成员

- media_kit适配者[ErBW_s](https://github.com/ErBWs)

- 所有开发者和贡献者

- ......

# 以下是原上游项目README

<div align="center">
    <img width="200" height="200" src="assets/images/logo/logo.png">
</div>

<div align="center">
    <h1>PiliPlus</h1>
<div align="center">

中文 | [English](README.en.md)

![GitHub repo size](https://img.shields.io/github/repo-size/bggRGjQaUbCoE/PiliPlus) 
![GitHub Repo stars](https://img.shields.io/github/stars/bggRGjQaUbCoE/PiliPlus) 
![GitHub all releases](https://img.shields.io/github/downloads/bggRGjQaUbCoE/PiliPlus/total) 
</div>
    <p>使用Flutter开发的BiliBili第三方客户端</p>
    
<img src="assets/screenshots/510shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/174shots_so.png" width="32%" alt="home" />
<img src="assets/screenshots/850shots_so.png" width="32%" alt="home" />
<br/>
<img src="assets/screenshots/main_screen.png" width="96%" alt="home" />
<br/>
</div>

<br/>

## 适配平台

- [x] Android
- [x] iOS
- [x] Pad
- [x] Windows
- [x] Linux

[![Packaging status](https://repology.org/badge/vertical-allrepos/piliplus.svg)](https://repology.org/project/piliplus/versions)

## refactor

- [ ] gRPC [wip]
- [x] 用户界面
- [x] 其他

## feat

- [x] 编辑动态
- [x] DLNA 投屏
- [x] 离线缓存/播放
- [x] 移动端支持点击弹幕悬停，点赞、复制、举报 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 播放音频
- [x] 跳过番剧片头/片尾
- [x] 安卓端 `loudnorm` 适配 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] Win/Mac 支持极验、短信登录 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 视频截取动图 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] AI 原声翻译
- [x] SuperChat
- [x] 播放课堂视频
- [x] 发起投票
- [x] 发布动态/评论支持`富文本编辑`/`表情显示`/`@用户`
- [x] 修改消息设置
- [x] 修改聊天设置
- [x] 展示折叠消息
- [x] 查看用户图文
- [x] 动态话题
- [x] 直播分区
- [x] 分享`视频`/`番剧`/`动态`/`专栏`/`直播`至消息
- [x] 创建/修改/删除关注分组
- [x] 移除粉丝
- [x] 直播弹幕发送表情
- [x] 收藏夹排序
- [x] 稍后再看 ~~`未看`~~ / `未看完` / ~~`已看完`~~ 分类
- [x] WebDAV 备份/恢复设置
- [x] 保存评论/动态
- [x] 高级弹幕 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 取消/置顶评论
- [x] 记笔记
- [x] 多账号支持 by [@My-Responsitories](https://github.com/My-Responsitories)
- [x] 屏蔽带货动态/评论
- [x] 互动视频
- [x] 发评/动态反诈
- [x] 高能进度条
- [x] 滑动跳转预览视频缩略图
- [x] Live Photo
- [x] 复制/移动/排序收藏夹/稍后再看视频
- [x] 超分辨率
- [x] 合并弹幕
- [x] 会员彩色弹幕
- [x] 播放全部/继续播放/倒序播放
- [x] Cookie 登录
- [x] 显示视频分段信息
- [x] 调节字幕大小
- [x] 调节全屏弹幕大小
- [x] 收藏夹/稍后再看多选删除
- [x] 搜索用户动态
- [x] 直播弹幕
- [x] 修改头像/用户名/签名/性别/生日
- [x] 创建/编辑/删除收藏夹
- [x] 评论楼中楼查看对话
- [x] 评论楼中楼定位点击查看的评论
- [x] 评论楼中楼按热度/时间排序
- [x] 评论点踩
- [x] 私信发图
- [x] 投币动画
- [x] 取消/追番，更新追番状态
- [x] 取消/订阅合集
- [x] SponsorBlock
- [x] 显示视频完整合集
- [x] 三连动画
- [x] 番剧三连
- [x] 带图评论
- [x] 视频 TAG
- [x] 筛选搜索
- [x] 转发动态
- [x] 合集图片
- [x] 删除/置顶/撤回私信
- [x] 举报用户/评论/视频/动态
- [x] 删除/发布/置顶文本/图片动态
- [x] 其他

## opt

- [x] 专栏界面
- [x] 私信界面
- [x] 收藏面板
- [x] PIP
- [x] 视频封面
- [x] 回复界面
- [x] 系统通知
- [x] 评论显示
- [x] 亮度调节
- [x] 视频播放
- [x] 视频 staff
- [x] 防止 bottomsheet 遮挡全屏视频
- [x] 其他

## fix

- [x] 番剧分集点赞/投币/收藏
- [x] bugs

<br/>

## 功能

- [x] 推荐视频列表(app 端)
- [x] 最热视频列表
- [x] 热门直播
- [x] 番剧列表
- [x] 屏蔽黑名单内用户视频
- [x] 无痕模式（播放视为未登录）
- [x] 游客模式（推荐视为未登录）

- [x] 用户相关
  - [x] 粉丝、关注用户、拉黑用户查看
  - [x] 用户主页查看
  - [x] 关注/取关用户
  - [x] 离线缓存
  - [x] 稍后再看
  - [x] 观看记录
  - [x] 我的收藏
  - [x] 站内私信
- [x] 动态相关
  - [x] 全部、投稿、番剧分类查看
  - [x] 动态评论查看
  - [x] 动态评论回复功能

- [x] 视频播放相关
  - [x] 双击快进/快退
  - [x] 双击播放/暂停
  - [x] 垂直方向调节亮度/音量
  - [x] 垂直方向上滑全屏、下滑退出全屏
  - [x] 水平方向手势快进/快退
  - [x] 全屏方向设置
  - [x] 倍速选择/长按 2 倍速
  - [x] 硬件加速（视机型而定）
  - [x] 画质选择（高清画质未解锁）
  - [x] 音质选择（视视频而定）
  - [x] 解码格式选择（视视频而定）
  - [x] 弹幕
  - [x] 字幕
  - [x] 记忆播放
  - [x] 视频比例：高度/宽度适应、填充、包含等
- [x] 搜索相关
  - [x] 热搜
  - [x] 搜索历史
  - [x] 默认搜索词
  - [x] 投稿、番剧、直播间、用户搜索
  - [x] 视频搜索排序、按时长筛选
- [x] 视频详情页相关
  - [x] 视频选集(分 p)切换
  - [x] 点赞、投币、收藏/取消收藏
  - [x] 相关视频查看
  - [x] 评论用户身份标识
  - [x] 评论(排序)查看、二楼评论查看
  - [x] 主楼、二楼评论回复功能
  - [x] 评论点赞
  - [x] 评论笔记图片查看、保存

- [x] 设置相关
  - [x] 画质、音质、解码方式预设
  - [x] 图片质量设定
  - [x] 主题模式：亮色/暗色/跟随系统
  - [x] 震动反馈(可选)
  - [x] 高帧率
  - [x] 自动全屏
  - [x] 横屏适配
- [ ] 等等

<br/>

## 下载

可以通过右侧 release 进行下载或拉取代码到本地进行编译

<br/>

## 声明

此项目（PiliPlus）是个人为了兴趣而开发，仅用于学习和测试，请于下载后24小时内删除。
所用API皆从官方网站收集，不提供任何破解内容。
在此致敬原作者：[guozhigq/pilipala](https://github.com/guozhigq/pilipala)
在此致敬上游作者：[orz12/PiliPalaX](https://github.com/orz12/PiliPalaX)
本仓库做了更激进的修改，感谢原作者的开源精神。

感谢使用

<br/>

## 致谢

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer)
- [media-kit](https://github.com/media-kit/media-kit)
- [dio](https://pub.dev/packages/dio)
- 等等
