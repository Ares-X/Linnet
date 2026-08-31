# Linnet 社区版发布

Linnet 的公开发行采用无付费证书的社区模式：PKG 不含 Apple Developer ID
Installer 签名，也不经过 Apple 公证；App 内的 Host、Settings、动态库和插件
使用同一张长期固定的自签 CMS 证书与 hardened runtime。固定 leaf 为跨版本
身份连续提供一致依据，但不等同于 Apple Developer ID 或公证，仍须逐版做真实
升级验收。用户还须核对
同一 GitHub Release 的源码标签、文件清单和 SHA-256，并完成首次手动信任。

## 用户信任边界

用户必须先计算 `Linnet.pkg` 的 SHA-256，并与同一正式 Release 说明中的摘要
逐字比对，再在 Finder 中按住 Control 点击或右键点击 `Linnet.pkg`，选择“打开”。若仍被 macOS 拦截，可在“系统设置 → 隐私与
安全性”中对该文件选择“仍要打开”。文档和脚本不得要求关闭 Gatekeeper、
清除 quarantine 属性或修改系统安全策略。

没有 Developer ID 不表示没有验证。正式产物仍必须满足：

- 标签、源码 revision、App 内嵌 metadata 和产物清单一致；
- App 与嵌套 Settings、动态库、插件均由仓库钉住的同一 CMS leaf 签名，并通过
  严格 codesign 结构校验；
- PKG 明确为 `Status: no signature`，且不能含 Installer Signature 记录；
- 候选目录精确匹配 `package/release_asset_manifest`；正式 Release 只有 1 个完整安装包，Core
  更新频道包含 Core、卸载器和 Catalog，数据频道包含 4 个不可变词包及已绑定基线的差分；
- 安装脚本保持当前用户范围，不安装 daemon、LaunchAgent、特权 helper；
- Complete 只拥有首次注册和受支持损坏安装的注册修复；首次安装最多要求一次注销，
  匹配已公布基线的健康安装使用 Core，Core 更新不要求注销；不匹配时明确使用
  Complete 修复 App，已有健康词包、个人数据及输入源注册保持不变。

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
预检出现密码框，应取消并排查。由于 CMS 签名时间会改变字节，本地预检输出不得作为
安装验收或正式发布候选。

正式候选只能由 `scripts/release-control candidate` 创建携带本地验收收据的
annotated `linnet-candidate/v<VERSION>-<FULL_REVISION>` 标签启动；裸标签会被拒绝。
先运行 `scripts/release-control verify-local`：恢复锁定输入并构建，再串行完成
strict lint、发布 owner、App/Swift/Rime、Periphery。验证期间不得编辑源码；临时
Git index 绑定完整源 tree，不改变暂存区。收据只保存在 ignored
`build/linnet-source-verification.json`；合并提交不同但 tree 完全相同时可复用。
这是可信维护者的验收声明，不宣称 Action 独立重跑了本地测试。

Settings UI 只在合法隔离桌面及 Developer Mode 下本地执行，否则明确记录
`NOT_EXERCISED`，由 candidate Action 补测；本地 PASS 时不重跑。
同一个 macOS job 只做一次 checkout、一次锁定 cache restore、一次 hydrate，验证
标签到 commit/tree 的绑定，保留依赖提交历史的版本检查和实际产物门。随后 Action 使用
`community-signing` Environment 中的 P12 和密码创建临时 Keychain，并只运行一次
`make archive`。同一次 Make 调用只编译一份 `build/linnet-pack`；
`make_package` 在产物边界验证两个 PKG，最终
`package/verify_publication_artifacts` 再验证完整 manifest 集合。中间的 archive
投影不重复验证同一 PKG。

