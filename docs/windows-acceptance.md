# Windows acceptance

Windows release acceptance is open. The target packages are **x64 and ARM64**
(64-bit operating systems); x86 application compatibility remains required.
Do not publish a Windows GitHub Release before the exact candidate passes the
required desktop and lifecycle journeys. Shared product behavior remains owned
by the root schemas, Settings document/renderer and Rime modules.

## Current evidence

### 2026-09-14 Debug bridging-header compilation

CI34767219183 on41111f2 passed its Mac/shared job, then compiled all Swift
objects but failed the debug `emit-module` job before linking or packaging.
The driver reused `shared_runtime-bridging.pch` from Clang cache variant
`7D6D0O1IW674` in a job expecting variant `3P3YV7OHZI451`; the emitted commands
also show CRT arguments on object compilation but not module emission. This is
within one fresh build, not stale installed input-method state.

Milestone: build the same optimized DLL with matching full CodeView/PDB symbols
without sharing that bridging PCH across incompatible compiler job contexts.
The existing build script remains the sole owner. Use the locked Swift driver's
`-disable-bridging-pch` option so each frontend imports the original header;
retain the header/API, full debug info, optimization and normal Clang validation.
Retire only automatic bridging-PCH reuse. No cache deletion, retries, validation
bypass, new dependency or duplicated CRT defaults. Compiler owner1->1; shared
bridging-PCH path1->0; new runtime layers/fallbacks/default producers0.
Allowed files: build-shared-runtime.ps1 and this evidence. Focused checks:
locked driver option/behavior, printed job plan, Windows PowerShell parsing and
the next native build. This build correction does not replace installed UAT.
Reference: [locked Swift driver's PCH job selection](https://github.com/swiftlang/swift-driver/blob/swift-6.3.3-RELEASE/Sources/SwiftDriver/Driver/Driver.swift#L1069-L1085).
The host driver printed object/module jobs importing the original header with
no PCH generation; this is job-plan evidence, not a Windows SDK compilation.
Windows PowerShell 5 parsing and diff checks passed. Native linking, matching
PDB identity and installation remain NOT_EXERCISED for this revision.

### 2026-09-13 Shared-runtime matching symbols

Milestone: native shared-runtime crash dumps must have same-build function/line
symbols alongside the existing frontend and librime PDBs. The exact6b11af2
symbols artifact contains 13 PDBs but no LinnetSharedRuntime PDB. Its build owner,
`build-shared-runtime.ps1`, invokes Swift with `-O` and no debug emission/linker
option. Retire that symbol-less invocation. Use supported Swift CodeView debug
emission and the existing MSVC linker's PDB output, with Release optimization
retained. The existing recursive PDB artifact upload already owns retention;
the installer's DLL-only runtime selection continues to exclude PDBs.
No debugger/SDK installation in Tiny, new symbol service, uploader, dependency
or production API. Compiler/packager/uploader owners 1 -> 1 each; added
layers/fallbacks/default producers 0. Allowed files: shared-runtime build script
and this evidence. Focused checks: Windows PowerShell parsing, upstream option
support, then actual next-build DLL/PDB identity and native runtime checks.
Previous native binary behavior is not acceptance of the newly built bytes.
Windows PowerShell 5 parsed both changed scripts successfully; diff check passed.
Actual generated PDB and DLL matching remain NOT_EXERCISED until native build.
References: [Swift Windows debugging options](https://github.com/compnerd/swift-win32-application#debugging)
and [locked driver linker support](https://github.com/swiftlang/swift-driver/blob/swift-6.3.3-RELEASE/Sources/SwiftDriver/Jobs/WindowsToolchain%2BLinkerSupport.swift).

### 2026-09-13 Resource-less ARM64X forwarding modules

CI34763560267 on6b11af2 built both installers. Its corrected icon extraction
passed both installers, Server/Deployer/Setup and x86/x64/ARM/ARM64 DLLs, then
failed on `weaselARM64X.dll` with count0/error1812 (no resource section). No
shared-runtime or lifecycle probe ran. Unlike the previous failed run, both
engineering installers and matching symbols were retained for diagnosis.

Milestone: check branding on its actual resource owners, not upstream's
resource-less forwarding stubs. Locked `arm64x_wrapper/build.bat` links both
ARM64X DLL/IME files with `/noentry`, dummy objects and export-forwarder libraries,
without a resource file. TSF RegisterProfiles obtains its icon path from the
real loaded module; only RegisterServer redirects the COM server path to the
wrapper. Retire the two wrong icon-target entries, not the wrappers, native
registration or any artwork comparison. Keep the installer, frontend EXE and
resource-bearing x86/x64/ARM/ARM64 DLL/IME checks. Existing package/runtime tests
remain responsible for forwarding modules. No new icon copy, resource loader,
fallback, production path or dependency; owner/layer counts unchanged.
Allowed files: preflight.ps1 and this evidence. Focused acceptance: inspect the
exact retained package's PE resources and execute the icon check on the real
resource-bearing payload; then the next native gate also includes ba5bf84's
non-solid installer. Installed branding and physical input remain separate UAT.

The retained ARM64 installer is 506,571,783 bytes, SHA256
`af997762103d7686b1a22bbf1b6f6a906359ee4b76c102d64d65a0affd50ae7f`.
Read-only native extraction in Tiny passed all 11 packaged product-icon targets
(installer, three EXEs, four DLLs, three packaged IMEs), plus Chinese/tray
resource102 in Server and all four native TSF DLLs. Both icon sizes match the
shared Linnet artwork. The actual installed old Server, Deployer and ARM64 TIP
still match Weasel artwork; installed Setup/uninstaller also differ from Linnet.
This is old installed payload, not evidence of a shell-cache-only issue. No
installation or icon-cache reset was performed; installed branding remains open.

The same package's app-local shared runtime loaded in Tiny and passed the real
channel C ABI cross-process round trip: a child changes the selection, the
resident process observes it, then both processes verify the original restored
selection. DLL SHA256 is
`c34f1767176c95678c50985a88124d4095b05555a24c88e14d2eab0996036d3b`.
This is component evidence, not Settings UI, installed feed or lifecycle PASS.

### 2026-09-13 Installer peak disk footprint

Milestone: install the same complete offline product without retaining a second
uncompressed installer-sized temporary file. Tiny's fresh read-only observation
at 22:52 +08:00 reports 1,661,767,680 free C: bytes, a 574,058,151-byte old Core
and 118,727,174-byte old build cache; no Registry Data/Runtime or rollback folders
exist yet. The preceding native ARM64 packaging log reports 563,788,160 total
uncompressed bytes. The staged factory expands to 677,662,701 bytes. Existing
package/build rollback uses same-volume rename, and Registry views hard-link
immutable packs, so neither should be counted as an additional full copy.

The proven extra disk owner is NSIS `SetCompressor /SOLID lzma`: its upstream
`Source/exehead/fileform.c` whole-compression path creates `dbd_hFile` in TEMP,
decompresses into it, then copies file bytes to their installation destinations.
New Core + that temporary data + first factory expansion is approximately
1.80 GB before regenerated Rime caches or filesystem overhead, already above
current free space even when the installer EXE stays on the host share. This is
a source-and-size projection, not a measured new-candidate installation peak.

Use the existing NSIS non-solid LZMA path, which writes decompressed file chunks
directly to each destination. Retire only `/SOLID`; preserve complete factory
packs, icons, metadata, install commands, learning data and rollback. No new
dependency, compression engine, temporary-directory override, disk guard or
cleanup procedure. Compression/installer/Registry owners 1 -> 1 each; added
layers/fallbacks/defaults 0. Allowed files: the NSIS patch, its lock digest and
this evidence document. Focused checks: pristine patch applicability and lock
verification; native packaging/runtime/lifecycle once after source freeze, then
actual guest peak-free-space observation. Existing CI34763560267 on6b11af2 must
finish unchanged; do not cancel it or treat it as validation of this later edit.
Reference: [NSIS compression option](https://nsis.sourceforge.io/Reference/SetCompressor)
and [upstream decompression paths](https://github.com/NSIS-Dev/nsis/blob/v311/Source/exehead/fileform.c).

The four current staged pack manifests independently sum to 677,662,701 payload
bytes (483,743,711 container bytes). Complete patch applicability against the
pristine locked Weasel, `scripts/upstream-sync verify` and diff checks passed.
No guest installation, cleanup or runtime change was performed. Actual package
size, peak free space and installed workflows remain unverified for this edit.

### 2026-09-13 Native frontend build dependencies

CI34757845236 compiled/linked the shared Swift DLL and built both librime
architectures, then failed in the x64 Weasel solution. Configurator.cpp now
consumes learning_sync.h -> settings_model.h -> rime/config.h, but the private
header/compiler definitions were supplied only to LinnetSettingsDialog.cpp.
RimeWithWeasel's existing enabled glog calls also have no linked implementation;
the four missing LogMessage symbols are not exported by rime.dll. The existing
locked glog static archive is retained by upstream's lib_x64/lib_Win32 stash.

Milestone: give the native consumers their actual declared build dependencies.
Promote Deployer's existing Rime include/definitions to its compile group (with
consistent PCH definitions), and link the existing per-architecture glog archive
and its Windows dbghelp dependency into Server and Deployer. Remove the redundant
Settings-only definitions/path. No new dependency/download/version or disabled
logging; the shared runtime and Rime behavior are unchanged. Native build-owner
count1->1, runtime operation owners unchanged, new fallback/default producers0.
Allowed files: the two projected vcxproj sections, patch lock and this record.
Focused evidence: original link errors, upstream stash/library path and glog's
declared dbghelp dependency, project XML/patch applicability; next native build
must verify linking. Logging output and installed input still require runtime
observation; successful linking alone does not prove their behavior.
The two projected project files parsed as XML and the complete patch applies
to pristine locked Weasel. The shared-source changes passed the existing
download-source and settings-update-checker selectors (1s/8s respectively), and
the lock/projection verifier plus diff check passed. Native compilation,
cross-process preferences, logging and installed-product journeys remain pending.

### 2026-09-13 Shared Stable and Preview channel selection

Milestone: Windows Settings must select the same Stable/Preview channel for Core
and language-data updates as macOS. The proven omission is the channel enum
being nested in the macOS update checker, while the Windows language-operation
caller always supplies the Stable Catalog and its Core caller has no preference.
Move that existing enum unchanged into LinnetSettingsDownloadSource and migrate
its Mac consumers/tests. Preserve the shipped Mac defaults key and Catalog URLs.
The Windows Swift boundary uses one product-scoped UserDefaults suite shared by
Settings and the server; synchronize at that cross-process preference boundary.
Native Settings saves the selection immediately, like macOS. Each language
operation captures its selected Catalog at start. The server selects its native
OS/channel feed before each manual check, following locked Weasel's existing
check_update path and WinSparkle0.9.4's locked appcast setting/read implementation.

Retire the Mac-private channel owner and Windows's hardcoded Stable data caller;
do not introduce an updater process, downloader, parser or new IPC operation.
Channel policy owners1->1, update engines1->1, C ABI boundary1->1; Windows gains
one necessary shared preference store rather than two executable-local stores.
The existing unshipped Win32 frontend still uses Stable without loading Swift.
Allowed files: shared download-source/checker/view and their existing tests,
Windows data-update ABI, native dialog/resources, update-config header,
WeaselServerApp projection patch/lock, and the owning Windows docs.
Focused checks: download-source and settings-update-checker selectors, exact
patch applicability/digest, then the next native build. Actual two-process
preference refresh, channel UI layout, per-native-OS feed selection and input
continuity require Windows UAT. This does not publish feeds or cure the existing
404/strictly-lower-updater baseline gap. Do not mark online updates accepted.

### 2026-09-13 Native read-access mask type

CI `34757008371` reached all shared Swift compilation jobs after UUID
disambiguation. Its only reported source error is `pack_file.swift:33`:
`GENERIC_READ` imports as UInt32 while `READ_CONTROL` imports as Int32, so OR
cannot be applied before the outer DWORD conversion. Milestone: retain the
exact native file-read rights with a well-typed mask. `LinnetWindowsDataFile`
remains the HANDLE/access owner for pack and Registry readers; convert
READ_CONTROL to DWORD before combining it with GENERIC_READ. Remove the invalid
mixed-type expression, not any rights/ACL check. Allowed files: that native
file boundary and this record. Owners 1 -> 1, layers/fallbacks unchanged,
new defaults/identity inference 0 -> 0. Focused check: exact 0x80020000 mask,
then one native build including the pending repair entry point. Linking,
packaging, installed input and repair UI are still unverified.

### 2026-09-13 Language-update repair entry point

Milestone: Windows Settings must expose macOS's explicit Repair Language Update
operation for conflicting same-version pack metadata. The proven omission is
the native UI/start ABI always using the shared operation's default
`allowCompleteRepair: false`; the existing shared Registry already owns repair
selection, separate replacement storage, activation, rollback and learning-data
preservation. Add an explicit Repair button and pass that choice through the
existing start ABI. Normal update and Full remain non-repair operations, and
repair keeps the current edition. Retire the native omission, not any validation
or shared mutation path. Owners 1 -> 1, ABI layers 1 -> 1, fallback/default
producers unchanged. Allowed files: native dialog/resources, shared-runtime
header and Windows update Swift boundary, this record and the Windows README.
Existing Registry repair coverage proves rejection without consent, separate
replacement/rollback retention and unchanged learning data; native build and
actual UI repair/cancel/input UAT must still validate this caller. No Core
updater/feed change, new parser, downloader or transaction state is introduced.

### 2026-09-13 Foundation UUID disambiguation

CI `34756136006` passed the Mac/shared-input job and reached Windows Swift
compilation beyond the removed CoreFoundation import. The next error is the
Registry transaction field: Windows `rpcdce.h` defines `UUID` as `GUID`, which
collides with `Foundation.UUID` through the native imports/bridging header.

Milestone: build the same shared transaction, temporary-file and synchronization
identities on Windows without changing their serialized representation. The
existing Foundation UUID remains the owner. Qualify its references throughout
the affected Windows compilation inputs: Registry declaration/storage/transactions,
sync controller, exclusive download sink, and Windows file/factory/view code.
Retire unqualified UUID lookup, not the native Windows headers or shared models.
No UUID alias, conversion layer, new producer or format; owners 1 -> 1, adapters
unchanged, fallbacks 0 -> 0, duplicate identity/default producers 0 -> 0.
Allowed files: those eight source files, the native compiler invocation and this
record. The compiler is also instructed with its upstream-supported
`-continue-building-after-errors` option to report errors from the remaining
compilation jobs in the same run. The existing nonzero-exit check still stops
packaging; no error is suppressed or treated as success. Focused checks:
`tests/verify_swift_units.sh --only data-registry,rime-sync-controller,download-transport`,
followed by the native Windows build/runtime probe. Exact installed-product
input, updates and lifecycle UAT remain required and are not yet exercised.
All three selected host tests passed (the original v0.1.10 process compatibility
row remains NOT_EXERCISED without its isolated probe). An isolated imported C
`typedef GUID UUID` reproduced the same ambiguous lookup; the qualified
Foundation type compiled and preserved exact UUID JSON encoding/decoding.

### 2026-09-13 Public Foundation run-loop boundary

CI `34755444537` proves the compiler loader fix: Swift 6.3.3 starts, emits
the bridging-header PCH, and reaches Linnet source compilation. Compilation
then fails at `shared_runtime.swift:1`: `no such module 'CoreFoundation'`.
The locked Windows SDK does not expose that imported C module. Its public
Foundation `RunLoop.run(mode:before:)` calls the same one-pass run-loop operation.

Milestone: native learning-sync polling must service the existing shared
controller without blocking input or importing an unavailable module. The owner
is `platforms/windows/shared_runtime.swift:linnet_sync_poll`; its consumers are
`LearningSync::Poll` and the existing `SharedRuntimeProbe`. Remove the direct
CoreFoundation import/call and use `RunLoop.current.run(mode: .default,
before: Date())`. The controller, C ABI, native timer and runtime dependency
packager are unchanged. Owners 1 -> 1, adapters 1 -> 1, fallbacks 0 -> 0,
duplicated schedules/defaults 0 -> 0. Allowed files: this boundary and this
acceptance record. Focused acceptance is the native shared-DLL probe (incremental
completion, hourly deadline and cancellation) in the next Windows CI. Installed
learning-sync/input UAT remains required; no new candidate is installed yet.
The host-only public RunLoop probe serviced both a due Timer and the main queue
with zero-wait polling (maximum observed call 0.027 ms). This is API/behavior
evidence on macOS, not Windows DLL or installed-product acceptance.

### 2026-09-13 Swift compiler loader correction

Milestone: the locked Windows compiler must start and reach the actual Linnet
source build. CI `34754322721` passed the Mac product/shared-input stages and
Windows preparation, then exited `-1073741515` (`0xC0000135`, missing DLL) before
any compiler output. Offline inspection of the exact SHA-256-verified Swift
installer, its SHA-512-verified BLD/RTL payloads and native MSI file inventory
proved `swiftc.exe -> SwiftDriverExecution.dll -> llbuildSwift.dll`. The last DLL
is absent from BLD/RTL and belongs to the upstream CLI component, which our
workflow explicitly disabled. This is not a Linnet source compiler diagnostic.

The existing workflow installer remains the sole owner: remove
`OptionsInstallCLI=0` and retain upstream's default CLI component. Keep debugger,
IDE, Python, Android and other-architecture SDK/runtime exclusions. No new
dependency version, extracted-DLL installation path, loader wrapper or fallback;
build-tool installer owners 1 -> 1, package runtime-closure owners 1 -> 1.
Allowed files: the Windows workflow and this evidence/Windows build docs.
Focused checks: native installer component/dependency inspection, workflow YAML
parse, then one native build. User payload remains the actual application DLL
closure, not the compiler's DLL closure. Installed-product UAT is still required.

Latest `origin/main` is `92dd4429803f2a70919791ae2da5b63d01ebd4e9`, with no
commits missing from this branch. Both configured Windows Core appcast URLs
currently return HTTP 404 because those files are only on this branch, not on
main. Their local empty XML documents do not prove a working update endpoint.
Real ordered online-update acceptance additionally needs a lower installed build
with the updater enabled and an authorized reachable candidate feed; the old
Tiny build 107 has its updater disabled. Do not claim that journey passed or
publish a Windows Release to make a test endpoint available.

### 2026-09-13 Windows brand icon correction

Follow-up milestone: let the existing packaged-icon check accept successfully
extracted large and small icons without weakening artwork equality. CI
`34760616037` built both installers from `870fb28`, then stopped at the first
installer's icon check, before shared-runtime or lifecycle execution. The
earliest reproduced defect is in `LinnetIconProbe.Pixels`: on Tiny Windows 11,
`ExtractIconExW` returns 1 for an ICO but 2 for a PE with both output handles;
the check incorrectly required exactly 1. The Windows shell owns extraction;
the existing probe and its installer/EXE/TIP consumers keep the same pixel
comparison. Retire only the incorrect exact-count restriction, retaining failed
return/handle checks and useful native diagnostics. Retain successfully built
engineering candidates even if a later preflight fails, so exact bytes remain
available for diagnosis; this does not publish a Release or mark UAT passed.
Allowed files: `preflight.ps1`, `windows-build.yml` and this evidence document.
Artwork/extraction/validation owners, pass-through layers, fallbacks and defaults
all remain unchanged. Focused check: use the existing guest C# compiler to embed
the same ICO in a disposable PE, compare both shell sizes against the ICO, and
reject different artwork and a missing path; then one affected native CI.
No daily-Mac load is required; exact installed candidate visuals remain required.

Focused guest verification passed: the unchanged Linnet ICO embedded by the
already installed C# compiler in a disposable x64 PE produced exactly the same
large/small shell pixels; different upstream artwork remained different, and a
missing file was rejected with native error 2. Windows PowerShell 5 parsed the
corrected preflight. Workflow YAML and diff checks passed. This verifies the
extraction boundary only, not the unavailable `870fb28` installer: the failed
run retained symbols and shared inputs but skipped both installer artifacts.

Milestone: Explorer, installation/uninstallation, Settings, the registered input
method and its Chinese-mode tray/language-bar icon must show Linnet's existing
bird, not Weasel's mark. The proven cause is preparation retaining upstream
`resource/weasel.ico`, `resource/zh.ico` and `WeaselSetup.ico`, plus NSIS's default
uninstaller icon and the new Settings dialog not assigning an icon.
The authoritative artwork remains the shared `Linnet.xcassets/AppIcon.appiconset`;
the Mac input-staging executable exports its existing resolutions with ImageIO.
Windows preparation replaces only the projected resource bytes, retaining
upstream resource IDs/loaders. Generic A, hourglass and full/half-width state
symbols remain distinct; they are not product logos. Smart English keeps its
existing packaged A icon and native schema-icon path.

Allowed files: Windows input staging, preparation, Settings dialog, NSIS patch
and lock, native preflight and owning documentation. Brand-art owners 2 -> 1;
resource loaders 1 -> 1; new wrappers/fallbacks/services 0 -> 0. Retire the
upstream product artwork and NSIS default uninstaller artwork, not mode state.
Focused checks: run the input-staging executable, inspect exported ICO frames,
verify patch applicability and native packaged icon extraction. Actual Settings,
input-switcher, tray and Explorer visuals require exact-candidate Windows UAT;
neither a Mac icon preview nor resource extraction is desktop acceptance.

Executed checks: the input-staging executable compiled and ran successfully;
all five ICO frames (16/32/64/128/256) decode to the exact shared PNG pixels.
ImageIO orders ICO frames largest-first; the first probe incorrectly assumed
insertion order, then comparison by actual dimensions passed without changing
production code. Tiny Windows 11 ARM64 accepted all five sizes through native
`LoadImageW`; its shell extracted the large/small icons and confirmed they differ
from upstream artwork. Windows PowerShell 5 parsed preparation, preflight and
the shared-runtime build script successfully. Icon SHA-256:
`21c347ae03b818513f2a78c03187d63e0a6a5ead2aab3cb829a642b560ef9ee1`.
Lock/diff/applicability checks passed. Installed candidate and desktop visuals
remain unchanged and NOT_EXERCISED. No Windows Release was published.

The preceding native CI run `34753222263` passed the Mac build and Windows
preparation but stopped at the first Swift invocation without a compiler
diagnostic. The current build wrapper discards the native exit code in a generic
exception. Before another run, retain that code and the compiler's standard
verbose output in the existing build owner; do not guess a dependency change
or install additional components. This is a diagnostic correction, not evidence
that the Windows compiler failure has been fixed.

### 2026-09-13 consolidated local validation

Passed on the development Mac with isolated data (not Windows UAT):

- `rime-sync-controller`, `data-registry`, `data-channel`, `download-transport`,
  `download-source`, `pack`, `settings-update-checker`, `settings-data-coordinator`.
  The new shared online-operation cases cover current-pack reuse, native
  activation rejection/success, cancellation and transaction cleanup.
- Current locked Rime runtime rebuilt; Windows projection/input, native Settings
  persistence, failed-write preservation, Unicode snapshots/learning integrity,
  native sync results and missing-user-schema failure probes passed against it.
- `scripts/stage-windows-build-inputs` produced all four shared factory packs and
  the Windows activation profile, then passed its projection/runtime checks.
- `make release` compiled the local unsigned macOS app and embedded Settings
  successfully, including the migrated shared online-operation caller. It was
  not installed or loaded into the daily input method.
- Lock verification, patch applicability, Xcode project parsing and diff whitespace
  checks passed. SwiftLint exits successfully but reports existing style/size
  warnings, including the enlarged conditional Registry files; it is not a
  warning-free result. No lint threshold or baseline was changed.

Two fixture corrections were needed: per-session URLProtocol configuration
instead of global registration, and matching catalog Core/minimum pack versions.
The real callers now pass the concrete transport they configure; there is no
test-only network API. An initial Settings probe linked the old Rime binary;
it passed after rebuilding the current patch. One coordinator compile overlapped
SDK-header publication and failed PCH timestamp validation; its serial rerun
passed. Neither was hidden by changing the behavior assertions.

Final installer review also found the newly installed factory subdirectory was
absent from upstream's flat-file uninstall list. Native NSIS now removes the
four factory containers, activation document and empty parent directories;
learned/user data remains untouched. Its actual removal is still a native
preflight/lifecycle item. Windows compiler, packaged DLL closure, installed
updates and desktop workflows remain NOT_EXERCISED for this source batch.

### Consolidated completion batch (supersedes incremental UAT)

The maintainer has now authorized stable WinSparkle and a Windows Swift build
toolchain with packaged runtime. This resolves the dependency-strategy blocker;
it does not authorize Windows Release publication. Keep the existing correction
batch and finish the portable update/sync integration before building or UAT.

Update milestone: restore an in-app upgrade flow through maintained WinSparkle,
retain the root language-pack/activation and synchronization policy owners,
and project them into the Windows host. WinSparkle owns installer downloading,
signature verification and update UI; the existing NSIS installer still owns
installation. Remove the blanket updater removal in preparation, packaging and
preflight, not the release-publication restriction. Use the native OS
architecture for installer selection because the shared x64 server also runs
on ARM64 Windows. One installer owner remains one; update-library integration
0 -> 1; duplicate updater/download implementations 0 -> 0. Allowed files are
the Windows projection/build/preflight/UI and current Weasel patch/lock, the
existing shared update/sync owners for actual Windows platform adaptations,
and this record. Later validation: existing Windows source/projection gate,
focused shared pack/sync selectors, then one native build/preflight and exact
candidate update/data/typing UAT. No development toolchain goes into Tiny.

The unbuilt source now restores WinSparkle 0.9.4 from its official binary
archive (SHA-256 `6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976`).
Preparation uses its current headers/import libraries and packages its DLL and
licenses. Tray and Settings requests share the existing server: `/update`
forwards the native tray command before the normal restart path, so a check
does not restart input or apply a draft. Installer execution remains native
WinSparkle/NSIS; no competing download or shutdown coordinator was added.
One native-platform helper replaces the diagnostic architecture guess and
serves update selection. Microsoft documents that GetNativeSystemInfo may
report x64 emulation on ARM; IsWow64Process2 supplies the actual native machine.
The pre-1709 compatibility branch is restricted to the existing Intel/AMD
Windows target; ARM64 requires Windows 11. Native-machine owners 2 guesses -> 1;
new parser/service 0 -> 0. These source paths are not compiled or accepted yet.

A dedicated Ed25519 key has been generated and retained locally outside Git
with private-file mode 600. Only its public key is in the Windows update
contract. The two appcasts contain no release entries. No private key, feed or
Windows artifact has been uploaded or published. Package/UAT evidence must
still cover exact signed bytes, per-OS selection, cancellation and failed
downloads without disturbing ongoing input.

The maintainer has requested one complete correction/alignment batch before
more desktop testing. Do not install the in-flight 385cb89 intermediate build,
dispatch another native build after each edit, or treat old-candidate results
as final acceptance. Its CI has now failed; retain it as diagnostic evidence
only. No build or UAT is currently running.

The remaining implementation work is distinct from missing acceptance:

Automatic-sync implementation milestone: an explicitly selected Windows sync
folder participates in the same hourly incremental learning schedule as macOS.
The existing Swift controller owns timing, retry, cancellation and terminal
results; Rime owns the incremental operation; the native installation config
owns the selected Windows folder. The missing Windows caller, not the Rime
algorithm, is the cause. Compile the actual controller into one x64 Swift DLL
used by the installed server on both OS architectures. A C ABI translates only
callbacks, and the existing IPC server serializes its run-loop pump with Rime
using a non-blocking lock. No second scheduler, parser, daemon or x86 Swift
runtime. The non-shipped Win32 server remains a build compatibility target;
x86 input clients continue to use the installed x64 server. Policy owners
1 -> 1; language/OS interoperability boundaries 0 -> 1; duplicate schedules
0 -> 0. Allowed files additionally include the shared sync controller, Windows
Swift/native boundary and its build/packaging inputs. Later focused checks:
existing sync-controller tests, native callback/run-loop and maintenance
regressions, then installed folder selection, automatic merge and continuous
typing. These are not run before the complete source batch closes.

Pack portability milestone: the existing manifest path validator accepts names
such as `opencc/CON.txt`, `opencc/file:stream`, and trailing-dot aliases, which
have different file/device meanings on Windows. Reject these in the canonical
downloaded-pack boundary before extraction on every build platform, so the one
pack format stays portable. Keep local Settings/user-dictionary names outside
this check. The existing validator and pack test own this correction; path
validators 1 -> 1, new parsers/layers/quotas 0 -> 0. This alone does not complete
Windows extraction or activation. The focused later selector is
`tests/verify_swift_units.sh --only pack`; it remains unrun in this phase.

The shared pack extractor now has an unbuilt Windows filesystem/cryptography
implementation. PackContract remains the single manifest/payload parser.
DataChannel and DataRegistry consume its throwing SHA-256 implementation
(CryptoKit on macOS, system CNG on Windows); the two separate digest entry
points are removed, 3 -> 1. Existing tool/fixture callers propagate errors and
the pack suite adds known-answer/chunk-boundary coverage. Windows extraction
holds non-reparse directory handles, checks the actual owner/write ACL, creates
files exclusively, flushes/closes them and marks completed files read-only.
These checks apply to downloaded-pack staging, not local Settings names.

The Swift DLL build now includes PackContract and that native file boundary.
It reuses zlibstatic.lib already supplied by the authorized Swift 6.3.3 SDK,
with matching pinned zlib 1.3.1 headers and license; there is no new zlib build,
installer or DLL. The exact SDK layout, MSVC linkage, CNG and filesystem behavior
remain NOT_EXERCISED. Registry storage, factory bootstrap and native runtime
setup and the online activation/UI workflow are now authored as described below.
No pack-specific public ABI was added solely for a test.
This source phase ran only read-only inspection and `git diff --check`, not
the pack/data-channel/data-registry tests or a Windows build.

Registry/factory/native setup milestone (CODE only, not compiled):

- The shared Registry remains the only ActiveState, manifest, compatibility and
  language-transaction owner. Windows publishes `Runtime/Active/activation.json`
  atomically and uses its existing `active_view` to select `Runtime/Views/UUID`.
  No second pointer format, state parser or recovery daemon was added. macOS
  keeps its atomic directory exchange; common projection selection is shared.
- One native HANDLE owner now handles private directories, identities, ACLs,
  exclusive reads/writes and readonly hard-link retirement (2 extraction handle
  classes -> 1 filesystem owner). User/SYSTEM/Administrators are the same
  trusted principals for ownership and write authority; Windows token default
  ownership is not assumed to be the individual user SID. New private
  directories have an explicit user-owned ACL; existing ACLs are not rewritten.
- Factory preparation uses `stage_language_pack_sources`, `build_data_pack`
  and the existing pack/profile CLI, not a Windows JSON/pack producer. The
  installer ships those four containers instead of a second flat dictionary
  tree. First activation alone uses the factory; Core upgrades do not downgrade
  already active packs. The existing flat user/learning directory is retained.
- `linnet_data_setup` supplies the Registry snapshot to actual Rime server and
  Configurator consumers. Setup/module registration is rerun after maintenance
  so resource resolvers cannot retain Program Files or a previous generation.
  Core-derived policy files reuse the build-time Windows schema appender.
  Shared immutable packs are never rewritten for platform policy changes.
- Native startup and resume use the existing deployment mutex and Rime's
  incremental deploy operation before accepting input; this also completes a
  restored generation after a crash. The mutex creator is consolidated (2 -> 1),
  deployment implementation remains 1 -> 1, new deployment receipts/caches 0.
  Startup and Settings resume deployment cost is **not measured** and remains
  a focused native acceptance item, not a claim of acceptable latency.
- Existing x64 runtime probes now enter through that production ABI, assert
  the flat learning path and activated view, and use only candidate/OS DLL
  search paths. Factory/installed input and Settings probes have not run.
- Installer minimum is corrected to Win10 1903+, ARM64 still Win11; silent
  rejection returns 1633 before any upgrade mutation. The old guessed-AMD64
  fallback is removed. This matches the UTF-8 manifest boundary and covers the
  readonly unlink API floor; older Windows support is not claimed.
- Allowed owners/callers are the Registry/Pack/Channel files, native setup,
  installer, shared Swift ABI, factory producer/build inputs, existing focused
  probes and these docs. Decoder/activation formats remain 1 -> 1; the old
  Program Files runtime-data path is de-authorized in shipped x64 hosts.

Later acceptance after the whole source batch: `pack,data-channel,data-registry`,
Windows projection, target compiler/linker and native bootstrap/read-only-pack
cleanup/atomic activation recovery; then exact installed upgrade/input/settings
and timings. Online download and native activation source is now integrated;
it still needs these focused/native checks. Directory-delta transport
remains macOS-only; Windows selects complete containers in the shared channel.

Online update/source freeze (CODE only until validation results below):

- Moved the actual catalog/download/staging/prepare loop out of the macOS
  Settings model into `LinnetLanguageDataUpdate`; both native consumers call it.
  The old inline loop is removed, 1 -> 1 operation, no new HTTP stack, pack
  selector, transaction format or mirror parser. Mac mutation lease/activation
  coordinator are unchanged; its Xcode source list includes the shared file.
- Windows adapts the same URLSession transport with FoundationNetworking,
  native IP parsing and the existing HANDLE/exclusive-file sink. Foundation,
  curl 8.9.1, Brotli 1.1.0 and libxml2 2.11.5 notices follow the tagged Swift
  toolchain dependency inputs. Actual linked DLL closure remains a native-build
  check; no separately built networking runtime is introduced.
- Native Settings polls the retained Swift async operation on its UI timer;
  no background callback retains an HWND. The Updates tab provides current/full
  data, source selection and cancellation. Close cancels and waits for cleanup;
  other mutation controls are disabled without applying or discarding drafts.
- Configurator's existing UpdateWorkspace owns publication, deploy, rollback
  and redeploy. Its commit hook opens a real selected-schema session and checks
  required modules, without typing or imposing a second schema inventory.
  Only after health succeeds does the shared Registry commit. Errors retain
  the original cause and surface once through the update UI.
- Manual upstream synchronization now shares automatic synchronization's two
  registry writers for attempt/result metadata (1 -> 1 storage owner). The
  unrecorded manual path is removed; no second scheduler or IPC path is added.
- Focused download-transport coverage now exercises the actual shared operation:
  current-pack reuse, activation success/rejection, unchanged Active before
  native publication, cancellation and owned-transaction cleanup. Tests are
  authored at this point, not claimed PASS.

| Area | Current source boundary | Completion work |
| --- | --- | --- |
| Normal input, English definitions/reverse lookup, themes and candidate actions | Shared Rime/data/renderers plus locked Weasel projection | Consolidated consumer review; retain existing source fixes and later verify the final bytes |
| Native snapshots and configuration persistence | Rime UserDbHelper / ConfigData / CustomSettings; native installer and Settings consumers | Snapshot correction is in 385cb89. The unbuilt source batch corrects configuration truncation, final stream failure and discarded native save results at their existing owners |
| Application updates | Stable WinSparkle 0.9.4 restored in the unbuilt batch | Build/verify signatures and per-OS selection; no published Windows channel or Release |
| Independent language-data updates | Shared PackContract/Registry, online operation and native Settings/activation are authored | Focused shared checks, native build and exact update/cancel/rollback/typing acceptance |
| Automatic learning synchronization | Unbuilt shared Swift controller DLL and native Rime callbacks, opt-in switch, native folder and attempt/result registry metadata | The existing native probe now covers actual DLL loading, incremental completion and cancellation, but it and installed typing/maintenance journeys remain unrun |
| Final desktop/lifecycle acceptance | Exact x64/ARM64 artifacts and dedicated targets | Resume only after the implementation batch closes; missing targets or reboot/uninstall authority remain explicit |

Persistence milestone: a failed configuration write must preserve the previous
file and report failure through native configuration consumers. ConfigData
remains the sole YAML serializer/file owner, with CustomSettings and the Windows
Configurator consuming its result. Replace direct destination truncation and
ignored save results with complete sibling-file publication and explicit native
failure propagation. Keep stream serialization separate from file publication;
no retry, quota, new parser, dependency, daemon or transaction framework.
Allowed files: existing core/Weasel patches and lock digests, native runtime
smoke coverage, Windows Settings consumer if its direct write behavior needs
correction, and this record. Owners 1 -> 1 at each existing boundary; new layers,
fallbacks and duplicate defaults 0 -> 0. Later focused acceptance must cover
failed output preserving old configuration bytes, successful overwrite and
native save-result propagation, then the affected composite after source freeze.
No daily Mac loading or new VM test is authorized by this source-review phase.
Atomic configuration publication also resolves the existing destination and
preserves its file permissions, so replacing direct stream writes does not
replace a valid configuration symlink or widen an existing private file.
The existing isolated host Settings probe now includes that compatibility row;
it remains unrun until the consolidated batch is ready.

The already-running 385cb89 CI terminated at 13:56 +08: production compilation
completed, but the native smoke probe failed C1189 because windows.h defines
ERROR and the newly included Rime DB header includes glog. Add glog's existing
GLOG_NO_ABBREVIATED_SEVERITIES configuration to both native probe targets in
runtime-smoke.vcxproj; keep the warnings/error policy and existing dependencies.
No installer was uploaded, no native preflight ran, and no retry was dispatched.
This compiler correction belongs to the same completion batch, not a new UAT
candidate. The source edits and failure-preservation coverage are not yet built
or run; only patch application/format inspection has been performed.

The consolidated Settings consumer review also found a concrete mutation bug:
OnData called Apply before identifying the requested action or opening a folder
picker. Exporting diagnostics, cancelling a backup destination, or cancelling
restore therefore silently saved every draft setting and redeployed input.
Remove that unconditional call. Apply and the existing save-on-close prompt
remain the only draft-publication entrypoints; backup snapshots applied files,
diagnostics reads the existing persisted Settings model, and confirmed restore
explicitly states that a successful restore discards unapplied drafts. Sync and
dictionary actions retain their existing native owners. Scope is the existing
Settings dialog and README; implicit draft-publication paths 1 -> 0, added
layers/guards/dependencies 0 -> 0. Final desktop coverage must edit a draft,
export diagnostics and cancel each file picker, then verify unchanged native
configuration and a retained draft before explicit Apply. Do not execute that
journey before the consolidated implementation phase closes.

### Active correction batch after dacaf10 desktop UAT

- Native `/sync` at 13:01 encountered ENOSPC on the 20 GB guest disk. The
  failure dialog is truthful and the same server resumed without restart, but
  `UserDbHelper::UniformBackup` opens the destination snapshot directly: a
  failed Chinese write truncated the previous 1,461-byte backup to zero.
  Preserve that failure and the live-database diagnostic copies; do not restore
  old learning or clear the database to obtain a pass. Windows servicing was
  active and its download/extraction tree is 1.67 GB; Linnet installed data is
  574 MB and user data 119 MB, without comparable new growth. Exact disk-growth
  attribution is not established by those inventory observations alone.
- Correct the existing native uniform-snapshot writer to finish and close a
  sibling temporary file before replacing the destination. Reuse standard
  filesystem rename, retain the native error result and remove only its failed
  temporary output. Retire direct truncation of an existing learning backup.
  Native backup, Settings backup and manual sync share this one owner; the
  separate live-sync cancellation/commit boundary remains unchanged. No new
  dependency, disk quota/preflight gate, retry, parser or backup coordinator.
  Allowed additional files: existing core patch/digest and Windows runtime
  smoke probe. Atomic publication owners 0 -> 1 for native snapshots; writer
  paths 1 -> 1; layers/fallbacks 0 -> 0. Validate failed output preserving old
  bytes plus successful overwrite/Unicode metadata, then affected shared and
  Windows native gates. Positive guest data UAT waits for adequate disk space.
- Validation consumer correction: the first host composite still loaded the
  older staged `lib/` runtime, while the fresh build was in `librime/dist/`.
  Its nominal pass is not new-code evidence. Reuse the existing Makefile
  `verify-rime-binaries` identity check before the Windows host runtime probe;
  do not duplicate fingerprint logic. The failure fixture must open LevelDB
  before constraining output, otherwise LevelDB bookkeeping fails before the
  snapshot writer is reached. Scope additionally includes `verify.sh`. This
  reuses one identity owner and removes an unchecked test-consumer path.
- Corrected host evidence: pinned runtime rebuilt and staged with matching
  hashes, Windows projection/runtime/Settings/snapshot composite passed, and
  existing live-sync regression passed with 5,904 samples. The original
  full-pinyin editor also passed six physical cases after the failed guest sync,
  on the same server process. Isolated host reads of the preserved guest DB
  copies retain all 5 English/34 Chinese keys and every deletion mark; no copy
  was restored to the guest. These results do not accept the failed dacaf10
  backup or prove the new source on Windows. Latest fetched main `92dd442` has
  no changes absent from this branch. The complete correction batch now needs
  one exact native build/preflight and installed-candidate regression.
- Exact dacaf10 Actions build/preflight passed and was upgraded on Tiny Windows
  11 ARM64 without logout/reboot. Installed payload hashes match, original
  registration/configuration and applications remain, and four original
  ARM64/x86/x64 editors passed 24 physical cases. New Settings fits the work
  area and readable labels/draft cancellation work. A fresh ARM64 application
  displays English IPA/glosses and its candidate Add-to-custom-words action
  opens the correct editable draft and cancels without committing input.
- English status icon still fails: preparation copies the locked upstream icon,
  but the NSIS shared-data file list omits .ico files. Include that required
  asset at the existing installer owner and add it to the existing installed
  file inventory check. Retire the incomplete package inventory, not the
  upstream schema-icon loader; no second icon, theme branch or fallback.
- During installation the schema selector's shortcut explanation is blank.
  Its Rime CustomSettings consumer reads staging/default.yaml, then the shared
  source when staging has been moved aside for upgrade. The shared source's
  Windows __patch has not been compiled at that point. Compile the two native
  configuration documents through Rime's existing deploy_config_file API before
  the installation UI reads them; keep the later workspace deployment owner.
  Do not hardcode a second shortcut/default list. Actual Ctrl+grave already
  works in a fresh installed application; this is the installation UI reader.
- The same native schema-selection consumer allocates const char*[] but uses
  scalar delete on both exits. Match those two deallocations to new[]; do not
  rewrite schema selection or claim an unobserved heap crash.
- Allowed production files: existing Weasel patch and lock digest, existing
  Windows preflight inventory, this record. Authoritative owners remain one
  per resource/configuration/allocation; additional layers, fallback branches,
  dependencies and duplicated defaults remain zero. Focused verification:
  fresh locked patch application/reversal and lock checks, guest PowerShell5
  parsing, then one native build/preflight after the correction batch is frozen
  and exact-candidate GUI/resource validation. No daily Mac loading is required.
  Current dacaf10 remains an engineering candidate, not release-accepted.

The latest installed engineering candidate is source `dacaf10`, build 107.
Actions run: <https://github.com/Ares-X/Linnet/actions/runs/34735427779>.
The ARM64 installer SHA-256 is
`99eb9ed33c1cd1b79aaa5c90c6e7269f80119fc98b8c596360e48702f737538d`.
Local evidence: `build/windows-uat-20260913-dacaf10/RESULTS.md`.

| Boundary | Evidence for that candidate | Remaining work |
| --- | --- | --- |
| Shared core and packaging | Both architectures built; Windows CI runtime and x64 installer lifecycle passed. Desktop UAT proved the English icon is missing from the package | Correct the installer resource inventory and repeat affected native gates after source freeze |
| Windows 11 ARM desktop | Original four ARM64/x86/x64 editors retained connections and passed 24 physical cases after upgrade. Five original applications retain their UI text. New native WordPad English gloss/selection/commit and candidate-to-Settings draft/cancel pass. Settings bounds, readable names and draft cancellation pass | English status icon FAIL; full Settings, Unicode backup/sync, remaining candidate/design and measured performance still open. One supplemental old WordPad gained a paragraph separator during the installer-focus key sequence; no product cause established |
| Lifecycle | Settings-busy Cancel retained old files/service/data; closing Settings and Retry completed upgrade with exit 0, no reboot question and no logout/reboot | Clean install/uninstall/reinstall, login/reboot and upstream Weasel coexistence on the final candidate |
| Native x64 desktop / Windows 10 | NOT_EXERCISED; CI is not desktop acceptance | Identify an available dedicated target before claiming these rows |
| Signing / publication | Engineering package is unsigned; no Windows Release | Formal signing and exact accepted-byte publication need a separate authorized release step |

The dedicated Tiny Windows 11 VM is authorized. Protect the daily Mac desktop,
input method and the dirty main checkout. Do not reset the guest or discard
learning data to make a test pass. Carry old failures forward as failures of
their own exact candidates, not as the status of replacement bytes.

## Active milestone: candidate-to-Settings installation lookup

- Installed `2bff3aa` in ARM64 WordPad 6528: the candidate menu expands,
  collapses and forgets learning correctly. Forget changed only the intentional
  test entry `algorithm` from `c=1` to `c=-1`; Chinese snapshots and every other
  English value are byte-identical. Original editor text is unchanged.
- `Add to custom words` does not open Settings. Its new panel consumer reads
  `HKLM\Software\Linnet` in the native ARM64 registry view, while the installer
  owns the 32-bit view. Native RegGetValue returns ERROR_FILE_NOT_FOUND there;
  the existing upstream language-bar lookup resolves the exact installed root.
  ARM64 and x86 probes both confirm that existing lookup. Directly launching
  the same installed deployer with `/add-word algorithm` opens the expected
  editable draft, proving the Settings endpoint itself works. It was closed
  normally without saving; no personal-word file was created.
- Deliverable/owner: share the existing upstream `GetWeaselRegName` utility
  between language-bar entrypoints and the candidate panel. Move its definition
  to the existing utility header and remove the private language-bar copy and
  the panel's raw default-view lookup. No second registration, architecture
  fallback, key copy, dependency or generic launcher. Lookup owners 2 -> 1;
  duplicated definitions 1 -> 1 (moved); new pass-through layers 0; fallback
  paths 0. Existing quoting/draft/save and all input/learning owners unchanged.
- Scope: three existing Weasel consumers/header through the locked patch and
  digest, plus this record. Focused checks: native ARM64/x86 registry results,
  fresh patch apply/reverse and lock checks, then the existing native build and
  exact-candidate context-menu opening/cancel plus normal-input continuity.
  No daily Mac loading, guest logout or dependency change is needed. Current
  in-flight `8973d03` does not contain this newly proven correction.
- Result: `platforms/windows/verify.sh` finished exit 0 after the complete
  correction. Fresh patch application/reversal, lock/publication, projections,
  runtime and native Settings/Unicode snapshot checks passed on the host.
  Native ARM64/x86 registry probes and direct draft/cancel evidence are under
  `build/windows-uat-20260913-8973d03`. Run `34734396702` passed its shared/mac
  job, then was deliberately cancelled during the Windows build because it
  lacks this product fix. No installer from that run was downloaded or installed;
  the next frozen source still requires Windows compilation and desktop UAT.

## Active milestone: Unicode backup and native snapshot integrity

- Deliver Unicode sync-folder backup, lossless learning snapshots and truthful
  sync completion. Rime owns snapshot serialization/merge and worker results;
  Settings and native Dictionary Manager consume those owners.
- Source `2bff3aa` crashed during native Output Snapshot with a Chinese sync
  path. An isolated call against those exact installed DLL bytes succeeds for
  ASCII but throws with code page 1252 for Chinese. The same probe with a Windows
  UTF-8 process manifest passes both paths. Matching-symbol dumps and the
  preserved pre-repair databases are under
  `build/windows-uat-20260913-2bff3aa/unicode-crash`. After the first crash,
  six physical mixed-input cases passed in the original Notepad without a
  server restart.
- A test folder-selection mistake selected Downloads before the intended
  Unicode folder. Sync consumed this old candidate's incorrectly formatted
  backup there and added swapped text/code entries. Original valid learning was
  retained. Both pre-incident snapshots and post-incident databases are preserved.
  Selective repair passed first on a database copy, then in the native Windows
  Dictionary Manager: exactly 17 erroneous zero-frequency entries received Rime
  deletion marks. The complete actual Chinese and English sync snapshots match
  the verified repair; all other records, weights and ticks are unchanged.
- Retire the Settings-only text-table header check; reject that known wrong
  format at `UserDbHelper::UniformRestore`, covering native merge and sync too.
  Keep native text-table import available. Enable UTF-8 in the deployer process
  manifest (Windows 10 1903+ / Windows 11); do not change Rime's path API encoding
  contract. Replace Dictionary Manager's 260-byte conversion buffer with the
  existing Settings-sized buffer and a guaranteed terminator; a valid Chinese
  Windows path can exceed 260 UTF-8 bytes. Use the standard native path
  conversion instead of a second fixed wide buffer. The installed-DLL probe
  confirmed the old buffer has no terminator for a valid 100-Chinese-character
  directory; the full-sized getter preserves the exact path. Catch the observed
  backup filesystem exception inside its Windows callback. Read the existing
  worker completion notification instead of treating
  successful scheduling as successful synchronization.
- Allowed files: existing core and Weasel patches/lock; Windows frontend
  manifest/dialog, existing runtime smoke source/project and this evidence file.
  No new dependency, parser, scheduler, sync engine or retry. Authority counts:
  format check 1 -> 1 (moved to its native owner); sync result 1 -> 1 (worker
  replaces scheduling inference); path owner 1 -> 1; pass-through/fallback
  paths 0 -> 0; duplicated defaults 0 -> 0. The manifest owns the OS encoding
  boundary; callback containment is distinct from the outer maintenance scope.
- Focused validation: existing `runtime_smoke --settings-probe`, extended with
  Unicode native snapshots, deleted entries/weights/ticks, rejected text-table
  restore/sync and the preserved text-import route. Then Windows compile and
  exact-candidate native/Settings backup/restore/failure UI and uninterrupted
  typing. No loaded Mac or daily-desktop mutation is needed.
- Host component results: locked core rebuild, existing Windows projection/
  runtime/Settings composite and `tests/verify_rime_runtime.sh --live-sync-probe`
  passed. The latter retained 5,907 live samples and rejected/recovered failure
  cases. Final source also uses the same native `path.c_str()` stream overload
  as Rime's TSV reader, with focused compilation checked. New Windows native
  compilation, manifest loading and exact-candidate GUI regression are still
  NOT_EXERCISED; no Windows Release was published.
- Actual post-repair typing: the original Notepad passed all six physical mixed
  input cases with the same server process. The Unicode sync folder is retained
  for the new candidate's backup regression; attempted navigation back to the
  old folder was cancelled without a settings change. Temporary per-app crash
  collection was removed and VM idle pause restored. The daily Mac and dirty
  main checkout were not changed. A fresh fetch found no unmerged main commits.

## Active milestone: native snapshot probe link correction

Run `34732355632` / `ad122b9` built the native frontend projects, then failed
linking the x64 runtime probe: LNK2019 for `rime::Config::SetString` called by
`SnapshotProbe`. It did not reach installer compression, runtime preflight or
installer uploads. Matching symbols were retained; the guest still runs
`2bff3aa`. This is a native test-link failure, not a passed candidate.

- Cause/owner: the new snapshot fixture called a C++ method absent from the
  Windows DLL export surface. Use the already-exported Rime C configuration API,
  as the native Settings model already does, on the same borrowed Config object.
  Retire that direct SetString call; do not export another private method or
  weaken/remove the probe. API owner 1 -> 1; fixture paths 1 -> 1; new wrappers,
  dependencies, fallbacks and product policy changes 0.
- Scope: existing `runtime_smoke.cc` and this record. Run the affected Windows
  host composite once, then rebuild the corrected full batch natively. The new
  artifact still requires native Unicode backup/restore and normal-input UAT;
  no daily Mac or guest lifecycle mutation is needed for the fixture correction.
- `scripts/stage-windows-build-inputs` completed with exit 0 after the complete
  label/icon/probe edit batch. Lock/publication/projection, shared runtime,
  native Settings persistence, Unicode snapshots/learning/sync and rejected
  user-customization deployment checks all passed. Evidence:
  `build/windows-uat-20260913-ad122b9/link-fix-host-verify.log`.
  This macOS-hosted composite is not Windows DLL linking or product UAT.

## Active milestone: Smart English native status icon

- Installed `2bff3aa` in ARM64 WordPad 6528 physically showed English completion,
  changing IPA/gloss details, exact Space commits, automatic pinyin lookup,
  prefixed Chinese lookup and Shift round trips. The Smart English schema bubble
  nevertheless displayed the default Chinese icon. Evidence is under
  `build/windows-uat-20260913-2bff3aa/english-review-*`.
- Cause/owner: shared Smart English correctly remains `ascii_mode=false` to
  provide candidates; the Windows projection provides no `schema/icon`, so
  Weasel's native schema-icon loader uses IDI_ZH. Supply the existing locked
  upstream `resource/en.ico` through `schema/icon`. The same native style feeds
  the tray, TSF language bar and status bubble. Do not falsify ascii_mode or add
  schema-specific branches to three separate UI consumers.
- Scope: existing Windows input-defaults projection, preparation script,
  Windows README and this evidence. Icon owner 1 -> 1; input-mode owner 1 -> 1;
  new runtime helpers/branches/dependencies 0; duplicated policy/defaults 0.
  Retire the missing English icon projection and stale README statement that
  Shift selects plain ASCII. User customization retains normal precedence.
- Validate the projected schema path and reuse of the locked icon, parse the
  PowerShell preparation script and use native Windows LoadImageW on that icon.
  The later exact candidate must prove packaging and all native UI consumers;
  these bytes are not part of the failed `ad122b9` CI. No Mac loading,
  iCloud or logout/reboot is required for this display change.
- Projection comparison passed: only English `schema/icon` changed; all other
  policies, labels, defaults and UI choice ordering were retained. Native
  Windows `LoadImageW` accepted the locked upstream icon at 16/32/64 pixels and
  PowerShell 5 parsed the preparation script with no errors. Packaged icon and
  tray/language-bar/status-bubble behavior remain NOT_EXERCISED on new bytes.
- The old candidate's physical tests committed exact `algorithm ` and
  `algorithms ` with IPA/gloss details following Right selection. Smart English
  `suanfa` and Chinese `|suanfa` produced English lookup candidates; tap Shift
  switched both ways, while held Shift preserved `你好WAF你好`. Original editor
  text was retained. Down means next page in the horizontal selector, not next
  candidate; semicolon is not the current default lookup prefix. Neither test
  expectation error is a product defect.
- Fresh native sync snapshots after these intentional commits retain all 17
  prior repair deletion marks. Chinese records differ only in the exercised
  `你好` dynamic weight; English adds `algorithm` and advances the native tick.
  New learning is preserved in `learning-before-candidate`, alongside the six
  original app identities and installed server PID 6296. VM idle pause is back
  on; no logout, reboot or server restart was used.

## Active milestone: shared user-facing Settings names

- Deliver readable Chinese/English choices for Chinese profiles, learning,
  reverse prefixes, Tab behavior, layouts, expansion and themes. The generated
  Windows catalog currently uses schema IDs and raw enum strings, while macOS
  already has user-facing names and Chinese translations.
- Move those existing names to the shared Settings enums; both native views and
  the Windows build-time catalog consume them. Windows reads the existing root
  string catalog using Foundation JSON, not a second translation table. Retire
  the private macOS name switches and the Windows raw-ID display paths. Stored
  IDs, ordering, defaults, Rime projections and native dialog behavior stay intact.
- Scope: Settings document/contract, the two existing macOS Settings views,
  Windows catalog/input-defaults generator and this evidence document. Naming
  owners 2 -> 1; translation catalogs 1 -> 1; pass-through layers 0 -> 0;
  fallback/compatibility branches 0 -> 0; duplicated policy/defaults 0 -> 0.
- Focused validation: regenerate the catalog and compare its complete contents
  excluding labels to the frozen baseline; run existing projection-renderer and
  appearance-preview selectors and compile the affected Settings views. No new
  wording-policing test, dependency or parser. Desktop label/layout acceptance
  requires the later exact Windows package; no live Mac/iCloud change is needed.
  This batch is separate from the in-flight `ad122b9` candidate; do not restart
  that CI or attribute these labels to its bytes.
- Results: all 43 changed choice labels are readable. The complete generated
  catalog is identical to the baseline after removing labels, including every
  saved ID, ordering, default, policy projection and design value. Existing
  projection-renderer and appearance-preview tests passed; the latter rendered
  all seven paired themes at both tested widths and appearances. The macOS
  Settings target compiled with a separate test bundle identity; all 30 shared
  names retain the exact compiled Chinese translations. No Settings application
  was opened; its build-created test registration was removed. Windows desktop
  label/fit acceptance remains NOT_EXERCISED until the later candidate.

## Earlier milestone: Settings projection and persistence

- Deliverable: native Windows settings must apply the root product choices,
  combine independent options, restore defaults and report a failed write;
  later desktop acceptance must prove that each displayed control has an effect.
- Owners/callers: root `LinnetSettingsDocument` and
  `LinnetSettingsProjectionRenderer` -> build-time Windows catalog -> native
  `Settings::Save` -> Rime configuration deployment. The Windows dialog and
  runtime smoke probe consume that same native model. Native Weasel still owns
  TSF, candidate interaction and deployment/service lifecycle.
- Proven defect: the draft delegates projection persistence to
  `rime::CustomSettings::Save`, which ignores `Config::SaveToFile`'s failure and
  returns success. A failed projection write can therefore leave the saved UI
  choices ahead of the actual input configuration.
- The isolated failure probe reproduced that false success and additionally
  showed that the draft's `@before 0` writes were interpreted as configuration
  paths, dropping fuzzy rules. Construct those literal keys with Rime's native
  map/list API; retain the shared renderer's order and spelling rules.
- Build preflight also exposed Ruby 2.6-incompatible `filter_map` calls and a
  Homebrew Boost path absent from the maintained build environment. Use
  `map.compact` and the existing locked `build/dependencies/boost` headers;
  neither fix adds a dependency or a fallback dependency source.
- Retire that persistence delegation in the draft. Use the already-linked Rime
  Config map and serializer directly; no new YAML parser, dependency, transaction
  framework or retry. Keep user `.custom.yaml` precedence and contents intact.
- Allowed scope: Windows settings catalog/model and its existing smoke probe,
  build-time projection scripts, native dialog integration and locked Weasel
  projection when its consumers are ready. Do not rebuild a full candidate
  between individual edits. Mainline website-only changes may merge independently.
- Counts for the persistence correction: product policy owner 1 -> 1; native
  persistence owner 1 -> 1; serialization delegation hops 2 -> 1; fallback paths
  0 -> 0; duplicated defaults 0 -> 0.
- Focused validation: build the shared catalog and run the existing
  `runtime_smoke --settings-probe` against isolated data, including combined
  options, resetting and an actual unwritable projection destination. Windows
  compile and Settings UI Apply/cancel/reopen/typing on an exact installed
  candidate remain required; host tests do not establish those results.

The following milestones record the earlier integration work. Settings and
candidate expansion are now compiled and installed in `2bff3aa`, but their full
desktop acceptance remains open; installed is not synonymous with accepted.

### 2026-09-13 checkpoint

- Mainline `92dd442` merged as `2dbad3a`. Its two new commits concern the website
  only; no input-core merge was omitted. The dirty daily/main checkout was not
  changed.
- Host `TEST`: the shared catalog now builds with system Ruby and locked Boost.
  The focused settings probe and `scripts/stage-windows-build-inputs` passed:
  actual rejected projection writes, persisted choices, combined fuzzy rules,
  metadata visibility, page size, theme/mode, font, layout, reset and the existing
  shared runtime/customization-failure checks. These are macOS librime component
  results for the current dirty source, not Windows UI acceptance.
- Guest read-only font probe: none of its 82 installed font families covers
  `U+2EBF4` or `U+2B9FA`, the two radical-lookup characters from the screenshot.
  The upstream Unicode translator's `U4e2d~0` candidate is `U+4E2D0`, not a
  glyph variant of `U+4E2D`. Do not replace the renderer based on that screenshot.
  No fonts or other dependencies were installed.
- Evidence: `build/windows-settings-20260913/RESULTS.md`. Installed candidate and
  VM lifecycle remain unchanged. No full Windows build or release was started.
- Next integration boundary: reconcile the native installer's existing
  `weasel.custom.yaml` theme choices with the new dialog, then connect and test
  the actual frontend consumers. Today those explicit user overrides precede
  the draft UI projection in authority; silently displaying an ineffective
  theme choice is not acceptable. Reuse the native deployment owner and remove
  the draft's nested maintenance handling when integrating Apply/backup/sync.

## Active milestone: native Settings integration

- User behavior: opening Settings shows the existing native theme; applying an
  edited option changes its real `.custom.yaml` keys, without rewriting unrelated
  options. Reset explicitly restores the selected page, including its font.
- Earliest cause: the unshipped draft writes a lower-priority
  `linnet_windows_user_*.custom.yaml` layer while Weasel's installation/theme
  dialog already writes the higher-priority native customization. Changing a
  theme in the new UI cannot win that precedence chain.
- Retire the extra generated-user layer and its schema includes. Shared default
  policies remain first; native `.custom.yaml` remains the final runtime owner.
  The dialog edits only the keys for changed choices using Rime's map/serializer,
  and retains the small saved-choice document for combined UI choices. Existing
  native themes are read from their real customization, with unknown themes
  displayed as custom and preserved until explicitly edited/reset.
- Apply, dictionary backup/restore and synchronization must enter the existing
  Configurator maintenance/exclusion boundary once. Remove the dialog's separate
  Maintenance class; retain the upstream server, mutex and Rime operations.
- Allowed files: existing Windows catalog/model/probe/projection scripts,
  `frontend/*`, existing locked Weasel deployer/frontends and lock digest, and
  Windows acceptance documentation. No shared input-policy rewrite or new
  dependency. Candidate expansion will use the existing native panel/layout and
  Rime candidate APIs; the older scratch projection must not replace the current
  installer fixes.
- Counts: runtime user customization layers 2 -> 1; default/policy owner 1 -> 1;
  dialog maintenance owners 1 -> 0 (existing Configurator retained); new services,
  IPC protocols and fallback deployment paths 0. A single native UI projection
  remains necessary because AppKit/SwiftUI is not a Windows frontend.
- Tests: extend the existing settings probe with an installed-style theme,
  unrelated-customization preservation and reset; then the affected shared
  projection composite. Full dual-architecture build waits for coherent frontend
  integration. Exact-candidate Settings Apply/cancel/reopen/input and lifecycle
  acceptance remain required in the authorized Windows desktop.

## Active milestone: candidate frontend integration

- Deliver expandable candidate browsing, a highlighted-candidate detail area,
  native disclosure and candidate context actions. Root Settings still supplies
  choices/defaults; Rime owns ordering, selection, learning and printable paging.
  Windows' existing Weasel panel/layout projects the visible rows; TSF and the
  existing request handler connect them to Rime.
- The older unshipped draft is incomplete: it changes unversioned Boost archive
  fields, uses the wrong deployer filename, omits a visible disclosure control,
  and computes keyboard rows independently from the actual visual layout.
  It must not replace the current installer or native Settings fixes.
- Keep existing candidate/style archives byte-compatible. Use the native
  response parser's optional named fields for new presentation data. Existing
  pre-upgrade clients must retain compact input; a new client advertises its
  candidate capability in the already-supported session metadata. This is a
  real loaded-client compatibility boundary, not an alternate input engine.
- Allowed files: locked Weasel candidate/request/response/UI/TSF owners, Windows
  frontend projection and its focused runtime/IPC tests, patch digest and this
  evidence document. Retire the draft's archive insertions and duplicated
  geometry interpretation. Do not add a parser, service or transport protocol.
- Counts: input/learning owner 1 -> 1; visual geometry owner 1 -> 1; IPC transport
  1 -> 1; product default owner 1 -> 1. The added capability distinguishes old
  loaded frontends until their host application restarts; the same-process
  upgrade regression must pass before this boundary can be retired.
- Acceptance: focused projection and archive compatibility tests, then the
  coherent dual-architecture build. Actual compact/expanded typing, row/digit
  selection, long words/glosses, mouse actions, layout/theme/DPI and unchanged
  pre-upgrade app connections remain required on the exact Windows candidate.

### Integration checkpoint (not product acceptance)

Native settings-model and projection tests passed for actual existing theme
readback, selective custom-key updates, unrelated-customization preservation,
write rejection and reset. The extra user projection layer and the dialog's
separate maintenance owner were removed. Native Configurator now releases its
maintenance scope on sync failures as well as success.

Candidate integration is now present in the locked patch: native geometry,
disclosure, selected English detail, TSF row/digit interactions and context
actions. A real Boost archive test confirms byte-compatible candidate/style
serialization and cross-decoding with the pristine upstream client. The accepted
installer patch section is unchanged. These results are `CODE`/host `TEST`, not
Windows compilation, `RUNTIME_LOADED`, `PRODUCT` or lifecycle acceptance.

The source-freeze review below resolves the legacy IMM scope and adds compact
vertical detail placement and text bounds. Build both target installers next
and exercise the exact new bytes. Detailed
commands/results and current scratch locations are recorded in
`build/windows-settings-20260913/RESULTS.md`.

### Source-freeze milestone

- The package installs TSF only (`old_ime_support = false` at the installer
  entrypoint); x86 applications use its Win32 TSF, not the optional legacy IMM
  registration. Do not invent an IMM mouse bridge without a shipped consumer.
  Remove the unneeded new IMM geometry/key path and retain upstream IMM behavior.
- Reuse root `LinnetCandidatePresentation` at build time for the candidate window
  limit, detail line limit and font-dependent detail widths. Retire the draft's
  100-item window/default formulas and unbounded footer, adding vertical sidecar
  placement and native DirectWrite clipping/trimming at the actual panel edge.
- Owners remain the shared Swift design -> generated constants/choice patches
  -> native StandardLayout/DirectWrite; TSF forwards its measured row targets to
  Rime. Defaults/design producers 1 -> 1; new IMM adapter paths 1 -> 0; transports
  1 -> 1. No new runtime dependency or registration path.
- Scope: Windows catalog/staging, existing candidate patch consumers and tests,
  lock digest and Windows docs. Run the affected host composite after this batch,
  then freeze and run the existing dual-architecture Windows build. UI performance
  and actual typing remain exact-candidate desktop acceptance, not host proof.

### Source-freeze host result

`scripts/stage-windows-build-inputs` passed for this integrated source, including
fresh locked-patch apply/reverse, shared input sessions, deployed Settings
composition/reset and expected customization failure. The Settings probe also
confirmed that changing/resetting font size changes the deployed detail geometry.
The actual Boost wide-text archive probe passed again with all new optional
presentation fields populated; pristine upstream clients cross-decode the same
archive bytes. The accepted installer patch section is unchanged.

Source is ready for the Windows compiler/package boundary, not accepted for
release. Detailed host logs are in `build/windows-settings-20260913`. The installed
candidate is still `bcd8919`; new native controls, rendering and lifecycle rows
remain `NOT_EXERCISED` until the new Actions bytes are installed and tested.

## Native compiler/lifetime correction

- Deliverable: the integrated candidate layout must compile with Windows' real
  coordinate types and destroy its new owned presentation buffers on replacement.
- Cause/owner: `StandardLayout` combines its `int` dimensions with `CSize::cx/cy`
  (`LONG`) in template-deduced `std::max`. These are distinct C++ types. Convert
  the native dimensions at those four calls; both Windows coordinate types are
  signed 32-bit, so this does not change the dimensions. Microsoft documents
  [CSize inheritance](https://learn.microsoft.com/en-us/cpp/atl-mfc-shared/reference/csize-class)
  and [SIZE fields](https://learn.microsoft.com/en-us/windows/win32/api/windef/ns-windef-size).
- `WeaselPanel::_CreateLayout` deletes through `Layout*`; new `StandardLayout`
  vector/string members need their actual destructor to run. Give that existing
  base a virtual default destructor, also honoring the existing FullScreenLayout
  destructor. This is an ownership correction, not a measured performance claim.
- Scope: those existing native layout owners, locked patch/digest and evidence.
  Geometry owner 1 -> 1; allocation owner 1 -> 1; additional helpers, defaults,
  fallbacks and services 0. Retire the mismatched-type calls/nonvirtual deletion.
- Validate by collecting the current exact Windows CI diagnostics, then one
  corrected native build after the correction batch; do not rerun unrelated
  host input suites for these native-only changes. Layout/typing/DPI and memory
  observations on the corrected installed candidate remain required.

Actions run `34718217649` on source `0979947` now confirms this exact compiler
failure: MSVC C2672 at all four native-coordinate calls; the two other reported
errors are their dependent expressions. The shared-input job passed, but no
Windows installers were produced/uploaded or installed. The correction batch
must pass a new Windows build before any desktop acceptance can begin.

The same correction batch also closes a verified test-integration omission:
`--settings-probe` was compiled into the Windows executable but only invoked by
the host verifier. The existing Windows preflight will invoke that mode with
the actual x64 runtime used by the packaged deployer, in its own temporary user
directory before installation. Reuse `Invoke-RuntimeSmoke` with optional probe
arguments; no new runner, service or deployment owner. The existing native
Settings test stays one owner; Windows execution changes from absent to required.
Scope includes `platforms/windows/preflight.ps1`. Parse with guest PowerShell 5,
then require the corrected CI to execute it; this does not replace desktop Apply.

## Candidate debug evidence retention

The locked upstream already builds frontend PDBs and installs librime PDBs to
`dist_x64/lib` and `dist_Win32/lib`; its own CI retains symbols. Linnet's Windows
workflow omitted that retention, so the ephemeral runner would discard the
matching symbols before desktop crash/hang diagnosis. Reuse the existing pinned
Actions artifact uploader to retain only these generated PDBs for seven days,
bound to the source SHA. Do not add a symbol compiler, archive dependency or
publication path. Build owner 1 -> 1; artifact uploader implementation 1 -> 1;
new services/dependencies 0. Scope: the existing Windows workflow and this
evidence document. Validate YAML and the existing publication boundary, then
confirm the corrected run's actual symbol inventory alongside its installers.

## Portable update scope still open

The current native Data page explicitly offers installer-based upgrades only.
Mainline `SettingsViews` / `SettingsModelLanguageData` also expose in-app Core
updates and independent language-data updates. These are not inherently macOS
features and remain incomplete Windows alignment; a passing typing/Settings
candidate must not close the full goal while they are missing.

The removed Weasel updater is WinSparkle. Reusing its maintained stable library
is the candidate approach for the installer-update boundary, pending permission
to restore that runtime dependency. It must consume Linnet's release identity,
not upstream Weasel's feed, and must not enable public publishing before UAT.
The [upstream publishing guide](https://winsparkle.org/guides/publishing-updates/)
specifies that platform matching follows the DLL architecture, not the native
OS. Linnet's shared x64 server on Windows ARM therefore requires explicit correct
installer targeting; a default x64 feed is not ARM64 update evidence.

Independent language data already has a root owner, `LinnetPackContract` and
`LinnetDataRegistry`; the existing shared packs include source dictionaries as
well as precompiled artifacts. Windows must preserve this contract and its native
deployment boundary, not grow a second format/parser or treat the macOS-built
dictionary binaries as Windows acceptance. No updater dependency, key, feed,
publication path or language-pack implementation has been changed in `849c6fd`.

The consolidated source review identifies a portability boundary, not a
macOS-only product feature: PackContract imports Darwin and CryptoKit, while
DataRegistry storage uses descriptor identity, symlink projections and
`renameatx_np` directory exchange. Changing imports alone cannot preserve the
activation contract on Windows. Reusing this Swift implementation would add a
Windows build toolchain and packaged runtime, plus native filesystem adaptation;
that dependency-strategy change needs approval before implementation. Do not
install a full development environment in the small UAT VM or implement a
parallel Windows pack parser/registry to bypass the decision. No new dependency
has been added in the consolidated source batch.

Automatic learning synchronization is another portable gap, separate from
language-pack downloads. Mainline's LinnetRimeSyncController schedules the
shared `sync_user_data_step` API; Windows currently exposes manual sync.
Weasel's pipe workers serialize Rime calls with `g_api_mutex`, whereas its GUI
message loop runs on another thread. A GUI timer must not call Rime outside
that boundary or block it in a way that deadlocks synchronous UI callbacks.
The current batch has not added a scheduler; this row is not implemented or
accepted and must remain open in the full Windows goal. The full controller
already owns timing, cancellation, last-attempt recording and terminal results,
with host operations supplied as closures. Projecting its numeric constants
into a second C++ scheduler would still duplicate those decisions. Resolve the
pending shared Swift dependency choice before selecting the Windows host
integration; do not introduce an interim scheduler that the reuse path replaces.

That dependency-strategy approval has now been received. Independent
persistence, Settings and compiler corrections are retained as source changes,
not installed evidence. Continue the shared Swift adaptation as part of the
same consolidated batch; no intermediate UAT or release is authorized.

## Native probe build correction

Run `34720228009` on `849c6fd` compiled the native frontend/Settings projects and
both installers, then failed while compiling the x64 runtime probe. The exact
diagnostics are C4244 at glog `logging.h:94,105` and C4996 at `logging.h:503`,
promoted by `/WX` to C2220. The probe's new Settings consumer includes private
Rime headers, but its project classified their installed dependency headers as
first-party `/W4` source. No Linnet source diagnostic or native product link
failure was reported. Neither installer was uploaded or installed because the
preflight was not reached. Same-run symbols were retained successfully.

- Deliverable: compile the existing runtime/Settings/archive probes with strict
  diagnostics on Linnet code and the compiler's normal external-header boundary
  on installed Rime/glog/Boost headers. Keep the existing IPC header exception;
  do not patch glog, disable `/WX` globally or skip a probe.
- Owner: `runtime-smoke.vcxproj`, consumed by both existing x64 and Win32 builds.
  Use MSVC's documented [external include directories](https://learn.microsoft.com/en-us/cpp/build/reference/external-external-headers-diagnostics)
  and standard MSBuild warning properties; remove duplicate command-line warning
  overrides. Compiler/test owners 1 -> 1; probe executions 2 -> 2; new dependencies,
  parsers, services and fallback paths 0.
- The same run spent about 9m35s compressing its installers before discovering
  this probe compile failure. Move those two existing compile invocations in
  `build.ps1` before NSIS packaging, after native binaries are built. Packaging
  and test owners remain one each; no new cache, runner or bypass is introduced.
- Scope: the probe project, existing Windows build script and this evidence.
  Check XML, PowerShell syntax and diff, then one corrected native build. Shared
  input policies and product sources are unchanged; do not repeat unrelated host
  typing matrices. Exact-candidate desktop UAT still waits for the full preflight.

## Active milestone: installed dialog bounds and upgrade finish page

- Deliver a fully reachable native Settings window at the tested desktop scale
  and finish an ordinary upgrade without an unsolicited restart requirement.
- Proven causes: the dialog resource is 650x385 DLU (actual 2139x1611 on the
  2560x1314 guest, Apply/Close below the work area); list columns use unscaled
  fixed pixel widths. The normal upgrade path unconditionally sets the NSIS
  reboot flag, although the new DLLs are installed immediately and only renamed
  old DLL deletion is deferred by the existing setup owner.
- Owners/consumers: `LinnetSettingsDialog.rc` -> native dialog and its list;
  `output/install.nsi` in the locked Weasel patch -> installer finish page.
  Retire the oversized resource coordinates, fixed column widths and ordinary
  upgrade's unconditional reboot flag. Preserve upstream deferred DLL cleanup,
  uninstall behavior and all input/session/selection paths.
- Allowed files: existing dialog resource/implementation, Weasel installer
  patch and its lock digest, this evidence document. No dependency or layout
  framework. Geometry owner 1 -> 1; installer reboot policy owner 1 -> 1;
  unconditional upgrade reboot sites 1 -> 0; new pass-through layers, fallbacks
  and duplicated defaults 0.
- Focused checks: fresh locked patch apply/reverse, `upstream-sync verify`,
  `verify_publication_owner.sh`, native dual-architecture compile and installer
  preflight; then exact-byte Settings bounds/Apply/cancel/reopen and retained-app
  normal upgrade in Tiny Windows 11. No daily Mac loading or guest logout is
  needed for this milestone. Full-goal update/lifecycle gaps remain open.
- Disproved digit-loss hypothesis: physical `nihao]]4` selects the partial `你`
  and keeps `hao` composing; Space then commits the complete `你好`. Starting a
  desktop PowerShell observation mid-composition steals focus and cancels it.
  Use hypervisor screenshots/keys between composition and commit, with text
  reads only after commit. Do not patch Rime/TSF to compensate for this observer.
  Pointer disclosure remains unverified until the actual button receives a
  physical click without an intervening focus-changing command.

## Installer boundary correction before the next desktop candidate

The `a6aa1ea` reboot correction was incomplete: a second `SetRebootFlag true`
at the end of the main installation section still runs for upgrades. That is
not the separate uninstaller flag. Remove this second normal-upgrade site;
retain the uninstaller flag and native old-DLL deletion. No new candidate may
be described as having passed the finish-page correction before actual UAT.

A read-only guest `/help` launch also returned 1 while native Settings PID 1436
was open (`build/windows-uat-20260913-a6aa1ea/deployer-open-settings-check.json`).
The upstream `WeaselDeployer.cpp` process-wide exclusive mutex rejects the
new process before command dispatch, including the installer's `/install` or
`/deploy`. The installer currently discovers that conflict only after stopping
input and replacing package files. The server and settings were not stopped
for this diagnostic.

- Deliverable: ask the user to close Settings/dictionary operations before
  installer mutation; Cancel or silent busy rejection leaves the existing
  package, server, registration and data untouched. Retry is user-driven after
  closing the window normally, allowing its unsaved-change prompt to run.
- Owner: existing deployer exclusive mutex. The NSIS installation section
  observes it at the first mutation boundary, with the standard System plug-in
  and Windows OpenMutex/CloseHandle. Do not invent another lock, terminate
  Settings, weaken its existing exclusion or retry an uncertain install.
- Retire the installer's assumption that deployment can start despite an
  already-open deployer. Retain the deployment command's own exclusion for
  genuinely concurrent launches. This does not claim the user cannot start a
  new Settings process later during installation.
- Scope: locked installer patch/digest, existing Windows installer preflight,
  this acceptance record. No input changes or dependency additions. Mutex/state
  owner 1 -> 1; pass-through layers 0 -> 0; fallback paths 0 -> 0; duplicate
  normal-upgrade reboot sites 1 -> 0 (originally 2, not 1); duplicated defaults 0.
- Focused checks: patch apply/reverse and lock verification, PowerShell 5 syntax,
  existing native preflight with the actual named mutex held and unchanged
  server/TIP/package assertions; then interactive Retry/Cancel while Settings is
  open, followed by ordinary upgrade and finish-page/bounds acceptance. Use
  Tiny Windows 11 only; no logout, reboot or daily Mac loading needed.

## Native learning snapshots, 2026-09-13

- Product failure in installed `2bff3aa`: the Data page's backup contains
  `Rime user dictionary export` text tables, not snapshots. Direct comparison
  with Dictionary Manager's native Output Snapshot and locked Rime source
  proves the table formatter omits deleted entries and serializes only commit
  counts, losing per-entry dynamic weights and ticks. Restore used the paired
  text-table importer, so it could not recover those missing facts.
- Deliverable/owner: existing Settings `Backup` / `Restore` must invoke Rime
  `backup_user_dict` / `restore_user_dict` within the existing Configurator
  maintenance scope. Copy the native snapshot from the directory returned by
  Rime, then keep the current configuration backup/recovery behavior. Rime,
  not the UI's filename inference, identifies the restored dictionary.
- Retire export/import-table calls in these two paths; Dictionary Manager's
  explicit text-table import/export remains available for its intended use.
  No custom format/parser, new dependency, restart or fallback is added.
  Learning-format owner 1 -> 1; Settings backup path 1 -> 1; pass-through layers
  0 -> 0; fallback branches 0 -> 0; duplicated defaults 0 -> 0.
- Allowed files: native Settings dialog, existing resource preparation script
  for the measured Dictionary Manager text clipping, and this acceptance record. Focused
  checks: isolated native snapshot round-trip with live and deleted entries,
  weights and ticks; diff/lock checks and native compilation. Exact-candidate
  Windows UI backup/restore must still prove these values, Unicode destination
  handling, unchanged settings and typing continuity. No daily Mac loading,
  logout or reboot is needed. Engineering table exports already collected are
  retained as defect evidence, not silently converted into accepted snapshots.
- The old engineering export is explicitly rejected by its native Rime text
  table header before configuration writes. An isolated negative test showed
  that upstream snapshot restore otherwise accepts this wrong format, reverses
  text/code and loses counts. This is a format-boundary check for actual files
  already produced, not a second parser or a compatibility importer. Other
  snapshot parsing remains Rime-owned; explicit text-table import stays in
  Dictionary Manager.
- The native Dictionary Manager opens and creates its own snapshot successfully.
  Its English first help paragraph is clipped at 20 DLU; the existing resource
  projection increases its height to 27 DLU, ending before the next label at
  y=55. Retire only the undersized resource value, with native resource/layout
  owners 1 -> 1 and no new layout layer. Exact-candidate visual acceptance
  remains open. Reopening Settings' folder picker after
  Dictionary Manager Output Snapshot worked; a hypothesized COM initialization
  failure was not reproduced and no COM lifecycle change was made.
