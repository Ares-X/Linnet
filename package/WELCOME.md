Welcome to 双韵 (Linnet)

Linnet is a local Chinese and Smart English input method for Apple silicon Macs.
Keystrokes, candidates, personal words, and learning data stay on this Mac. The
input process contains no network client or telemetry.

This installer works only in the current user's account. It installs Linnet in
~/Library/Input Methods and verified language data in
~/Library/Application Support/Linnet. It does not require administrator access
or install a daemon, launch item, privileged helper, or background updater.

This community package is not signed with an Apple Developer ID and is not
notarized. Continue only after the package matches its exact Release SHA-256.
README provides direct offline uninstall commands. Open the package from Finder with Control-click or right-click >
Open; if macOS still blocks it, use System Settings > Privacy & Security > Open
Anyway. Never disable Gatekeeper or clear quarantine attributes. Stop if the
checksum differs or macOS reports damage or malware.

After installation:

- `Linnet.pkg` is the full install/repair package the user explicitly selects
  and confirms in Installer; Core never falls back to it automatically.
  Only creation of the first installed App registers Linnet and submits one
  standard macOS enablement request. Complete repair of an existing App and
  every Core update leave registration, enablement and selection untouched.
  Healthy installations use Core for routine updates. Core neither
  re-registers the source nor stops the live InputMethodKit Host. Existing
  applications keep their input connections. Complete repair stages and
  atomically replaces the App without forcing either Linnet window to close.
  Other applications stay open.
  Settings can apply an installed Core after you switch away from Linnet and
  finish the current composition or data operation. Other applications stay open;
  Settings starts and verifies the new Core without another logout.
  After upgrading from 0.1.10, reopen a Settings window that was already open
  before using data operations. The old window cannot read the new incremental
  learning format; its data requests are rejected. Other applications stay open.
- For a clean first installation, save open work, log out of macOS once, and
  log in again. Core preserves the same input-source identity and current
  client connections without requesting another logout.
- If Core reports a non-matching published baseline or damaged App bytes,
  explicitly run `Linnet.pkg` for Complete byte repair; Core never triggers
  that fallback silently. If Linnet is missing or disabled in the Input menu,
  add or enable it in System Settings > Keyboard > Text Input > Edit; an
  existing-App repair never resubmits authorization.
  If Core reports duplicate, conflicting, or unverifiable registration remnants,
  run the offline uninstall commands in README, then install Complete.
  Do not use Complete for a routine healthy upgrade or to bypass a rejected
  App identity or version.
- If macOS asks for first-use approval, allow it, then select Linnet yourself
  and confirm that it is present in the menu-bar input menu.
- A fresh installation defaults to full pinyin. Choose it or one of seven
  double-pinyin profiles in Settings > Input, then apply the change. Linnet does
  not reserve F4 or Control+grave.
- Tap Shift to switch between the current Chinese profile and Smart English.
  Use Caps Lock for raw ASCII; the status indicator then shows A.
- Open Settings from the native Linnet input menu. It is embedded in Linnet,
  is not installed as a separate product, does not remain in the Dock, and
  exits when its last window closes.

Smart English always provides spelling correction and fuzzy matching. Settings
can independently enable context prediction and selection learning; choose simplified or traditional Chinese
output; and set a 12–32 pt candidate font size. Every font preset uses fonts
built into macOS; Linnet does not download or require third-party fonts.

Settings checks the published Catalog once when it opens and shows a quiet
inline Core/data update status. After the one-time 0.1.15 bridge, a Core update
is downloaded, verified and explicitly applied in Settings without Installer,
a password, logout or restart. Language-data downloads run only when you start them in Settings. GitHub is the default source; a third-party
public mirror or a compatible custom HTTPS mirror can be selected explicitly.
Linnet never switches sources automatically and verifies the catalog, container,
and every packaged file before activation. Third-party mirrors may observe your
IP address, request time, and requested public file URLs, but Linnet does not
send them personal dictionaries, learning data, or credentials.

Keep the installer until installation and first input are complete. The exact
SHA-256 is printed in the same stable Release notes. Core updates live in the
same repository's versioned Core update channel. README provides direct offline
commands for complete removal; Linnet does not download or publish an
uninstaller.

Before uninstalling, switch to another input source, sign out and back in, then
open only Terminal. The README commands permanently remove the App, all Linnet
data, backups, preferences and Installer receipts. Export anything you need
before running them.

---

欢迎使用双韵（Linnet）

Linnet 是面向 Apple 芯片 Mac 的本地中文与智能英文输入法。按键、候选、
个人词和学习数据都保留在本机；输入进程不包含网络客户端或遥测。

