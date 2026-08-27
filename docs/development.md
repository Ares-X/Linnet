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
| `package/` | 当前用户域 PKG、语言包、卸载器和 publication plan |
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

精确 source patch 删除被拒绝的 `(text, code)`，`linnet_reviewed` 表添加接受行。不存在 Python composer、自动 tone inference、L1/L2/L3 重分层、rime-ice 中文候选 merge 或运行时 fallback。

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

只改变 document 的 Apply 仅在 `Transactions/<UUID>/configuration-candidate/` 暂存一份 `linnet_settings.json`。Host 校验候选与 expected/base revision，以唯一 live document 为 canonical owner 执行 CAS 和同卷原子交换，再从已发布 document reconcile 可重建 custom YAML、按固定顺序部署 exact 11 份 config（default、九个产品 schema 与 squirrel），使旧 session generation 失效并用 fresh session 验证所选方案。成功必须回报同一 SHA-256 `activeSettingsRevision`；交换、reconcile、部署或健康检查失败时，Host 原子换回旧 document、重新 reconcile/deploy 并验证旧 revision，无法验证则 fail closed。Host 启动也会在 Rime 接受输入前从 canonical document 向前 reconcile。该快速路径不 finalize Rime、不运行 maintenance、不重编词典，也不创建备份。个人数据变更与语言数据激活仍在隔离候选中验证，再通过 Host 的唯一 live runtime owner 原子切换并健康检查。

Core App 不携带语言数据。Chinese、English、LTS 和 Extended 各有独立 `(kind, sequence, version, content_sha256)`，通过一个完整 Active 视图消费。精确格式和文件成员由 Registry、package 工具及其结构门共同验证；文档不维护第二份成员清单。

## 上游和依赖

`upstreams.lock.json` 是唯一版本 owner；`.gitmodules` 和 gitlink 是受验证投影。直接产品上游集合固定为：

1. Squirrel / Rime；
2. rime-ice；
3. Hallelujah；
4. rime-wanxiang；
5. RIME-LMDG。

公开源码以一个独立根快照发布，不继承 Squirrel 的 Git 父链。Squirrel 来源由 lock 中的精确 tag/commit 和发布 SBOM 的 `VARIANT_OF` 关系共同证明；构建不得从当前分支的祖先关系推断来源。

rime-ice 只提供锁定的英文补充、OpenCC/符号/部件数据和选择的 Lua 源；不提供 Linnet 中文候选或 runtime schema。Hallelujah 原始应用、localhost UI、JavaScriptCore 和运行时 SQLite 不进入产品。

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
release identity。进入发布时，只有精确 main revision 和最终八件产物
`package/verify_publication_artifacts` 验证才能冻结本地候选；普通 main 提交不会额外
构建或签名候选。真实安装验收必须使用该本地归档同一次签名产生的原字节；
通过后，唯一的 revision + 八文件集合摘要 SSH 控制标签依次授权 `core`、`data`、
`catalog` 与 `public` / Latest。控制标签推送前不得创建 Release 或推进稳定 Catalog。
定时 GitHub workflow 只报告候选更新，不得自动修改仓库、合并上游或发布。

RIME-LMDG 的上游 `LTS` 资产允许原作者在同一 URL 原位替换，因此上游 URL 只用于
发现和本地审查候选；被 Linnet 接纳的原始模型字节数与摘要仍记录在
`rime_lmdg_grammar`，冷构建只从 lock 指定的同仓库固定 `data-N` LTS 包获取，再由
PackTool 验证容器、解包并复核内部原始模型。接受新模型时，维护者须先在隔离
checkout 中预计算未来 LTS 包摘要，并在同一个最终提交里写入未来 `data-N` URL、
容器摘要、原始模型摘要和数据 release identity。本地已验证的原始模型允许这个最终
提交在远端包尚未存在时生成并验证完整八件归档。随后先把该精确提交推到一个临时、
不匹配 `v*.*.*` 的 seed tag，再由唯一 mutation owner 发布同一提交的五件数据资产：

```bash
git tag "data-seed-${sequence}" "${candidate_revision}"
git push origin "refs/tags/data-seed-${sequence}"
GH_TOKEN=... GITHUB_REPOSITORY=Ares-X/Linnet \
  LINNET_RELEASE_TOOL=/absolute/path/to/verified/linnet-pack \
  package/publish_github_release data-seed "${archive_dir}" \
  "${version}" "${sequence}" "${candidate_revision}"
git push origin ":refs/tags/data-seed-${sequence}"
git tag -d "data-seed-${sequence}"
```

这个 `data-seed` 步骤是正常 main/CI 发布门之外唯一的冷构建启动边界：它仍须由最终
八件产物 verifier 接受，并且远端 `data-seed-N` 必须精确指向 candidate revision；
它只允许发布五件 `data` 预发布资产，不得调用 `catalog`，也不得推进 `data-channel`，
因此尚未验收的未来模型不会被已安装用户看到。发布后必须从 clean checkout 走一次
固定包冷构建，确认外层容器和内部原始模型都与 lock 一致；只有同一个
`candidate_revision` 才能快进到 `main`。临时 seed tag 不触发产品发布 workflow，
发布成功后立即删除；正式 `data-N` tag 继续绑定该提交。普通构建没有回退到可变
上游资产的路径。

