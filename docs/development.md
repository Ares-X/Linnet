# Linnet 维护开发指南

本指南面向贡献者和维护者，说明当前源码结构、唯一 owner、构建入口、数据更新、验证层级和提交约定。用户安装、操作、配置与隐私说明统一见 [README](../README.md)；正式候选与发布流程见 [release.md](release.md)。

## 支持与工具

- Apple Silicon arm64；
- macOS 13+；
- 完整 Xcode；
- Swift / SwiftUI、C++、Shell、Ruby；
- ripgrep（`rg`，只供源码与架构检查使用，不进入 App 或安装包）；
- 锁定的 Git 子模块和下载输入。

项目自有构建、数据生成、校验和发布路径不使用 Python。上游子模块可能包含自己的语言或工具，但不得因此把 Python 引回 Linnet 的 steady-state owner。

源码结构门依赖真实 `rg` 的匹配与退出码语义，不使用仓库内的近似 shim。开始验证前先确认 `command -v rg` 成功。

## 变更与贡献

1. 先检查 `git status --short`，保护与任务无关的 staged、unstaged 和 untracked 文件。
2. 缺陷修复先记录最小复现、精确 revision 和最早错误 owner。
3. 先新增或确认能表达产品要求的 focused test，再修改生产 owner。
4. 一个变更只处理一个清晰 owner 边界，不混入无关重命名、格式化或框架迁移。
5. 删除被替代的 wrapper、fallback、重复默认或推断路径，不能只在旧路径外再包一层。
6. 先运行 focused gate，再运行相称的 development composite。
7. 报告必须分开写明源码、构建、安装态和真实用户验收；较低等级 PASS 不能替代较高等级。

提交或 Pull Request 应说明用户可见结果、唯一 owner、退役路径、变更文件、实际验证、未执行工作流，以及数据、兼容、隐私和许可证影响。不要提交生成缓存、构建产物、用户数据、DiagnosticReports、私钥、证书、密码或开发机绝对路径。

## 目录

| 路径 | 职责 |
| --- | --- |
| `sources/` | InputMethodKit 前端、候选窗、Host 生命周期和共享产品代码 |
| `sources/LinnetSettings/` | Settings UI、typed document、personal data、backup、Registry 与 IPC |
| `plugins/smart_english/` | Smart English 原生 Rime plugin |
| `data/linnet/` | Linnet 自有 schema、默认值、英文决策和静态产品数据 |
| `data/chinese/overrides/` | 已复现、人工接受的中文读音与排序决定 |
| `patches/` | 对精确上游源码应用且摘要锁定的必要补丁 |
| `scripts/` | 上游同步、runtime build、数据 staging 和 metadata 工具 |
| `package/` | 当前用户域 PKG、语言包和 publication plan；卸载命令由 README 直接提供 |
| `tests/` | focused、engine、package 和 product gates |
| `upstreams.lock.json` | 所有上游版本、提交、输入摘要与直接上游集合 |
| `config/linnet-data-releases.json` | Chinese/English/LTS/Extended release identity |

`data/plum`、`build`、`lib` 和 `bin` 是生成或复制投影，不是上游或产品事实 owner。不要直接修它们来让测试通过。

## 运行时架构

### 输入状态

macOS 只看到一个 Linnet 输入源。Rime 内部包含八个中文 profile 和一个 `linnet_en`：

- `ascii_composer` 负责独立 Shift、组合键、长按、未上位编码的原样提交和 Caps Lock；
- 紧随其后的 `linnet_mode_switch_processor` 只把已确认的 Shift 转换映射为中文/Smart English schema 切换；
- 当前 `Context` 保存直接 Shift 的来源中文 schema，返回后清空；
- Settings typed document 唯一拥有中文方案选择；fresh document 默认全拼，已有 document 的显式选择保持不变。renderer 将同一选择投影为 `default.custom.yaml` 的首个中文 schema、Smart English 反查 Prism 和直接 Shift 返回目标；
- `switcher/fix_schema_list_order=true` 让 fresh session 只消费该确定性顺序，旧 `user.yaml/var/previously_selected_schema` 不再拥有选择权；输入前端不在每次按键时推断方案、不保存第二份模式表，也不重新判断 Shift 时长。

### 中文

中文表直接来自 `upstreams/rime-wanxiang/dicts/*.dict.yaml` 的锁定 allowlist。所有 profile 共享 `linnet_zh` dictionary/userdb、LTS grammar 和产品 filter 链，只投影不同的 speller algebra 与 preedit。

Linnet 差异只有两个人工 owner：

- `reviewed_pronunciations.tsv`：已接受的读音替换；
- `reviewed_rankings.tsv`：已接受的精确排序行。

精确 source patch 删除被拒绝的 `(text, code)`，`linnet_reviewed` 表添加接受行。锁定的 `rime-ice/cn_dicts/ext.dict.yaml` 是唯一中文补充输入：构建期投影器只接收万象核心尚未拥有的三字及以上行，使用万象 `zi` 表转换声调编码，拒绝歧义或无法验证的读音，再以低权重导入同一个 Rime dictionary graph。不存在提交进仓库的生成词典、第二个运行时 translator、自动猜音或运行时 fallback。