候选 Action 把 manifest 的原字节直接写入三个 Draft GitHub Releases：Core 3 件、data
4 个完整词包及对应差分、public 1 件。GitHub Actions artifact 不是发布传输或存储 owner，因此不会再
上传约 906 MB artifact、随后在另一个 job 下载并解压同一份数据。
Core 与 public Draft 必须精确绑定当前候选 revision；data Draft 由固定 tag、标题、
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
失败保留原始安装，只有明确确认 Complete/完整词包修复后才允许全量传输。
安装器与 Settings 复用一个数据 mutation lease，不关闭任何应用。

rsync batch 是系统维护的非确定性传输格式；可验证的是精确目标内容，不是重复构建得到
同一 batch。首次生成后冻结其原字节并验收。在后续 Core-only 候选中，将已发布 delta
的同仓库 URL、revision、bytes/SHA-256 加入 `sources`，并在相应 `pack_baselines`
记录中指定 `delta_source`；构建复用该资产，不能重生成另一个 delta 覆盖已公开 data
Release。新 pack sequence 才选择新的基线并生成新的差分。当前阶段此基线锁更新由
维护者在发布准备时完成，并非后台自动改写。

## GitHub 发布

正式产物的构建、签名、候选暂存和最终公开都由 GitHub Actions 完成；维护者 Mac
负责源码验收与 Action 原字节安装验收，并在验收后创建不可变授权标签：

1. 运行 `scripts/release-control verify-local`，提交其绑定的相同 source tree，
   在 clean、精确远端 `main` 运行 `scripts/release-control candidate`；
2. 等待唯一 macOS candidate job 成功。它复用源码收据，补齐未执行的 Settings UI，
   只构建、签名一次，并把 manifest 中的全部产物直接放入
   `core-v<VERSION>`、`data-<SEQUENCE>` 和 `v<VERSION>` 三个 Draft Releases；
3. 用已认证的 GitHub CLI 把三个 Draft 的互不重叠资产下载到一个新空目录。记录
   candidate job summary 的 revision 与产物集合摘要，并在本地重新运行最终 verifier；
4. 在真实账号用该目录完成“两轮同 leaf Core”：从前一公开版升级到候选，再重装
   同一原字节。两轮都须无注销、无 Keychain 密码提示、Host PID 不变且
   `AXHidden=false`，并保留 enabled/selected、UserData、输入菜单、Settings 和真实输入；
5. 验收通过后运行
   `scripts/release-control authorize "$ARCHIVE_OUTPUT_DIR"`。本地命令只能重新验证
   全部 manifest 文件和三个远端 Release 的 SHA-256/size，并通过 SSH 创建
   `linnet-publication/v<VERSION>-<FULL_REVISION>-h<SET_SHA256>`；它不能构建、
   上传、编辑 Release 或推进 Catalog；
6. 授权标签启动 Ubuntu publisher job。它从 GitHub Release metadata 验证完整 manifest
   集合，只下载约 4 KB 的 `Linnet-Data-Channel.json`，然后按
   Core → data → 非强制快进 Catalog → Public / Latest 的顺序发布。大型资产不再下载。

更新锁定 LTS 模型时，显式
`linnet-data-seed/v<VERSION>-<SEQUENCE>-<FULL_REVISION>` 标签启动同一个 macOS
构建 owner。它从 `upstreams.lock.json` 的上游 URL 下载并验证固定 bytes/SHA-256，
完成完整候选构建与最终 verifier，但只暂存并公开 manifest 中的 data 预发布资产；不得发布
Core/Public，也不得推进 Catalog。随后只有同一 revision 可快进到 `main`，再走正常
candidate 流程。正常版本不运行 seed 模式。

任一项失败都停止在当前幂等边界；不能覆盖、删除或 `--clobber` 已公开资产。候选
字节本身有误时，修复必须形成新的 revision；只有已验收版本推进时才增加 build，
数据内容变化时才增加必要的数据 sequence，再由
macOS Action 生成新候选。`v<VERSION>` 只标识公开版本，两个控制标签分别只授权
显式 data seed 或已验收的产物集合。

