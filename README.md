# Linnet

<p align="center">
  <img src="resources/branding/readme-banner.svg" width="680" alt="Linnet — Chinese and English, in one flow">
</p>

Linnet（双韵）是一款为 macOS 打造的开源双语输入法。它把中文输入与 Smart English 放进同一个系统输入源：轻按 Shift 即可往返，Caps Lock 则随时进入不经过转换的原始 ASCII。

**一个输入源，两种语言，一种连贯的输入体验。**

> [!NOTE]
> 当前正式 Release 只提供一个完整安装包 `Linnet.pkg`。它没有使用 Apple Developer ID 签名，也未经过公证；macOS 可能拦截安装并要求用户手动确认信任。SHA-256 直接写在同一 Release 的说明中，Core 与语言数据组件则位于同仓库、明确标注的更新频道，不再与普通用户下载混在一起。

**[下载最新版 Linnet.pkg](https://github.com/Ares-X/Linnet/releases/latest)**

本文对应本分支版本；正式可下载版本以 Latest Release 为准，各版本的功能与变化见[版本记录](CHANGELOG.md)。

[产品体验](#产品体验) · [性能与体积](#性能与体积) · [安装](#安装) · [使用指南](#使用指南) · [设置](#设置) · [隐私](#隐私) · [参与贡献](#参与贡献)

[精校与增强](#基于成熟上游由-linnet-精校与增强) · [拼音反查英文](#拼音反查英文) · [自定义词与 Text Expander](#自定义词与-text-expander) · [版本、来源与许可证](#版本来源与许可证)

## 为什么选择 Linnet

- **中英自然切换**：中文与 Smart English 共用一个 macOS 输入源，不用在系统输入法列表里来回寻找。
- **完整的中文体验**：内置全拼与七种双拼方案，共用同一套中文候选、学习数据和本地语言模型。
- **真正面向英文输入**：Smart English 提供补全、拼写建议、IPA、中文释义、上下文预测与连续输入处理，同时始终保留原始输入。
- **离线且可掌控**：个人词、学习数据、Text Expander 和备份默认保存在本机；启用后，macOS 通过 Linnet 固定的 `iCloud Drive/Linnet` 目录同步 Rime 学习词。
- **原生 macOS 产品**：菜单栏状态、候选窗与 Settings 形成统一体验，并提供浅色、深色和多套候选主题。
- **核心与语言数据分开更新**：更新界面或程序时复用已安装的词库和模型，语言包优先使用差分；支持设置内 Core 更新的版本无需关闭其他应用或再次注销。
- **常用内容随手输入**：自定义词进入正常候选与学习流程，Text Expander 用短码展开地址、邮箱或固定回复；修改后只增量加载实际变化的个人词典。

### 基于成熟上游，由 Linnet 精校与增强

Linnet 复用 Squirrel、librime、万象、RIME-LMDG、rime-ice 与 Hallelujah 的成熟能力，在此基础上完成数据精校、原生英文扩展、双语交互与 macOS 产品增强。上游版本按来源锁定，选取范围、修订与质量审核有记录可查。Linnet 目前在这些基础上完成了：

- **中文精校与补充**：以万象词表和 LTS 语法模型为核心，保留八种全拼/双拼的一致词库与学习数据；通过可审计的审核表修正已确认的读音、错码与候选顺序，并从锁定的 rime-ice 扩展表中补充万象尚未覆盖的三字及以上词条。补充词会先转换到万象的声调编码与权重空间，重复、歧义或无法验证读音的行不会进入产品。
- **英文数据整理**：从 Hallelujah 与 rime-ice 的锁定输入中选择词频、发音、中文释义和补充词条，经过确定性归一化、去重、格式检查和人工质量审核后生成 Linnet 的英文数据。
- **原生 Smart English 增强**：复用 Rime 的英文前缀补全与学习能力，由 Linnet 的 C++ 插件补充模糊匹配、纠错排序、IPA 与释义、原始输入候选、上下文排序、下一词预测交互及连续输入的空格处理，并把拼音反查接入同一套候选体验。
- **双语排序与输入语义**：在中文候选与明确英文单词发生碰撞时，结合当前拼音方案、完整编码、静态词频与学习结果决定顺序；由 Linnet 统一协调补全、纠错、预测、大小写、Space/Return、Tab、数字选词、方向键和原始输入，让两种语言在同一个输入源内配合。
- **macOS 产品增强**：在 Squirrel/librime 运行时之上提供单输入源三状态、光标旁状态提示、候选详情、七套主题、原生 Settings、个人数据管理，以及首次注销后无需再次注销的 Core 更新路径。

具体上游版本、选取范围、修改方式和许可证见[第三方来源说明](THIRD_PARTY_NOTICES.md)与[开发指南](docs/development.md)。

## 产品体验

### 一个输入源，三个明确状态

| 状态 | 菜单栏 | 适合场景 |
| --- | --- | --- |
| 中文 | `中` 或 `双` | 全拼或当前双拼、中文候选、本地语法模型 |
| Smart English | `En` | 英文补全、纠错、释义、发音与上下文预测 |
| 原始 ASCII | `A` | 代码、密码、终端和任何不希望被转换的文本 |

独立轻按左 Shift 或右 Shift，在中文与 Smart English 之间切换；Caps Lock 进入或退出原始 ASCII。组合键、Shift 加字母以及长按 Shift 都不会误触发模式切换。
若切换前仍有未上屏的拼音或英文，Linnet 会先原样提交这些字母，不会替用户选择中文候选或英文补全。

![Linnet 中文、Smart English 与原始 ASCII 三种输入状态的真实光标提示](resources/readme/input-modes.png)

_光标旁提示当前输入状态；菜单栏同步显示 `中`/`双`、`En` 或 `A`。_

### 中文输入

Linnet 首次使用默认全拼，也可以在 Settings 中选择自然码、小鹤、微软、搜狗、智能 ABC、紫光或拼音加加。八种方案共享中文词库与学习数据，切换方案不需要重新建立个人词频。候选输出支持简体与繁体切换。

中文可选择标准 Rime 学习、Linnet 增强学习或关闭学习；增强学习会对逐字组成的生僻词组补充学习强化。英文学习单独开关，关闭学习保留已有记录，重新启用后继续使用；需要删除时再到“数据与更新”中清理。

中文候选支持横排或竖排、每页 3/5/7/9 项。选择“可展开”后，首次候选保持紧凑，翻页时展开为对齐网格；展开的行列数量可独立设置，详见下方“外观与个性化”。列宽按完整词测量，宽度不足时减少实际列数，保持词首对齐，不拆词换行或无限拉长窗口。左右键逐项移动，上下键移到相邻显示行的对应位置；越过可见范围时网格整体推进。也可以选择始终按页滚动。

在中文连续输入中，按住 Shift 输入全大写缩写时，缩写会保持原样，左右两侧的拼音仍继续匹配并组成中文句子。

常用辅助入口包括：

- `Shift+V`：符号命令；
- `U` + 十六进制码点：Unicode 输入；
- `cC` + 表达式：本地计算器；
- `uU` + 全拼：部件拆字查询；
- `|` + 当前拼音编码：在中文模式中反查英文；也可在 Settings 中显式改用 `;`。

### Smart English

Smart English 适合连续英文写作，也适合在中文工作流中临时输入术语：

- 前缀补全、自动纠错、模糊单词匹配与下一词预测；纠错和模糊匹配是英文模式的核心能力，不提供关闭开关；预测候选显示 `1–9` 序号，可直接用数字键选择；
- 常见前缀补全结合词频、已有学习与上下文排序；继续翻页可以访问后续候选。
- 可选 IPA 和中文释义；
- 保留首字母大写或全大写；
- Space 上屏时是否自动附加空格可在 Settings 中配置；
- URL、邮箱、路径、版本号和代码标识符尽可能保持原文；
- 原始输入始终保留；已构成完整英文词或明确的全大写缩写时，原文优先于更长的补全结果。

Tab 可以设为智能接受、候选导航，或完全交给当前应用。按 `Esc` 可关闭本次预测并清除当前英文上下文。

![Linnet 拼音反查英文与 Smart English 的真实候选窗](resources/readme/bilingual-features.png)

_左侧为中文模式的拼音反查，右侧为带 IPA 和中文释义的英文补全。_

### 外观与个性化

横向展开的列数和最多行数分别可选 3／4／5，默认 5 列、最多 3 行。候选不足时按实际行数显示，最多不超过 5 行；未展开时仍使用原来的每页候选数量。各列按可见词宽排列并上下对齐，减少短词之间的空白。

候选窗口提供宣纸、月华、青岩、陶印、雾青、原生玻璃和墨朱七套主题，每套都包含浅色与深色版本。中文与英文可以分别选择紧凑状态下的横排或竖排；展开后统一使用多行网格。英文释义显示在网格下方，随高亮候选更新并按实际内容调整高度，不额外预留空白。字体、字号、候选数量和展开方式也可以独立调整。

![Linnet 七套候选窗主题的 Light 与 Dark 实际渲染](resources/readme/theme-gallery.png)

_图中部分主题使用全称，设置中使用简称；透明度和系统材质会随 macOS 外观及当前应用背景变化。_

除了输入外观，Linnet 还支持：

- 自定义词；
- 按完整单词禁用英文候选；
- 以 `x;` 开头的 Text Expander，例如 `x;addr`；
- 中文、英文学习数据的独立开关与清理；
- 个人数据导入、导出、数据变更操作前的恢复点，以及用户手动创建的完整备份与恢复；
- 通过产品固定的 `iCloud Drive/Linnet` 目录增量同步中英文学习词，无需选择文件夹；自动检查严格限制为每小时最多一次，完整个人数据另以手动恢复归档传输。

## 性能与体积

### 本地处理，共享资源，按变化加载

输入前端使用 Swift／AppKit，设置界面使用 SwiftUI，Smart English 以原生 C++ 集成到 Rime。中文组词、英文纠错与预测都在本机完成，无需等待网络请求。

- **跨应用复用语言资源**：运行期间保留已初始化的词库、模型与双语索引，减少新输入会话的重复加载和首键等待。
- **个人词典增量加载**：修改自定义词或 Text Expander 时，只重建实际变化的个人词典，无需重新部署全部拼音方案。
- **同步期间继续输入**：iCloud 文件读写在后台进行，本机学习词合并分批执行，保留正在输入的拼音和候选。

已有本地 Rime 热态按键基准记录为：**英文 p95 0.510 ms，中文 p95 1.392 ms**，即该次测量中 95% 的采样按键处理时间不超过相应数值。这是 0.1.10 阶段的引擎历史测量，范围为按键处理与候选上下文读取，**不包含 macOS 事件传递和候选窗显示，也不是当前版本的整机输入延迟**。测量记录见[验收记录](docs/product-acceptance.md#0110-history-convergence-and-root-cause-index)，测量范围见[引擎基准实现](tests/rime_smoke_test.cc)。

内存与 CPU 占用会随词库加载、输入场景和学习数据变化，目前尚未公布统一环境下的整机基准。

### 下载大小与磁盘空间

完整安装包包含程序、中文与英文词库、本地语言模型和辅助数据；核心更新只更新程序部分。以下是固定版本的参考值，采用十进制 MB：

| 内容 | 大小 | 说明 |
| --- | --- | --- |
| [0.1.15 完整安装包](https://github.com/Ares-X/Linnet/releases/tag/v0.1.15) | **426.8 MB**（407.0 MiB） | 首次安装所需的 `Linnet.pkg`，包含离线语言数据 |
| [0.1.15 Core 更新包](https://github.com/Ares-X/Linnet/releases/tag/core-v0.1.15) | **6.55 MB** | 该版本的桥接 PKG，不包含整套词库与模型；后续核心更新大小以对应版本为准 |
| [当前锁定的 LTS 模型](upstreams.lock.json) | **420.25 MB** | 模型文件的未压缩大小，已包含在完整安装内容中，无需额外下载 |

**下载大小不等于安装后占用。** 磁盘还会保存解压后的语言数据、生成的输入方案、学习记录与备份；总占用随使用情况变化。模型文件大小也不代表它会全量常驻内存。

核心与词包分离后，日常程序升级可复用大体积语言数据。语言包更新优先使用差分，未变化的词包直接复用；无法使用差分时，设置会提示确认完整修复。

## 系统要求

- Apple Silicon Mac（arm64）；
- macOS 13 或更高版本。

## 安装

### 获取社区版本

请从项目的 **[Latest Release](https://github.com/Ares-X/Linnet/releases/latest)** 只下载一个文件：`Linnet.pkg`。进入下载目录后计算哈希：

```bash
shasum -a 256 Linnet.pkg
```

输出必须与同一 Release 说明中列出的 64 位 SHA-256 完全一致。Linnet 安装到当前用户目录，不需要管理员权限，也不会安装守护进程、启动项或特权辅助程序。

### 首次启用

1. 在 Finder 中按住 Control 点击（或右键点击）已校验的 `Linnet.pkg`，选择 **打开**，再次确认 **打开**。若系统没有显示该选项，请打开 **系统设置 → 隐私与安全性**，在 Linnet 的拦截提示旁选择 **仍要打开**，然后返回安装器。
2. 在 macOS 安装器中依次选择 **继续 → 安装**并等待“安装成功”。Linnet 只安装到当前用户的 `~/Library/Input Methods/Linnet.app`；不要把 App 手工拖动或复制到其他目录。
3. 保存工作，注销当前 macOS 账户并重新登录。这一步只在第一次安装时执行，用于让 macOS 完成输入源登记；以后安装 Core 更新不需要再次注销。
4. 重新登录后打开 **系统设置 → 键盘 → 文本输入 → 编辑**。如果列表中已有 Linnet，确认它已启用；如果没有，点击 **+**，搜索或找到 **Linnet**，选择后点击 **添加**，并按 macOS 提示允许该输入源。
5. 从菜单栏输入菜单中选择带小鸟图标的 **Linnet**。选择始终由用户和 macOS 管理，安装器不会代替你切换。这只是一个 Linnet 输入源，不需要分别添加中文和英文。
6. 确认菜单栏显示 `中`/`双`，输入拼音可以提交中文候选；独立轻按 Shift 应显示 `En` 并输入英文，Caps Lock 应显示 `A`；输入菜单中的 **Settings** 应能打开设置窗口。

已完成首次安装的用户，后续从 Settings 检查、下载并应用 Core 更新，不必重新添加输入源；旧版本需先完成一次桥接升级，见[升级与卸载](#升级与卸载)。**安装成功不等于新代码已经运行**：旧式安装包只替换磁盘文件，还需在设置中应用已安装的更新。具体操作见[应用核心更新](#应用核心更新)。

Linnet 不会自动点击系统授权、选择或停用输入源。若 Linnet 被 macOS 移除或停用，请在 **系统设置 → 键盘 → 文本输入 → 编辑** 中重新添加或启用。社区安装包没有 Apple Developer ID 签名或公证，因此“无法验证开发者”是预期提示；只应在文件名和 Release 中的 SHA-256 都校验成功后手动信任。不要关闭 Gatekeeper、清除隔离属性或执行来源不明的安装命令；校验和不一致或系统报告文件损坏时应立即停止。

## 使用指南

### 切换输入状态

- 中文 ↔ Smart English：独立轻按左 Shift 或右 Shift；
- 任意模式 ↔ 原始 ASCII：Caps Lock；
- 当前有尚未上屏的拼音或英文时，先原样提交字母再切换；
- `Shift+字母`、带 Command/Option/Control 的 Shift 组合键与长按 Shift 不切换模式。

系统输入菜单中的小鸟代表唯一的 Linnet 输入源；`中`、`双`、`En`、`A` 才是当前输入状态。

### 拼音反查英文

只记得中文意思时，可以用拼音找英文词，无需离开输入窗口。在中文模式中，先输入 Settings 选择的触发键，再输入当前全拼或双拼编码。默认触发键是 `|`；如果用户明确选择 `;`，分号才会成为反查触发键。

```text
|suanfa  → algorithm
```

选择自然码后，同一示例可以写成 `|srfa`。Smart English 中直接输入当前全拼或双拼编码即可查看英文候选，不使用反查触发键；普通英文候选仍排在前面，拼音结果不会取代原始输入，`;` 等标点始终直接交给当前应用。

### 自定义词与 Text Expander

在 **Settings → 词典**中配置常用名称、短语和固定文本：

- **自定义词**由显示文本和小写 Rime code 组成，会进入正常候选和学习流程。
- **禁用英文词**按大小写不敏感的完整词隐藏静态、学习、纠错、发音和预测候选。
- **Text Expander**触发器必须以 `x;` 开头；未知触发器按原文保留，展开值不会再经过大小写、空格或释义处理。

例如，添加触发器 `x;addr`，将展开值设为完整地址；以后输入这个短码即可展开保存的文本。

点击 **应用更改** 后，Linnet 只更新本机个人数据并增量加载实际变化的词典；不会为一条自定义词或 Text Expander 重新部署全部输入方案。

## 设置

从 macOS 输入菜单选择 **Settings**，界面支持 English 与简体中文。设置窗口内嵌在 `Linnet.app` 中，不会作为独立应用安装，也不会常驻 Dock。

| 标签 | 可以管理的内容 |
| --- | --- |
| 外观 | 七套主题、浅色/深色、字体、字号、候选数量、横排/竖排与候选展开方式 |
| 输入 | 中文区管理全拼/双拼、学习、简繁、Emoji、标点、辅助码和反查；Smart English 区管理自动大写、IPA、释义、预测、学习、Space 尾随空格和 Tab；英文纠错与模糊匹配始终可用 |
| 词典 | 自定义词、禁用英文词与 Text Expander |
| 数据与更新 | Core 与词包版本、iCloud Drive 增量学习同步、手动增量恢复备份、事务恢复记录、导入导出、学习数据清理与隐私处理后的诊断 |

主题卡片上下展示同一套主题的浅色、深色候选小样，包含真实编号、文字和选中样式。宣纸是暖纸色与琥珀下划线，月华是玉绿竖线，青岩是冷蓝方角高亮，陶印是陶土色圆角块，雾青是半透明青绿，原生玻璃是系统材质与蓝色高亮，墨朱是黑白底与朱红下划线。界面主题随 Core 更新，设置预览与实际候选窗使用同一套主题资源；无需更新词包，也不会重置已选主题、字体和字号。

外观预览会使用所选主题、字号与布局；需要改变输入行为的选项在点击 **Apply Changes** 后生效。请不要手工编辑 Linnet 生成的 `linnet_user.custom.yaml`、`squirrel.custom.yaml`、`default.custom.yaml` 或 schema custom 文件。

Settings 每次打开时会从同一 GitHub 仓库读取一个经过校验的小型 Catalog，并在“Data & Updates / 数据与更新”中安静显示“已是最新”、Core 更新或具体语言数据更新。更新频道可选择 **正式版**（默认）或 **预览版**；两者的 Core 检查和语言数据下载始终使用同一个所选 Catalog，不会自动切换或回退。同一区域还会比较磁盘上已安装的 Core 与当前 Host 的版本和 build，避免把“安装成功”误报成“新代码已经运行”。源码 revision 仅在高级详情中显示。输入进程始终离线；检查不会下载大型词库，也不会弹出系统通知。只有用户明确点击语言数据更新后，Settings 才会下载并校验语言包，再通过现有事务原子激活。

本地语言数据比频道版本更新时，会明确显示“已安装的语言数据领先于此更新频道”，不会提示降级或下载旧包。语言包以各自的 Data release 序号比较新旧；整组更新必须兼容且不让任何已有包倒退，同一序号对应不同内容会报告校验失败。已有词包优先下载与当前内容匹配的差分，不变词包直接复用。缺少可用差分或差分校验失败时，保留当前数据，只有再次确认完整修复后才下载有变化的完整词包；首次安装尚不存在的词包需要完整基线。

手动上传恢复备份时，第一次建立完整基线，之后只上传不可变差分；没有变化则不重复上传。恢复链损坏需要单独确认新建完整基线，不会静默覆盖旧备份。这与每小时至多一次的 Rime 增量学习同步相互独立；完整迁移文件仍可手动导出。

## 升级与卸载

Linnet 不会在后台自动修改 Core。Settings 检查到更新后，只有用户点击 **下载核心更新 / Download Core Update** 才会下载并校验 Catalog 绑定的精确文件。安装了 0.1.15 桥接版后，后续 Core 可在设置中点击 **应用更新… / Apply Update…** 完成：先切换到其他输入法，其他应用保持打开，不需要 Installer、密码、注销或重启。

正式版本页只提供完整安装包；`core-v<version>` 预发布页供已有用户免注销更新，`data-<sequence>` 预发布页供 Settings 更新语言数据。它们不会成为 Latest Release。

0.1.15 是一次性桥接版：0.1.14 及更早的固定 CMS 版本仍会下载旧式 Core PKG，并显示 **打开旧版安装器… / Open Legacy Installer…**；只需按 macOS 提示完成这一次升级。之后在 Settings 中下载并应用核心更新即可，不需要寻找发布页中的文件或手工比对哈希。0.1.7 或更早的旧 ad-hoc 版本、App 缺失或损坏时仍须运行完整 `Linnet.pkg` 修复。

### 应用核心更新

1. 从 Linnet 输入菜单打开 **Settings**。
2. 进入 **数据与更新 → 核心更新**（**Data & Updates → Core update**）。查看“已安装”和“正在运行”：前者是磁盘上的版本，后者是当前输入法进程实际加载的版本。
3. 若有可下载的 Core 更新，先点击 **下载核心更新**，等待下载和验证完成。
4. 完成或取消当前组词，再从 macOS 输入菜单切换到其他输入法，保留正在使用的应用窗口。
5. 新式在线更新点击 **应用更新…**（**Apply Update…**）；若刚通过旧式 PKG 完成桥接，则点击 **应用已安装的更新…**（**Apply Installed Update…**）。不要把它们与用于保存设置的 **Apply Changes** 混淆。
6. 操作完成后切回 Linnet，输入几个字确认候选窗正常；回到核心更新卡片，确认“正在运行”与“已安装”一致。

从 0.1.10 升级后，如果 Settings 窗口在升级前已经打开，请关闭并从 Linnet 输入菜单重新打开这个设置窗口，再进行备份、导入或修改数据。旧窗口不认识新的增量学习数据格式，其数据操作会被拒绝；无需退出正在使用的其他应用，也无需注销。

没有待应用更新时，按钮置灰是正常的。有未保存的设置或正在进行的数据操作时，请先完成页面提示的操作。应用被阻止时，根据卡片说明处理后重试；Linnet 不会替你切换输入源或强制关闭用户应用。若旧版 Host 不支持当前会话内应用更新，会明确提示等下次正常登录或重启后生效，不应反复重装或删除输入源。支持会话内更新的 Host 无需注销。

固定 CMS 版本之间的正常升级只使用 Core；0.1.7 或更早的旧 ad-hoc 版本，以及 App 缺失、损坏或发布身份不符时，使用完整 `Linnet.pkg`。Complete 保留健康的已安装词包与个人数据；若 App 已存在，它也不会触碰输入源状态。注册缺失或停用由 **系统设置 → 键盘 → 文本输入 → 编辑** 处理，而不是让安装器重复申请授权。重复、冲突或无法验证的系统残留必须先执行下文的离线卸载命令，再重新安装 Complete。不要手工复制 App 或绕过检查。

### 卸载

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

## 故障排查

### 系统找不到 Linnet

- 确认安装位置是 `~/Library/Input Methods/Linnet.app`；
- 完成一次真正的注销并重新登录；
- 在 **系统设置 → 键盘 → 文本输入 → 编辑** 中手动添加并允许 Linnet；
- Control-Space 只会轮换 macOS 已启用的输入源，Linnet 不接管这个系统快捷键。

### 只能输入字母

- 菜单栏为 `A`：关闭 Caps Lock；
- 菜单栏为 `En`：轻按 Shift 返回中文；
- 没有 `中`/`双`：在 **Settings → 输入**选择中文方案并应用，再重新选择 Linnet。

### Settings 无法应用

不要手工修改生成的 YAML。前往 **数据与更新 → 诊断**（**Data & Updates → Diagnostics**）刷新并复制诊断；公开前仍需人工检查文本与截图，避免包含个人信息。

### 报告问题

请提供 macOS 版本、Mac 芯片、Linnet 版本、下载文件 SHA-256、当前状态、Rime 方案、发生问题的应用和最小复现输入。不要提交个人词典、学习数据库、私钥、证书密码或完整用户目录。

## 隐私

Linnet 没有账户体系、遥测、广告或分析 SDK，也不调用在线翻译、在线拼写或生成式模型。输入处理在本机完成；个人词典、学习数据和本地备份默认保存在以下目录：

```text
~/Library/Application Support/Linnet/
```

启用 iCloud 同步或手动上传备份后，相应个人数据也会进入你的 iCloud Drive。

只有用户在 Settings 中明确选择导入时，Linnet 才会读取其他 Rime 或 Hallelujah 数据。导出文件可能包含用户主动选择的个人数据，需由用户自行妥善保存与删除。

iCloud Drive 学习词同步由用户显式启用，但目录固定为 `iCloud Drive/Linnet`，不提供目录选择器。Linnet 使用其中的 `Linnet-Rime-Sync` 目录，按设备交换标准 Rime 学习词快照，并由原生合并器增量合并中英文学习记录；自动周期最多每小时一次，用户也可主动点按“立即同步”。云目录读写在后台进行，本机合并分成短小批次，不进入输入法维护模式、不清空正在输入的拼音或候选。

尚可撤销的学习事务会保留；取消、重开词库或远端快照变化后，恢复合并仍保留原有学习结果。未加载的词库等自然启用后再同步，复制期间又有修改的词库延后重试，不阻塞其他词库。学习内容没变化时不会重写云端快照，过大的新快照不会替换上一次可读取的副本。Linnet 使用标准 Rime 学习记录，云端传输由 macOS 的 iCloud Drive 完成。

自动同步只处理学习词，不运行 Rime 配置备份；自定义词、停用词、Text Expander 和设置不属于学习词同步。需要迁移这些数据时，可手动上传或审阅 `Linnet-Full-Backup.linnet-data`；导入仍需确认，并会先创建本地备份。

更新联网由 Settings 处理：打开设置时向 GitHub 请求小型更新目录以检查版本，用户明确点击核心或语言数据更新后才下载对应文件。两者都使用“数据与更新”中的下载源选择；更改来源只影响之后开始的下载，不会自动切换或回退。第三方下载镜像可能看到 IP、请求时间与公开文件 URL，但 Linnet 不会向 GitHub 或镜像发送个人词典、学习数据、备份、诊断或凭据。

## 参与贡献

构建 Linnet 需要 Apple Silicon Mac、macOS 13+、完整 Xcode、Git 和 `ripgrep`。项目主要使用 Swift/SwiftUI、C++、Shell 与 Ruby，不携带 Python 运行时。

```bash
./action-build.sh release
tests/verify_swift_units.sh --list
tests/verify_swift_units.sh --only OWNER
```

日常改动只运行所属 owner 的 focused 测试；准备冻结候选时才运行一次
`scripts/release-control verify-local` 完整本机验收。

已有完整依赖缓存时，可以离线构建：

```bash
no_download=1 ./action-build.sh release
```

普通开发不需要签名证书，也不需要把本地构建注册为系统输入法。目录结构、数据生成、上游同步、测试层级与本机验收方法请阅读[开发指南](docs/development.md)；打包、签名和公开发布流程请阅读[发布指南](docs/release.md)。

## 版本、来源与许可证

当前正式版本见 [Latest Release](https://github.com/Ares-X/Linnet/releases/latest)；本分支版本为 **0.1.16（预览版）**。完整的用户可见变化见[版本记录](CHANGELOG.md)。

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
