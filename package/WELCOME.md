Welcome to 双韵 (Linnet)

Linnet is a local Chinese and Smart English input method for Apple silicon Macs.
Keystrokes, candidates, personal words, and learning data stay on this Mac. The
input process contains no network client or telemetry.

This installer works only in the current user's account. It installs Linnet in
~/Library/Input Methods and verified language data in
~/Library/Application Support/Linnet. It does not require administrator access
or install a daemon, launch item, privileged helper, or background updater.

This community package is not signed with an Apple Developer ID and is not
notarized. Continue only after the package and uninstaller match their exact
release SHA-256 files. Open it from Finder with Control-click or right-click >
Open; if macOS still blocks it, use System Settings > Privacy & Security > Open
Anyway. Never disable Gatekeeper or clear quarantine attributes. Stop if the
checksum differs or macOS reports damage or malware.

After installation:

- `Linnet.pkg` is the full install/repair package the user explicitly selects
  and confirms in Installer; Core never falls back to it automatically.
  Complete is the sole registration owner for a clean first installation or a
  supported, signature-verified App repair. It registers only a missing source
  idempotently and never enables or selects it; an exact existing source is
  preserved during full repair. Healthy installations use Core for routine
  updates. Core neither
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
- If Core reports a non-matching published baseline or a missing registration,
  explicitly run `Linnet.pkg` for Complete repair; Core never triggers that
  fallback silently.
  If Core reports duplicate, conflicting, or unverifiable registration remnants,
  run the official uninstaller first, then install Complete.
  Do not use Complete for a routine healthy upgrade or to bypass a rejected
  App identity or version.
- Open System Settings > Keyboard > Text Input > Edit, add and allow Linnet if
  macOS asks, then select Linnet from the menu-bar input menu.
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
inline Core/data update status. Core remains a user-approved package update;
language-data downloads run only when you start them in Settings. GitHub is the default source; a third-party
public mirror or a compatible custom HTTPS mirror can be selected explicitly.
Linnet never switches sources automatically and verifies the catalog, container,
and every packaged file before activation. Third-party mirrors may observe your
IP address, request time, and requested public file URLs, but Linnet does not
send them personal dictionaries, learning data, or credentials.

Keep the installer until installation and first input are complete. The exact
SHA-256 is printed in the same stable Release notes. Core updates and the
uninstaller live in the same repository's versioned Core update channel.

Before uninstalling, switch to another input source. The uninstaller never runs
the installed Host; if the exact Host or Settings process remains active, sign
out and back in, then retry. Runtime logs live in the fixed product path
`Application Support/Linnet/Runtime/Logs` and leave with the default Runtime
removal. Default uninstall keeps personal data; purge additionally removes
preferences and remaining personal data without inferring a system temporary path.

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
  唯一输入源注册责任方。它只在输入源缺失时幂等注册，不会程序化启用或选择输入源；
  已验证的现有输入源在完整修复中保持不变。健康安装的常规升级只使用 Core。
  macOS 14 及以上必须在系统设置中手动添加并允许一次。Core 不会重新注册或停止
  正在服务的 InputMethodKit Host；Complete 修复会暂存并原子替换 App，不强制关闭
  任何 Linnet 窗口；其他应用保持打开并保留输入连接。用户先切换到其他输入法，
  且没有未完成组合或数据事务时，可在 Settings 中主动应用新 Core；其他应用保持打开；
  否则新 Core 会在下次登录或重启后接管，也不会再次弹出启用授权。
  从 0.1.10 升级后，备份、导入或修改数据前，请关闭并重新打开升级前已打开的
  Settings 窗口。旧窗口不认识新的增量学习格式，其数据操作会被拒绝；其他应用无需退出。
- 全新首次安装时，保存工作，注销一次 macOS，再登录同一账户。Core 保持同一个
  输入源身份和当前连接，常规升级不请求再次注销。
- 若 Core 报告未匹配精确发布基线或输入源未注册，请由用户主动运行 `Linnet.pkg`
  完整修复；它不会由 Core 静默回退触发。
  若 Core 报告重复、冲突或无法验证的注册残留，
  请先运行官方卸载器，再安装 Complete。
  不要把 Complete 用作健康安装的常规升级，也不要用它绕过被拒绝的 App 身份或版本。
- 打开 系统设置 → 键盘 → 文本输入 → 编辑；添加 Linnet，并在 macOS 请求时
  选择允许，然后从菜单栏输入菜单选择 Linnet。
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
Core 仍需用户确认安装；语言数据只在用户从 Settings 主动发起时下载。GitHub 是默认来源，也可明确选择第三方
公开镜像或兼容的自定义 HTTPS 镜像。Linnet 不自动切换来源，并在激活前校验
Catalog、容器和每个文件。第三方镜像可能看到 IP、请求时间和公开文件 URL，
但不会收到个人词典、学习数据或凭据。

安装和首次输入完成前，请保留安装包，并核对同一 Release 说明中的 SHA-256。
使用、隐私、升级与卸载说明见 Linnet Release 页面。

卸载前先切换到其他输入法。卸载器不会执行已安装的 Host；若精确 Host 或
Settings 进程仍在运行，请注销并重新登录后重试。运行日志固定存放在
`Application Support/Linnet/Runtime/Logs`，会随默认卸载的 Runtime 一起删除。
默认卸载保留个人数据；完整清理还会删除偏好与剩余个人数据，不推断系统临时路径。
