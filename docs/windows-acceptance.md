# Windows acceptance

Windows release acceptance is open. The target packages are **x64 and ARM64**
(64-bit operating systems); x86 application compatibility remains required.
Do not publish a Windows GitHub Release before the exact candidate passes the
required desktop and lifecycle journeys. Shared product behavior remains owned
by the root schemas, Settings document/renderer and Rime modules.

## Current evidence

The latest installed engineering candidate is source `bcd8919`, build 107.
Actions run: <https://github.com/Ares-X/Linnet/actions/runs/34709910769>.
The ARM64 installer SHA-256 is
`c275d621e68d9a11ae99b3db565e4f462db130a3bd181878564125ada5c12bec`.
Local evidence: `build/windows-uat-20260913-bcd8919/RESULTS.md`.

| Boundary | Evidence for that candidate | Remaining work |
| --- | --- | --- |
| Shared core and packaging | Both architectures built; Windows CI runtime and x64 installer lifecycle passed | Repeat affected gates after the next source freeze |
| Windows 11 ARM desktop | Upgrade and cancellation, 84 physical typing cases in ARM64/x86/x64 applications, English glosses, reverse lookup, retained learning and theme passed | Full Settings, candidate interaction/design, font coverage and measured performance |
| Lifecycle | Same-language upgrade retained selection and open application connections without logout/reboot in this run | Clean install/uninstall/reinstall, login/reboot and upstream Weasel coexistence on the final candidate |
| Native x64 desktop / Windows 10 | NOT_EXERCISED; CI is not desktop acceptance | Identify an available dedicated target before claiming these rows |
| Signing / publication | Engineering package is unsigned; no Windows Release | Formal signing and exact accepted-byte publication need a separate authorized release step |

The dedicated Tiny Windows 11 VM is authorized. Protect the daily Mac desktop,
input method and the dirty main checkout. Do not reset the guest or discard
learning data to make a test pass. Carry old failures forward as failures of
their own exact candidates, not as the status of replacement bytes.

## Active milestone: Settings projection and persistence

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

The existing uncommitted Windows Settings/frontend files are drafts, not part of
`bcd8919`. In particular, candidate expansion has draft consumers only. Do not
describe them as shipped or accepted until integrated and exercised.

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