进入正常产品发布时，候选必须是 clean、精确远端 `main` revision。本机固定 CMS
身份只构建和签名一次，独立 verifier 接受精确八文件；真实 Settings 与
InputMethodKit 安装验收只使用该目录的原字节。通过后执行
`scripts/release-control publish /absolute/release-directory`。命令以非 force SSH tag
绑定版本、完整 revision 和八文件集合摘要，再由同一个 publisher 依次执行 `core`、
`data`（此时只接受既有 seed 的相同字节）、`catalog` 和 `public` / Latest。正式
`v<version>` 标签只标识版本，`linnet-publication/*` 控制标签只授权已验收的同一批
字节；GitHub 不重新编译或重签。稳定 Catalog 仍只有一个 owner 和一个 URL。

GitHub Actions 会缓存锁定下载、runtime 构建依赖、经 fingerprint 和 inventory digest
验证的原生 Rime 编译 transport，以及英文生成数据。只有默认 `main`
的 native Rime profile 可以在成功任务结束后写入缓存；功能分支和候选只读取当前
ref 或默认分支缓存，避免每个
候选保存一份无法被后续候选复用的大型副本。
缓存不是版本或发布权威：每次运行仍由 `action-install.sh` 校验 commit、tree、摘要、
内部 fingerprint 与产物形状；不匹配时只重建受影响部分。缓存命中也不会跳过
archive 和 publication 验证。commit/PR CI 先串行执行快速 lint、release owner 和数据
identity 门，通过后把 App、Swift owner tests 与 native Rime 三个完整 profile 放到
隔离 runner 并行执行；任一 profile 失败仍使精确 revision 的整体 CI 失败。branch push
不再与同 revision 的 PR workflow 重复运行完整门，连续更新也只保留最新一次。

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

普通贡献者运行到 `release` 即可，不需要证书或 Keychain。官方 `archive` lane
必须使用仓库钉住的固定 community CMS leaf，因此只对持有仓库外发布身份的维护者
开放；缺少精确身份时会在打包前失败，不会回退到 ad-hoc。旧 `candidate` lane 与
自定义 UAT 签名 profile 已删除；任何可安装候选只认固定 production CMS identity。

## 社区版打包

### 一次性配置本机签名身份

本地发布身份属于维护者工具，不属于 Linnet 产品数据，也不会被卸载器清理。先把固定
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
输入登录密码、删除既有目标或重复运行配置命令。日常 signer 只消费这两个固定输出。

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
PKG、卸载器、确定性语言包和 sidecar；不要另写脚本重签或修补输出。由于 CMS
签名时间会改变字节，这个本地产物不是正式发布候选；正式安装验收必须下载自动
`release-ci` 记录的同一不可变八文件 artifact。

### 本地安装验收与 macOS 安全检查

社区安装包没有 Apple Developer ID，也没有 Apple 公证。只有在独立确认精确 HEAD、artifact SHA-256 和候选 metadata 后，才可以使用 macOS 的单次标准信任流程：

