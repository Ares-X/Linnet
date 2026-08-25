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
- 候选目录只有 8 个验证产物；正式 Release 精确发布 1 个完整安装包，Core
  更新频道发布 2 个文件，数据频道发布 5 个文件；
- 安装脚本保持当前用户范围，不安装 daemon、LaunchAgent、特权 helper；
- Complete 只用于首次安装并最多要求一次注销；之后 Core 更新不要求注销。

## 本机构建与验证

普通开发构建不需要证书。只有维护者生成可公开安装的 `archive` 时才使用固定
生产身份；Keychain 与密码都位于仓库外，并由脚本自动解锁和锁回：

首次配置这台维护者 Mac 时，先把当前用户拥有且权限为 `0600` 的固定输入放到：

- `~/Library/Application Support/Linnet Maintainer/Signing/community-cms/community-cms.p12`
- `~/Library/Application Support/Linnet Maintainer/Signing/community-cms/p12-password`

然后只运行一次 `scripts/provision-community-signing`。它在创建任何 Keychain 前核对
仓库钉住的证书 SHA-1/SHA-256，配置 `/usr/bin/codesign` 的访问分区，完成非交互
签名探针并锁回。任一固定输出已经存在时都会失败，且没有 replace、repair 或 delete
入口；失败只回滚本次创建的精确目标并恢复原搜索列表。成功后不要在每次发版前重跑。
若配置或日常归档出现密码框，应取消并排查，不能输入 macOS 登录密码或删除既有身份。

```bash
export LINNET_CANDIDATE_REVISION="$(git rev-parse HEAD)"
export ARCHIVE_OUTPUT_DIR="$(mktemp -d /private/tmp/linnet-release.XXXXXX)"
./action-build.sh archive
```

本机固定路径为 `~/Library/Keychains/Linnet-Community-CMS.keychain-db`，解锁密码
位于权限 `0600` 的
`~/Library/Application Support/Linnet Maintainer/Signing/community-cms/keychain-password`。
它是 Linnet 专用随机密码，不是用户的 macOS 登录密码；初次配置一次后，脚本只从
该文件非交互读取，日常构建不得显示密码框。构建要求工作树干净，并把当前 HEAD
写入 App metadata。`make community` 复用唯一 external-CMS 签名 owner；
`package/make_package` 只封装已验证字节，不重新签名或修复。普通 `release` / `debug`
仍是 unsigned 开发产物；旧的可安装 UAT 签名 profile 与 `candidate` lane 已删除。

本地 `archive` 只用于维护者预检。CMS 签名含签名时间，因此本机验收后再由 CI
重新编译或重签会产生另一组字节，不能冒充同一候选。正式安装验收与公开发布只认
下面发布 workflow 一次生成的不可变八文件 artifact。

最终 8 个候选产物使用独立 pack CLI 验证：

```bash
release_version="$(sed -n \
  's/^MARKETING_VERSION = \([^[:space:]]*\)$/\1/p' \
  config/LinnetProduct.xcconfig)"
LINNET_RELEASE_TOOL=/absolute/path/to/linnet-pack \
  package/verify_publication_artifacts \
  "$ARCHIVE_OUTPUT_DIR" "$release_version" "$LINNET_CANDIDATE_REVISION"
```

## GitHub 发布

`.github/workflows/release-ci.yml` 只允许从受保护的 `main` 手动启动，不再由版本
标签触发，也不会在安装验收后重建：

1. `build-candidate` 先确认当前 revision 等于远端 `main`，且该精确 revision 的
   main CI 已成功；之后才从 `community-signing` Environment Secrets 导入固定 P12，
   在临时 Keychain 中只编译、CMS 签名一次；
2. 最终 verifier 接受精确 8 个文件后，workflow 将这 8 个文件上传为不可覆盖的
   GitHub Actions artifact，并记录 artifact ID、digest、逐文件 SHA-256 和下载链接；
3. 维护者下载同一个 artifact，在真实账号完成“两轮同 leaf Core”：先用前一已验收
   的固定 CMS 版（首次公开后即前一公开版）升级到候选，再把同一候选的原字节重装
   一次。两轮都须验证无注销、无
   Keychain 密码提示、登录会话不变，并保留 enabled/selected、UserData、输入菜单、
   Settings 和真实输入；此时尚未创建 Release、标签或推进 Catalog；
4. 验收通过后，维护者只批准一次受保护的 `community-publication` Environment。
   `stage-update-channels` 才按该 artifact ID 下载并重验，不接触证书、不重编或重签
   产品；唯一 publisher 依次发布 Core、data，并在核对远端字节后推进 Catalog；
5. `publish-stable` 依赖上述受保护阶段，再按同一 artifact ID 下载并重验，只上传
   `Linnet.pkg`，由同一 publisher 创建指向该 revision 的 `v<version>` 标签并设为
   Latest。标签只是版本身份，不是重建触发器或第二个发布授权 owner。

任一项失败都不批准任何公开频道；修复必须形成新的 revision、build 和必要的数据
sequence，再生成新的 artifact，不能替换旧 artifact 或已公开资产。重复执行只接受
字节完全相同的远端状态。签名任务无论成功或失败都会恢复原 Keychain 搜索列表，
删除临时 Keychain、P12、密码文件和目录。

旧 ad-hoc → 固定 CMS 只是一条一次性的历史 Core lifecycle 验收边；唯一记录在
`config/linnet-community-signing.json`。其中固定 leaf、bundle ID、macOS major 和
“迁移契约指纹”共同决定该历史证据能否继续复用：任一项与当前候选失配，才必须在
隔离的 legacy-seeded 账号或虚拟机中重做迁移；全部匹配时不得要求每个候选重复该
迁移。该记录只闭合 legacy lifecycle edge，不能冒充当前候选的菜单、Settings、
输入交互或完整安装 UAT；当前候选仍以步骤 3 的“两轮同 leaf Core”为发布前证据。

Settings 只读取 `data-channel` 的一个稳定指针，不读取可变 Release 别名，也不
维护第二份 Core 版本清单。仓库没有候选 Catalog 地址或自动回退路径。

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
后输入源可用；同一 bundle ID/path 的后续 Core 更新必须验证：Installer 返回
`RestartAction=None`、登录会话不变、个人数据不变、输入源 enabled/selected
意图不被覆盖，并由新 build 提供输入。每个精确候选的“两轮同 leaf Core”必须使用
同一不可变 artifact：第一轮从前一已验收的固定 CMS 版（首次公开后即前一公开版）
升级，第二轮重装候选原字节；两轮均
不得注销或索要 Keychain 密码，并须验证登录会话、enabled/selected、UserData、
输入菜单、Settings 和真实输入。旧 ad-hoc 身份迁移的复用与失效条件只由
`config/linnet-community-signing.json` 中的固定 leaf、bundle ID、macOS major 和
“迁移契约指纹”决定，不是逐候选步骤。只有 App 与系统登记都明确缺失时才走未注册
修复；App 缺失但系统仍残留 enabled/disabled 身份会在 payload 前失败，不能猜测或
覆盖用户状态。发布 Keychain 密码永远不属于用户安装流程；历史首次身份迁移若由
macOS 显示输入源安全确认，它是一次系统授权，不是 Keychain 密码。

任何校验和、产物清单、App metadata 或安装状态不一致都应停止发布；不得用
重新签名、手工复制 App、清缓存或降低验证门来制造通过结果。
