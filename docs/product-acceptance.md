# Linnet product acceptance

Current policy: except for the isolated cold-build `data-seed` boundary below,
one clean exact-main checkout builds and CMS-signs the candidate once on the
maintainer Mac. A passing final `package/verify_publication_artifacts` run
freezes exactly eight local files. Real installed Settings/InputMethodKit
acceptance consumes those bytes before any remote publication mutation. The
maintainer then uses Git SSH to create one lightweight control tag binding
version, full revision and the eight-file set digest. That tag authorizes the
one ordered Core/data/Catalog/public publication chain; GitHub stores the
accepted bytes but does not rebuild them. Installation acceptance remains
separate evidence and must name the exact revision, build, set digest and file
hashes exercised.

The historical UAT9 summary below is retained only as static evidence from
2026-08-12; its former artifact directory has been removed from versioned
project state. An ignored local `package/release/` directory may still retain
those old bytes, but it is not a source, current candidate or publication
evidence. Those bytes no longer match the current locked Wanxiang LTS asset,
Settings copy or security owners and are not eligible for installation UAT.
Only a clean exact-main local archive generated after the current source, data,
App and package gates pass is eligible. It may be built and signed once only.
Valid real-window/VoiceOver evidence and controlled installed-product evidence
remain required before making the corresponding V/I acceptance claims; they do
not create a second publication authority. A canonical Catalog bound to
deterministic packs, the versioned Core update channel and a published service
remain requirements of the tagged community release.

Retired UAT9 historical artifact identity (not a current candidate):

- complete PKG: `51ca8fed7a90d09480fb03ea90a62c30fa760ff171b7c271fd82b8341c2283e7`
  (458,736,785 bytes; logical payload 885,915,895 bytes);
- Core PKG: `f24da8711aac64f9f7dc0e75073803dd7004beb42cc5fa0089d297656a29810c`
  (2,306,232 bytes);
- uninstall command: `d639e1f21b3daa0f90ee048a1d4fdd01b99751b1f42ff4151ce57179adc94a00`;
- embedded data identity: catalog sequence 4 (Chinese 12, English 8, LTS 2,
  Extended 5). This retired identity is not the current identity, whose only
  owner is `config/linnet-data-releases.json`.

UAT7 was discarded before acceptance because its bundled Installer welcome
copy incorrectly described the source selector as absent. UAT8 was discarded
before acceptance because its custom-mirror copy over-promised public
reachability. UAT9 was their historical successor, but its retirement means it
is no longer a candidate or a current product projection.

`README.md` defines the user-visible product promise; this file records the
evidence required before those promises may be reported as installed-product
acceptance. Exact main, embedded release metadata and the immutable eight-file set digest
own the staged candidate identity; the `linnet-publication/*` SSH control tag
owns publication authorization, and the version tag records the resulting
public version. This document defines evidence levels but does not authorize
either mutation.

Passing source tests, engine smoke tests or package expansion is necessary but
not sufficient for installed-product acceptance. Each V/I claim below requires
current evidence from the same candidate revision and artifact set.

`config/linnet-community-signing.json` is the sole record for the one-time
historical legacy ad-hoc-to-fixed-CMS Core lifecycle acceptance. Its fixed leaf,
bundle ID, macOS major and identity-classifier `迁移契约指纹` are the complete
invalidation key: if any value differs from the current candidate, the legacy
transition must be repeated in an isolated legacy-seeded account or VM; while
all four match, it must not be repeated for every candidate. Host continuity and
TIS non-mutation are not inferred from that historical fingerprint; the current
package lifecycle matrix owns them. That history closes only the legacy identity
edge and is not current-candidate UI or complete installed UAT. Every
exact candidate still requires `两轮同 leaf Core` on its immutable bytes: the
previous accepted fixed-CMS build (the previous public build after the first
publication) to candidate, then a byte-identical reinstall of that same candidate.
Both rounds must prove no logout or Keychain password prompt, the
same login session, retained enabled/selected intent and UserData, and working
input menu, Settings and real input.

## Evidence levels