维护更新必须修改唯一 review ledger/source patch，而不是生成第二份中文词典或运行时修正规则。

### Smart English

标准 Rime table translator 拥有普通英文 prefix 和 userdb。Linnet 原生 plugin 只拥有成熟 Rime 没有提供的边界：

- forced-raw 安全候选；
- Phonex 与本地有界距离排序；
- IPA、中文释义和 skip metadata；
- session spacing、sentence boundary、context rank 与 learned bigram；
- prediction UI 行为；
- 中文 exact 候选与普通英文表候选的当前会话同-span 顺序；
- 拼音到英文投影的 typed lookup。

不要把普通 prefix、学习或 schema 选择重新实现进 plugin，也不要新增 SQLite、网络、系统拼写检查器或第二个英文词典运行时。

### Settings 与数据

Settings document 拥有候选外观、中文默认项、反查触发键、学习策略和 Smart English 交互开关；personal store 拥有自定义词、禁用词与 Text Expander。唯一标准 personal runtime patch `linnet_user.custom.yaml` 只投影禁用词；document-owned 句首大写与 Tab 确定性投影到八份中文 schema custom 和一份英文 schema custom。旧 `linnet_user.yaml` 仅作一次性迁移输入并在成功写入后退役。

只改变 document 的 Apply 仅在 `Transactions/<UUID>/configuration-candidate/` 暂存一份 `linnet_settings.json`。Host 校验候选与 expected/base revision，以唯一 live document 为 canonical owner 执行 CAS 和同卷原子交换，再从已发布 document reconcile 可重建 custom YAML、按固定顺序部署 exact 11 份 config（default、九个产品 schema 与 squirrel），使旧 session generation 失效并用 fresh session 验证所选方案。成功必须回报同一 SHA-256 `activeSettingsRevision`；交换、reconcile、部署或健康检查失败时，Host 原子换回旧 document、重新 reconcile/deploy 并验证旧 revision，无法验证则 fail closed。Host 启动也会在 Rime 接受输入前从 canonical document 向前 reconcile。该快速路径不 finalize Rime、不运行 maintenance、不重编词典，也不创建备份。个人表变更在隔离候选中按内容差异重建对应 stabledb，未变化且有 canonical source 的数据库以 APFS clone 复用；Host 原子交换后只重新打开已部署配置，不运行 schema maintenance。语言数据激活仍执行完整候选部署和健康检查。

Core App 拥有界面主题，但不携带语言数据。`data/squirrel.yaml` 同时进入 Host 和 Settings 的资源包；Host 在 Rime 初始化前由现有 ProjectionRenderer 将其投影到 UserData，再由 Rime 按标准流程应用用户外观选项。只有 Core 主题字节改变时才重建 `Build/squirrel.yaml`，不会清空词典或学习缓存。旧词包可以保留原有不可变主题文件，但不再决定实际界面；新词包不再包含它。

Chinese、English、LTS 和 Extended 各有独立
`(kind, sequence, version, content_sha256, data_abi, min_core)`，通过一个完整 Active
视图消费；只有对应 pack 内容或兼容边界变化才推进该 pack。Catalog 保持现有 JSON
格式，但发布身份是 `data-channel` 的精确 commit/blob；它引用当前 Core 和当前四个
不可变 pack。Core-only 更新生成新的 Catalog snapshot，却复用原 data Release 和所有
未变 pack sequence。精确格式和文件成员由 Registry、package 工具及其结构门共同验证；
文档不维护第二份成员清单。

## 上游和依赖

`upstreams.lock.json` 是唯一版本 owner；`.gitmodules` 和 gitlink 是受验证投影。直接产品上游集合固定为：

1. Squirrel / Rime；
2. rime-ice；
3. Hallelujah；
4. rime-wanxiang；
5. RIME-LMDG。

公开源码以一个独立根快照发布，不继承 Squirrel 的 Git 父链。Squirrel 来源由 lock 中的精确 tag/commit 和发布 SBOM 的 `VARIANT_OF` 关系共同证明；构建不得从当前分支的祖先关系推断来源。

rime-ice 提供锁定的英文补充、OpenCC/符号/部件数据、选择的 Lua 源，以及唯一选中的中文扩展输入 `cn_dicts/ext.dict.yaml`；后者只在构建期通过上述投影边界补充万象缺词，不提供 runtime schema 或第二套中文候选 owner。Hallelujah 原始应用、localhost UI、JavaScriptCore 和运行时 SQLite 不进入产品。

查看候选更新：

```bash
scripts/upstream-sync report
```

验证当前 lock/gitlink/输入：

```bash
scripts/upstream-sync verify
```

`report` 不得修改仓库。升级时在隔离 checkout 中同时更新精确 lock 和 gitlink，比较 effective product projection；不能直接合并 Stable，也不能从运行时自动跟随上游。