词包身份变化时序号必须严格递增，身份不变时序号必须保持不变。合并或 squash
可能一次包含多次合法修订，因此基线比较不要求序号恰好加一；不得为了合并检查
把已有序号重新编号，或允许同一序号对应不同内容。Catalog 的词包快照序号遵循
相同的顺序规则，Core-only 变化不推进词包序号。

旧 ad-hoc → 固定 CMS 只是一条一次性的历史 Core lifecycle 验收边；唯一记录在
`config/linnet-community-signing.json`。其中固定 leaf、bundle ID、macOS major 和
identity classifier 的“旧迁移投影指纹”共同决定该历史证据能否继续复用：任一项与
当前候选失配，才必须在隔离的 legacy-seeded 账号或虚拟机中重做迁移；全部匹配时
不得要求每个候选重复该迁移。Host 连续性和 TIS 不变性由当前 package lifecycle
matrix 独立验证。该记录只闭合 legacy identity edge，不能冒充当前候选的菜单、
Settings、输入交互或完整安装 UAT；当前候选仍以步骤 4 的“两轮同 leaf Core”为
发布前证据。

Settings 只读取 `data-channel` 的一个稳定指针，不读取可变 Release 别名，也不
维护第二份 Core 版本清单。仓库没有候选 Catalog 地址或自动回退路径。

GitHub 令牌只用于把已经验证的字节写入当前仓库；固定 P12 与密码分别存放在
`community-signing` Environment 的
`LINNET_COMMUNITY_CMS_P12_BASE64` 和 `LINNET_COMMUNITY_CMS_P12_PASSWORD`
Secrets 中。它们不是 Apple 开发者凭据，也不会被打包、写入日志或公开。

## 安装验收

代码、静态产物和安装产品必须分别报告。首次 Complete 安装需验证一次注销
后输入源可用；同一 bundle ID/path 的后续 Core 更新必须验证：Installer 返回
`RestartAction=None`、登录会话不变、个人数据不变、输入源 enabled/selected
意图不被覆盖，更新期间 Host PID 不变且 `AXHidden=false`；安装脚本不得启动、隐藏或替换
Host，更新前已连接及更新后新打开的应用都可输入。安装后还须验证 Settings 分别显示
installed/running version、build 和 revision。立即应用的唯一 owner 是 Host 的 typed
activation state：用户必须先通过系统菜单切走 Linnet，且不得有未完成输入或数据事务。
TextEdit、Teams、Codex 及其他已连接应用始终保持打开；任一安全条件不满足时 Host
保持运行且 Settings 显示拒绝原因。Settings 不关闭用户应用，也不程序化切换输入源。
Host 接受后还须在退出前复核同一 typed 状态；Settings 只能从 canonical 路径启动并核对
精确 revision；再单独验证 Host 自然重启后由新 build 提供输入。
每个精确候选的“两轮同 leaf Core”必须使用
同一组 Draft Release 原字节：第一轮从前一已验收的固定 CMS 版（首次公开后即前一公开版）
升级，第二轮重装候选原字节；两轮均
不得注销或索要 Keychain 密码，并须验证登录会话、enabled/selected、UserData、
输入菜单、Settings 和真实输入。旧 ad-hoc 身份迁移的复用与失效条件只由
`config/linnet-community-signing.json` 中的固定 leaf、bundle ID、macOS major 和
“旧迁移投影指纹”决定，不是逐候选步骤。Core 只接受唯一、精确匹配的 TIS source/bundle
身份；App 缺失或注册缺失时在 payload 前失败。受支持签名 App 的缺失注册由 Complete
修复；重复、冲突、未知 bundle 或任何残留身份必须先走官方卸载，不能猜测或覆盖用户
状态。发布 Keychain 密码永远不属于用户安装流程；历史首次身份迁移若由
macOS 显示输入源安全确认，它是一次系统授权，不是 Keychain 密码。

任何校验和、产物清单、App metadata 或安装状态不一致都应停止发布；不得用
重新签名、手工复制 App、清缓存或降低验证门来制造通过结果。