| Level | Evidence | What it may prove |
| --- | --- | --- |
| C | source, type, unit and structural tests | an owner contract and regression guard exist |
| E | real librime deployment and candidate probes | schemas, candidates, learning and latency work in the engine |
| P | final App/PKG/archive expansion and executable probes | shipped bytes, signing, layout and process startup work |
| V | screenshots, accessibility tree and direct Settings interaction | visible hierarchy, copy, states, keyboard access and responsiveness work |
| I | clean installed macOS workflow | InputMethodKit registration, focus, application interoperability and lifecycle work |
| R | publication using final assets | names, checksums, update URLs, canonical Catalog/container bindings and release instructions agree |

`C`, `E` or `P` evidence must never be reported as installed-product evidence.
`V` may use an expanded product without installing it. `I` begins only after
all non-install blockers are closed.

## Release policy

- One candidate revision, one Core App and one complete public PKG are used for
  all final evidence. Rebuilding invalidates downstream evidence.
- Every failure is traced to the earliest owner. A downstream workaround does
  not close the finding.
- A P0 or P1 product defect blocks the release only when it is reproduced on
  the exact current candidate and remains open. Missing V/I evidence,
  `NOT_EXERCISED` and `ENVIRONMENT_INVALID` are evidence gaps: they block only
  the corresponding V/I claim. P2 findings require an explicit product
  decision and must be listed in the release notes.
- Core/data assets, stable Catalog promotion and the public `Linnet.pkg` must
  come from a locally archived candidate whose revision is exact current
  `main`, after the final eight-artifact verifier. The set digest and exact
  eight-file bytes freeze that candidate. The same set must pass installed
  acceptance before one SSH control tag bound to its exact version, full
  revision and set digest releases any remote mutation. A later source revision
  requires a new archive,
  installed acceptance and control tag before a new channel update.
- The sole bootstrap exception is `data-seed-N`: an exact temporary seed tag
  plus the same final eight-artifact verifier may publish only the five data
  prerelease assets needed by a future cold build. It cannot call `catalog`,
  advance `data-channel`, publish Core or create Public / Latest; normal main
  and CI gates must later reaccept the same bytes before installed acceptance.
- No validation step may push, create a tag, publish a GitHub Release, weaken
  macOS security settings or delete user data.
- One local archive command is the sole candidate build/sign owner. Ordinary
  main commits do not build or sign a candidate. It uses the fixed community
  P12 through the dedicated Keychain and locks it again. The SSH-authorized
  publisher has no signing step and may only upload the exact verified set.

### Data-update authority subtraction

| Count | Before | After |
| --- | ---: | ---: |
| private publisher-signature authorities | pack manifest + Catalog (2) | 0 |
| Settings/Registry verification interpretations | Settings container check + Registry pack check + Settings identity recheck (3) | Registry install call (1) |
| local package dependencies on external data roots | 1 | 0 |
| App-revision fields in language-data handoffs | 1 | 0 |
| public Latest authorization owners | machine record + version tag (2) | revision + set-digest SSH control tag (1) |
| stable Catalog promotion owners | public-release side effect (1) | explicit catalog stage (1) |

Retained checks protect distinct boundaries: direct canonical GitHub HTTPS owns
Catalog origin; sequence floors prevent replay; Catalog byte count/SHA-256
bind the downloaded container; manifest/path/file hashes protect extraction;
Core/ABI checks protect runtime compatibility; atomic activation protects live
state. No retained check re-signs or independently reconstructs pack identity.

### CI and release-control authority subtraction

| Count | Before | After |
| --- | ---: | ---: |
| full product gates for one feature revision before merge | branch push + PR (2) | PR only (1) |
| commit-CI product execution | one serial composite (1) | App/Swift/Rime profiles in parallel under one workflow owner (3 profiles, 1 authority) |
| upstream Git fetches with the exact locked commit already cached | one per source (all) | 0 |
| native Rime compilations on a verified exact cache hit | 1 | 0 |
| cache writers per main run | 1 | native Rime profile only (1) |
| cache transport facts | locked source/generated data (1) | locked source/generated data + compiled native runtime (2 distinct owners) |
| per-release GitHub webpage controls | dispatch + protected web approval (2) | 0 |
| candidate build/sign owners | 1 | local exact-main archive (1) |
| publication authorization owners | protected web approval (1) | revision + set-digest SSH tag (1) |
| publisher qualification paths | current main or public version tag (2) | SSH publication tag (1) |
| publication artifact downloads | stage + stable jobs (2) | 0 |
| publication jobs | stage + stable (2) | ordered publisher (1) |

