# Linnet 社区版发布

Linnet 的公开发行采用无付费证书的社区模式：PKG 不含 Apple Developer ID
Installer 签名，也不经过 Apple 公证；App 内的 Host、Settings、动态库和插件
使用同一张长期固定的自签 CMS 证书与 hardened runtime。固定 leaf 为跨版本
身份连续提供一致依据，但不等同于 Apple Developer ID 或公证，仍须逐版做真实
升级验收。首次使用需按 macOS 提示手动确认；Release 提供源码标签、文件清单和 SHA-256 供核对。

## 用户信任边界

从项目 Release 下载 `Linnet.pkg`，在 Finder 中按住 Control 点击或右键点击，选择“打开”。
需要确认下载文件时，可将 SHA-256 与同一 Release 的摘要比对。若仍被 macOS 拦截，可在“系统设置 → 隐私与
安全性”中对该文件选择“仍要打开”。文档和脚本不得要求关闭 Gatekeeper、
清除 quarantine 属性或修改系统安全策略。

没有 Developer ID 不表示没有验证。正式产物仍必须满足：

- 标签、源码 revision、App 内嵌 metadata 和产物清单一致；
- App 与嵌套 Settings、动态库、插件均由仓库钉住的同一 CMS leaf 签名，并在构建、
  暂存和发布边界通过严格 codesign 结构校验；
- PKG 明确为 `Status: no signature`，且不能含 Installer Signature 记录；
- 候选目录精确匹配 `package/release_asset_manifest`；正式 Release 只有 1 个完整安装包，Core
  更新频道包含 Core 和 Catalog，数据频道包含 4 个不可变词包及已绑定基线的差分；
- 安装脚本保持当前用户范围，不安装 daemon、LaunchAgent、特权 helper；
- PKG 中的 `linnet-pack` 与运行时检查工具须按 arm64 macOS 13.0 编译，并检查包内 Mach-O 的最低系统版本；仅在较新构建机器上运行成功不能证明旧系统兼容。
- Complete 只在首次创建 App 时注册输入源并向 macOS 提交一次启用请求；已有 App
  的 Complete 字节修复与 Core 更新都不注册、启用或选择输入源。允许与菜单选择
  始终由用户和 macOS 管理。首次安装最多要求一次注销，
  匹配已公布基线的健康安装使用 Core，Core 更新不要求注销；不匹配时明确使用
  Complete 修复 App，已有健康词包与个人数据保持不变；Complete 与 Core 对已有 App
  都不触碰输入源状态。缺失或停用的输入源只能由用户在系统设置中添加或启用。

用户安装边界不依赖维护者 Keychain，也不把自签证书是否进入用户系统信任根当作
App 完整性事实。Core 在写入前核对已公布的精确差分基线；Core 与 Complete 在写入后
核对包内固定 designated requirement、发布 metadata 和候选 App 整树 SHA-256。任何
一项不匹配都会保留原安装并失败；固定 CMS 的完整链与嵌套代码结构仍只由构建、暂存和
发布 owner 严格验证一次。

## 本地预检与 Action 正式候选

普通开发构建不需要证书。维护者 Mac 仍可用仓库外固定 CMS 身份做一次可选
`archive` 预检，但它不是公开候选，也不能上传或授权发布。正式候选的唯一构建和
签名 owner 是 `.github/workflows/release-ci.yml` 的 macOS GitHub Action。

首次配置维护者 Mac 的本地预检身份时，把当前用户拥有且权限为 `0600` 的固定输入放到：

- `~/Library/Application Support/Linnet Maintainer/Signing/community-cms/community-cms.p12`
- `~/Library/Application Support/Linnet Maintainer/Signing/community-cms/p12-password`

