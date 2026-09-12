# Linnet

简体中文 · [English](README.en.md)

<p align="center">
  <img src="resources/branding/readme-banner.svg" width="680" alt="Linnet — Chinese and English, in one flow">
</p>

<p align="center">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/License-GPL--3.0--or--later-blue" alt="License: GPL-3.0-or-later"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-blue" alt="Apple Silicon arm64">
  <a href="https://github.com/Ares-X/Linnet/actions/workflows/pull-request-ci.yml"><img src="https://github.com/Ares-X/Linnet/actions/workflows/pull-request-ci.yml/badge.svg?event=pull_request" alt="PR CI"></a>
</p>

Linnet（双韵）是一款为 macOS 打造的开源双语输入法，将中文输入与 Smart English 放进同一个系统输入源。

**一个输入源，两种语言，一种连贯的输入体验。**

> [!NOTE]
> 首次安装请下载 `Linnet.pkg`。社区版没有 Apple Developer ID 签名或公证，macOS 可能要求手动确认信任；Release 说明提供 SHA-256，供核对下载文件。

**[下载最新版 Linnet.pkg](https://github.com/Ares-X/Linnet/releases/latest)**

正式版：**[0.1.25（107）](https://github.com/Ares-X/Linnet/releases/tag/v0.1.25)**，包含连续中英混输增强。各版本功能与修复见[版本记录](CHANGELOG.md)。

已有用户可在 **Settings → 数据与更新 → 正式版** 下载并应用 Core 更新。

[产品体验](#产品体验) · [安装](#安装) · [使用指南](#使用指南) · [升级与卸载](#升级与卸载) · [隐私](#隐私) · [参与贡献](#参与贡献)

## 为什么选择 Linnet

- **中文输入**：全拼与七种双拼，共享词库、学习数据和本地语言模型。
- **连续混输**：中文句子中直接输入英文整词，无需中途上屏或切换模式。
- **Smart English**：补全、纠错、IPA、中文释义与上下文预测，保留原始输入。
- **个人词典与离线数据**：自定义词、Text Expander、学习与备份保存在本机，可选 iCloud 学习词同步。
- **原生 macOS 体验**：统一输入源、候选窗与 Settings，七套浅色／深色主题。
- **轻量更新**：Core 与语言数据分开更新，复用词库与模型，支持设置内免注销更新。

### 基于成熟上游，由 Linnet 精校与增强

Linnet 基于 Squirrel／librime，结合万象词库、RIME-LMDG 模型、rime-ice 与 Hallelujah 的数据与能力，提供中文精校、原生 Smart English 扩展、候选交互及 macOS 设置与更新。来源、修改范围与许可证见[第三方来源说明](THIRD_PARTY_NOTICES.md)。

## 产品体验

### 一个输入源，三个明确状态

| 状态 | 菜单栏 | 适合场景 |
| --- | --- | --- |
| 中文 | `中` 或 `双` | 全拼或当前双拼、中文候选、本地语法模型 |
| Smart English | `En` | 英文补全、纠错、释义、发音与上下文预测 |
| 原始 ASCII | `A` | 代码、密码、终端和任何不希望被转换的文本 |

轻按左 Shift 或右 Shift 切换中文与 Smart English；Caps Lock 进入或退出原始 ASCII。光标旁和菜单栏都会提示当前状态。

<details>
<summary>查看三种状态的光标提示</summary>

![Linnet 中文、Smart English 与原始 ASCII 三种输入状态的真实光标提示](resources/readme/input-modes.png)

</details>

### 中文输入

默认使用全拼，也可在 Settings 选择自然码、小鹤、微软、搜狗、智能 ABC、紫光或拼音加加。八种方案共享词库与学习数据，支持简体／繁体输出。

默认提供邻键误按和前后鼻音纠错；有效原读音优先，正常双拼与简拼仍可用。需要固定混用读音时，可在 **Settings → 输入 → 模糊音** 选择 z/zh、n/l、in/ing 等 12 组组合，默认均不勾选。

<details>
<summary>纠错与学习如何工作</summary>

- 原编码能组成完整读音时，首选保留原读音，读音纠错优先于邻键纠错。例如自然码 `hghk` 首选仍对应 `heng hao`，后面依次建议“很好”“更好”；全拼按完整拼音处理。
- 邻键纠错处理每个音节内的一次误按，多个音节可分别纠错。手动启用的模糊音不再仅作为弱纠错候选，但仍保留原读音；折叠时显示已选组合，点击“应用更改”后生效。
- 中文可选择标准 Rime 学习、Linnet 增强学习或关闭学习；增强学习会强化逐字组成的生僻词组。英文学习单独开关。关闭学习保留已有记录，重新启用可继续使用；删除记录需到“数据与更新”中清理。

</details>

**连续中英混输**：中文按当前全拼或双拼编码输入，英文直接敲原文，可在一句中多次切换，中途不必上屏。以下使用自然码：

| 连续敲键 | 选词上屏 |
| --- | --- |
| `kwregiondemigration` | 跨region的migration |
| `womfxuykalignyixwvegegapdesolution` | 我们需要align一下这个gap的solution |

![自然码连续输入我们需要align一下这个gap的solution的虚拟机实录](resources/readme/mixed-align.gif)

_录制于 0.1.25 Preview · macOS 虚拟机 Safari 文本框 · 自然码、每页 3 项候选；自动按键实录，原速播放。其他拼音方案使用各自中文编码，英文拼写相同。_

<details>
<summary>查看短句“跨region的migration”实录</summary>

![自然码连续输入跨region的migration的虚拟机实录](resources/readme/mixed-region.gif)

</details>

`size`、`mode`、`save` 等有拼音歧义的词会同时提供中文与英文候选；排序仍取决于上下文与学习，有歧义时需选词。开启中文学习后，选过的混输词句和英文分界可跨全拼／双拼复用。按住 Shift 输入 `CPU`、`DNS`、`HTTPS` 等大写缩写会保留原文，两侧拼音继续组成中文。

辅助输入：`Shift+V` 符号、`U` + 十六进制码点输入 Unicode、`cC` + 表达式计算、`uU` + 全拼查部件拆字。用拼音查英文见[拼音反查英文](#拼音反查英文)。

### Smart English

- 前缀补全、拼写纠错、模糊匹配与下一词预测，结合词频、学习和上下文排序；可选 IPA 与中文释义。
- 保留首字母大写或全大写；URL、邮箱、路径、版本号和代码标识符尽可能保持原文。
- 原始输入始终可选；完整英文词或明确的大写缩写优先于更长的补全结果。

可在 Settings 配置 Space 上屏后的尾随空格，以及 Tab 的智能接受、候选导航或交给应用三种行为。`Esc` 关闭本次预测并清除英文上下文。

![Linnet 拼音反查英文与 Smart English 的真实候选窗](resources/readme/bilingual-features.png)

_左：中文模式的拼音反查；右：带 IPA 和中文释义的英文补全。_

### 外观与个性化

宣纸、月华、青岩、陶印、雾青、原生玻璃和墨朱七套主题均提供浅色与深色版本。中英文可分别选择横排／竖排；字体、字号、候选数量和展开方式也可调整。

<details>
<summary>查看七套主题与布局选项</summary>

![Linnet 七套候选窗主题的 Light 与 Dark 实际渲染](resources/readme/theme-gallery.png)

| 布局 | 选项 |
| --- | --- |
| 紧凑候选 | 每页 3／5／7／9 项 |
| 横向展开 | 列数与最多行数分别可选 3／4／5；默认 5 列、最多 3 行 |
| 纵向展开 | 每行 5／6／7 项，最多 3 行 |

展开后统一使用多行网格，方向键在候选间移动，也可设为始终按页滚动；展开设置不影响紧凑候选数量。英文释义显示在网格下方，跟随高亮候选并按内容调整高度。

</details>

### 下载大小与磁盘空间

以下使用十进制 MB；包大小以对应 Release 为准。

| 内容 | 参考大小 | 包含内容 |
| --- | --- | --- |
| [0.1.25 完整安装包](https://github.com/Ares-X/Linnet/releases/tag/v0.1.25) | **约 428 MB** | 程序、中英文词库、本地模型和辅助数据 |
| [0.1.25 Core 更新包](https://github.com/Ares-X/Linnet/releases/tag/core-v0.1.25) | **约 7 MB** | 仅程序，复用已安装语言数据 |
| [锁定的 LTS 模型](upstreams.lock.json) | **420.25 MB** | 未压缩模型文件，已包含在完整安装内容中 |

下载大小不等于安装后占用：磁盘还保存解压数据、生成方案、学习记录和备份；模型文件大小也不等于常驻内存用量。

## 系统要求

Apple Silicon Mac（arm64），macOS 13 或更高版本。

## 安装

### 获取社区版本

从 **[Latest Release](https://github.com/Ares-X/Linnet/releases/latest)** 下载 `Linnet.pkg`。可在下载目录运行以下命令，与同一 Release 的 SHA-256 核对：

```bash
shasum -a 256 Linnet.pkg
```

Linnet 安装到当前用户目录，无需管理员权限，不安装守护进程、启动项或特权辅助程序。

### 首次启用

1. 在 Finder 中右键点击 `Linnet.pkg`，选择 **打开**并确认；若被拦截，到 **系统设置 → 隐私与安全性 → 仍要打开**，再返回安装器。
2. 选择 **继续 → 安装**，等待成功。安装位置为 `~/Library/Input Methods/Linnet.app`，不要手动移动或复制 App。
3. 保存工作，**注销并重新登录一次**，让 macOS 完成首次输入源登记。
4. 在 **系统设置 → 键盘 → 文本输入 → 编辑** 中添加或启用 **Linnet**，按提示允许，并从菜单栏输入菜单选中它。中英文共用这一个输入源；安装器不会代替你选择或授权。
5. 输入拼音确认中文候选可用，再用 Shift、Caps Lock 检查[三种状态](#一个输入源三个明确状态)；从输入菜单打开 **Settings**。

请只信任本项目 Release 的文件；哈希不符或提示损坏时停止安装，不要关闭 Gatekeeper、清除隔离属性或执行来源不明的安装命令。

后续使用[设置内 Core 更新](#应用核心更新)，无需重新添加输入源或注销。旧版升级、同版本修复及 App 损坏的处理见[升级与卸载](#升级与卸载)。

## 使用指南

### 拼音反查英文

在中文模式输入 `|` + 当前全拼／双拼编码，即可按中文意思找英文：全拼 `|suanfa`、自然码 `|srfa` 都可查到 `algorithm`。可在 Settings 显式改用 `;` 触发；默认分号不触发反查。

Smart English 中直接输入当前拼音编码，无需触发键。普通英文候选优先，原始输入保留，`;` 等标点直接交给应用。

### 自定义词与 Text Expander

在 **Settings → 词典** 配置，点击 **应用更改** 保存：

- **自定义词**：显示文本 + 小写 Rime code，参与正常候选和学习。也可右键候选“添加到自定义词…”，确认草稿编码后保存。
- **禁用英文词**：按大小写不敏感的完整词隐藏静态、学习、纠错、发音和预测候选。右键“忘记此候选的学习记录”只删除学习，内置词仍可能出现。
- **Text Expander**：以 `x;` 开头的短码展开固定文本，例如 `x;addr` 展开完整地址。未知触发器原样保留，展开内容不再经过大小写、空格或释义处理。

个人词典修改只增量加载实际变化的内容。

## 设置

从输入菜单打开 **Settings**，可选 English／简体中文界面。设置内嵌在 `Linnet.app`，不单独安装或常驻 Dock。

| 标签 | 主要内容 |
| --- | --- |
| 外观 | 主题、明暗、字体、候选数量与布局 |
| 输入 | 中文方案、模糊音、学习、简繁、Emoji、标点、辅助码与反查；英文自动大写、IPA、释义、预测、学习、Space 与 Tab，纠错和模糊匹配始终可用 |
| 词典 | 自定义词、禁用英文词、Text Expander |
| 数据与更新 | Core／词包更新、iCloud 学习同步、备份与恢复、导入导出、学习清理、脱敏诊断 |

外观可直接预览，输入行为变更需点击 **应用更改 / Apply Changes**。不要手工编辑生成的 `linnet_user.custom.yaml`、`squirrel.custom.yaml`、`default.custom.yaml` 或 schema custom 文件。

**语言数据更新**：在“数据与更新”选择正式版（默认）或预览版。优先差分、复用未变化词包；无可用差分或差分失败时下载对应完整词包，新数据准备好前继续使用当前数据。同版本冲突可点 **修复语言数据更新**，下载有变化或冲突的完整词包，保留个人设置、学习词和未变化词包，不降级或重装。

## 升级与卸载

日常升级使用 Settings 中的 Core 更新，复用语言数据，无需关闭其他应用、输入密码或注销；Core 不会在后台自动修改。语言数据更新也在 Settings 中完成。

首次安装和 App 修复使用完整 `Linnet.pkg`；修复会保留健康词包与个人数据，无需先卸载。完整包、Core 与语言数据分别发布在正式版、`core-v<version>` 和 `data-<sequence>` 页面，后两者不会成为 Latest Release。

### 应用核心更新

1. 打开 **Settings → 数据与更新 → 核心更新**，点击 **下载核心更新**，等待下载和校验完成。
2. 完成或取消组词，从 macOS 输入菜单切换到其他输入法，保留其他应用窗口。
3. 点击 **应用更新… / Apply Update…**。它与保存设置的 **Apply Changes** 不同。
4. 切回 Linnet 试打几个字，并确认“正在运行”与“已安装”版本一致；“已安装”只表示磁盘文件已更新。

<details>
<summary>旧版升级、修复与更新异常</summary>

| 情况 | 处理方式 |
| --- | --- |
| 已完成 0.1.15 桥接的固定 CMS 版本 | 后续直接在 Settings 下载并应用 Core，无需自行寻找文件或核对哈希 |
| 0.1.14 及更早的固定 CMS 版本 | 先通过“打开旧版安装器…”完成一次 0.1.15 桥接，再点“应用已安装的更新… / Apply Installed Update…” |
| 0.1.7 及更早的 ad-hoc 版本，或 App 缺失、损坏、发布身份不符 | 使用完整 `Linnet.pkg` 修复 |
| 同版本 App 修复 | 使用完整 `Linnet.pkg`；在线 Core 仅升级到更高版本 |

- 无待应用更新时按钮置灰正常；未保存设置、数据操作或其他阻塞按卡片提示处理后重试。
- Settings 显示旧信息时，关闭窗口并从输入菜单重开，无需退出其他应用。
- 旧 Host 若提示下次正常登录或重启后生效，按提示完成；不要反复重装或删除输入源。
- App 已存在时，完整安装器保留输入源状态；缺失或停用的注册需在系统键盘设置中添加／启用，不必预先清理系统注册。Linnet 不会代替你切换输入源、授权或强制关闭应用。

</details>

### 卸载

卸载会永久删除本机 App、个人数据、备份和偏好；需要保留的数据请先导出。

<details>
<summary>展开完整卸载步骤与本地命令</summary>

先从 macOS 输入菜单切换到其他输入法，注销并重新登录，然后只打开 Terminal。以下命令完全在本机运行，不下载或执行网络脚本。它会永久删除本机 Linnet App、全部本地个人数据、备份、偏好和安装记录；需要保留的数据请先导出。

```bash
/usr/bin/find -P "$HOME/Library/Application Support/Linnet" -x -type d -exec /bin/chmod u+rwx {} + 2>/dev/null || true
/bin/rm -rf -x -- "$HOME/Library/Input Methods/Linnet.app" "$HOME/Library/Application Support/Linnet"
/usr/bin/defaults delete io.github.ares-x.inputmethod.Linnet 2>/dev/null || true
/usr/bin/defaults delete io.github.ares-x.inputmethod.Linnet.settings 2>/dev/null || true
/bin/rm -f -- "$HOME/Library/Preferences/io.github.ares-x.inputmethod.Linnet.plist" "$HOME/Library/Preferences/io.github.ares-x.inputmethod.Linnet.settings.plist"
/usr/sbin/pkgutil --volume "$HOME" --pkgs | /usr/bin/grep '^io\.github\.ares-x\.inputmethod\.Linnet\..*\.pkg$' | while IFS= read -r receipt; do /usr/sbin/pkgutil --volume "$HOME" --forget "$receipt" >/dev/null; done
```

完成后再次注销并重新登录，以刷新 macOS 输入源列表。iCloud Drive 中的同步数据与恢复备份，以及导出到其他目录的文件，需自行另行管理。

</details>

## 故障排查

### 系统找不到 Linnet

确认 App 位于 `~/Library/Input Methods/Linnet.app`，完成首次注销／登录，再到 **系统设置 → 键盘 → 文本输入 → 编辑** 添加并允许 Linnet。Control-Space 只轮换 macOS 已启用的输入源，Linnet 不接管此快捷键。

### 只能输入字母

菜单栏为 `A` 时关闭 Caps Lock，为 `En` 时轻按 Shift。若没有 `中`／`双`，在 **Settings → 输入** 选择并应用中文方案，再选中 Linnet。

### Settings 无法应用

到 **数据与更新 → 诊断** 刷新并复制诊断，不要手改生成的 YAML；公开前检查文本与截图中的个人信息。

### 报告问题

请附 macOS 版本、Mac 芯片、Linnet 版本、下载文件 SHA-256、当前输入状态与 Rime 方案、受影响应用和最小复现输入。不要提交个人词典、学习数据库、私钥、证书密码或完整用户目录。

## 隐私

输入处理在本机完成，没有账户、遥测、广告或分析 SDK，也不调用在线翻译、拼写或生成式模型。个人词典、学习数据和本地备份位于 `~/Library/Application Support/Linnet/`。

**可选 iCloud**：学习同步通过 `iCloud Drive/Linnet` 共享中英文学习记录，不自动同步自定义词、禁用词、Text Expander 或设置。启用同步或手动上传备份后，相应个人数据进入你的 iCloud Drive。

<details>
<summary>同步、备份与导入导出的范围</summary>

- 自动同步最多每小时检查一次，也可立即同步，期间可继续输入，无需先用过两种语言或保持文档打开。
- Settings 显示本机合并／导出时间及失败、待重试状态；本机完成不代表另一台 Mac 已收到，跨设备传输由 iCloud Drive 负责。
- 在“数据与更新”可手动上传、审阅增量恢复备份、查看事务恢复记录或导入导出。导入需确认并先创建本地备份；云端没有可用历史时新增完整备份，不删除已有备份。
- 只有明确选择导入，才读取其他 Rime／Hallelujah 数据。导出文件可能含个人数据，其保存与删除由你管理。

</details>

**更新联网**：打开 Settings 时向 GitHub 请求更新目录；点击相应更新后才下载 Core／语言文件。下载使用所选来源，更改只影响后续下载，不自动切换或回退。第三方镜像可看到 IP、请求时间和公开文件 URL；Linnet 不向 GitHub 或镜像发送个人词典、学习数据、备份、诊断或凭据。

## 参与贡献

构建 Linnet 需要 Apple Silicon Mac、macOS 13+、完整 Xcode、Git 和 `ripgrep`。项目主要使用 Swift/SwiftUI、C++、Shell 与 Ruby，不携带 Python 运行时。

```bash
./action-build.sh release
tests/verify_swift_units.sh --list
tests/verify_swift_units.sh --only OWNER
```

普通开发不需要签名证书，也不需要把本地构建注册为系统输入法。目录结构、数据生成、上游同步、测试层级与本机验收方法请阅读[开发指南](docs/development.md)；打包、签名和公开发布流程请阅读[发布指南](docs/release.md)。

## 版本、来源与许可证

Linnet 是从 Squirrel 修改而来的独立社区发行版，不代表任何上游项目的官方发行。本仓库已修改上游代码与数据；首个公开修改版日期为 2026-08-20。主要关系如下：

| 上游来源 | Linnet 的使用与修改 | 许可证摘要 |
| --- | --- | --- |
| [Squirrel](https://github.com/rime/squirrel) / [librime](https://github.com/rime/librime) | macOS 输入法与 Rime 运行时基础；修改了产品身份、单输入源双语工作流、候选交互、原生 Settings 与发行打包 | GPL-3.0-only（Squirrel）；BSD-3-Clause（librime） |
| [Rime Wanxiang](https://github.com/amzxyz/rime-wanxiang) | 中文词典核心与八种全拼/双拼布局；锁定上游表，并应用经过审核的读音、错码与排序修正 | CC BY 4.0 |
| [RIME-LMDG](https://github.com/amzxyz/RIME-LMDG) | 锁定并离线打包 Wanxiang LTS 语法模型 | CC BY 4.0 |
| [rime-ice](https://github.com/iDvel/rime-ice) / [HallelujahIM](https://github.com/dongyuwei/hallelujahIM) | 选取 rime-ice 三字及以上中文扩展词及英文、部件、符号、Emoji/OpenCC、Lua 输入，并选取 Hallelujah 词频、发音与释义输入；经确定性投影、归一化和人工审核生成 Linnet 数据 | GPL-3.0-only；精确适用范围见第三方声明 |
| librime-lua、librime-octagram、librime-predict 及其他运行时依赖 | 随 App 静态集成或嵌入，未作为第二套产品来源 | 以第三方声明、发行 NOTICE 与 SBOM 为准 |

完整的来源范围、修改说明和许可证关系见[第三方来源、修改与许可证](THIRD_PARTY_NOTICES.md)，许可证文本见 [`LICENSES/`](LICENSES/)。正式发行包还会携带绑定到精确版本与提交的 `NOTICE.md`、`SBOM.spdx.json`、`VERSION.json` 和许可证文件，避免 README 摘要与实际交付内容漂移。

Linnet 自有源码采用 [GPL-3.0-or-later](LICENSE.txt) 许可证。