The second cache path owns a genuinely new transport fact: verified compiled
runtime bytes. It does not own source identity and cannot merge with a partial
live runtime; the lock, source commits, patches and runtime fingerprint remain
the sole product authority. Candidate and publication tags protect different
mutation boundaries: the first may build/sign and upload only, while the second
may publish only the exact artifact that passed installed acceptance.

## Core language-experience gates

The language data is accepted as a user experience, not merely as a set of
well-formed files. Every release candidate must pass all four levels below.

| Surface | Data/integrity gate | Engine/product gate | Release-blocking quality budget |
| --- | --- | --- | --- |
| Chinese vocabulary and ranking | locked Wanxiang tables are imported directly; one declarative Linnet review dictionary and exact pronunciation patch preserve accepted differences without a Python composer or generated second dictionary truth | locked daily/work/tech/finance/modern/place/polyphone/sentence corpus returns reviewed top five in full pinyin and Natural Code; all eight profiles exercise the same dictionary. In Chinese mode an independently meaningful exact English word is first by default; only a same-span exact Chinese candidate reached through the active Prism's complete non-abbreviated path and backed by a static dictionary entry meeting Rime's lexical floor keeps Chinese first, including after that entry becomes a learned candidate. The native matrix covers 72/72 common exact-English profile cases, 15 fresh-to-learned collision transitions across all eight profiles, a learned weak-collision negative, plus prefix and correction negatives | no warning on the 215-case corpus, exact-English profile matrix or live candidate-overlap matrix; every reported ranking regression gets a reproduced case and reviewed owner, never an opaque runtime patch |
| English vocabulary, IPA and definitions | one canonical generator; visible definitions contain no HTML/control/broken-bracket artifact; proprietary names may be explicitly untranslated | ordinary completion, all four correction types, case, IPA, definition, untranslated-name and overflow behavior are probed through librime | no missing/classification gap in the shipped display index; every high-frequency sampled defect is fixed or explicitly skipped with provenance |
| Pinyin-to-English reverse lookup | one reviewed JSON snapshot owns candidate order; direct validation enforces byte-sorted keys, case-insensitive deduplication, the 64-candidate cap and exact embargo parity | Smart English resolves reviewed full-pinyin keys automatically; every Chinese profile resolves its own reviewed full- or double-pinyin code after the selected `;` or `|` trigger, including codes with an internal semicolon | committed quality cases are all green; a confirmed non-word cannot appear in any key |
| Association and learning | Chinese Wanxiang LTS grammar and Smart English static/learned context have one owner each | Chinese long-sentence Golden, English longest-context/static/learned-only/contraction/spacing, and exact Chinese auto-phrase promotion are exercised | a learned result must stay session/user scoped as designed; raw input, punctuation, application keys and cancellation must remain usable |

Counts describe coverage, not correctness. A large row count can never waive
the reviewed corpus, runtime probes, or release sampling. New upstream data is
blocked if it regresses one of these owner-level cases.

## Graphical configuration gates

Every GUI control must map to exactly one typed setting and one deterministic
Rime/Squirrel projection. A control without an engine probe is not considered
implemented. The simple surface currently covers:

For document-only Apply, Settings stages only
`Transactions/<UUID>/configuration-candidate/linnet_settings.json`. Host owns
the expected/base-revision CAS, atomic canonical-document exchange, projection
reconciliation, ordered exact-11 deployment, fresh-session readiness and exact
`activeSettingsRevision`; a failed activation atomically restores, reconciles
and redeploys the previous document or fails closed. The personal runtime patch
`linnet_user.custom.yaml` owns disabled words only. Sentence capitalization and
Tab behavior come from the typed document and are projected into the eight
Chinese schema custom files plus the English schema custom file.