然后只运行一次 `scripts/provision-community-signing`。它在创建任何 Keychain 前核对
仓库钉住的证书 SHA-1/SHA-256，配置 `/usr/bin/codesign` 的访问分区，完成非交互
签名探针并锁回。任一固定输出已经存在时都会失败，且没有 replace、repair 或 delete
入口；失败只回滚本次创建的精确目标并恢复原搜索列表。成功后不要在每次发版前重跑。

可选本地预检命令是：

```bash
export LINNET_CANDIDATE_REVISION="$(git rev-parse HEAD)"
export ARCHIVE_OUTPUT_DIR="$(mktemp -d /private/tmp/linnet-release-preflight.XXXXXX)"
./action-build.sh archive
```

本机固定 Keychain 的密码是 Linnet 专用随机密码，不是 macOS 登录密码；如果配置或
预检出现密码框，应取消并排查。本地固定 CMS 签名包允许用于专用虚拟机的开发探索
测试，记录精确源码与包摘要，不得上传或公开。组件、布局、Settings 与性能测试在
开发机使用隔离数据；虚拟机用于真实键盘输入、安装升级、可能需要注销的生命周期
以及第二个 iCloud 端点。由于 CMS 签名时间会改变字节，本地测试不能替代正式发布前
对 Action 原始产物的安装验收，也不要求为每轮开发探索先触发 Action。

使用 `scripts/release-control candidate` 为已提交的 revision 创建候选标签。
候选申请不要求本地测试收据、干净工作区或精确远端 main；Action 只构建标签指向的
已提交源码，不包含未提交修改。根据改动运行相关测试并记录实际结果，未运行项目
明确记为 `NOT_EXERCISED`。`verify-local` 是可选的完整非交互检查；Periphery 可单独
运行，结果供审阅，不阻止构建或发布。

Settings UI 仅在专用测试桌面按需运行 `scripts/release-control verify-settings-ui`。
它不依赖另一份测试收据，也不是申请候选的前置条件。独立 bundle ID 和数据目录
不能隔离鼠标、键盘或焦点，不得在维护者日常输入会话中运行 XCUITest。
`archive` 只构建、签名、打包及检查最终文件；需额外检查时显式运行对应测试。
正式发布仍需验证受本次变更影响的实际安装与产品行为，不能把未执行的流程记为通过。

同一个 macOS job 只做一次 checkout、一次锁定 cache restore、一次 hydrate，验证
标签到 commit/tree 的绑定，保留依赖提交历史的版本检查和实际产物门。随后 Action 使用
`community-signing` Environment 中的 P12 和密码创建临时 Keychain，并只运行一次
`make archive`。同一次 Make 调用只编译一份 `build/linnet-pack`；
`make_package` 在产物边界验证两个 PKG，最终
`package/verify_publication_artifacts` 再验证完整 manifest 集合。中间的 archive
投影不重复验证同一 PKG。

候选 Action 把 manifest 的原字节直接写入三个 Draft GitHub Releases：Core 2 件、data
4 个完整词包及对应差分、public 1 件。GitHub Actions artifact 不是发布传输或存储 owner，因此不会再
上传约 906 MB artifact、随后在另一个 job 下载并解压同一份数据。
Core 与 public Draft 必须精确绑定当前候选 revision；data Draft 由固定 tag、
预发布状态及词包、差分的精确文件名、字节数和 SHA-256 拥有。其 target 必须是完整的
direct commit，但 byte-identical 的不可变 pack 可以跨候选 revision 复用，且不得删除、
重建或重新上传。

### 差分基线与可复用产物

`config/linnet-update-baselines.json` 锁定前一公开 Complete 的 revision、字节数和
SHA-256，以及每个目标词包对应的基线内容身份。`package/prepare_update_baseline`
通过现有下载 owner 获取同仓库资产并缓存；旧 App 按它自己的已发布 revision 验证
CMS 和资源，不能拿当前源码重新推算旧版 metadata。Core 基线与词包基线独立推进，
修改 Core 不能隐式增加任何词包的 sequence。