上游升级始终先在本地完成：获取候选 revision，审查许可证、源码差异、现有
patch 是否仍精确适用，以及 Linnet 自己的词典和交互优化是否被保留；然后运行
focused 测试、`scripts/upstream-sync verify` 与完整 product gate。只有这些结果都
通过后，才在同一个提交中更新 gitlink、`upstreams.lock.json`、必要 patch 和数据
release identity。定时 GitHub workflow 只报告候选更新，不得自动修改仓库、合并
上游或发布。

正常正式候选先由 `scripts/release-control verify-local` 恢复并校验锁定依赖、构建，
串行完成 strict lint、发布 owner、App/Swift/Rime 和 Periphery。验证期间冻结修改；
临时 Git index 将待提交文件、删除、权限和 gitlink 绑定到一个 Git tree，不改真实
暂存区；首尾 tree 必须相同。唯一收据位于 ignored
`build/linnet-source-verification.json`，是维护者的本地验收声明，不是云端独立测试证明。
`verify-local` 不启动桌面 UI 自动化，收据中的 Settings UI 记为 `NOT_EXERCISED`。
在有 Developer Mode 的专用测试桌面单独运行
`scripts/release-control verify-settings-ui`，只补跑 UI 验收，不重复已通过的非交互检查。
它要求同一 source tree 的本地收据；失败或中断保持未通过，候选申请仍会拒绝。
独立 bundle ID、数据目录和 `CFFIXED_USER_HOME` 不隔离鼠标、键盘、焦点或输入源会话；
不得在维护者正在使用的桌面运行 XCUITest。

仅在维护者明确要求先发布预览、稍后验收时，可用 `candidate-preview "原因"`
代替完整收据申请；它记录未测试状态，不执行测试，且不能用于正式发布。详见发布文档。

提交相同 tree 后，在 clean、精确远端 `main` 上执行
`scripts/release-control candidate`，创建携带收据的 annotated
`linnet-candidate/v<VERSION>-<FULL_REVISION>` 标签；不再手动推送裸标签。
唯一 macOS release Action 验证标签、commit、tree 和必需测试结果，一次
checkout/cache/hydrate，保留历史相关的版本单调性检查及实际签名 App/package 门。
不重跑已由收据绑定为 PASS 的源码、Rime 或 Settings UI 测试。它使用临时 Keychain
构建、签名、打包和最终验证一次。
互不重叠的 Core 2 件、data 4 个完整词包及对应差分和 public 1 件直接写入三个 Draft GitHub
Releases。候选传输
不使用 GitHub Actions artifact，也不把正式签名字节从本地上传。

RIME-LMDG 的上游 `LTS` 资产允许原作者在同一 URL 原位替换，因此普通冷构建只从
lock 指定的同仓库固定 `data-N` LTS pack 恢复，再由 PackTool 验证容器、内部模型
bytes 和 SHA-256。接受新模型时，维护者仍先在隔离 checkout 预计算未来 LTS pack
摘要，并在同一个最终提交写入上游原始模型身份、未来 `data-N` 身份和数据 release
identity。由于未来 `data-N` 尚不存在，只有显式
`linnet-data-seed/v<VERSION>-<SEQUENCE>-<FULL_REVISION>` 标签可以启动 seed：

- macOS Action 只在这个显式模式从上游锁定 URL 下载原始模型，并先验证 lock 中的
  bytes/SHA-256；
- 同一个 Action 完成正式的完整 manifest 产物构建和
  `package/verify_publication_artifacts`，但只暂存并公开四件 data 预发布资产；
- seed 不创建 Core/Public Release，不写 `data-channel`，因此已安装用户看不到它；
- 只有同一个 `candidate_revision` 可以快进到 `main`；随后正常 candidate Action
  必须从已发布的固定 `data-N` pack 冷构建并得到相同 data bytes。

进入安装验收时，本地只下载 candidate Action 的三个 Draft Release 原字节。离线安装、
功能和 UI 验收通过后，`scripts/release-control preview /absolute/release-directory`
重新验证完整候选并只创建 `linnet-preview/*` 标签；Ubuntu publisher 公开既有
Core/data 预发布并推进 `preview-channel`，不触碰稳定 Catalog、Public 或 Latest。
从旧版 Settings 选择 Preview 完成真实在线升级和跨 Mac iCloud 验收后，再运行
`scripts/release-control authorize /absolute/release-directory`。正式标签复核同一批
字节，推进 `data-channel`，最后公开 public / Latest。两个 Catalog 各有一个固定 URL，
Settings 只消费用户明确选择的一个频道，不自动回退。

GitHub Actions 会缓存锁定下载、runtime 构建依赖、经 fingerprint 和 inventory digest
验证的原生 Rime 编译 transport、固定 Periphery binary，以及英文生成数据。手动
commit CI 是共享 build cache 的 writer；PR、正式候选和 data-seed 只读 main cache。
GitHub [不允许不同标签相互读取各自的 cache](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache)，因此候选不再写只能由同标签复用的副本，
也不搬运或编译已本地验证的 Swift 测试 cache。Swift owner tests
只使用 `tests/swift_test_cache.sh` 的独立内容指纹 cache，不存在第二个静态模块编译
owner。缓存不是版本或发布权威：
每次运行仍由 `action-install.sh` 校验 commit、tree、摘要、内部 fingerprint 与产物
形状，不匹配时只重建受影响部分。