| Panel | Current typed controls | Current evidence |
| --- | --- | --- |
| Appearance | seven candidate-window theme families (Xuan/Moon/Slate/Clay/Mist/Glass/Ink), each with Light/Dark twins while Settings keeps the native macOS appearance; 12–32 pt candidate font size, five macOS-native bilingual font presets, independent Chinese/English horizontal-or-vertical layouts, 3/5/7/9 candidates per page, scrolling-only or disclosure-enabled browsing, and a persistent local candidate preview | the right-column selector renders all seven Light/Dark pairs from the canonical bundled Catalog, and the preview uses the selected point size without scale-down or truncation. The typed renderer and canonical-preview parser cover all 14 variants and 21 family/mode projections. The disclosure state is transient per composition: when enabled, it exposes up to three real Rime pages with a 27-item hard cap and uses absolute candidate indices; it is not a third layout. Mist and neutral Glass share the one native material implementation, while the other five remain opaque. The optional current-client appearance capability is isolated behind one typed resolver and falls back to the macOS appearance when absent or malformed. Cross-application Light/Dark behavior, real-window theme comparison, disclosure mouse/AX interaction, material/contrast, Increase Contrast and Reduce Transparency review remain UAT / `NOT_EXERCISED` |
| Input | Chinese profile (full pinyin or one of seven double-pinyin schemes), Emoji default, simplified/traditional output default, Chinese/English punctuation default, auxiliary-code single-character preference, `;`/`\|` pinyin-reverse trigger, and enhanced/standard/off Chinese learning strategy. The typed Settings document is the one profile owner: a fresh document defaults to full pinyin, while an existing explicit profile is preserved. Configuration Apply deterministically places it first in the Rime schema list and projects the same value to Smart English reverse lookup and direct-Shift return. `user.yaml` history is non-authoritative | native engine acceptance proves all eight profile projections and fresh-session ownership, direct Shift into Smart English and exact same-profile return, including two interleaved sessions, plus Shift+letter, held Shift, Caps Lock raw ASCII and Caps-on Shift pass-through. The document projection is exercised through deploy and fresh sessions for traditional output, reverse trigger, sentence capitalization and Tab; the separate personal runtime writer is exercised for disabled words. Installed fresh-default/profile preservation, key handling and the other seven profiles' learning rows remain UAT / `NOT_EXERCISED` |
| Dictionary | custom words, disabled English words and Text Expander | codec/transaction/engine probes pass; table editing and error-state visual audit pending |
| English | sentence capitalization, Tab behavior, IPA, Chinese definitions, context prediction, spelling correction and selection learning | projection and real librime visibility/correction/prediction probes pass. The learning control closes both the standard English user dictionary and native session-bigram read/write paths while preserving static context and spacing; real-window bilingual hierarchy and installed candidate-window audit remain UAT |
| Data | Catalog-bound pack update/cancel, GitHub direct/default, built-in GH-Proxy public mirror (third-party), advanced custom compatible HTTPS mirror, edition repair, legacy import, learning reset, portable data, backups and diagnostics | current source/component gates cover the selector, bilingual copy, no automatic fallback and the single Catalog identity owner. No current package projection exists; visible failure recovery, VoiceOver, real mirror transfer and installed lifecycle evidence are pending |

The Beta Settings bundle supports exactly English and Simplified Chinese.
Every visible string-catalog entry has reviewed Simplified Chinese copy; a
structural gate rejects any partial third locale. Traditional
Chinese UI is not a Beta promise and may only be added later as one complete
locale. Localization completeness alone is not visual proof.

## User-journey matrix

