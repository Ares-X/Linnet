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
macOS CI. The only Windows-specific YAML is `weasel.yaml`, which owns candidate
window presentation and application integration, not input behavior.

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
Weasel renders that existing comment field.

The Windows presentation is generated from all seven Linnet theme families in
`data/squirrel.yaml`, producing fourteen light/dark schemes and seven
deterministic selector previews. Weasel's native system-dark-mode detection and
theme selector are retained; selecting a family writes its light/dark pair.
macOS material blur and custom underline/tile drawing are not portable Weasel
capabilities and are deliberately not emulated.

Weasel retains its mature schema selector, theme selector, user-dictionary
management, synchronization and deployment entrypoints. Its optional
package-mutating schema downloader is removed completely because root Linnet
data is package-owned. The SwiftUI/AppKit
Linnet Settings application is not shipped on Windows. Input defaults still
come from the shared schemas, rather than a second Windows settings model.

## Build

Normal pull-request and branch CI performs the full build. Locally, first run
the existing macOS preparation to create the canonical data and embedded Lua
header:

```bash
./action-install.sh
scripts/stage-windows-build-inputs
```

Transfer `data/plum`, `data/opencc`, the repository, and the generated header
to Windows. In a Visual Studio 2022 developer environment:

```powershell
git submodule update --init --depth 1 -- librime upstreams/weasel
git -C librime submodule update --init --recursive --depth 1
platforms/windows/prepare.ps1 `
  -DataRoot C:\path\to\shared-data `
  -EmbeddedLuaHeader C:\path\to\linnet_embedded_lua.h `
  -WeaselConfig C:\path\to\weasel.yaml `
  -ThemePreviewRoot C:\path\to\preview
platforms/windows/build.ps1 -BoostRoot C:\path\to\boost_1_89_0
```

The output is `build/windows/weasel/output/archives/Linnet-Windows-*-installer.exe`.
Product version and build number come only from `config/LinnetProduct.xcconfig`.
CI then runs `platforms/windows/preflight.ps1`; the installer is not uploaded
unless both Win32 and x64 `rime.dll` builds pass real Chinese/English candidate
sessions and the package passes silent Traditional Chinese installation,
Simplified Chinese upgrade, both 32/64-bit TSF registration, deploy, service
startup and uninstall lifecycle on the Windows runner. The gate uses an
isolated temporary `%AppData%`, checks every runtime file referenced by OpenCC,
then reruns the same input sessions against the installed shared data and the
dictionaries generated on Windows. The installer carries the canonical
`data/dicts` source graph needed for a clean-machine Chinese build; macOS-built
dictionary binaries are not treated as Windows evidence. Setup or deployment
failures must propagate as a nonzero installer result. It also installs the
candidate a second time to exercise the upgrade path, proving obsolete package
data is removed while the isolated user dictionary directory survives upgrade
and uninstall.
An unrun or failing Windows preflight is a UAT `NO-GO`; manual testing starts
only from an uploaded candidate that passed this gate.

Tag builds retain the verified Windows installer as a private workflow artifact.
The unsigned candidate is deliberately not attached to the public release;
publication remains blocked until a Windows signing owner and verification gate
exist.

## Acceptance status

- Local/macOS: lock, overlay, owner/subtraction and source-structure checks.
- Local/macOS shared runtime: real librime sessions for Chinese profiles, Smart
  English IPA/glosses, prediction, correction, reverse lookup and learning.
- Windows CI: Visual Studio x64/Win32 runtime plus ARM/ARM64/ARM64X TSF
  compilation; Win32 and installed x64 `rime.dll` black-box input sessions;
  silent Traditional install and Simplified upgrade, package,
  registry, TSF, deploy, service-start and uninstall lifecycle.
- Still required before calling a Windows release accepted: install/uninstall
  on a clean Windows 10 and Windows 11 VM, coexistence with upstream Weasel,
  typing in Win32 and modern applications, candidate UI, native ARM64 runtime,
  user-data isolation, injected-failure upgrade rollback, and code-signing
  verification.

A passing macOS check or headless Windows compile is component evidence only;
it is not Windows product UAT.