Core 包只携带差分和安装工具；已有词包下载与其内容匹配的 `.linnetdelta`，没有变化
的词包直接复用。差分经系统 rsync 回放到 APFS 写时复制副本，核对完整目标后才发表。
传输按差异块生成；本地保留未改变文件的 COW 副本，仅重建发生变化的文件。
被修改文件使用 rsync 的临时文件替换，不使用 `--inplace`，以保持只读词包权限；
因此单个被修改文件的临时空间仍按其完整大小计算，不能把网络差分大小当作磁盘峰值。
失败保留原始安装。语言数据没有可用差分或差分失败时，自动下载同一 Catalog 中的完整词包；完整包仍须通过原有摘要与内容校验。Core 的 Complete 重装仍由完整安装包执行。
安装器与 Settings 复用一个数据 mutation lease，不关闭任何应用。
Core 与已有安装的 Complete 修复必须保留 `Linnet.app` 目录的文件身份，
只原子交换完整 `Contents`；不能将已注册 App 根目录换到暂存区再删除。
Settings 的已安装版本读取同一磁盘安装的 Info.plist 与 VERSION.json，
不能与进程缓存的旧 Bundle 元数据混用；Host 的运行版本仍是启动时的不可变快照。

差分 Core 使用独立的 `update.core.pkg` receipt；Complete 的 App、词包和激活投影
使用 `complete.*.pkg` receipts，只指向隐藏暂存目录。不能复用旧版全量安装的
live-payload receipt，否则 PackageKit 会在 preinstall 与 postinstall 之间删除本版
未携带的旧文件。旧 receipts 仅由 README 的离线卸载命令清理，升级不修改或遗忘它们。
变更安装组件布局时，必须在专用虚拟机用精确候选验证真实 PackageKit 的旧版迁移、
重复安装与 Core/Complete 交替；源码夹具不能替代产品安装和输入验收。

rsync batch 是系统维护的非确定性传输格式；可验证的是精确目标内容，不是重复构建得到
同一 batch。首次生成后冻结其原字节并验收。在后续 Core-only 候选中，将已发布 delta
的同仓库 URL、revision、bytes/SHA-256 加入 `sources`，并在相应 `pack_baselines`
记录中指定 `delta_source`；构建复用该资产，不能重生成另一个 delta 覆盖已公开 data
Release。新 pack sequence 才选择新的基线并生成新的差分。当前阶段此基线锁更新由
维护者在发布准备时完成，并非后台自动改写。

## GitHub 发布

正式产物的构建、签名、候选暂存和最终公开都由 GitHub Actions 完成；维护者 Mac
负责源码验收与 Action 原字节安装验收，并在验收后创建不可变授权标签：

1. 完成与改动相关的验证并提交源码，运行 `scripts/release-control candidate`；
2. 等待唯一 macOS candidate job 成功。它只构建、签名一次，并把
   manifest 中的全部产物直接放入
   `core-v<VERSION>`、`data-<SEQUENCE>` 和 `v<VERSION>` 三个 Draft Releases；
3. 用已认证的 GitHub CLI 把三个 Draft 的互不重叠资产下载到一个新空目录。记录
   candidate job summary 的 revision 与产物集合摘要，并在本地重新运行最终 verifier；
4. 用候选原字节完成受本次变更影响的安装、功能或 UI 验收；按下文选择生命周期测试，
   不默认重跑全部矩阵。随后运行
   `scripts/release-control preview "$ARCHIVE_OUTPUT_DIR"`；它只创建字节绑定的
   `linnet-preview/*` 标签。Ubuntu publisher 只公开 Core/data 预发布并非强制推进
   `preview-channel`，不推进 `data-channel`、不公开 `v<VERSION>`、不改变 Latest；
5. 在受支持公开基线的 Settings 选择 Preview，完成一次真实在线发现、Core 下载和
   候选原字节的运行中生效。验证无需注销或密码、
   Host 符合激活协议、个人数据与应用连接保留、菜单和真实输入正常。语言数据或同步
   有变化时，再验证对应数据更新或双向 iCloud 合并；已验证的同一原字节不重复验收。