| ID | User journey | Required proof | Current status |
| --- | --- | --- | --- |
| J01 | Download, checksum and trust instructions | P, I, R | No current package exists. Retired UAT9 checksums remain historical evidence only; a new revision-bound Core/complete projection, installed trust flow and public Release bytes are pending. |
| J02 | Clean install, add/enable Linnet and coexist with Squirrel | I | `NOT_EXERCISED`. Installation acceptance must use the exact verified eight-file local archive; rebuilding or re-signing creates different evidence. The record can change to `passed` only after this row and the full required matrix succeed. |
| J03 | First Chinese input and candidate commit | E, I | E covers same-event commit for ordinary Chinese punctuation and ASCII `,`/`.`/`:` inside numbers, plus idle `/` and `~` as ordinary symbols; installed workflow remains pending. |
| J04 | left/right Shift tap, chord, hold and active composition | C, E, I | replay/engine covers exact-once raw-letter commit rather than candidate/completion selection in every Chinese profile and Smart English; active full-pinyin composition explicitly exercises both `Shift_L` and `Shift_R`. The required six-application installed workflow (Terminal, VS Code, Chrome, Apple Notes, Word and Teams) is `NOT_EXERCISED` |
| J05 | Caps Lock, passwords, URLs, paths and code identifiers | E, I | E passed: Caps Lock down/type/up enters and leaves raw ASCII in both Chinese and Smart English; installed Terminal/password-field behavior remains pending |
| J06 | full pinyin and all seven double-pinyin profiles, including the live Chinese/English candidate boundary | E, I | The focused native engine gate and fresh unsigned Release/development composite pass all eight profile overlap and page-tail boundaries on the working tree; installed profile selection remains pending. |
| J07 | Smart English completion, correction, ranking, independently configurable IPA/definition, prediction, correction and selection learning | C, E, I | C/E pass after the final lexicon rebuild and graphical-control projection probes. Native engine rows prove same-event Space commit with the trailing space, prediction selection by arrows and `1–9`, `Esc` cancellation, and that disabling selection learning stops both learned-candidate reads and bigram writes while static context suggestions and spacing remain available; installed interaction remains pending. |
| J08 | Chinese and English user learning, including enhanced/standard/off Chinese policy and isolated QA phrase `云杉码` for `yunshanma` | C, E, I | Focused owner tests, complete Swift units, the native Rime gate, package-architecture gate, fresh unsigned Release build and development composite pass on the current working tree. Native rows pass the three Chinese strategies and restore under full pinyin plus enabled/disabled English-selection learning. Signed installation, the other seven profile runtime-policy rows, persistence across the required fresh login and all I evidence are `NOT_EXERCISED`; no V or installed-product PASS is claimed. |
| J09 | application focus changes preserve standard Squirrel/Rime session behavior without a Linnet mode ledger | C, I | source guard proves the private persistence/transition owner is absent; real application switching remains pending |
| J10 | Settings defaults, bilingual copy and every editable control | C, V, I | Focused Settings tests, complete Swift units, the native Rime gate, package architecture, fresh unsigned Release build and development composite pass for typed controls, bilingual copy, preview projection and download-source state. The safe hidden-window capture was `ENVIRONMENT_INVALID` (incomplete pixels and root-only AX), so the signed candidate/product gate, valid real-window/AX evidence, VoiceOver, keyboard interaction, installation and fresh-login behavior remain `NOT_EXERCISED`; no V or I PASS is claimed. |
| J11 | user words, disabled words, Text Expander and selective import/export | C, E, V, I | headless coverage exists; visible and installed workflow pending |
| J12 | backup history, retention, reveal, restore and learning reset | C, V, I | transaction tests exist; visible/error/installed workflow pending |
| J13 | Catalog-bound Core, Chinese, English, LTS and Extended update, source selection, cancellation, rollback and offline failure | C, P, V, I, R | Current source/component gates bind Core version/build/revision/package bytes and all language packs in one Catalog. The service is typed `published`; Settings verifies the stable same-repository Catalog, while Registry retains manifest/file verification and atomic data activation. Installed UAT first exercises the immutable artifact without advancing a remote channel. After approval, the `catalog` stage must verify exact remote Core/data bytes before its fast-forward; that fast-forward, real Settings activation and GitHub/GH-Proxy transfers remain `NOT_EXERCISED` until the approved channel is exercised. |
| J14 | input process stays offline; Settings performs one quiet version check and user-initiated mutations | C, P, I | Source guards retain Settings as the only bounded network owner. Opening Settings may fetch only the bounded Catalog and shows an inline result; Core installation and language-pack downloads still require user action, with no daemon, background installer or notification owner. A current package offline scan, remote check and installed observation remain `NOT_EXERCISED`. |
| J15 | Core upgrade, pack-only update and incompatible downgrade | P, I | Package/registry fixtures require Complete-only registration plus one logout. Core closes only Settings and never stops the live InputMethodKit Host or calls register/enable/select, so existing client connections remain authoritative during installation. Settings compares installed and running version/build/revision; the Host alone may accept a post-install graceful activation when Linnet is not selected, no InputMethodKit controller remains connected and no data transaction is active. Settings then launches only the canonical installed bundle and must observe the exact installed identity before reporting success. Every exact artifact still requires the installed `两轮同 leaf Core` sequence plus accepted/rejected activation rows; these installed rows remain `NOT_EXERCISED` for the current working tree. |
| J16 | default uninstall, retained data, reinstall and explicit purge | P, I | plan/fixture covered; installed residue audit pending |
| J17 | keyboard navigation, focus order, labels, VoiceOver and reduced-motion behavior | V, I | pending |
| J18 | cold start, first key, sustained typing, memory, disk and p95/p99 latency | E, P, I | The native runtime gate is the threshold owner and requires p95 ≤ 5 ms and p99 ≤ 15 ms. Its retained-resource-session row also requires a new independent client to produce its first candidate in under 100 ms; the current isolated run measured 6 ms after process-level warm-up. A frozen-candidate report must retain its actual measurements; component PASS alone is not P/I evidence. Retired UAT9 historically measured 458,736,785 compressed bytes and 885,915,895 logical payload bytes. The new LTS identity and current source require a new package size projection; installed cold start, APFS usage and first-run cache growth remain I pending. |
| J19 | empty, loading, download, validation, disk-full, conflict and rollback error states | C, V, I | partial headless coverage; visible recovery audit pending |
| J20 | artifact names, sizes, checksums, notices, SBOM, update URLs and README agree | P, R | The candidate owner accepts one clean exact-main revision, signs once locally, and freezes exactly eight verifier-approved files. Installation consumes that exact set before any channel mutation. Only the SSH control tag binding version, full revision and eight-file set digest may let the existing publisher route Core/data/Catalog and the unchanged `Linnet.pkg` to public Release / Latest. Staged local-byte and final Release-page evidence remain distinct R rows. |