1. 在 Finder 中按住 Control 点击或右键点击已经校验的 PKG，选择“打开”。
2. 如果系统只报告无法验证开发者或无法检查恶意软件，打开 **系统设置 → 隐私与安全性**，在安全性区域选择 **仍要打开 / Open Anyway**；该按钮通常只在打开尝试后约一小时内出现，具体界面以 [Apple 的当前说明](https://support.apple.com/guide/mac-help/mh40616/mac) 为准。
3. 再次核对显示的文件名并确认；macOS 可能要求当前账户的登录密码。
4. 如果提示文件损坏、包含恶意软件，或身份、文件名、摘要与本地候选不一致，立即停止，不要继续安装。

不得用 `xattr` 清除隔离属性、关闭 Gatekeeper 或修改系统安全策略。公开用户流程使用同一套 Finder / 隐私与安全性确认，不提供绕过系统保护的命令。

随后在自己的测试账户完成 clean Complete 首装：它只注册，随后由用户完成
唯一一次真正的注销/登录、系统输入源添加与允许、从 macOS 输入菜单选择 Linnet
和真实输入。

旧 ad-hoc → 固定 CMS 是一次性的历史 Core lifecycle 验收，唯一记录在
`config/linnet-community-signing.json`。其固定 leaf、bundle ID、macOS major 和
identity classifier 的“迁移契约指纹”是完整失效键：任一项与当前候选失配，才在
隔离的 legacy-seeded 账号或虚拟机中重做；四项全部匹配时不得为每个候选重复迁移。
Host 连续性和 TIS 不变性不从这份历史指纹推断，统一由当前 package lifecycle matrix
验证。该历史记录只闭合 legacy identity edge，不是当前候选菜单、Settings、真实输入
或完整安装 UAT。

每个精确候选仍须在同一真实账号使用 workflow 的不可变 artifact 完成
“两轮同 leaf Core”：先从前一已验收的固定 CMS 版（首次公开后即前一公开版）升级
到候选，再把同一候选的原字节重装一次。两轮都要
证明 Installer 无注销、无 Keychain 密码提示、登录会话不变，并保留
enabled/selected、UserData、输入菜单、Settings 和真实输入。旧身份的历史迁移不
授权同 leaf Core 重新 register、enable 或 select。preinstall 必须在 payload 前以
正常 AppKit 退出请求只确认 Settings 已停止；Settings 拒绝退出、未保存草稿或进行中
操作必须让安装 fail closed，不能强杀。运行中的 Host 必须保持同一 PID，更新前已
连接的应用与更新后新打开的应用都要继续输入。安装完成后，Settings 必须分别显示
磁盘与运行中的 version/build/revision；只有切换离开 Linnet、所有旧 Host 的
InputMethodKit controller 已断开且没有数据事务时，Host 才能接受自行退出。Settings
随后只从 canonical 安装路径启动 Host，并在精确 revision 一致后报告生效；任一前提
不满足都必须拒绝，不能强杀。还要分别证明 enabled/disabled、selected、
missing-App+unregistered repair 与用户数据均保留；missing App 仍有
enabled/disabled 系统身份必须在 payload 前失败。默认卸载和显式 purge 仍需要独立
验证数据保留/删除与注销边界。选择 Linnet 后，可从其原生输入菜单的 **Settings**
打开设置；它是 `Linnet.app` 内嵌的 accessory App，不作为独立产品安装、不常驻
Dock，并在最后一个窗口关闭后退出。

安装器、系统设置、授权提示、输入菜单、菜单栏状态、真实候选和 Settings 的教程截图都必须来自同一冻结候选完成的这次安装 UAT。可以保留品牌图，但不能用 mock、其他 revision、局部测试窗口或另一台机器的提示冒充当前步骤；未实际出现的提示不写成已观察事实。

PR 只提交源码、测试和必要文档，不提交 archive、PKG 或本机日志。PR 说明应列出
精确 commit、八文件集合摘要、逐文件 SHA-256、实际通过的验证和未执行项。
安装验收不会自行创建公开版本 tag 或稳定 Release；只有验收人显式运行
`scripts/release-control publish /absolute/release-directory` 后，唯一 publisher 才能
复用哈希控制标签绑定的同一批字节完成发布。该操作使用 Git SSH 与 GitHub CLI，
不依赖 GitHub 网页或 GitHub Actions 编译。

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

`data/chinese/reports/enriched_pinyin_english.json` 的候选顺序是 rank owner，`pinyin_embargo_remove.tsv` 是精确删除 owner。Smart English 直接查询 full-pinyin key；中文的标准 affix segmentor 去掉触发前缀，当前 profile Prism 只解码完整非纠错路径，再查询同一 key。生成器只把这份审核快照投影到 `p/<pinyin>`，不得自动重写快照或另设运行时排序表。

所有 profile 必须覆盖默认 `;` 和可选 `|`、标准音节分隔符、profile 内部可能使用的分号，以及 64/65 个可达 Prism key 的 fail-closed 边界。

### Rime Core

当前锁定的 librime 有三处直接影响输入交互的上游缺口：被 `uniquifier` 包裹的标点必须读取 genuine candidate；InputMethodKit 退出时的 composition abort 必须取消 `AsciiComposer` 内未完成的修饰键手势；`commit_text` 切换不得把零输入的被动预测当成用户选择。`patches/librime-linnet-core-interactions.patch` 在 librime 的原始 owner 内统一修复这三处，不改变标点内容、全半角、配对、数字上下文或输入方案所有权。未来上游提供等价修复后，必须同时移除该 patch、lock/build wiring 和对应结构守卫，并重跑 native runtime 与 product gates。

### Lua

产品使用的 rime-ice Lua 源由 allowlist 选择并嵌入锁定 librime-lua plugin。日期/UUID 对 `linnet_pinyin` tag 的边界修正以精确 patch 应用。Lua state 生命周期补丁仍是当前 pin 的必要部分。只有未来上游明确保证 Lua state 晚于所有 gear/translation 销毁，或保证它们在 `Registry::Clear` / `lua_close` 前全部销毁，才可移除该补丁；移除时必须同时更新 lock/build wiring，并重跑 Lua lifetime、embedding、runtime 和 product gates。

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

### Development composite

```bash
tests/verify_development.sh
```

这是普通开发的综合门，不需要签名或安装。它覆盖 owner/source guards、package lifecycle、IPC、中文/英文 projection 和真实 Rime 行为，但不是 package architecture、签名产物或安装 UAT；package architecture 使用下一节的独立门。

### Package architecture

```bash
tests/verify_package_architecture.sh
```

它可使用临时 fixture 验证 package 结构；通过不代表已生成发布 PKG。

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