本安装器只安装到当前用户账户：Linnet 位于 ~/Library/Input Methods，
经过校验的语言数据位于 ~/Library/Application Support/Linnet。安装不需要
管理员权限，也不安装守护进程、启动项、特权辅助程序或后台更新器。

本社区安装包没有 Apple Developer ID 签名，也没有经过 Apple 公证。只有在
安装包与同一正式 Release 说明中的精确 SHA-256 一致时才能继续。在 Finder
中按住 Control 点击或右键点击安装包，选择“打开”；若仍被拦截，请前往
系统设置 → 隐私与安全性 → 仍要打开。不要关闭 Gatekeeper，也不要清除
隔离属性。若校验和不一致，或系统报告文件损坏、含恶意软件，请停止安装。

安装完成后：

- `Linnet.pkg` 是用户明确选择并在 Installer 最终确认的完整安装/修复包；Core
  不会自动切换到它。Complete 是全新首次安装或受支持、已验证签名 App 修复的
  字节修复责任方。只有首次创建 App 时才注册并向 macOS 提交一次启用请求；已有
  App 的 Complete 修复与 Core 更新都不注册、启用或选择输入源。允许与菜单选择
  始终由用户完成。
  0.1.15 是从旧式 Core PKG 进入设置内更新的一次性桥接版；此后的健康安装只使用
  `.linnetcore`。用户先切换到其他输入法，且没有未完成组合或数据事务时，可在
  Settings 中主动应用新 Core；其他应用保持打开，不需要 Installer、密码、注销或重启。
  Core 不会重新注册、启用或选择输入源。
  从 0.1.10 升级后，备份、导入或修改数据前，请关闭并重新打开升级前已打开的
  Settings 窗口。旧窗口不认识新的增量学习格式，其数据操作会被拒绝；其他应用无需退出。
- 全新首次安装时，保存工作，注销一次 macOS，再登录同一账户。Core 保持同一个
  输入源身份和当前连接，常规升级不请求再次注销。
- 若 Core 报告未匹配精确发布基线或 App 字节损坏，请由用户主动运行 `Linnet.pkg`
  完整修复；它不会由 Core 静默回退触发。若输入菜单缺少或停用了 Linnet，请在
  系统设置 → 键盘 → 文本输入 → 编辑 中添加或启用；已有 App 的修复不会重复申请授权。
  若 Core 报告重复、冲突或无法验证的注册残留，
  请先运行 README 中的离线卸载命令，再安装 Complete。
  不要把 Complete 用作健康安装的常规升级，也不要用它绕过被拒绝的 App 身份或版本。
- 若 macOS 首次请求允许 Linnet，请选择“允许”，再从菜单栏输入菜单选择 Linnet。
  Complete 不会代替用户确认授权或切换输入源。
- 全新安装默认全拼；可在 Settings → 输入选择全拼或七种双拼之一并应用更改。
  Linnet 不占用 F4 或 Control+grave。
- 轻按 Shift 在当前中文方案与智能英文之间切换；Caps Lock 用于原始 ASCII，
  此时菜单栏状态显示 A。
- 从原生 Linnet 输入菜单打开 Settings。它内嵌于 Linnet，不作为独立产品
  安装、不常驻 Dock，并在最后一个窗口关闭后退出。

智能英文始终提供拼写纠错和模糊匹配。Settings 可分别开关上下文预测和选词学习，选择默认
简体或繁体输出，并把候选字号设为 12–32 pt。所有字体预设只使用 macOS
内置字体，不会下载或依赖第三方字体。

Settings 打开时会检查一次已发布 Catalog，并以内联方式显示 Core/数据更新状态。
更新频道可选正式版（默认）或预览版；Core 检查和语言数据下载始终使用同一所选频道，
不会自动切换或回退。
Core 仍需用户确认安装；语言数据只在用户从 Settings 主动发起时下载。GitHub 是默认来源，也可明确选择第三方
公开镜像或兼容的自定义 HTTPS 镜像。Linnet 不自动切换来源，并在激活前校验
Catalog、容器和每个文件。第三方镜像可能看到 IP、请求时间和公开文件 URL，
但不会收到个人词典、学习数据或凭据。

安装和首次输入完成前，请保留安装包，并核对同一 Release 说明中的 SHA-256。
使用、隐私、升级与卸载说明见 Linnet Release 页面。

卸载前先切换到其他输入法，注销并重新登录，然后只打开 Terminal。README
直接给出完全离线的本地命令；命令会永久删除 App、全部 Linnet 数据、备份、
偏好和 Installer receipts，需要保留的数据请先导出。
