# Linnet product acceptance

Current policy: a version tag authorizes one unsigned community release from
that exact source revision. The tag workflow must build and verify the same
eight candidate artifacts, then route one complete installer to the stable
Release and the Core/data assets to two same-repository prerelease channels.
Installation acceptance remains separate
evidence and must name the exact revision, build and artifact hashes exercised.

The historical UAT9 summary below is retained only as static evidence from
2026-08-12; its former artifact directory has been removed from versioned
project state. An ignored local `package/release/` directory may still retain
those old bytes, but it is not a source, current candidate or publication
evidence. Those bytes no longer match the current locked Wanxiang LTS asset,
Settings copy or security owners and are not eligible for installation UAT.
There is currently no eligible installable candidate. A new candidate must be rebuilt
from one frozen revision after the current source, data, App and package gates
pass. Valid real-window/VoiceOver evidence, controlled installed-product
evidence, one committed revision, a canonical Catalog bound to deterministic packs,
the versioned Core update channel, a published service and real Linnet large-pack transfer through
GH-Proxy remain required.

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
acceptance. The Git tag and embedded release metadata own publication identity;
this document does not create a second approval commit or machine state.

Passing source tests, engine smoke tests or package expansion is necessary but
not sufficient. A release candidate is accepted only when the user journeys
below have current evidence from the same candidate revision and artifact set.

## Evidence levels

| Level | Evidence | What it may prove |
| --- | --- | --- |
| C | source, type, unit and structural tests | an owner contract and regression guard exist |
| E | real librime deployment and candidate probes | schemas, candidates, learning and latency work in the engine |
| P | final App/PKG/archive expansion and executable probes | shipped bytes, signing, layout and process startup work |
| V | screenshots, accessibility tree and direct Settings interaction | visible hierarchy, copy, states, keyboard access and responsiveness work |
| I | clean installed macOS workflow | InputMethodKit registration, focus, application interoperability and lifecycle work |
| R | draft release workflow using final assets | names, checksums, update URLs, canonical Catalog/container bindings and release instructions agree |

`C`, `E` or `P` evidence must never be reported as installed-product evidence.
`V` may use an expanded product without installing it. `I` begins only after
all non-install blockers are closed.

## Release policy

- One candidate revision, one Core App and one complete public PKG are used for
  all final evidence. Rebuilding invalidates downstream evidence.
- Every failure is traced to the earliest owner. A downstream workaround does
  not close the finding.
- P0 and P1 findings block the release. P2 findings require an explicit product
  decision and must be listed in the release notes.
- A published asset must come from the exact tagged revision and pass the
  community artifact verifier before upload. A later source revision requires
  a new version tag and fresh artifacts.
- No validation step may push, create a tag, publish a GitHub Release, weaken
  macOS security settings or delete user data.
- Manual release-CI dispatch is a read-only source verifier. A tag job uses the
  GitHub Actions short-lived repository token only to create the matching
  GitHub Release after local artifact verification; it uses no Apple key,
  certificate, Keychain, Catalog private key or signing request.

### Data-update authority subtraction

| Count | Before | After |
| --- | ---: | ---: |
| private publisher-signature authorities | pack manifest + Catalog (2) | 0 |
| Settings/Registry verification interpretations | Settings container check + Registry pack check + Settings identity recheck (3) | Registry install call (1) |
| local package dependencies on external data roots | 1 | 0 |
| App-revision fields in language-data handoffs | 1 | 0 |
| pre-install machine-approval states | `authorized` (1) | 0; only post-UAT `passed` result |

