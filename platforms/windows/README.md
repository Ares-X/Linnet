# Linnet for Windows

The Windows distribution reuses the stable Weasel 0.17.4 frontend. It does
not fork Rime behavior or maintain a second language-data build.

## Ownership

| Fact or boundary | Before | After |
| --- | --- | --- |
| Input behavior and schemas | root Linnet data | unchanged: root Linnet data |
| Native Rime behavior | locked root librime and patches | unchanged: the same source is built as `rime.dll` |
| Lua, octagram, prediction, Smart English | root locked plugins | unchanged: merged into the root-owned `rime.dll` |
| macOS frontend | Squirrel-derived app | unchanged |
| Windows TSF, IPC, candidate UI, installer | none | one locked Weasel projection |
| Windows updates | none | none; Weasel's updater is removed until Linnet owns a signed Windows update contract |

Weasel's nested librime, plum recipes, default schemas, updater and optional
schema downloader are not product authorities. Windows consumes the exact
`data/plum` and `data/opencc` projection made by `scripts/stage-linnet-data` on
macOS CI. Shared input defaults are exported by the existing Settings projection
renderer for all eight Chinese profiles, English and global defaults at build
time and included through Rime's native `__patch` mechanism,
before user customization. The grammar selection is exported from the shared
data registry too: Windows uses the shipped Wanxiang LTS model, not the compact
developer fixture. Windows does not duplicate those policies or ship a
Swift runtime. `weasel.yaml` owns candidate window presentation and application
integration, not input behavior.

The projection assigns Linnet its own TSF/profile/language-bar GUIDs, registry
root, IPC pipe/window, deployer mutexes, `LinnetServer.exe` process name,
log/user directory and installed system DLL names. Linnet and upstream Weasel
are designed to coexist without sharing those owners; coexistence remains a
target-Windows acceptance item. Internal build-target names remain an upstream
compatibility detail and are renamed only at the installer boundary.

## Portable product features

The Windows package consumes the same staged files and merged Rime modules as
macOS. Portable feature truth remains in those root-owned schemas, dictionaries
and modules; Windows does not maintain a second feature ledger. The installed
manifest records only verifiable package provenance: product version, locked
Weasel/librime commits, projected configuration digest and updater state.

English glosses are not a Windows-side dictionary or online translation
service. `linnet.smart.db` remains the sole metadata owner and Smart English
projects its `m/ipa/` and `m/zh/` records into standard Rime candidate comments.
Weasel renders that existing comment field, removing only the leading metadata
marker used by the macOS frontend; IPA and Chinese definitions remain visible.

The Windows presentation is generated from all seven Linnet theme families in
`data/squirrel.yaml`, producing fourteen light/dark schemes and seven
deterministic selector previews. Weasel's native system-dark-mode detection and
theme selector are retained; selecting a family writes its light/dark pair.
Colors preserve Squirrel's ABGR interpretation. macOS underline/bar themes use
Weasel's native selection border; tile themes retain their filled selection.
Long horizontal candidate rows wrap using Weasel's native width limit.
macOS material blur and custom drawing are not emulated.

Weasel retains its mature schema selector, theme selector, user-dictionary
management, synchronization and deployment entrypoints. The
schema switcher opens with Ctrl+` or F4; choose Smart English there for English
completion with IPA and Chinese glosses. Shift's plain ASCII mode is separate
and does not show candidates. The optional
package-mutating schema downloader is removed completely because root Linnet
data is package-owned. The SwiftUI/AppKit
Linnet Settings application is not shipped on Windows. Input defaults still
come from the shared schemas and projection renderer, rather than a second
Windows settings model. This includes continuous mixed Chinese/English input,
schema-aware Chinese spelling correction and conservative nasal-final correction,
uppercase intent, code-shaped raw input and the reviewed English and Chinese
supplemental dictionaries.

## Build

Pull-request CI and manually dispatched clean-build CI perform the full build.
Locally, first run
the existing macOS preparation to create the canonical data and embedded Lua
header:

```bash
./action-install.sh
scripts/stage-windows-build-inputs
```

Transfer `data/plum`, `data/opencc`, the repository, and `build/windows-inputs`
to Windows. In a Visual Studio 2022 developer environment:

```powershell
git submodule update --init --depth 1 -- librime upstreams/weasel
git -C librime submodule update --init --recursive --depth 1
platforms/windows/prepare.ps1 `
  -DataRoot C:\path\to\shared-data `
  -EmbeddedLuaHeader C:\path\to\linnet_embedded_lua.h `
  -InputPolicyRoot C:\path\to\windows-inputs\policies `
  -WeaselConfig C:\path\to\weasel.yaml `
  -ThemePreviewRoot C:\path\to\preview
platforms/windows/build.ps1 -BoostRoot C:\path\to\boost_1_89_0
```