PR CI 和手动 commit CI 都只验证干净 checkout/SDK 边界：恢复锁定 cache、检查 lint、
publication/data identity，hydrate 一次、完成一次 unsigned App build，再运行 Periphery。
Swift owner、native Rime、Settings UI 和真实产品流程只由绑定精确 tree 的本机收据负责，
不在 Action 重复。`main` push 不自动执行完整验证；连续 PR 更新只保留最新一次。

## 构建

普通本地 Release：

```bash
./action-build.sh release
```

已有完整校验输入后的离线构建：

```bash
no_download=1 ./action-build.sh release
```

该路径：

- 从锁定源码构建 arm64 librime 与 plugin；
- 构建 Smart English 原生 plugin 和确定性数据；
- staging 当前 schema、字典、Lua、OpenCC 和 grammar；
- 构建本地 unsigned development App；
- 不安装、注册、启用或选择输入源；
- 不创建公开 PKG，也不授权发布。

本地构建保留正式 `Linnet.xcodeproj` 的标准 App target，只在 DerivedData 中生成一份
构建投影：Host target 使用不产生 Launch Services 注册任务的 bundle product type，
同时强制输出 `.app`、`APPL`、Mach-O executable 和 `PkgInfo`；Settings 继续使用标准
App target 与独立的 `.local-build.settings` 身份。构建前后不会调用 `lsregister` 清理，
也不会触碰已安装 Linnet 的 TIS 授权。Periphery 复用同一个构建 owner。

`build/Local/Build/Products` 永远只保存 unsigned 的 `.local-build` 身份，不会再被原地改写成
生产输入源，也不会被打包。`community` 只在 `build/Candidate.noindex/Intermediates.noindex` 中短暂
建立 `.app` staging，复制本地产物后才投影正式 bundle ID、release metadata 与固定 CMS
签名；全部校验通过后以 `Linnet.candidate` / `Settings.candidate` 目录冻结。
`verify_product`、PKG 和 ZIP 只消费这份候选，打包时才在一次性工作目录中重建
`Linnet.app`。`.candidate` 和 `.payload` 后缀不是 Launch Services 隔离机制；
`.noindex` 仅限制索引发现，不阻止显式注册。暂存脚本要求真实路径位于 `.noindex` 内；
不得将正式身份的展开副本复制到普通 UAT、报告或临时目录长期留存。
留存与传输优先使用现有 PKG/Core 包；需要保留签名构建树时使用普通 tar/ZIP 归档，
只在专用测试环境解压。不要靠注册后再注销副本来清理开发环境。
Xcode 本地产物与可安装生产身份仍保持分离。

普通贡献者运行到 `release` 即可，不需要证书或 Keychain。正式 `archive` lane
由 macOS release Action 使用仓库钉住的固定 community CMS leaf；缺少精确身份时
会在打包前失败，不会回退到 ad-hoc。维护者 Mac 上的同身份 `archive` 只作预检，
不能成为候选或上传源。旧 `candidate` lane 与自定义 UAT 签名 profile 已删除；
任何可安装候选只认固定 production CMS identity。

## 社区版打包

### 一次性配置本机预检签名身份

本地预检身份属于维护者工具，不属于 Linnet 产品数据，README 的离线卸载命令也不会清理它。先把固定
P12 和它的一行密码分别放到以下仓库外路径，两者都必须是当前用户拥有、权限为
`0600` 的普通文件：

- `~/Library/Application Support/Linnet Maintainer/Signing/community-cms/community-cms.p12`
- `~/Library/Application Support/Linnet Maintainer/Signing/community-cms/p12-password`

只在这台 Mac 从未配置过该身份时运行一次：

```bash
scripts/provision-community-signing
```

这个唯一 provisioning owner 会核对仓库钉住的 SHA-1/SHA-256，随机生成 Linnet
专用 Keychain 密码，配置 `/usr/bin/codesign` 的访问分区，完成一次非交互签名探针，
再把 Keychain 锁回。输出固定为
`~/Library/Keychains/Linnet-Community-CMS.keychain-db` 和权限 `0600` 的
`~/Library/Application Support/Linnet Maintainer/Signing/community-cms/keychain-password`。
任一输出已经存在都会直接停止；命令没有 replace、repair 或 delete 模式。失败时只
清理本次创建的精确目标并恢复原 Keychain 搜索列表。P12 密码和随机 Keychain 密码都
不是 macOS 登录密码；如果配置或之后的 `archive` 弹出密码框，应取消并排查，不要
输入登录密码、删除既有目标或重复运行配置命令。本地预检 signer 只消费这两个固定输出。

发布维护者可以在自己的 Mac 上预检固定 production CMS 打包。前提是：