6. 本次变更所需验收通过后运行
   `scripts/release-control authorize "$ARCHIVE_OUTPUT_DIR"`。本地命令只能重新验证
   全部 manifest 文件和三个远端 Release 的 SHA-256/size，并通过 Git 创建
   `linnet-publication/v<VERSION>-<FULL_REVISION>-h<SET_SHA256>`；它不能构建、
   上传、编辑 Release 或推进 Catalog；
7. 正式授权标签启动同一个 Ubuntu publisher job。它从 GitHub Release metadata 验证完整 manifest
   集合，只下载约 4 KB 的 `Linnet-Data-Channel.json`，然后按
   Core → data → 非强制快进 Catalog → Public / Latest 的顺序发布。大型资产不再下载。
   若同一份 Complete 已作为预发布公开，按同一源码与资产摘要直接转为稳定版，
   无需重传资产；正式发布会移除预发布标记。

若候选提交中的工作流有发布故障，可在修复合入 `main` 后，用
`gh workflow run release-ci.yml --ref main -f authorization_tag=<已有授权标签>`
继续发布。工作流仍检出该标签对应的源码，并核对原资产摘要，不重新构建候选。

更新锁定 LTS 模型时，显式
`linnet-data-seed/v<VERSION>-<SEQUENCE>-<FULL_REVISION>` 标签启动同一个 macOS
构建 owner。它从 `upstreams.lock.json` 的上游 URL 下载并验证固定 bytes/SHA-256，
完成完整候选构建与最终 verifier，但只暂存并公开 manifest 中的 data 预发布资产；不得发布
Core/Public，也不得推进 Catalog。随后只有同一 revision 可快进到 `main`，再走正常
candidate 流程。正常版本不运行 seed 模式。

任一项失败都停止在当前幂等边界；不能覆盖或 `--clobber` 已公开资产。候选
字节本身有误时，修复必须形成新的 revision；候选一旦公开到 Preview，就成为在线
升级基线，后续 Preview 必须使用新的产品版本并严格增加 Core build，不能改写已公开的
`core-v<VERSION>`。尚未公开、只停留在 Draft 的候选修订可保持版本与 build 不变。数据内容变化时才增加必要的数据 sequence，再由
macOS Action 生成新候选。`v<VERSION>` 只标识公开版本；data seed、Preview 和正式
发布三个控制标签分别只授权自己的边界。

词包身份变化时序号必须严格递增，身份不变时序号必须保持不变。合并或 squash
可能一次包含多次合法修订，因此基线比较不要求序号恰好加一；不得为了合并检查
把已有序号重新编号，或允许同一序号对应不同内容。Catalog 的词包快照序号遵循
相同的顺序规则，Core-only 变化不推进词包序号。

Core 更新只接受已安装的固定 CMS 身份；此前公开的旧 ad-hoc App 必须使用
Complete 修复，不能进入 Core 的就地更新路径。
Complete 仍须验证旧 App 的代码完整性和明确身份，在不修改既有 TIS 状态与个人数据的
前提下替换 App；仅在变更涉及此路径时补做相应修复验收。

Settings 只读取用户明确选择的 `data-channel` 或 `preview-channel` 指针，不读取
可变 Release 别名，也不维护第二份 Core 版本清单；默认始终是正式频道，未知保存值
回到正式频道，不存在自动回退路径。

GitHub 令牌只用于把已经验证的字节写入当前仓库；固定 P12 与密码分别存放在
`community-signing` Environment 的
`LINNET_COMMUNITY_CMS_P12_BASE64` 和 `LINNET_COMMUNITY_CMS_P12_PASSWORD`
Secrets 中。它们不是 Apple 开发者凭据，也不会被打包、写入日志或公开。

### Windows 发布边界

