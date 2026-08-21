# Linnet 版本记录

本文件记录 Linnet 自身的用户可见变化。继承的 Squirrel 历史请查阅
[Squirrel changelog](https://github.com/rime/squirrel/blob/master/CHANGELOG.md)。

## 0.1.2 — 2026-08-21

### 下载与更新

- 正式 Release 现在只展示一个完整安装包 `Linnet.pkg`，普通用户不再需要在
  Core、语言包、Catalog、ZIP 和多份校验文件之间判断该下载什么。
- 同仓库使用两个明确标注的预发布频道：`core-v<version>` 保存免注销 Core
  更新与卸载器，`data-<sequence>` 保存 Linnet Settings 使用的四个语言包和
  Catalog；它们不会成为 Latest Release。
- SHA-256 直接写入对应 Release 说明；发布前仍对最终字节、未签名 PKG、App
  结构、语言包和 Catalog 执行同等级验证。
- GitHub Actions 继续复用经过重新验证的锁定依赖缓存，并升级到当前 Node 24
  Action 运行时，减少重复下载和构建等待。

## 0.1.1 — 2026-08-20

Linnet 的首个公开社区版本，提供源码、可复现构建流程、未使用 Apple Developer ID 签名的安装包及 SHA-256 校验文件。macOS 首次安装需要用户在 Finder 或“隐私与安全性”中手动确认信任。

### 双语输入体验

- 以一个 macOS 输入源承载中文、Smart English 与原始 ASCII 三种状态。
- 轻按左或右 Shift 在当前中文方案与 Smart English 之间切换；Caps Lock 保留原始 ASCII。
- 提供紧凑的模式提示、稳定的候选导航，以及横排或竖排候选布局。

### 中文与拼音反查

- 提供全拼、自然码、小鹤、微软、搜狗、智能 ABC、紫光和拼音加加八种方案，共享中文词典与学习数据。
- 中文候选使用锁定的 Wanxiang 数据，并叠加可审计的 Linnet 读音与排序修正。
- 支持用当前全拼或双拼编码反查英文；触发键可选择 `;` 或 `|`。
- 支持简繁、Emoji、中英文标点、辅助码、符号命令、Unicode 输入和本地计算器。

### Smart English

- 提供前缀补全、拼写建议、IPA、中文释义、上下文排序与下一词预测。
- 保留大小写、连续英文空格，以及 URL、邮箱、路径、版本号和代码标识符的原始形式。
- 原始输入始终保留为安全候选；Tab 可设为智能接受、候选导航或交给当前应用。
- 支持自定义词、禁用词、Text Expander，以及中英文学习数据的独立管理。

### 外观、设置与个人数据

- 提供宣纸、月华、青岩、陶印、雾青、原生玻璃和墨朱七套浅色/深色主题。
- 内置原生 Settings，可管理输入、词典、英文、外观、数据与本地候选预览。
- 支持个人数据导入导出、自动备份、恢复及中英文学习数据清理。
- 输入进程保持离线；语言数据更新只允许由用户在 Settings 中主动发起。

### 平台与交付

- 支持 Apple Silicon Mac 与 macOS 13 及以上版本。
- 提供可复现的源码构建、组件化语言数据、发行身份、NOTICE、SBOM 与许可证打包流程。
- 社区安装包不依赖付费证书或公证；App 内部使用 hardened-runtime ad-hoc 签名保持代码结构完整，安装包由校验和与公开源码绑定。