- 工作树已经形成一个干净的本地 commit，`LINNET_CANDIDATE_REVISION` 精确等于 HEAD；
- focused、`tests/verify_development.sh` 和普通 `./action-build.sh release` 已通过；
- 固定生产 Keychain 已一次性配置，且脚本能从权限 `0600` 的仓库外密码文件
  非交互解锁；
- 输出目录是贡献者新建的空绝对目录。

```bash
export LINNET_CANDIDATE_REVISION="$(git rev-parse HEAD)"
export ARCHIVE_OUTPUT_DIR=/absolute/path/to/new-empty-output

./action-build.sh archive
```

`archive` 会沿同一链生成并验证固定 CMS leaf 的 App、未签名的 Complete/Core
两个 PKG、确定性语言包和 sidecar；卸载命令从对应版本源码标签读取，不是发布资产。
不要另写脚本重签或修补输出。由于 CMS
签名时间会改变字节，这个本地产物不是正式发布候选；正式安装验收必须下载
`release-ci` 直接写入三个 Draft GitHub Releases 的同一 manifest 产物原字节。

### 本地安装验收与 macOS 安全检查

社区安装包没有 Apple Developer ID，也没有 Apple 公证。只有在独立确认精确 source
revision、Draft Release SHA-256 和候选 metadata 后，才可以使用 macOS 的单次标准信任流程：