Retained checks protect distinct boundaries: direct canonical GitHub HTTPS owns
Catalog origin; sequence floors prevent replay; Catalog byte count/SHA-256
bind the downloaded container; manifest/path/file hashes protect extraction;
Core/ABI checks protect runtime compatibility; atomic activation protects live
state. No retained check re-signs or independently reconstructs pack identity.

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
| J02 | Clean install, add/enable Linnet and coexist with Squirrel | I | `NOT_EXERCISED`. There is no current package candidate. Contributors may run non-authoritative local UAT after their own candidate passes build/package/checksum gates. The machine record can change to `passed` only through the canonical result workflow after this row and the full required matrix succeed. |
| J03 | First Chinese input and candidate commit | E, I | E covers same-event commit for ordinary Chinese punctuation and ASCII `,`/`.`/`:` inside numbers, plus idle `/` and `~` as ordinary symbols; installed workflow remains pending. |
| J04 | left/right Shift tap, chord, hold and active composition | C, E, I | replay/engine covered; the required six-application installed workflow (Terminal, VS Code, Chrome, Apple Notes, Word and Teams) is `NOT_EXERCISED` |
| J05 | Caps Lock, passwords, URLs, paths and code identifiers | E, I | E passed: Caps Lock down/type/up enters and leaves raw ASCII in both Chinese and Smart English; installed Terminal/password-field behavior remains pending |
| J06 | full pinyin and all seven double-pinyin profiles, including the live Chinese/English candidate boundary | E, I | The focused native engine gate passes all eight profile overlap and page-tail boundaries on the working tree; the canonical Release rerun and installed profile selection remain pending. |
| J07 | Smart English completion, correction, ranking, independently configurable IPA/definition, prediction, correction and selection learning | C, E, I | C/E pass after the final lexicon rebuild and graphical-control projection probes. Native engine rows prove same-event Space commit with the trailing space, prediction selection by arrows and `1–9`, `Esc` cancellation, and that disabling selection learning stops both learned-candidate reads and bigram writes while static context suggestions and spacing remain available; installed interaction remains pending. |
| J08 | Chinese and English user learning, including enhanced/standard/off Chinese policy and isolated QA phrase `云杉码` for `yunshanma` | C, E, I | Focused owner tests, complete Swift units, the native Rime gate and package-architecture gate pass on the current working tree. Native rows pass the three Chinese strategies and restore under full pinyin plus enabled/disabled English-selection learning. A fresh unsigned Release build and development composite, signed installation, the other seven profile runtime-policy rows, persistence across the required fresh login and all I evidence are `NOT_EXERCISED`; no V or installed-product PASS is claimed. |
| J09 | application focus changes preserve standard Squirrel/Rime session behavior without a Linnet mode ledger | C, I | source guard proves the private persistence/transition owner is absent; real application switching remains pending |
| J10 | Settings defaults, bilingual copy and every editable control | C, V, I | Focused Settings tests, complete Swift units, the native Rime gate and package architecture pass for typed controls, bilingual copy, preview projection and download-source state. A fresh unsigned Release build and development composite are `NOT_EXERCISED`. The safe hidden-window capture was `ENVIRONMENT_INVALID` (incomplete pixels and root-only AX), so the signed candidate/product gate, valid real-window/AX evidence, VoiceOver, keyboard interaction, installation and fresh-login behavior are also `NOT_EXERCISED`; no V or I PASS is claimed. |
| J11 | user words, disabled words, Text Expander and selective import/export | C, E, V, I | headless coverage exists; visible and installed workflow pending |
| J12 | backup history, retention, reveal, restore and learning reset | C, V, I | transaction tests exist; visible/error/installed workflow pending |
| J13 | Catalog-bound Core, Chinese, English, LTS and Extended update, source selection, cancellation, rollback and offline failure | C, P, V, I, R | Current source/component gates bind Core version/build/revision/package bytes and all language packs in one Catalog. The service is typed `published`; Settings verifies the stable same-repository Catalog, while Registry retains manifest/file verification and atomic data activation. The `data-channel` fast-forward publication and real GitHub/GH-Proxy transfers remain `NOT_EXERCISED` until the tagged workflow completes. |
| J14 | input process stays offline; Settings performs one quiet version check and user-initiated mutations | C, P, I | Source guards retain Settings as the only bounded network owner. Opening Settings may fetch only the bounded Catalog and shows an inline result; Core installation and language-pack downloads still require user action, with no daemon, background installer or notification owner. A current package offline scan, remote check and installed observation remain `NOT_EXERCISED`. |
| J15 | Core upgrade, pack-only update and incompatible downgrade | P, I | Package/registry fixtures require Complete-only enable plus one logout. Core uses pre-payload cooperative Host/Settings quiescence, then one new-Host transition for final Host exit, registration and conditional selection; it never enables or logs out, restores Linnet when selected before/during the update, and preserves a newer non-Linnet choice. Exact installed rerun remains required. |
| J16 | default uninstall, retained data, reinstall and explicit purge | P, I | plan/fixture covered; installed residue audit pending |
| J17 | keyboard navigation, focus order, labels, VoiceOver and reduced-motion behavior | V, I | pending |
| J18 | cold start, first key, sustained typing, memory, disk and p95/p99 latency | E, P, I | The native runtime gate is the threshold owner and requires p95 ≤ 5 ms and p99 ≤ 15 ms. A frozen-candidate report must retain its actual measurements; component PASS alone is not P/I evidence. Retired UAT9 historically measured 458,736,785 compressed bytes and 885,915,895 logical payload bytes. The new LTS identity and current source require a new package size projection; installed cold start, APFS usage and first-run cache growth remain I pending. |
| J19 | empty, loading, download, validation, disk-full, conflict and rollback error states | C, V, I | partial headless coverage; visible recovery audit pending |
| J20 | artifact names, sizes, checksums, notices, SBOM, update URLs and README agree | P, R | The release owner now requires eight candidate artifacts and routes them 1/2/5 to the stable, Core and data channels. Exact remote bytes and Release-page evidence remain pending until the tagged workflow completes. |