当前三个 Release 频道只发布 macOS 安装包、Core 更新和共享语言数据。Windows
构建上传的安装程序只是有时限的私有 Actions 候选产物，不属于任何 Release
清单，发布任务也不得下载或转发它。

在同一份 Windows 安装程序完成真实 Windows 10/11 安装、升级、卸载、共存、
Win32/现代应用输入、候选界面、用户数据隔离、失败回滚及原生 ARM64 等 UAT
之前，不得在 GitHub 创建 Windows Release，也不得把它附加到现有 Release。
CI 通过、签名通过和 macOS 验证都不能替代该验收。未来增加 Windows 发布入口
时，必须绑定被测源码 revision 和安装程序 SHA-256，并在字节不一致时停止发布。

## 安装验收

代码、静态产物和安装产品必须分别报告。首次 Complete 安装需验证一次注销
后输入源可用；同一 bundle ID/path 的后续在线 Core 更新必须验证：无需 Installer、
密码或注销，登录会话与个人数据不变，输入源 enabled/selected 意图不被覆盖。
旧式 Core PKG 桥接另须验证 `RestartAction=None`，且安装阶段不改变 Host PID 或
隐藏 Host（`AXHidden=false`）。更新前已连接及更新后新打开的应用都须可输入。
Settings 分别显示 installed/running version、build 和 revision。立即应用的唯一 owner 是 Host 的 typed
activation state：用户必须先通过系统菜单切走 Linnet，且不得有未完成输入或数据事务。
TextEdit、Teams、Codex 及其他已连接应用始终保持打开；任一安全条件不满足时 Host
保持运行且 Settings 显示拒绝原因。Settings 不关闭用户应用，也不程序化切换输入源。
Host 接受后还须在退出前复核同一 typed 状态；Settings 只能从 canonical 路径启动并核对
精确 revision；再单独验证 Host 自然重启后由新 build 提供输入。
每个 Core 候选以一次从受支持公开基线到候选原字节的真实在线升级为正常发布证据。
本机或专用虚拟机的有效证据均可使用；不因切换测试机器而重跑同一条路径。
同版本 Complete 修复不能代替有序 Core 升级；Core 仍只接受更高版本。

额外验收由变更决定：安装脚本、签名身份或注册流程变化时测首次安装；卸载、迁移、
持久化或恢复路径变化时测对应流程；升级事务、失败恢复或跨次状态变化时测有具体
失败假设的重复升级/故障场景。普通 Settings、候选 UI 或学习同步修复不要求重建
低版本、重复同一路升级、注销或重启。仅文档修改不构建候选，也不重跑产品测试。
已通过的检查只有在相关代码/字节变化、发现新失败或仍有明确证据缺口时才重跑。
未执行的无关项目如实记录 NOT_EXERCISED，不自动阻塞发布。

在线升级须验证无需注销或密码，登录会话、enabled/selected、UserData、输入菜单、
Settings 和真实输入保留。
PKG 不以旧 App 的签名、版本或 TIS 注册状态作为安装前提。旧 App 缺失 Contents
时可补入新 Contents，失败则退回原来的空目录状态；App 根目录保持不变。Complete 可首次安装、
覆盖重装或修复旧 App；Core 包仍需要现有 App 与兼容的语言运行时。新 App 的签名、
目标字节、路径和现有数据兼容性在实际写入边界检查。输入源尚未启用时，安装完成后
提示用户到系统设置添加；不要求预先完整卸载，也不把启用失败报告成安装失败。
发布 Keychain 密码永远不属于用户安装流程。
安装脚本也不得调用依赖用户系统信任根的深度验签来判断 App 是否损坏；用户侧只核对
冻结的 designated requirement、发布 metadata、差分基线和精确目标整树。

任何校验和、产物清单、App metadata 或安装状态不一致都应停止发布；不得用
重新签名、手工复制 App、清缓存或降低验证门来制造通过结果。
