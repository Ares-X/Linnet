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

- `ascii_composer` 负责独立 Shift、组合键、长按、组词提交和 Caps Lock；
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
release identity，再由标签触发发布。定时 GitHub workflow 只报告候选更新，不得
自动修改仓库、合并上游或发布。

GitHub Actions 会缓存锁定下载、runtime 构建依赖、英文生成数据和 Rime 预编译产物。
缓存不是版本或发布权威：每次运行仍由 `action-install.sh` 校验 commit、tree、摘要、
内部 fingerprint 与产物形状；不匹配时只重建受影响部分。缓存命中也不会跳过
archive 和 publication 验证。发布 workflow 把“准备锁定依赖”和“构建并验证归档”
显示为独立步骤，便于直接看到下载、生成、编译和打包进度。

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
- 构建本地 unsigned/ad-hoc development App；
- 不安装、注册、启用或选择输入源；
- 不创建公开 PKG，也不授权发布。

贡献者可以直接运行 `archive` lane 生成与公开版本相同的未签名社区产物；该路径不需要证书或 Keychain。显式 `candidate` lane 仍保留给确有自有 CMS 测试身份的维护者，但不是贡献或发布前置。

## 社区版打包

贡献者可以在自己的 Mac 上完成打包和真实输入法工作流。前提是：

- 工作树已经形成一个干净的本地 commit，`LINNET_CANDIDATE_REVISION` 精确等于 HEAD；
- focused、`tests/verify_development.sh` 和普通 `./action-build.sh release` 已通过；
- 输出目录是贡献者新建的空绝对目录。

```bash
export LINNET_CANDIDATE_REVISION="$(git rev-parse HEAD)"
export ARCHIVE_OUTPUT_DIR=/absolute/path/to/new-empty-output

./action-build.sh archive
```

`archive` 会沿同一链生成并验证 ad-hoc App、未签名的 Complete/Core PKG、卸载器、确定性语言包和 sidecar；不要另写脚本重签或修补输出。

### 本地安装验收与 macOS 安全检查

社区安装包没有 Apple Developer ID，也没有 Apple 公证。只有在独立确认精确 HEAD、artifact SHA-256 和候选 metadata 后，才可以使用 macOS 的单次标准信任流程：

1. 在 Finder 中按住 Control 点击或右键点击已经校验的 PKG，选择“打开”。
2. 如果系统只报告无法验证开发者或无法检查恶意软件，打开 **系统设置 → 隐私与安全性**，在安全性区域选择 **仍要打开 / Open Anyway**；该按钮通常只在打开尝试后约一小时内出现，具体界面以 [Apple 的当前说明](https://support.apple.com/guide/mac-help/mh40616/mac) 为准。
3. 再次核对显示的文件名并确认；macOS 可能要求当前账户的登录密码。
4. 如果提示文件损坏、包含恶意软件，或身份、文件名、摘要与本地候选不一致，立即停止，不要继续安装。

不得用 `xattr` 清除隔离属性、关闭 Gatekeeper 或修改系统安全策略。公开用户流程使用同一套 Finder / 隐私与安全性确认，不提供绕过系统保护的命令。

随后在自己的测试账户完成 clean Complete 首装：它注册并请求 enable，随后完成唯一一次真正的注销/登录、系统输入源添加与允许、从 macOS 输入菜单选择 Linnet 和真实输入。之后的 Core 同版本重装与升级只能刷新注册，不调用 enable/select，必须不注销；preinstall 必须在 payload 前以正常 AppKit 退出请求确认 Host/Settings 均已停止，Settings 拒绝退出、未保存草稿或进行中操作必须让安装 fail closed，不能强杀。还要分别证明 enabled/disabled、selected 状态与用户数据均保留。默认卸载和显式 purge 仍需要独立验证数据保留/删除与注销边界。选择 Linnet 后，可从其原生输入菜单的 **Settings** 打开设置；它是 `Linnet.app` 内嵌的 accessory App，不作为独立产品安装、不常驻 Dock，并在最后一个窗口关闭后退出。

安装器、系统设置、授权提示、输入菜单、菜单栏状态、真实候选和 Settings 的教程截图都必须来自同一冻结候选完成的这次安装 UAT。可以保留品牌图，但不能用 mock、其他 revision、局部测试窗口或另一台机器的提示冒充当前步骤；未实际出现的提示不写成已观察事实。

PR 只提交源码、测试和必要文档，不提交 archive、PKG 或本机日志。PR 说明应列出精确 commit、artifact SHA-256、实际通过的工作流和未执行项。本地验收不会自动创建 tag、Release 或上传资产。

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

该命令用于已经冻结、具有准确 release metadata 且完成 ad-hoc 结构签名的 Release App。结果仍需与可见 Settings、真实输入源、Terminal/VS Code/Chrome/Apple Notes/Word/Teams 六应用、安装/升级/卸载和远程发布证据分开报告。

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
- `docs/product-acceptance.md` 是 machine-bound 的当前证据投影，路径不能随意移动。
- 已被源码与测试替代的旧 ADR 通过 Git 历史查询，不在主分支保留第二份现行说明。
