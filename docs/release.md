# Linnet 社区版发布

Linnet 的公开发行采用无付费证书的社区模式：PKG 不含 Apple Developer ID
Installer 签名，也不经过 Apple 公证；App 内的 Mach-O 使用 hardened-runtime
ad-hoc 签名，作为代码结构与嵌套组件完整性边界。用户信任来自同一 GitHub
Release 的源码标签、文件清单和 SHA-256，而不是开发者证书。

## 用户信任边界

用户必须先计算 `Linnet.pkg` 的 SHA-256，并与同一正式 Release 说明中的摘要
逐字比对，再在 Finder 中按住 Control 点击或右键点击 `Linnet.pkg`，选择“打开”。若仍被 macOS 拦截，可在“系统设置 → 隐私与
安全性”中对该文件选择“仍要打开”。文档和脚本不得要求关闭 Gatekeeper、
清除 quarantine 属性或修改系统安全策略。

无签名不表示无验证。正式产物仍必须满足：

- 标签、源码 revision、App 内嵌 metadata 和产物清单一致；
- App 与嵌套 Settings、动态库、插件均通过严格 codesign 结构校验；
- PKG 明确为 `Status: no signature`，且不能含 Installer Signature 记录；
- 候选目录只有 8 个验证产物；正式 Release 精确发布 1 个完整安装包，Core
  更新频道发布 2 个文件，数据频道发布 5 个文件；
- 安装脚本保持当前用户范围，不安装 daemon、LaunchAgent、特权 helper；
- Complete 只用于首次安装并最多要求一次注销；之后 Core 更新不要求注销。

## 本机构建与验证

公开构建不需要证书、Keychain 或签名密码：

```bash
export LINNET_CANDIDATE_REVISION="$(git rev-parse HEAD)"
export ARCHIVE_OUTPUT_DIR="$(mktemp -d /private/tmp/linnet-release.XXXXXX)"
./action-build.sh archive
```

构建要求工作树干净，并把当前 HEAD 写入 App metadata。`make community` 负责
ad-hoc 签名；`package/make_package` 只封装已验证字节，不重新签名或修复。

最终 8 个候选产物使用独立 pack CLI 验证：

```bash
release_version="$(sed -n \
  's/^MARKETING_VERSION = \([^[:space:]]*\)$/\1/p' \
  config/LinnetProduct.xcconfig)"
LINNET_RELEASE_TOOL=/absolute/path/to/linnet-pack \
  package/verify_publication_artifacts \
  "$ARCHIVE_OUTPUT_DIR" "$release_version" "$LINNET_CANDIDATE_REVISION"
```

测试用 UAT CMS 身份仍可用于本地、非公开的安装回归；它不是公开发布前置，
也不得进入 Git、CI、Release 或文档中的普通用户流程。

## GitHub 发布

版本标签是把候选版本公开为正式 Release / Latest 的唯一授权。标签必须为
`v<MARKETING_VERSION>` 并直接指向要发布的源码 revision；安装验收记录本身
不授权公开 Release，因此单一根提交仓库不会产生第二条正式版本真相。

正式标签之前先完成一次可安装候选收口：

1. 候选 revision 已推送到 `main`，且该精确 revision 的 main CI 全部通过；
2. 从同一干净 revision 构建并独立验证 8 个归档文件；
3. 依次运行唯一 publisher 的 `core`、`data`、`catalog` 阶段。`catalog` 只有在
   远端 Core 和 data 预发布的状态、文件名和 SHA-256 全部与本地候选一致后，
   才把同一 Catalog 仅快进写入 `data-channel`；
4. 使用该 Core 包在已完成首次安装的账号内原位升级，不注销；再从真实安装态
   Settings 获取并激活该 Catalog，完成输入源、个人数据、Shift、全拼/双拼和
   Smart English 的 InputMethodKit 验收；
5. 任一项失败都停止，不创建正式版本标签。修复必须形成新的 revision、build
   和必要的数据 sequence，再重新走上述候选流程；不能替换已经公开的资产。

验收通过后才推送版本标签。`.github/workflows/release-ci.yml` 会在无证书环境中：

1. 校验标签、源码与语言数据 metadata；
2. 构建 community archive；
3. 验证精确 8 个候选文件、App ad-hoc 完整性及两个未签名 PKG；
4. 从唯一 `release_asset_manifest` 投影三个同仓库频道：`v<version>` 的稳定
   Release 只上传 `Linnet.pkg`，`core-v<version>` 上传 Core PKG 与卸载器，
   `data-<sequence>` 上传 Catalog 与四个语言包；
5. 按 `core` → `data` 重验候选阶段的精确远端字节；`public` 创建正式版本前还
   必须确认稳定指针已经是同一 Catalog，但无权改写它，最后才把单安装包设为
   Latest。重复执行只能接受字节完全相同的已发布状态。

Settings 只读取 `data-channel` 的一个稳定指针，不读取可变 Release 别名，也不
维护第二份 Core 版本清单。仓库没有候选 Catalog 地址或自动回退路径。

该令牌只用于把已经验证的字节写入当前仓库的两个预发布频道、一个稳定 Catalog
指针和一个正式 Release，不是 Apple 开发者凭据，也不会被打包或公开。

## 安装验收

代码、静态产物和安装产品必须分别报告。首次 Complete 安装需验证一次注销
后输入源可用；同一 bundle ID/path 的后续 Core 更新必须验证：Installer 返回
`RestartAction=None`、登录会话不变、个人数据不变、输入源 enabled/selected
意图不被覆盖，并由新 build 提供输入。

任何校验和、产物清单、App metadata 或安装状态不一致都应停止发布；不得用
重新签名、手工复制 App、清缓存或降低验证门来制造通过结果。