1. 在 Finder 中按住 Control 点击或右键点击已经校验的 PKG，选择“打开”。
2. 如果系统只报告无法验证开发者或无法检查恶意软件，打开 **系统设置 → 隐私与安全性**，在安全性区域选择 **仍要打开 / Open Anyway**；该按钮通常只在打开尝试后约一小时内出现，具体界面以 [Apple 的当前说明](https://support.apple.com/guide/mac-help/mh40616/mac) 为准。
3. 再次核对显示的文件名并确认；macOS 可能要求当前账户的登录密码。
4. 如果提示文件损坏、包含恶意软件，或身份、文件名、摘要与本地候选不一致，立即停止，不要继续安装。

不得用 `xattr` 清除隔离属性、关闭 Gatekeeper 或修改系统安全策略。公开用户流程使用同一套 Finder / 隐私与安全性确认，不提供绕过系统保护的命令。

随后在自己的测试账户完成 clean Complete 首装：它只注册，随后由用户完成
唯一一次真正的注销/登录、系统输入源添加与允许、从 macOS 输入菜单选择 Linnet
和真实输入。

Core 直升只接受固定 CMS App，公开 0.1.8 是最低直接升级版本。0.1.7 或更早的旧
ad-hoc App 由 Complete 修复；Core 必须在 payload 前拒绝并给出该操作提示。package
lifecycle 直接验证 Core 拒绝时不修改 App/Runtime，并验证 Complete 接受旧身份时保留
个人数据和输入源状态。

每个精确候选仍须在同一真实账号使用 Action 生成的 Draft Release 原字节完成
“两轮同 leaf Core”：先从前一已验收的固定 CMS 版（首次公开后即前一公开版）升级
到候选，再把同一候选的原字节重装一次。两轮都要
证明 Installer 无注销、无 Keychain 密码提示、登录会话不变，并保留
enabled/selected、UserData、输入菜单、Settings 和真实输入。Complete 修复旧身份和
同 leaf Core 更新都不重新 register、enable 或 select。Core preinstall 只验证候选、已安装
App、Active data 与 package-owned read-only typed TIS 状态；脚本不关闭 Host 或任何
用户应用，也不调用 `osascript`。Core 与 Complete 均不声明 `must-close`；安装过程
持有 Settings 数据事务共用的 mutation lease，不关闭 Settings。运行中的 Host 必须保持同一
PID，更新前已连接的应用与更新后新打开的应用都要继续输入。安装完成后，Settings
必须分别显示磁盘与运行中的 version/build/revision；只有切换离开 Linnet、没有未完成
composition 或数据事务时，Host 的 typed activation owner 才能接受自行退出。Settings
随后只从 canonical 安装路径启动 Host，并在精确 revision 一致后报告生效；任一前提
不满足都必须拒绝，不能强杀。Core 遇到 missing App 或 missing TIS registration 必须
在 payload 前失败；缺失或停用的输入源由用户在系统设置中添加或启用，已有 App 的
Complete 修复也不触碰 TIS。重复、冲突或未知 TIS 残留必须先执行 README 的离线
完整卸载命令，并验证全量删除与注销边界。选择 Linnet 后，可从其原生输入菜单的 **Settings**
打开设置；它是 `Linnet.app` 内嵌的 accessory App，不作为独立产品安装、不常驻
Dock，并在最后一个窗口关闭后退出。

安装器、系统设置、授权提示、输入菜单、菜单栏状态、真实候选和 Settings 的教程截图都必须来自同一冻结候选完成的这次安装 UAT。可以保留品牌图，但不能用 mock、其他 revision、局部测试窗口或另一台机器的提示冒充当前步骤；未实际出现的提示不写成已观察事实。

PR 只提交源码、测试和必要文档，不提交 archive、PKG 或本机日志。PR 说明应列出
精确 commit、manifest 集合摘要、逐文件 SHA-256、实际通过的验证和未执行项。
安装验收不会自行创建正式版本 tag 或稳定 Release；Preview 只允许验收人显式运行
`scripts/release-control preview /absolute/release-directory` 后公开候选 Core/data 和
候选 Catalog。只有完整验收后显式运行
`scripts/release-control authorize /absolute/release-directory` 后，本地才会用
Git SSH 创建哈希控制标签。随后唯一 GitHub Action publisher 从 Release metadata
复核同一批字节并完成发布；本地命令不能上传、编辑 Release 或推进 Catalog。

## 数据维护

### 中文升级

1. 用 `scripts/upstream-sync report` 发现稳定 Wanxiang 候选。
2. 在隔离 checkout 更新 lock 和 gitlink。
3. 让现有 source patch 精确应用；fuzz、缺失或多余匹配都失败。
4. 运行 `tests/verify_chinese_source_projection.sh`。
5. 运行八 profile golden、grammar、learning 和真实 Rime runtime。
6. 只在复现证明 Linnet 必须保持差异时修改 reviewed ledger。
7. 接受的数据字节变化必须推进 `config/linnet-data-releases.json` 对应 sequence/version/digest。

不要从当前 schema algebra 反向生成 expected golden；fixture 必须独立拥有审核后的输入码和语义。

### 英文释义与词汇

`data/linnet/linnet_en_zh_decisions_final.tsv` 是每个 Linnet 中文释义或 skip 决定的唯一 owner。构建工具拒绝重复、乱序、非法、缺少决策或 final-only rank 不一致。

维护步骤：

1. 比较锁定 Hallelujah/rime-ice 候选的 effective word、rank、IPA、translation、prediction、correction 和 pinyin supplement。
2. 人工审核产品可见差异。
3. 在 final TSV 中写简洁中文或明确 `-`；不要自动选“更长”的上游释义。
4. 新词 rank 只进入专用 rank ledger，不在另一份翻译 overlay 重复。
5. 运行英文投影、固定词族、真实 Rime 和 package source digest gate。

结构性全量验证不能替代人工质量抽样；报告必须写明样本与未审核范围。

### 拼音反查

`data/chinese/reports/enriched_pinyin_english.json` 的候选顺序是 rank owner，`pinyin_embargo_remove.tsv` 是精确删除 owner。Smart English 通过当前 profile Prism 将完整、非纠错的全拼或双拼编码还原为 full-pinyin key，再查询同一 key；中文的标准 affix segmentor 先去掉触发前缀。生成器只把这份审核快照投影到 `p/<pinyin>`，不得自动重写快照或另设运行时排序表。

所有中文 profile 必须覆盖默认 `|` 和用户可选的 `;`、标准音节分隔符、profile 内部可能使用的分号，以及 64/65 个可达 Prism key 的 fail-closed 边界。Smart English 使用无前缀的当前 profile Prism 自动反查，但不继承中文触发键。默认 idle `/ , . ; ' [ ] - =` 必须到达 host；英文模式的 `;` 始终透传，中文模式只有用户显式选择 `;` 作为反查触发键或当前方案把它当作拼写键时才进入组合。

### Rime Core

英文前缀优化来自独立研究的产品提交 `cdaf6bb` 与 `115887e`，研究数据和实验程序不进入产品。现有 TableTranslator 在 English schema 的 `completion_by_weight` 下，对两字符及以上前缀先展开最多 1,000 个 Prism key，按词频排序，后续按 key 偏移惰性读取，不能按重新排序后的候选序号跳过尾部。SmartEnglishFilter 复用原有学习／静态上下文排序；SmartEnglishTranslator 的纠错质量统一为 `frequency / 1e8`，不额外减 1。没有新模型、NSSpellChecker、索引或排序 owner。Smart English 规范构建统一使用 `-O2`。该内部 `LookupWords` C++ 签名变化同样要求重建全部原生插件；对应验收为 `tests/verify_rime_runtime.sh`，含常见前缀、完整候选集合、错拼、跨方案和输入连续性，原 p95/p99 门槛不变。研究中的排名取舍不能宣称为全场景无退步，最终 Core 与 English 词包必须联合加载后做真实输入验收。

当前锁定的 librime 有三处直接影响输入交互的上游缺口：被 `uniquifier` 包裹的标点必须读取 genuine candidate；InputMethodKit 退出时的 composition abort 必须取消 `AsciiComposer` 内未完成的修饰键手势；`commit_text` 切换不得把零输入的被动预测当成用户选择。`patches/librime-linnet-core-interactions.patch` 在 librime 的原始 owner 内统一修复这三处，不改变标点内容、全半角、配对、数字上下文或输入方案所有权。未来上游提供等价修复后，必须同时移除该 patch、lock/build wiring 和对应结构守卫，并重跑 native runtime 与 product gates。

引擎性能回移保持现有版本与单一 owner：核心交互补丁包含 librime [`1d0df6e`](https://github.com/rime/librime/commit/1d0df6e40cdcac17a986adc65e4668ae84ae0ada) 的 Prism / Syllabifier 临时字符串优化及上游边界测试；Lua 补丁包含 librime-lua [`ec52e48`](https://github.com/hchunhui/librime-lua/commit/ec52e48ea18f11af37717a01c337f853215cf70b) 的增量 GC。不引入该提交之前无关的 ReverseDb 路径变化，仍使用 Lua 5.4.8。Prism 的 C++ 参数类型改变，必须由 `no_download=1 ./action-install.sh` 一次重建引擎及插件，不能只替换单个 dylib。相关验收使用 `tests/verify_rime_runtime.sh --profile-key-matrix-probe` 与 `--mixed-input-probe`，不要求 App 或发布矩阵。

### Lua

产品使用的 rime-ice Lua 源由 allowlist 选择并嵌入锁定 librime-lua plugin。日期/UUID 对 `linnet_pinyin` tag 的边界修正以精确 patch 应用。Lua state 生命周期补丁仍是当前 pin 的必要部分。只有未来上游明确保证 Lua state 晚于所有 gear/translation 销毁，或保证它们在 `Registry::Clear` / `lua_close` 前全部销毁，才可移除该补丁；移除时必须同时更新 lock/build wiring，并重跑 Lua lifetime、embedding、runtime 和 product gates。

### Grammar 模型增量对照

固定输入集只用于回归，不能单独证明模型更新有价值。先对锁定的旧、新 `.gram` 做语义差分，再生成受影响输入，最后人工判断候选变化是否合理。不要只比文件大小、二进制偏移或固定语料的总通过率。

`tests/rime_grammar_delta.cc` 复用当前 Octagram `GramDb::Load` 和 Darts 遍历 API，以流式方式比较全部 key / weight，只输出新增、删除和调权条目，不反编译保存两份完整词表，也不实现新二进制格式。输出的负权重表示不存在；其余值是 `log(frequency) * 10000`，不是概率。`encoded_hex` 保留完整身份；`text` 只展示能按当前编码器无损往返的内容，不能还原时留空。

准备好现有 native runtime 后，在仓库根目录执行（`old_model`、`new_model` 指向待比较文件）：

```bash
mkdir -p build/model-delta
clang++ -std=c++17 -O3 -DGLOG_USE_GLOG_EXPORT tests/rime_grammar_delta.cc \
  -Ibuild/upstreams/git/plugins/octagram/src -isystem librime/dist/include \
  -isystem build/dependencies/boost lib/rime-plugins/librime-octagram.dylib \
  lib/librime.1.dylib -o build/model-delta/compare
DYLD_LIBRARY_PATH="$PWD/lib:$PWD/lib/rime-plugins" build/model-delta/compare \
  "$old_model" "$new_model" > build/model-delta/changes.tsv \
  2> build/model-delta/summary.log
ruby tests/select_grammar_delta_cases.rb build/model-delta/changes.tsv build/model-delta
```

抽样器按新增／删除／调权方向及词长分层，每层按 key 的 SHA-256 确定性选择至多 64 条，补上权重变化最大的 64 条。读音取自当前 `linnet_zh.dict.yaml` 导入图，记录实际分词、来源、多音歧义及无法生成输入的条目；生成的目标词不是独立质量 oracle。句尾 `$` 是 Octagram 的 rear 规则，不是用户输入字符：抽样报告单列排除数量，需补上有前文的句子复核；其他非汉字／不可还原 key 同样不得记为 PASS。

把 `delta-inputs.txt` 送入现有 `rime_golden_probe`，旧、新模型分别使用独立 shared/user 目录和新进程，其余 runtime、schema、词典及用户初始状态必须一致。比较首选、前五项及目标排名，保留模型 SHA-256、完整差分、生成输入和原始输出。对发现的反例用独立初始用户状态重验。抽样升降数量不代表整体质量提升率；出现明确退步时保留旧模型，不按更新日期自动替换。此对照只在模型变更时执行，不进入每次代码小改的常规矩阵。

## 验证层级

### Focused

```bash
tests/verify_runtime_footprint.sh
tests/verify_lua_embedding.sh
tests/verify_chinese_source_projection.sh
tests/verify_english_data_projection.sh
tests/verify_rime_runtime.sh
tests/verify_swift_units.sh
```

只运行受影响的最小集合，先证明缺陷用例，再证明它转绿。
Swift owner 测试可以先用 `tests/verify_swift_units.sh --list` 查看名称，再用
`tests/verify_swift_units.sh --only OWNER[,OWNER...]` 精确选择；例如候选窗改动运行
`--only candidate-presentation,candidate-snapshot-builder,panel-geometry,candidate-window`，
不会连带执行备份、下载、IPC 或数据 Registry。`--appearance-preview` 仍是
`--only appearance-preview` 的兼容简写。不要建立按源码字符串或文件名自动猜测测试的
第二套门禁；由改动所属 owner 明确选择测试。
精确选择 `candidate-window` 时只运行候选行为和布局矩阵；README 三张产品图的生成与
像素对比只在不带选择器的完整 Swift 冻结门中运行一次。

| 改动 owner | 日常 focused 命令 |
| --- | --- |
| 候选投影、Grid、面板几何 | `tests/verify_swift_units.sh --only candidate-presentation,candidate-snapshot-builder,panel-geometry,candidate-window` |
| Settings ↔ Host 事务 | `tests/verify_swift_units.sh --only settings-ipc,settings-update-checker,settings-data-coordinator` |
| 个人数据或备份 | `tests/verify_swift_units.sh --only personal-data,settings-session,backup-store` |
| Rime 路径或 session | `tests/verify_swift_units.sh --only rime-path,rime-session-lease` |
| Settings 可见交互 | `tests/verify_visible_settings_fixture.sh --ui-test TEST_NAME` |
| App 内嵌 Rime 与插件 | `tests/verify_packaged_rime.sh APP APP/Contents/Applications/Settings.app`；直接加载产物中的库，不使用开发机的动态库搜索路径 |
| 输入方案、按键或词频 | 对应的 `verify_profile_golden.rb`、`verify_chinese_grammar.sh`、`verify_chinese_learning_policy.sh` 或 `verify_rime_runtime.sh` 单门 |
| 右键忘记候选与焦点 | `tests/verify_rime_runtime.sh --candidate-forget-probe` |
| 原文光标编辑与代码词 | `tests/verify_rime_runtime.sh --raw-editing-probe`；混输边界同时运行 `--mixed-input-probe` |
| Installer 脚本 | 生成精确候选后，只在专用虚拟机执行真实首次安装、升级、Core、Complete、卸载和重装 |
| 产物私有路径扫描 | `ruby tests/verify_artifact_privacy.rb`；再用 `scripts/build-privacy scan APP` 检查已有产物，无需重建 |
| 发布事务脚本 | `tests/verify_action_publication.sh`；仅发布链变更或候选 Action 执行 |

Swift 夹具通过 `LinnetTestScratch.directory` 使用本轮测试专属目录；不要直接使用
Foundation 的 `temporaryDirectory`（macOS 上不会随 `TMPDIR` 重定向）。
`verify_swift_units.sh` 负责在成功、失败退出或 INT/TERM 中断后回收目录，包括只读
词包；删除失败会使测试门失败，不会静默忽略。编译缓存不在回收范围内。
强制杀死父进程（SIGKILL）或断电无法执行退出清理，不在此保证内。

主题卡片渲染或 OCR 失败时，可单独运行
`tests/verify_swift_units.sh --appearance-preview`。它复用同一测试与编译缓存，
不需要下载词库或构建 Rime；其结果不能替代完整本机收据或安装验收。

Settings 的实际点击、滚动或窗口行为失败时，在隔离桌面运行
`tests/verify_visible_settings_fixture.sh --ui-test [test-name,...]`；不传测试名运行完整
Settings UI 套件，也可传逗号分隔的现有方法名复现所选用例。此入口不运行 Rime/Swift
全套门、签名或发布打包。真实界面测试只在明确隔离的 macOS 桌面执行，
不得为了测试而关闭使用者的应用；通过也不等于正式安装包验收。
每个用例失败后立即停止该用例内的后续点击，但继续其余独立用例；任意失败仍使
整个门失败。不要恢复全局“首错跳过其他用例”标志，以免每次构建只能发现一个问题。
原生 xcresult（含失败截图）保留在 `build/settings-ui-results/`，不参与正式发布传输。

### Development composite

```bash
tests/verify_development.sh
```

这是准备冻结候选时运行一次的本机综合门，不是每次小改动的默认命令。它不需要签名
或安装，覆盖 App、Swift owner、IPC、中文/英文 projection 和真实 Rime 行为；安装
生命周期只在专用虚拟机验收，package architecture 使用下一节的独立门。

### Finalized local candidate

```bash
tests/verify_product.sh release
```

该命令用于已经冻结、具有准确 release metadata 且由固定 community CMS leaf 完成
签名的 Release App。结果仍需与可见 Settings、真实输入源、Terminal/VS Code/
Chrome/Apple Notes/Word/Teams 六应用、安装/升级/卸载和远程发布证据分开报告。

## 调试与临时目录

- 不用重启、缓存删除或用户数据清理代替诊断。
- 先记录精确 revision、进程、schema、输入序列和最早错误 owner。
- 测试临时目录必须在成功、失败和信号退出时清理精确路径。
- 不递归删除 repo、home、Application Support 或模糊 glob。
- 不提交日志、crash dump、用户数据、私钥、密码或绝对开发路径。
- 如果当前安装态正在使用旧 Linnet，不要为了源码测试 kill 系统进程或假装新代码已加载。

## 文档维护

- README 是唯一普通用户文档，拥有安装、操作、配置、故障排查、隐私和贡献入口，不保存研发事故档案。
- 本文件唯一拥有贡献和维护方式；release guide 只保存 community artifact、package、安装验收与 publication 顺序。
- `docs/product-acceptance.md` 拥有证据等级与验收要求；只有绑定精确 revision 和产物的运行报告才拥有当次证据。
- 已被源码与测试替代的旧 ADR 通过 Git 历史查询，不在主分支保留第二份现行说明。