## Finding ledger

| Status | Priority | Finding | Earliest owner | Required closure |
| --- | --- | --- | --- | --- |
| closed | P0 | An embedded hardened Settings process could pass static code-sign verification but crash while loading the ad-hoc parent `librime` because the nested signature lacked the library-validation entitlement. | Release App nested signing boundary | Release build now signs Settings inside-out and verifies its entitlement, dependency, RPATH and nested signature. Headless gates no longer launch the regular GUI merely to observe two seconds of liveness; real Settings launch remains one installed-product UAT row. |
| UAT | P1 | Settings has an always-visible local candidate preview that consumes the canonical bundled Squirrel theme source. Component and projection tests pass, but the safe hidden-window attempt produced incomplete pixels and a root-only AX tree, so it is `ENVIRONMENT_INVALID` rather than accepted V evidence. | Settings appearance preview and visible accessibility presentation | inspect all theme/layout/font extremes, unavailable/error states, keyboard traversal and VoiceOver in the controlled App/installed UAT; compare the real candidate renderer with the preview |
| open | P1 | The complete Settings state matrix has no valid current real-window screenshot or accessibility-tree evidence; the rejected offscreen harness rendered blank pixels and a root-only AX tree. | Settings presentation and accessibility contracts | inspect Appearance, Input, Dictionary, English and Data in English and Simplified Chinese from the next frozen candidate; include all three download sources and their disabled/error/privacy states, and record hierarchy, copy, focus and controls without counting the invalid offscreen evidence |
| open | P1 | No installed-product evidence exists for input-source discovery, the required six-application focus behavior (Terminal, VS Code, Chrome, Apple Notes, Word and Teams), upgrade, rollback, uninstall or residue. | current-user Installer and InputMethodKit lifecycle | complete one controlled clean-install-to-purge UAT only after every non-install blocker is closed |
| UAT | P0 | The installed Host is newer than the current Aqua/InputMethodKit session. Registration and System Settings can enumerate Linnet, but a native source-change trace proves Control-Option-Space rotates only through system Shuangpin, Unicode Hex Input and hallelujah. Exact `a27bb4d` placed `postinstall-action=logout` only in the Core component; macOS then reported `RestartAction=None` for the final product, proving that action was not the product conclusion owner. | product Distribution conclusion plus the installed Host lifecycle | Complete retains `onConclusion=RequireLogout` and accepts only clean first install/reinstall; its postinstall registers and requests enablement but never selects. Core has no logout conclusion: package preinstall cooperatively quiesces Host/Settings, then one new-executable transition owns final Host exit, public TIS registration and conditional restoration without enabling or overriding a newer non-Linnet choice. Remaining product closure is a real corrected Core upgrade in the same logged-in account, verifying new Host/Settings mappings plus retained enabled/disabled, selected and user-data state. |
| closed | P0 | At exact `94e7c6f`, Shift down/up on `linnet_zh` changed `ascii_mode` to true while `schema_id` remained `linnet_zh`; Smart English had instead been placed behind a Shift-plus-space binding. The wrong product transition was caused by treating a convenient standard key binding as the user contract. | direct Chinese/Smart-English transition after upstream gesture classification | `ascii_composer` still owns tap/chord/hold and composition commit; one native Rime processor maps only its accepted isolated-Shift result to the other schema. The focused engine probe covers all eight Chinese profiles, default round trip, Shift+letter, held Shift and Caps Lock raw ASCII, while source guards reject the retired chord shortcut and private Swift mode owners |
| closed | P0 | Packaging exact `bb368e1` rejected the Chinese pack before emitting artifacts because the direct-Shift schemas and Glass `squirrel.yaml` changed pack bytes while the release manifest still named the preceding content digests. | `config/linnet-data-releases.json` language-pack identity | Chinese advances to `0.5.9` / sequence 17, English to `0.4.7` / sequence 12 and the Catalog to sequence 10, each bound to the source inventory digest computed by the existing pack owner; the same `make_package` rejection is the RED and must turn GREEN before installation |
| closed | P1 | The Host lifecycle CLI discarded InputMethodKit failures and postinstall treated the Installer service as the user's Text Input UI session, so transient enable/selection results could be reported as success without adding Linnet to the user's persistent input-source list. | `SquirrelInstaller` TIS boundary and Host CLI exit projection | registration, explicit enablement, selection and disablement retain typed failures. Complete registers and requests enablement but never selects. Core accepts only its package-bound prior-state tuple and may conditionally restore Linnet within its single refresh transition; it cannot enable or accept an alternate target identifier. Uninstall leaves source retirement to the required fresh login session. |
| closed | P0 | During exact `83e7adb` default-uninstall UAT, the old App and generated data were removed but the preserved `linnet_zh.userdb` rotated its LevelDB log and manifest after the uninstaller invoked `--disable-input-source`; the pre-action and post-action byte manifests differed while the already-quiesced Host had no pending user input. | default uninstaller lifecycle sequence | remove the TIS disable transition from uninstall, retain the exact Host/Settings quit as the only pre-delete product action, and let the already-required fresh login retire the absent source; the real default-uninstall row must repeat from restored pre-action bytes and prove UserData, Backups and Transactions byte-identical before installation can pass |
| closed | P1 | Caps Lock lacked an automated key-event proof across Chinese and Smart English. | input-event engine acceptance | `rime_smoke_test` now proves Caps Lock down/type/up enters and leaves raw ASCII in both schemas; installed Terminal/password-field coverage remains in J05 |
| open | P1 | Source, LTS identity and Settings bytes changed after the retired UAT9 projection, leaving no current local package projection. | language-data release identity and local package projection | after trust and IPC owners freeze, build one new revision-bound Core/complete/uninstaller identity and pass full `verify_product release`, independent expansion, code-sign policy, checksums, zero build/debug files, Full Active and source-to-packaged-Settings byte parity |
| open | P1 | The source service is enabled, but the candidate has no remote fast-forward Catalog or installed real-network evidence yet. | archive and remote publication owners | publish Core and the deterministic packs, then fast-forward the exact canonical Catalog to `data-channel`; verify remote sequence, Core/package binding and pack bytes before installed Settings UAT |
| closed | P2 | Candidate labels/opacity/radius, fuzzy-pinyin policy, restore defaults and reviewed advanced overrides are not Beta controls. The former design draft over-promised them; font and theme presets are implemented. | typed settings document and deterministic projection renderer | retired controls remain outside the Beta contract; any future addition requires its own typed owner and product evidence |
| closed | P1 | Settings previously shipped partial Traditional-Chinese strings beside otherwise English fallback, and dynamic status classified any Chinese locale as Simplified Chinese. | Settings bundle string catalog and typed presentation locale | Beta now supports exactly English and Simplified Chinese; every entry has reviewed Simplified Chinese, unsupported Chinese scripts uniformly fall back to English, and structural/component gates reject a mixed third locale |
| superseded | P1 | Earlier packaging added private LaunchServices unregister calls for scratch Apps. The later upstream-alignment audit found that mature Squirrel/Hallelujah package flows do not create this cleanup owner. | ordinary temporary work-root cleanup plus macOS registration lifecycle | private `lsregister` calls are retired; current package/source guards require build products never to become selectable input sources, while actual installed registration remains J02/J16 product evidence |
| superseded | P2 | The former signed-data path performed verification while the visible state still said “downloading.” | Settings language-data update state machine | the private signature path is retired; Catalog and each downloaded artifact enter the existing typed “verifying” state before container/manifest verification, while cancellation and activation owners are unchanged |
| closed | P1 | Language-data downloads were hard-coded to GitHub, leaving users on constrained networks without an explicit route choice. | Settings-only pack route | the current typed owner defines GitHub direct as default, the built-in [GH-Proxy public mirror](https://gh-proxy.com/) (third-party), and one advanced user-entered compatible HTTPS mirror for pack bytes. Catalog retrieval remains direct and canonical; invalid or retired preferences fail closed, no automatic fallback exists, and the Catalog/Registry owners are unchanged. Mirrors can observe IP, request time and public pack URLs, while Linnet sends no personal dictionaries, learning data or credentials. Source/component evidence is current; package, real-network, visible and installed evidence remain in J13/J14 and the open V/UAT rows. |
| closed | P1 | The former two-profile Chinese ranking gate left six double-pinyin layouts with representative smoke only. | Chinese Golden corpus/profile projection | one reviewed fixture now covers all eight profiles with the same 215 canonical cases plus seven profile/learning boundaries; the runtime gate requires all 1,776 probes to pass |
| closed | P1 | Settings inferred online-update availability from local Active data and an embedded public key, so an unpublished channel looked actionable. | typed Linnet data-channel service state | one `LinnetDataChannel.Service` owns publication status. The published state is now coupled to the release workflow that writes the exact Catalog to the stable branch; Settings consumes that typed state and one verified Core/data availability result. Remote and visible evidence remain in the open P/V/UAT rows. |
| closed | P1 | When Active data could not be decoded, the data screen displayed both “Recommended” and “Installation needs repair.” | Settings runtime snapshot projection | `dataEdition` is now absent when the authoritative snapshot is absent; Data displays “Unavailable,” and long-tail management remains disabled until the installation is repaired. |

The first P0 was found only by executing Settings from the expanded PKG. This
is why static package inspection is retained but is no longer considered a
product acceptance result by itself.

## Required acceptance record

The eventual accepted v3 approval commit (`installation_uat=passed` and
`publication=go`) and its machine record must name:

- Git revision and whether the worktree exactly matched it;
- App, PKG and language-pack SHA-256 values;
- macOS version and Apple Silicon hardware class;
- commands and reports for C/E/P evidence;
- screenshots and accessibility findings for V evidence;
- clean install through uninstall/purge results for I evidence;
- draft release asset and download/update verification for R evidence;
- every accepted residual P2 risk and its user-visible mitigation.

The credential-free manual candidate job verifies source and locked inputs; it
does not create a signing handoff or publish. Local package and installation
UAT build deterministic data containers and Catalog bytes directly. After
the installed workflow succeeds, a result commit records `installation_uat=passed`
and the exact three candidate artifact digests; the canonical verifier checks
that evidence after the fact. Formal archive assembly creates the remaining
product assets from the accepted candidate, then revalidates the resulting
digest-bound publication plan immediately before its first remote mutation. An
existing data release must be a prerelease at the accepted revision; an
existing product release must remain a draft at that revision. Any extra or
differing asset is a hard failure, while a byte-identical planned subset is the
only retry state.

Until the remaining rows are complete, lower-class component evidence must not
be reported as installed-product acceptance.
