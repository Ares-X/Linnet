# Linnet 社区版发布

Linnet 的公开发行采用无付费证书的社区模式：PKG 不含 Apple Developer ID
Installer 签名，也不经过 Apple 公证；App 内的 Mach-O 使用 hardened-runtime
ad-hoc 签名，作为代码结构与嵌套组件完整性边界。用户信任来自同一 GitHub
Release 的源码标签、文件清单和 SHA-256，而不是开发者证书。

## 用户信任边界

用户必须先校验 `Linnet.pkg.sha256`，再在 Finder 中按住 Control 点击或右键
点击 `Linnet.pkg`，选择“打开”。若仍被 macOS 拦截，可在“系统设置 → 隐私与
安全性”中对该文件选择“仍要打开”。文档和脚本不得要求关闭 Gatekeeper、
清除 quarantine 属性或修改系统安全策略。

无签名不表示无验证。正式产物仍必须满足：

- 标签、源码 revision、App 内嵌 metadata 和产物清单一致；
- App 与嵌套 Settings、动态库、插件均通过严格 codesign 结构校验；
- PKG 明确为 `Status: no signature`，且不能含 Installer Signature 记录；
- Complete/Core、语言包、Catalog、卸载器共 18 个文件，全部带精确 SHA-256；
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

最终 18 文件使用独立 pack CLI 验证：

```bash
LINNET_RELEASE_TOOL=/absolute/path/to/linnet-pack \
  package/verify_publication_artifacts \
  "$ARCHIVE_OUTPUT_DIR" 0.1.1 "$LINNET_CANDIDATE_REVISION"
```

测试用 UAT CMS 身份仍可用于本地、非公开的安装回归；它不是公开发布前置，
也不得进入 Git、CI、Release 或文档中的普通用户流程。

## GitHub 发布

版本标签是唯一发布授权。标签必须为 `v<MARKETING_VERSION>` 并直接指向要
发布的源码 revision；不再使用额外 approval commit，因此单一根提交仓库不会
产生第二条发布真相。

推送标签后，`.github/workflows/release-ci.yml` 会在无证书环境中：

1. 校验标签、源码与语言数据 metadata；
2. 构建 community archive；
3. 验证精确 18 文件、App ad-hoc 完整性及两个未签名 PKG；
4. 使用 GitHub Actions 提供的短期仓库令牌创建对应 Release 并上传文件。

该令牌只用于把已经验证的字节写入当前 GitHub Release，不是 Apple 开发者
凭据，也不会被打包或公开。

## 安装验收

代码、静态产物和安装产品必须分别报告。首次 Complete 安装需验证一次注销
后输入源可用；同一 bundle ID/path 的后续 Core 更新必须验证：Installer 返回
`RestartAction=None`、登录会话不变、个人数据不变、输入源 enabled/selected
意图不被覆盖，并由新 build 提供输入。

任何校验和、产物清单、App metadata 或安装状态不一致都应停止发布；不得用
重新签名、手工复制 App、清缓存或降低验证门来制造通过结果。