The output is `build/windows/weasel/output/archives/Linnet-Windows-*-installer.exe`.
Product version and build number come only from `config/LinnetProduct.xcconfig`.
Opening or cancelling the upgrade wizard before clicking Install leaves the
existing input service in place. Package replacement begins only when installation
starts; user dictionaries and customization remain in the user's Linnet directory.
CI then runs `platforms/windows/preflight.ps1`; the installer is not uploaded
unless both Win32 and x64 `rime.dll` builds pass real Chinese/English candidate
sessions and the package passes silent Traditional Chinese installation,
Simplified Chinese upgrade, both 32/64-bit TSF registration, installer-owned
deployment, service startup and uninstall lifecycle on the Windows runner. The
gate uses an isolated temporary `%AppData%`, checks every runtime file referenced
by OpenCC, then reruns the same input sessions against the installed shared data
and the dictionaries generated on Windows. The installer carries the canonical
`data/dicts` source graph needed for a clean-machine Chinese build; macOS-built
dictionary binaries are not treated as Windows evidence. Setup or deployment
failures must propagate as a nonzero installer result. It also installs the
candidate a second time to exercise the upgrade path, proving obsolete package
data is removed while the isolated user dictionary directory survives upgrade
and uninstall.
An unrun or failing Windows preflight is a UAT `NO-GO`; manual testing starts
only from an uploaded candidate that passed this gate.

These CI builds retain the verified Windows installer only as an expiring
Actions artifact for real-machine UAT. It is deliberately absent from
the public release manifest and no publication job downloads it. Passing CI,
adding a signature, or manually renaming that artifact does not authorize a
Windows GitHub Release.

Windows publication remains blocked until the complete target-Windows UAT below
passes against one exact candidate. A later publication milestone must bind the
public asset to that candidate revision and installer SHA-256, retain the UAT
environment and result, and fail if the bytes differ. Until then the repository
has zero Windows Release paths; the existing publisher remains macOS-only.

## Acceptance status

- Local/macOS: locked patch application, theme generation and data integrity.
- Local/macOS shared runtime: real librime sessions for Chinese profiles, Smart
  English IPA/glosses, prediction, correction, reverse lookup and learning.
- Windows CI: Visual Studio x64/Win32 runtime plus ARM/ARM64/ARM64X TSF
  compilation; Win32 and installed x64 `rime.dll` black-box input sessions;
  silent Traditional install and Simplified upgrade, package,
  registry, TSF, installer-owned deployment, service-start and uninstall
  lifecycle.
- Still required before calling a Windows release accepted: install/uninstall
  on a clean Windows 10 and Windows 11 VM, coexistence with upstream Weasel,
  typing in Win32 and modern applications, candidate UI, native ARM64 runtime,
  user-data isolation, injected-failure upgrade rollback, and code-signing
  verification.

A passing macOS check or headless Windows compile is component evidence only;
it is not Windows product UAT. Every required row must be exercised on the
exact installer that would be published; an unexecuted row is `NOT_EXERCISED`,
not a pass.

### Desktop validation on Parallels

Use the authorized Windows guest, with the exact Actions installer SHA-256
verified after transfer. `prlctl exec "Tiny Windows 11" --current-user` runs in
the logged-in user's desktop session; omitting `--current-user` runs as SYSTEM
in session 0 and cannot establish user input behavior. Keep administrative
installation and user-desktop typing separate, without changing UAC policy.

`prlctl capture "Tiny Windows 11" --file <host-path.png>` captures only the guest.
For typing, send actual press/release events with `prlctl send-key-event --json`,
including held Shift spans. Do not use clipboard paste or editor text setters.
Check the foreground window before each journey: launching a guest console can
take focus from an editor or dismiss a menu. Observe the candidate before commit
and read the application's resulting text afterwards.

On ARM64, installation and menu visibility alone do not establish a working
frontend. The installed COM class must resolve its forwarded exports using
Linnet's own system DLLs. Record native ARM64 and emulated x64/x86 application
results separately, and retain the exact candidate when a load failure occurs.