## Finding ledger

| Status | Priority | Finding | Earliest owner | Required closure |
| --- | --- | --- | --- | --- |
| closed | P0 | An embedded hardened Settings process could pass static code-sign verification but crash while loading the ad-hoc parent `librime` because the nested signature lacked the library-validation entitlement. | Release App nested signing boundary | Release build now signs Settings inside-out and verifies its entitlement, dependency, RPATH and nested signature. Headless gates no longer launch the regular GUI merely to observe two seconds of liveness; real Settings launch remains one installed-product UAT row. |
| evidence-gap | — | Settings has an always-visible local candidate preview that consumes the canonical bundled Squirrel theme source. Component and projection tests pass, but the safe hidden-window attempt produced incomplete pixels and a root-only AX tree, so it is `ENVIRONMENT_INVALID` rather than accepted V evidence. | Settings appearance preview and visible accessibility presentation | inspect all theme/layout/font extremes, unavailable/error states, keyboard traversal and VoiceOver in the controlled App/installed UAT; compare the real candidate renderer with the preview |
| evidence-gap | — | The complete Settings state matrix has no valid current real-window screenshot or accessibility-tree evidence; the rejected offscreen harness rendered blank pixels and a root-only AX tree. | Settings presentation and accessibility contracts | inspect Appearance, Input, Dictionary, English and Data in English and Simplified Chinese from the next frozen candidate; include all three download sources and their disabled/error/privacy states, and record hierarchy, copy, focus and controls without counting the invalid offscreen evidence |
| evidence-gap | — | No installed-product evidence exists for input-source discovery, the required six-application focus behavior (Terminal, VS Code, Chrome, Apple Notes, Word and Teams), upgrade, rollback, uninstall or residue. | current-user Installer and InputMethodKit lifecycle | complete one controlled clean-install-to-purge UAT only after every non-install blocker is closed |
| evidence-gap | P0 | At `b5cf850`, Core/manual activation stopped the existing IMKServer while TextEdit PID 20213 retained its old client endpoint. TextEdit then produced no Host activation or key event; fresh TextEdit PID 73247 immediately created a working connection to the replacement Host. Unicode Hex Input was the only enabled keyboard-layout fallback, so the disconnected client appeared to have a dead keyboard. | Core package Host lifecycle | Core leaves Host alive, closes only Settings and performs no TIS mutation. Post-install activation is now a separate Host-owned transition that fails closed while Linnet is selected, any InputMethodKit controller remains connected or a data transaction is active; Settings verifies the exact installed revision after relaunch. Static contract/source gates pass, but the exact signed package still needs installed continuity plus accepted/rejected activation rows. |
| closed | P1 | At `b5cf850`, Host startup created and immediately destroyed its readiness session without traversing a real candidate query. Once the last client session was gone, a new application's first Chinese lookup paid about 541 ms for dictionary paging, followed by about 149 ms on the first lazy English-dictionary access. | Host runtime readiness and shared Rime resource lifetime | One composition-free session now primes the selected schema's real candidate path and remains owned by the Host process; per-application composition sessions stay independent. The same owner refreshes before stale cleanup, retires before every all-session cleanup, and is restored after user-data sync or configuration reload. The isolated independent-client probe measured 6 ms against a 100 ms contract; installed cold-start evidence remains J18 pending. |
| closed | P0 | At exact `94e7c6f`, Shift down/up on `linnet_zh` changed `ascii_mode` to true while `schema_id` remained `linnet_zh`; Smart English had instead been placed behind a Shift-plus-space binding. The wrong product transition was caused by treating a convenient standard key binding as the user contract. | direct Chinese/Smart-English transition after upstream gesture classification | `ascii_composer` still owns tap/chord/hold and composition commit; one native Rime processor maps only its accepted isolated-Shift result to the other schema. The focused engine probe covers all eight Chinese profiles, default round trip, Shift+letter, held Shift and Caps Lock raw ASCII, while source guards reject the retired chord shortcut and private Swift mode owners |
| closed | P0 | Packaging exact `bb368e1` rejected the Chinese pack before emitting artifacts because the direct-Shift schemas and Glass `squirrel.yaml` changed pack bytes while the release manifest still named the preceding content digests. | `config/linnet-data-releases.json` language-pack identity | Chinese advances to `0.5.9` / sequence 17, English to `0.4.7` / sequence 12 and the Catalog to sequence 10, each bound to the source inventory digest computed by the existing pack owner; the same `make_package` rejection is the RED and must turn GREEN before installation |
| closed | P1 | The Host lifecycle CLI and postinstall treated Installer as the user's Text Input session, enabling repeated stop/register/selection designs to disturb menu state and client connections. | Complete registration and Core package lifecycle | Complete owns the only `TISRegisterInputSource` call. Core has no Host lifecycle CLI and never calls register/enable/select; uninstall retains the sole product-process termination command. |
| closed | P0 | During exact `83e7adb` default-uninstall UAT, the old App and generated data were removed but the preserved `linnet_zh.userdb` rotated its LevelDB log and manifest after the uninstaller invoked `--disable-input-source`; the pre-action and post-action byte manifests differed while the already-quiesced Host had no pending user input. | default uninstaller lifecycle sequence | remove the TIS disable transition from uninstall, retain the exact Host/Settings quit as the only pre-delete product action, and let the already-required fresh login retire the absent source; the real default-uninstall row must repeat from restored pre-action bytes and prove UserData, Backups and Transactions byte-identical before installation can pass |
| closed | P1 | Caps Lock lacked an automated key-event proof across Chinese and Smart English. | input-event engine acceptance | `rime_smoke_test` now proves Caps Lock down/type/up enters and leaves raw ASCII in both schemas; installed Terminal/password-field coverage remains in J05 |
| gate | P1 | Every publication candidate requires a fresh revision-bound Core/complete/uninstaller projection after source, LTS identity or Settings bytes change. | language-data release identity and immutable local archive | before candidate build/sign, require exact current main; then freeze one immutable eight-file set accepted by `package/verify_publication_artifacts`. Before pushing its SSH control tag, pass installed Settings/InputMethodKit acceptance on those same bytes. Full `verify_product release`, independent expansion, code-sign policy, checksums, zero build/debug files, Full Active and source-to-packaged-Settings byte parity remain candidate gates. |
| closed | P1 | The former release workflow could publish Core/data and advance the stable Catalog before installed UAT. | single revision + set-digest SSH authorization boundary | the workflow is retired; only the local verified set can receive the post-UAT control tag that starts the ordered Core/data/Catalog/public chain without a rebuild |
| closed | P2 | Candidate labels/opacity/radius, fuzzy-pinyin policy, restore defaults and reviewed advanced overrides are not Beta controls. The former design draft over-promised them; font and theme presets are implemented. | typed settings document and deterministic projection renderer | retired controls remain outside the Beta contract; any future addition requires its own typed owner and product evidence |
| closed | P1 | Settings previously shipped partial Traditional-Chinese strings beside otherwise English fallback, and dynamic status classified any Chinese locale as Simplified Chinese. | Settings bundle string catalog and typed presentation locale | Beta now supports exactly English and Simplified Chinese; every entry has reviewed Simplified Chinese, unsupported Chinese scripts uniformly fall back to English, and structural/component gates reject a mixed third locale |
| closed | P1 | Direct Xcode Settings UI tests could register fixture Apps from their temporary DerivedData path and delete the files without retiring those LaunchServices records. | test-owned fixture cleanup | package/install paths retain no private LaunchServices mutation; the UI-test cleanup now unregisters only `.app` bundles discovered below its marker-owned temporary DerivedData root and fails if that exact path remains in the registry. |
| superseded | P2 | The former signed-data path performed verification while the visible state still said “downloading.” | Settings language-data update state machine | the private signature path is retired; Catalog and each downloaded artifact enter the existing typed “verifying” state before container/manifest verification, while cancellation and activation owners are unchanged |
| closed | P1 | Language-data downloads were hard-coded to GitHub, leaving users on constrained networks without an explicit route choice. | Settings-only pack route | the current typed owner defines GitHub direct as default, the built-in [GH-Proxy public mirror](https://gh-proxy.com/) (third-party), and one advanced user-entered compatible HTTPS mirror for pack bytes. Catalog retrieval remains direct and canonical; invalid or retired preferences fail closed, no automatic fallback exists, and the Catalog/Registry owners are unchanged. Mirrors can observe IP, request time and public pack URLs, while Linnet sends no personal dictionaries, learning data or credentials. Source/component evidence is current; package, real-network, visible and installed evidence remain in J13/J14 and the open V/UAT rows. |
| closed | P1 | The former two-profile Chinese ranking gate left six double-pinyin layouts with representative smoke only. | Chinese Golden corpus/profile projection | one reviewed fixture now covers all eight profiles with the same 215 canonical cases plus seven profile/learning boundaries; the runtime gate requires all 1,776 probes to pass |
| closed | P1 | Settings inferred online-update availability from local Active data and an embedded public key, so an unpublished channel looked actionable. | typed Linnet data-channel service state | one `LinnetDataChannel.Service` owns publication status. The published state is coupled to the explicit `catalog` stage that verifies Core/data and writes the exact Catalog to the stable branch; the approved public job requires that state before Release. Settings consumes the typed state and one verified Core/data availability result. Remote and visible evidence remain in the open P/V/UAT rows. |
| closed | P1 | When Active data could not be decoded, the data screen displayed both “Recommended” and “Installation needs repair.” | Settings runtime snapshot projection | `dataEdition` is now absent when the authoritative snapshot is absent; Data displays “Unavailable,” and long-tail management remains disabled until the installation is repaired. |

The first P0 was found only by executing Settings from the expanded PKG. This
is why static package inspection is retained but is no longer considered a
product acceptance result by itself.

## Required installed-product acceptance record

Any future installed-product acceptance record must name:

- Git revision and whether the worktree exactly matched it;
- App, PKG and language-pack SHA-256 values;
- macOS version and Apple Silicon hardware class;
- commands and reports for C/E/P evidence;
- screenshots and accessibility findings for V evidence;
- clean install through uninstall/purge results for I evidence;
- draft release asset and download/update verification for R evidence;
- every accepted residual P2 risk and its user-visible mitigation.

The maintainer assembles all eight product assets from the clean exact-main
checkout and signs exactly once; the eight-file set digest and per-file hashes
identify the only installable candidate. Installation acceptance records those
same identities but does not itself authorize publication. The maintainer then
runs `scripts/release-control publish /absolute/release-directory`; its one
non-force SSH tag binds version, revision and set digest. The existing publisher
revalidates that tag and the same local directory, uploads Core/data, advances
the stable Catalog, uploads `Linnet.pkg`, and creates the public version tag.
An existing data or Core release must
be a prerelease with the same verified bytes; an existing stable product release
must retain the exact verified asset set. Any extra or differing asset is a hard
failure, while a byte-identical planned subset is the only retry state.

Until the remaining rows are complete, lower-class component evidence must not
be reported as installed-product acceptance.
