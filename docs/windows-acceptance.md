# Windows acceptance

Windows release acceptance is open. The target packages are **x64 and ARM64**
(64-bit operating systems); x86 application compatibility remains required.
Do not publish a Windows GitHub Release before the exact candidate passes the
required desktop and lifecycle journeys. Shared product behavior remains owned
by the root schemas, Settings document/renderer and Rime modules.

## Current evidence

The latest installed engineering candidate is source `2bff3aa`, build 107.
Actions run: <https://github.com/Ares-X/Linnet/actions/runs/34722883865>.
The ARM64 installer SHA-256 is
`2e1dc0c324e8a1da5b59456fcca77acde2d3e5d868211d4b18f121508d913935`.
Local evidence: `build/windows-uat-20260913-2bff3aa/RESULTS.md`.

| Boundary | Evidence for that candidate | Remaining work |
| --- | --- | --- |
| Shared core and packaging | Both architectures built; Windows CI runtime and x64 installer lifecycle passed | Repeat affected gates after the next source freeze |
| Windows 11 ARM desktop | Original four ARM64/x86/x64 editors retained connections and passed 24 physical cases after upgrade; both Edge editors retained text and accepted mixed input; config and learning retained. Additional ARM64 WordPad English gloss, Right-selection, pinyin/reverse lookup and Shift round trips passed | Settings bounds FAIL; English status icon FAIL; full Settings, remaining candidate interactions/design and measured performance still open |
| Lifecycle | Same-language upgrade retained selection and open application connections without logout/reboot in this run | Clean install/uninstall/reinstall, login/reboot and upstream Weasel coexistence on the final candidate |
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
