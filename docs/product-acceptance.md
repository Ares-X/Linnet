# Linnet product acceptance

Current policy: except for the isolated cold-build `data-seed` boundary below,
one clean exact-main revision first passes the complete local composite and
installation-preflight gates. Its candidate tag starts one macOS release job:
one checkout/cache/hydrate, serial lint/owner/Swift/Rime/Periphery gates, then
one CMS-signed archive build. No second full-CI workflow qualifies the same
revision. A passing `package/verify_publication_artifacts` run freezes exactly
eight files: three Core-channel assets (Core PKG, uninstaller and raw Catalog),
four immutable language packs and one public `Linnet.pkg`. The same job stages
or verifies the candidate-bound Core/Public Drafts and the byte-bound data
Draft. A data Draft already attached to any valid direct commit is reused
without mutation when its tag, title, prerelease state and four pack assets are
byte-identical. Real installed
Settings/InputMethodKit acceptance downloads and consumes those exact bytes
before any public-channel mutation. The maintainer then uses Git SSH to create
one lightweight control tag binding version, full revision and the eight-file
set digest. That tag authorizes the Ubuntu Action's ordered
Core/data/Catalog/public publication chain without a large-asset redownload or
rebuild. Installation acceptance remains separate evidence and must name the
exact revision, build, set digest and file hashes exercised.

The historical UAT9 summary below is retained only as static evidence from
2026-08-12; its former artifact directory has been removed from versioned
project state. An ignored local `package/release/` directory may still retain
those old bytes, but it is not a source, current candidate or publication
evidence. Those bytes no longer match the current locked Wanxiang LTS asset,
Settings copy or security owners and are not eligible for installation UAT.
Only a clean exact-main Action candidate generated after the current source,
data, App and package gates pass is eligible. It may be built and signed once.
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

## 0.1.10 history convergence and root-cause index

Audit identity: 2026-08-29, implementation baseline `e6f5da15bbe0c3359da595b5b1daf05e46ff7cd5`
in `release-0.1.15`. At audit start `git rev-list --all --count` returned 914.
The audit also reconciled repository Issues 1–2, PRs 3–17, the retained UAT
records below and the repeated user-observed failures in this document. This is
the only durable root-cause ledger; README, CHANGELOG and Release Notes may
summarize shipped behavior but must not become competing acceptance owners.

| Root-cause family | Earliest authority after convergence | Retired or forbidden path | 0.1.10 status |
| --- | --- | --- | --- |
| input-source registration and damaged-install repair | Complete installer plus package-owned typed read-only TIS classification | Core register/enable/select, installed-Host inspection CLI, missing-App Core repair, `osascript` authorization | owner, package-lifecycle and full serial source gates pass on the local freeze; exact installed Core and repair rows remain pending |
| Shift, Caps Lock and Chinese/English state | Rime `ascii_composer` plus the accepted direct-Shift schema transition | Swift ASCII bridge, private mode fallback or per-app state ledger | owner and full serial C/E gates pass on the local freeze; the installed application matrix remains pending |
| Host update and multi-application continuity | Host typed activation state | client/process history, application kill/reopen and custom JXA/`osascript` quiescer; Apple Installer's Settings-only `must-close` remains | owner, source, package and full serial gates pass on the local freeze; TextEdit/Teams/Codex/etc. I rows still block public release |
| per-schema keys, punctuation and mixed input | tracked default/schema projection plus deployed eight-schema capability matrix | ignored staged defaults, test-only schema patches, two-profile samples, idle punctuation capture and hidden numeric-separator state | the full serial native matrix passes all eight profiles; warm p95 is 0.510 ms for English and 1.392 ms for Chinese against the 5 ms limit, with cold-client first keys at 10 ms and 2 ms. Installed key/application rows remain pending |
| Chinese ranking and rime-ice supplement | Wanxiang core plus reviewed Linnet ledger and verified-only build projection | rime-ice runtime translator, `best_guess`, duplicate Wanxiang ownership | source-quality, final-pack projection, eight-profile Golden and native runtime gates pass on the local freeze; installed ranking samples remain pending |
| candidate and Settings presentation | CandidatePresentation/Panel geometry and four-page Settings contract | per-layout sizing, five-page navigation, disappearing update action and duplicate page-mark helpers | the focused candidate owner gate and Settings build-for-testing pass on the current tree; the full serial rerun, foreground/minimized/cross-Space behavior and real-window/AX V/I evidence remain pending |
| Core, pack and Catalog publication identity | App/Core bytes; each pack metadata/hash; Catalog snapshot of the current Core plus existing immutable packs, bound by the exact `data-channel` commit/blob | App build driving pack sequence, candidate revision as a second data-Draft owner and Catalog masquerading as data-release identity | owner and regression gates implemented; no current package exists, so current P and remote R evidence remain pending along with the exact serial rerun |
| lint, dead code and CI cost | strict zero-baseline lint, Periphery, one serial macOS chain and one Swift cache owner | 131-entry baseline, path rewriting, duplicate hydrates/builds and static-module cache owner | local gates pending final integrated run; Actions deliberately not exercised |
| learning sync, backups, uninstall and residue | standard Rime incremental sync, manual full-backup owner and package-owned uninstaller that executes no installed App bytes | automatic full backup, user-selected iCloud folder, post-uninstall TIS mutation, installed-Host quit/purge commands and broad temporary-root deletion | component evidence retained; real round-trip/residue I rows pending |

Closed here means the named source/component owner and regression gate exist;
it never upgrades an unexecuted V/I/R row to PASS.

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
bundle ID, macOS major and identity-classifier `旧迁移投影指纹` are the complete
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

### Local 0.1.10 user feedback — 2026-08-30

Installed source `53ab4e263e971c6849d0dd0dfa6cdea4e9447a9b`, version
0.1.10 (69), Core PKG SHA-256
`a26d2dc6fa323e52dd6afe8365d72ea666dfbada7d8023cfc301615d290f11f3`:
macOS Installer completed successfully and the Active language-data metadata
hash remained unchanged. After being asked to check input after applying the
update, the user reported “输入正常”. This is real-user input feedback for the
local candidate, not a claim that every application, theme, accessibility or
reinstall row was individually exercised. The later Action-built candidate
still requires its own artifact identity and installed acceptance; this local
package must not be substituted for those bytes.

### Candidate publication failure — 2026-08-30

Action `33300580967`, source `414841ff9b17716cd0da43c4e6dcb95fb74dd4b8`,
stopped at 08:09:46 UTC before signing or upload. Its comparison against the
merge's first parent rejected Chinese sequence 31→34: the metadata owner
required an exact +1 increment even though the branch contained multiple
valid data revisions. Local preflight had not exercised this merge-endpoint
comparison. The correction retains one metadata owner and removes the two
adjacency assumptions (pack and Catalog); changed identities must increase,
unchanged identities must retain their sequence, and reused identities or
regressing ABI/minimum-Core remain rejected. The existing regression suite
covers individual transitions, their merged endpoints and reverse/non-increasing
transitions. README version duplication found in the same local release checks
was removed without changing the gate. These are release-tool corrections,
not input-runtime changes or a successful cloud rerun.

### Cloud theme-preview assertion — 2026-08-30

Action `33301220240`, source `c3cd850a58469f729cb305d45152c03e5cce8ad7`,
passed source/publication checks, then failed at 08:28:08 UTC in the Swift
appearance-preview fixture. Vision recognized 13 occurrences of “输入” instead
of 14 in the 680-point Dark Aqua theme grid. Compilation succeeded. The
macos-26-arm64 runner also logged an unavailable paravirtual display driver,
but that does not establish the cause of the recognition difference.

On the maintainer's macOS 26.6, both default 2x and explicitly controlled 1x
captures passed all four appearance/width cases; visual inspection of the 1x
Dark Aqua 680-point image found all fourteen samples. Thus a scale-only cause
was not reproduced and the cloud assertion is not yet a confirmed product
rendering defect. The old fixture saved only 900-point images after its
assertion, so the failed cloud image was lost. The fixture now saves each
capture before recognition, logs its pixel dimensions and emits the synthetic
PNG in the existing job log on a count failure. The fourteen-sample threshold,
rendering path and production UI remain unchanged. Cloud diagnosis and formal
artifact publication remain incomplete; no third cloud run was authorized.

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
- Core assets, the raw Catalog snapshot and the public `Linnet.pkg` must come
  from the macOS Action candidate whose revision is exact current `main`, after
  the self-contained serial candidate gates and final eight-artifact verifier.
  Core/Public Drafts remain bound to that exact candidate revision. Each data
  pack is instead owned by its immutable bytes and metadata; a data Draft may be
  reused across candidate revisions when its target is a valid direct commit and
  its tag, title, prerelease state, filenames, sizes and SHA-256 digests match
  exactly. The Catalog is the candidate's snapshot of the current Core plus
  those existing immutable packs. The eight-file set digest freezes that exact
  combination, which must pass installed acceptance before one SSH control tag
  bound to its version, full revision and set digest authorizes public-channel
  mutation. A later source revision requires a new Core/Public/Catalog Action
  candidate and installed acceptance, but does not create or rewrite a
  byte-identical data Draft.
- The sole bootstrap exception is
  `linnet-data-seed/v<VERSION>-<SEQUENCE>-<REVISION>`. The macOS Action may
  fetch only the upstream model identity already fixed in the lock, must pass
  the same final eight-artifact verifier, and may publish only four data
  prerelease assets. It cannot advance `data-channel`, publish Core or create
  Public / Latest; the normal main candidate gate must later rebuild from that
  fixed data Release before installed acceptance.
- No validation step may push, create a tag, publish a GitHub Release, weaken
  macOS security settings or delete user data.
- One macOS Action archive command is the sole formal candidate build/sign
  owner. Ordinary main commits do not build or sign a candidate. It uses the
  fixed community P12 through a temporary Keychain and removes that Keychain
  afterward. The SSH-authorized Ubuntu publisher has no signing or large-asset
  upload/download step and may only publish the exact staged set.

### Data-update authority subtraction

| Count | Before | After |
| --- | ---: | ---: |
| private publisher-signature authorities | pack manifest + Catalog (2) | 0 |
| Settings/Registry verification interpretations | Settings container check + Registry pack check + Settings identity recheck (3) | Registry install call (1) |
| local package dependencies on external data roots | 1 | 0 |
| App-revision fields in language-data handoffs | 1 | 0 |
| App/Core build paths owning pack sequence | 1 | 0 |
| pack publication identities | one shared Catalog/data tag interpretation | four per-pack metadata/hash owners |
| Catalog publication identity | data release sequence | exact `data-channel` commit/blob |
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
| automatic full product gates for one change through merge | PR + main (2) | PR only (1; release candidate is explicit) |
| automatic full main matrices | every main push (1) | manual dispatch only (0 automatic) |
| macOS product runners per full CI | quality + App + Settings UI + Swift + Rime (5) | one serial product runner (1) |
| Settings UI authoritative-success exits | pre-Xcode empty-array false success + completed suite (2) | completed suite only (1) |
| upstream Git fetches with the exact locked commit already cached | one per source (all) | 0 |
| native Rime compilations on a verified exact cache hit | 1 | 0 |
| build-cache writers per full run | native Rime profile only (1) | manual commit CI job only (1) |
| Swift compile/cache owners | direct compiles plus proposed support module (2) | `tests/swift_test_cache.sh` only (1) |
| cache transport facts | locked source/generated data (1) | locked source/generated data + verified tools/compiled runtime (3 distinct byte classes, one cache boundary) |
| per-release GitHub webpage controls | dispatch + protected web approval (2) | 0 |
| candidate build/sign owners | local exact-main archive (1) | macOS Action archive (1) |
| publication authorization owners | protected web approval (1) | revision + set-digest SSH tag (1) |
| publisher qualification paths | current main or public version tag (2) | SSH publication tag (1) |
| release CLI compiler sites in one archive | package + archive + verifier (3) | Make owner shared by all consumers (1) |
| same-PKG verification sites | producer + archive projection + final publication (3) | producer + final publication (2 distinct boundaries) |
| large candidate uploads | Actions artifact + Release (2) | Draft Release only (1) |
| large publisher downloads | artifact handoff + final roundtrip (2) | 0; only the Catalog is downloaded |

The build cache transports verified source/generated data, compiled runtime
and pinned tool bytes, but owns none of their product identities and cannot
merge with a partial live runtime. Locks, source commits, patches, fingerprints
and pinned tool hashes remain authoritative. Candidate and publication tags protect different
mutation boundaries: the first may build/sign and stage Draft bytes only, while
the second may publish only the exact byte set that passed installed acceptance.

## Core language-experience gates

The language data is accepted as a user experience, not merely as a set of
well-formed files. Every release candidate must pass all four levels below.

| Surface | Data/integrity gate | Engine/product gate | Release-blocking quality budget |
| --- | --- | --- | --- |
| Chinese vocabulary and ranking | locked Wanxiang tables remain the core; one declarative Linnet review dictionary and exact pronunciation patch preserve accepted differences. The locked rime-ice extended table is projected only at build time: Wanxiang-owned, short, ambiguous and unverifiable rows are rejected before a low-weight supplement enters the same dictionary graph, without a generated checked-in dictionary or second runtime owner | locked daily/work/tech/finance/modern/place/polyphone/sentence corpus returns reviewed top five in full pinyin and Natural Code; all eight profiles exercise the same dictionary, including a long proper-name supplement case. In Chinese mode an independently meaningful exact English word is first by default; only a same-span exact Chinese candidate reached through the active Prism's complete non-abbreviated path and backed by a static dictionary entry meeting Rime's lexical floor keeps Chinese first, including after that entry becomes a learned candidate. The native matrix covers 72/72 common exact-English profile cases, 15 fresh-to-learned collision transitions across all eight profiles, a learned weak-collision negative, plus prefix and correction negatives | no warning on the 215-case corpus, exact-English profile matrix or live candidate-overlap matrix; every reported ranking regression gets a reproduced case and reviewed owner, never an opaque runtime patch |
| English vocabulary, IPA and definitions | one canonical generator; visible definitions contain no HTML/control/broken-bracket artifact; proprietary names may be explicitly untranslated | ordinary completion, all four correction types, case, IPA, definition, untranslated-name and overflow behavior are probed through librime | no missing/classification gap in the shipped display index; every high-frequency sampled defect is fixed or explicitly skipped with provenance |
| Pinyin-to-English reverse lookup | one reviewed JSON snapshot owns candidate order; direct validation enforces byte-sorted keys, case-insensitive deduplication, the 64-candidate cap and exact embargo parity | Smart English resolves reviewed full-pinyin keys automatically; every Chinese profile resolves its own reviewed full- or double-pinyin code after the default `|` or user-selected `;` trigger, including codes with an internal semicolon | committed quality cases are all green; a confirmed non-word cannot appear in any key |
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
| Input | Chinese profile (full pinyin or one of seven double-pinyin schemes), Emoji default, simplified/traditional output default, Chinese/English punctuation default, auxiliary-code single-character preference, default `\|` or explicit `;` pinyin-reverse trigger, enhanced/standard/off Chinese learning strategy, plus Smart English capitalization, IPA, definitions, prediction, correction, learning, Space and Tab behavior. The typed Settings document is the one profile owner: a fresh document defaults to full pinyin, while an existing explicit profile is preserved. Configuration Apply deterministically places it first in the Rime schema list and projects the same value to Smart English reverse lookup and direct-Shift return. `user.yaml` history is non-authoritative | native engine acceptance proves all eight profile projections and fresh-session ownership, direct Shift into Smart English and exact same-profile return, including two interleaved sessions, plus Shift+letter, held Shift, Caps Lock raw ASCII and Caps-on Shift pass-through. The document projection is exercised through deploy and fresh sessions for traditional output, reverse trigger, sentence capitalization and Tab; the separate personal runtime writer is exercised for disabled words. Installed fresh-default/profile preservation, key handling and the other seven profiles' learning rows remain UAT / `NOT_EXERCISED` |
| Dictionary | custom words, disabled English words and Text Expander | codec/transaction/engine probes pass; table editing and error-state visual audit pending |
| Data & Updates | installed/running Core identity, always-present activation card, Catalog-bound pack update/cancel, GitHub direct/default, built-in GH-Proxy public mirror (third-party), advanced custom compatible HTTPS mirror, iCloud incremental learning sync, manual full backup/restore, transaction recovery history, edition repair, legacy import, learning reset, portable data and diagnostics | current source/component gates cover the selector, bilingual copy, no automatic fallback, one Catalog identity owner and one 0.1.9-to-0.1.10 identity-free Host compatibility branch. That branch must disappear at 0.1.11. Visible failure recovery, VoiceOver, real mirror transfer and installed lifecycle evidence are pending |

The Beta Settings bundle supports exactly English and Simplified Chinese.
Every visible string-catalog entry has reviewed Simplified Chinese copy; a
structural gate rejects any partial third locale. Traditional
Chinese UI is not a Beta promise and may only be added later as one complete
locale. Localization completeness alone is not visual proof.

## User-journey matrix

| ID | User journey | Required proof | Current status |
| --- | --- | --- | --- |
| J01 | Download, checksum and trust instructions | P, I, R | No current package exists. Retired UAT9 checksums remain historical evidence only; a new revision-bound Core/complete projection, installed trust flow and public Release bytes are pending. |
| J02 | Clean install, add/enable Linnet and coexist with Squirrel | I | `NOT_EXERCISED`. Installation acceptance must use the exact verified eight-file Draft Release set produced by the candidate Action; rebuilding or re-signing creates different evidence. The record can change to `passed` only after this row and the full required matrix succeed. |
| J03 | First Chinese input and candidate commit | E, I | E covers same-event commit for ordinary Chinese punctuation and ASCII `,`/`.`/`:` inside numbers, plus idle `/` and `~` as ordinary symbols; installed workflow remains pending. |
| J04 | left/right Shift tap, chord, hold and active composition | C, E, I | replay/engine covers exact-once raw-letter commit rather than candidate/completion selection in every Chinese profile and Smart English; active full-pinyin composition explicitly exercises both `Shift_L` and `Shift_R`. The required six-application installed workflow (Terminal, VS Code, Chrome, Apple Notes, Word and Teams) is `NOT_EXERCISED` |
| J05 | Caps Lock, passwords, URLs, paths and code identifiers | E, I | The E regression gate covers Caps Lock down/type/up entering and leaving raw ASCII in both Chinese and Smart English. Current exact serial E execution and installed Terminal/password-field behavior remain pending. |
| J06 | full pinyin and all seven double-pinyin profiles, including the live Chinese/English candidate boundary | E, I | The local freeze passes the complete serial Release/development composite, all eight 222-case Golden profiles, the native overlap/key/page-tail matrix and its mapping-mutation negative. Warm p95 is 0.510 ms for English and 1.392 ms for Chinese. E is passed for this source freeze; installed profile selection remains `NOT_EXERCISED`. |
| J07 | Smart English completion, correction, ranking, independently configurable IPA/definition, prediction, correction and selection learning | C, E, I | The local freeze passes the complete serial owner and native rows for Space behavior, arrow and `1–9` selection, passive-prediction labels, `Esc`, selection learning and static-context spacing. Current C/E are passed; installed interaction remains `NOT_EXERCISED`. |
| J08 | Chinese and English user learning, including enhanced/standard/off Chinese policy and isolated QA phrase `云杉码` for `yunshanma` | C, E, I | The local freeze passes complete Swift, native Rime, package architecture, unsigned Release and development composite rows for enhanced/standard/off Chinese policy, full-pinyin restore, enabled/disabled English learning and upstream multi-device dictionary sync. Current C/E are passed; signed installation, fresh-login persistence and all I evidence remain `NOT_EXERCISED`. |
| J09 | application focus changes preserve standard Squirrel/Rime session behavior without a Linnet mode ledger | C, I | source guard proves the private persistence/transition owner is absent; real application switching remains pending |
| J10 | Settings defaults, bilingual copy and every editable control | C, V, I | The local freeze passes typed controls, bilingual copy, preview projection, download-source state, four-page layout, foreground/minimized owner tests and the isolated fixed-home fixture. Two full Settings UI attempts on 2026-08-30 were `ENVIRONMENT_INVALID` before any product test: macOS first reported an active system-authentication session, then timed out enabling XCTest automation mode; both isolated homes and preference domains were removed and protected real-user bytes stayed unchanged. Signed product, real-window/AX, VoiceOver, keyboard interaction, installation and fresh-login behavior remain `NOT_EXERCISED`; no V or I PASS is claimed. |
| J11 | user words, disabled words, Text Expander and selective import/export | C, E, V, I | headless coverage exists; visible and installed workflow pending |
| J12 | backup history, retention, reveal, restore and learning reset | C, V, I | transaction tests exist; visible/error/installed workflow pending |
| J13 | Catalog-bound Core, Chinese, English, LTS and Extended update, source selection, cancellation, rollback and offline failure | C, P, V, I, R | Current source/component gates bind Core version/build/revision/package bytes and all language packs in one Catalog. The service is typed `published`; Settings verifies the stable same-repository Catalog, while Registry retains manifest/file verification and atomic data activation. Installed UAT first exercises immutable Draft Release bytes without advancing a remote channel. After authorization, the Action publisher must verify exact remote Core/data metadata and Catalog bindings before its non-force fast-forward; that fast-forward, real Settings activation and GitHub/GH-Proxy transfers remain `NOT_EXERCISED` until the authorized channel is exercised. |
| J14 | input process stays offline; Settings performs one quiet version check and user-initiated mutations | C, P, I | Source guards retain Settings as the only bounded network owner. Opening Settings may fetch only the bounded Catalog and shows an inline result; Core installation and language-pack downloads still require user action, with no daemon, background installer or notification owner. A current package offline scan, remote check and installed observation remain `NOT_EXERCISED`. |
| J15 | Core upgrade, pack-only update and incompatible downgrade | P, I | Package/registry fixtures require Complete-only registration plus one logout. Core installation never stops the live InputMethodKit Host or calls register/enable/select. Settings compares installed and running version/build/revision. Immediate activation is user initiated; the Host accepts only after Linnet is selected away, no composition or data transaction is active, and the Settings requester remains alive. The 0.1.9 older-Host blocker-wire compatibility test and its 0.1.11 sunset are still being implemented and are not PASS. Release is also blocked until the same existing inactive client applications are proven to stay open and reconnect when Linnet is selected again. Settings launches only the canonical installed bundle and verifies its exact identity. Every artifact still requires installed continuity plus accepted/rejected/race rows; current P/I remain `NOT_EXERCISED`. |
| J16 | default uninstall, retained data, reinstall and explicit purge | P, I | Package fixtures reject exact running Host/Settings processes before mutation, execute no installed App bytes, preserve UserData/Backups/Transactions/preferences by default, reject recursive roots on another filesystem, and remove Registry-owned `Runtime/Logs` through the existing Runtime deletion owner without inferring a system temporary path; exact installed default/purge/reinstall residue evidence remains pending. |
| J17 | keyboard navigation, focus order, labels, VoiceOver and reduced-motion behavior | V, I | pending |
| J18 | cold start, first key, sustained typing, memory, disk and p95/p99 latency | E, P, I | The native runtime gate requires p95 ≤ 5 ms and p99 ≤ 15 ms. The local freeze measured English p95/p99 0.510/0.519 ms and Chinese 1.392/1.423 ms over 8,192 samples, with independent cold-client first keys at 10 ms and 2 ms against the 100 ms limit. Candidate presentation measured 23.73 ms cold and 1.43 ms steady p95. E is passed; signed package size, installed cold start, APFS usage and first-run cache growth remain P/I pending. |
| J19 | empty, loading, download, validation, disk-full, conflict and rollback error states | C, V, I | partial headless coverage; visible recovery audit pending |
| J20 | artifact names, sizes, checksums, notices, SBOM, update URLs and README agree | P, R | The candidate Action accepts one clean exact-main revision, runs its own serial candidate gates, signs once on macOS, and freezes exactly eight verifier-approved Draft Release files. Installation consumes that exact set before any public-channel mutation. Only the SSH control tag binding version, full revision and eight-file set digest may let the Ubuntu publisher route Core/data/Catalog and the unchanged `Linnet.pkg` to public Release / Latest. Candidate Draft bytes and final Release-page evidence remain distinct R rows. |

## Finding ledger

| Status | Priority | Finding | Earliest owner | Required closure |
| --- | --- | --- | --- | --- |
| closed | P0 | An embedded hardened Settings process could pass static code-sign verification but crash while loading the ad-hoc parent `librime` because the nested signature lacked the library-validation entitlement. | Release App nested signing boundary | Release build now signs Settings inside-out and verifies its entitlement, dependency, RPATH and nested signature. Headless gates no longer launch the regular GUI merely to observe two seconds of liveness; real Settings launch remains one installed-product UAT row. |
| evidence-gap | — | Settings has an always-visible local candidate preview that consumes the canonical bundled Squirrel theme source. Component and projection tests pass, but the safe hidden-window attempt produced incomplete pixels and a root-only AX tree, so it is `ENVIRONMENT_INVALID` rather than accepted V evidence. | Settings appearance preview and visible accessibility presentation | inspect all theme/layout/font extremes, unavailable/error states, keyboard traversal and VoiceOver in the controlled App/installed UAT; compare the real candidate renderer with the preview |
| evidence-gap | — | The complete Settings state matrix has no valid current real-window screenshot or accessibility-tree evidence; the rejected offscreen harness rendered blank pixels and a root-only AX tree. | Settings presentation and accessibility contracts | inspect Appearance, Input, Dictionary and Data & Updates in English and Simplified Chinese from the next frozen candidate; include wide two-column and compact stacked layouts, all three download sources and their disabled/error/privacy states, and record hierarchy, copy, focus and controls without counting the invalid offscreen evidence |
| evidence-gap | — | No installed-product evidence exists for input-source discovery, the required six-application focus behavior (Terminal, VS Code, Chrome, Apple Notes, Word and Teams), upgrade, rollback, uninstall or residue. | current-user Installer and InputMethodKit lifecycle | complete one controlled clean-install-to-purge UAT only after every non-install blocker is closed |
| superseded | P0 | At `b5cf850`, Core/manual activation treated Controller teardown as client disconnection, stopped the existing IMKServer while TextEdit PID 20213 retained its old endpoint, and left that TextEdit without Host activation or key events; fresh TextEdit PID 73247 connected to the replacement Host. The later append-only application-history containment avoided that race but made normal updates require quitting every app that had used Linnet. | Core package Host lifecycle | Installer-owned replacement and the process-history containment are both retired. Core installation leaves the Host and TIS state untouched. The explicit Host transition now requires Linnet to be inactive, composition and data mutation to be idle, and the requester to remain alive; it rechecks the same live boundaries before its sole graceful exit. Settings launches and verifies only the canonical installed Host. Focused contract/build evidence must be followed by exact installed TextEdit/Teams/Codex reconnect rows before this candidate is accepted. |
| closed | P1 | At `b5cf850`, Host startup created and immediately destroyed its readiness session without traversing a real candidate query. Once the last client session was gone, a new application's first Chinese lookup paid about 541 ms for dictionary paging, followed by about 149 ms on the first lazy English-dictionary access. | Host runtime readiness and shared Rime resource lifetime | One composition-free session now primes the selected schema's real candidate path and remains owned by the Host process; per-application composition sessions stay independent. The same owner refreshes before stale cleanup, retires before every all-session cleanup, and is restored after user-data sync or configuration reload. The isolated independent-client probe measured 6 ms against a 100 ms contract; installed cold-start evidence remains J18 pending. |
| closed | P0 | At exact `94e7c6f`, Shift down/up on `linnet_zh` changed `ascii_mode` to true while `schema_id` remained `linnet_zh`; Smart English had instead been placed behind a Shift-plus-space binding. The wrong product transition was caused by treating a convenient standard key binding as the user contract. | direct Chinese/Smart-English transition after upstream gesture classification | `ascii_composer` still owns tap/chord/hold and composition commit; one native Rime processor maps only its accepted isolated-Shift result to the other schema. The focused engine probe covers all eight Chinese profiles, default round trip, Shift+letter, held Shift and Caps Lock raw ASCII, while source guards reject the retired chord shortcut and private Swift mode owners |
| closed | P0 | Packaging exact `bb368e1` rejected the Chinese pack before emitting artifacts because the direct-Shift schemas and Glass `squirrel.yaml` changed pack bytes while the release manifest still named the preceding content digests. | `config/linnet-data-releases.json` language-pack identity | At that historical `bb368e1` milestone, Chinese advanced to `0.5.9` / sequence 17, English to `0.4.7` / sequence 12 and the Catalog to sequence 10, each bound to the source inventory digest computed by the existing pack owner. Those values are retained only as the historical rejection closure and are not the current release identity; current identity comes solely from `config/linnet-data-releases.json`. |
| closed | P1 | The Host lifecycle CLI and postinstall treated Installer as the user's Text Input session, enabling repeated stop/register/selection designs to disturb menu state and client connections. | Complete registration and Core package lifecycle | Complete owns the only `TISRegisterInputSource` call. Core and uninstall have no product-process termination owner; the uninstaller executes no installed App bytes, and Core never calls register/enable/select. |
| closed | P0 | During exact `83e7adb` default-uninstall UAT, the old App and generated data were removed but the preserved `linnet_zh.userdb` rotated its LevelDB log and manifest after the uninstaller invoked `--disable-input-source`; the pre-action and post-action byte manifests differed while the already-quiesced Host had no pending user input. | default uninstaller lifecycle sequence | Both the TIS-disable transition and installed Host cleanup commands are retired. The user first selects another input source; exact Host or Settings presence makes uninstall fail closed and instructs logout/retry. Default uninstall preserves UserData, Backups, Transactions and preferences byte-for-byte while removing Registry-owned Runtime logs with Runtime. Purge removes remaining persistent data and preferences; no system temporary path is inferred. Real default/purge rows remain required. |
| closed | P1 | Caps Lock lacked an automated key-event proof across Chinese and Smart English. | input-event engine acceptance | `rime_smoke_test` now proves Caps Lock down/type/up enters and leaves raw ASCII in both schemas; installed Terminal/password-field coverage remains in J05 |
| gate | P1 | Every publication candidate requires a fresh revision-bound Core/complete/uninstaller projection after source, LTS identity or Settings bytes change. | App/Core identity, immutable pack identity and exact Action candidate | before candidate build/sign, require exact current main and let the same candidate job run the serial full gates; then freeze one Action-built eight-file set accepted by `package/verify_publication_artifacts` and staged as Draft Releases. Before pushing its SSH control tag, pass installed Settings/InputMethodKit acceptance on those same bytes. Full `verify_product release`, independent expansion, code-sign policy, checksums, zero build/debug files, Full Active and source-to-packaged-Settings byte parity remain candidate gates. |
| closed | P1 | The former release workflow could publish Core/data and advance the stable Catalog before installed UAT. | single revision + set-digest SSH authorization boundary | the candidate Action can only stage Draft bytes; only the post-UAT local verifier can create the digest-bound tag that starts the Action-owned Core/data/Catalog/public chain without a rebuild |
| closed | P2 | Candidate labels/opacity/radius, fuzzy-pinyin policy, restore defaults and reviewed advanced overrides are not Beta controls. The former design draft over-promised them; font and theme presets are implemented. | typed settings document and deterministic projection renderer | retired controls remain outside the Beta contract; any future addition requires its own typed owner and product evidence |
| closed | P1 | Settings previously shipped partial Traditional-Chinese strings beside otherwise English fallback, and dynamic status classified any Chinese locale as Simplified Chinese. | Settings bundle string catalog and typed presentation locale | Beta now supports exactly English and Simplified Chinese; every entry has reviewed Simplified Chinese, unsupported Chinese scripts uniformly fall back to English, and structural/component gates reject a mixed third locale |
| closed | P1 | Direct Xcode Settings UI tests could register fixture Apps from their temporary DerivedData path and delete the files without retiring those LaunchServices records. | test-owned fixture cleanup | package/install paths retain no private LaunchServices mutation; the UI-test cleanup now unregisters only `.app` bundles discovered below its marker-owned temporary DerivedData root and fails if that exact path remains in the registry. |
| superseded | P2 | The former signed-data path performed verification while the visible state still said “downloading.” | Settings language-data update state machine | the private signature path is retired; Catalog and each downloaded artifact enter the existing typed “verifying” state before container/manifest verification, while cancellation and activation owners are unchanged |
| closed | P1 | Language-data downloads were hard-coded to GitHub, leaving users on constrained networks without an explicit route choice. | Settings-only pack route | the current typed owner defines GitHub direct as default, the built-in [GH-Proxy public mirror](https://gh-proxy.com/) (third-party), and one advanced user-entered compatible HTTPS mirror for pack bytes. Catalog retrieval remains direct and canonical; invalid or retired preferences fail closed, no automatic fallback exists, and the Catalog/Registry owners are unchanged. Mirrors can observe IP, request time and public pack URLs, while Linnet sends no personal dictionaries, learning data or credentials. Source/component evidence is current; package, real-network, visible and installed evidence remain in J13/J14 and the open V/UAT rows. |
| closed | P1 | The former two-profile Chinese ranking gate left six double-pinyin layouts with representative smoke only. | Chinese Golden corpus/profile projection | one reviewed fixture now covers all eight profiles with the same 215 canonical cases plus seven profile/learning boundaries; the runtime gate requires all 1,776 probes to pass |
| closed | P0 | The Golden runner linked its deploy tree from ignored `data/plum/default.yaml` while the shipped owner was tracked `data/linnet/default.yaml`; its hard-coded profile list let a local staged default and the committed product projection diverge without failing the gate. | tracked `data/linnet/default.yaml`, tracked schema files and the isolated Golden deployment | the Golden runner now derives exactly eight formal Chinese profiles from the tracked default, copies the tracked default and schemas into its isolated shared tree, and verifies every deployed reverse-lookup pattern/prefix against that owner. Ignored Plum staging may provide generated dictionaries and grammar, but no longer owns schema selection or Settings defaults. |
| closed | P1 | `tests/fixtures/linnet_zh_pipe.custom.yaml` silently patched two deployed schemas to `|`, so the focused run could report pipe behavior even when the canonical default projection had not produced it. | Settings document projection plus tracked Rime default | the test-only patch is deleted. Golden verifies the deployed canonical projection directly; the native profile matrix obtains the default trigger through the real Settings renderer rather than a fixture that changes product behavior. |
| closed | P0 | After the fixture was removed, the native profile matrix still encoded all eight formal profiles with custom `;` and only one Microsoft cross-case with `|`—the exact reverse of the product contract that defaults every profile to `|` and offers `;` as an explicit option. | exact orthogonal profile/trigger matrix | all eight formal rows now exercise the default `|`; one additional Microsoft row exercises explicit `;`, including its internal-semicolon spelling. The orchestration gate locks that exact nine-row matrix and forbids restoration of the trigger/profile Cartesian product. Earlier Golden/Rime green runs remain historical evidence for their recorded revisions; current exact serial execution and installed key handling remain pending. |
| closed | P1 | Settings inferred online-update availability from local Active data and an embedded public key, so a missing stable Catalog looked actionable. | stable same-repository Catalog and Settings verification boundary | the verified stable Catalog is the one publication owner. The explicit `catalog` stage verifies Core/data and writes that exact Catalog to the stable branch; Settings consumes the verified Catalog/Core/data availability result, while Registry validates manifests and files before activation. Remote and visible evidence remain in the open P/V/UAT rows. |
| closed | P1 | When Active data could not be decoded, the data screen displayed both “Recommended” and “Installation needs repair.” | Settings runtime snapshot projection | `dataEdition` is now absent when the authoritative snapshot is absent; Data displays “Unavailable,” and long-tail management remains disabled until the installation is repaired. |
| closed | P0 | The first registration repair on top of `e6f5da1` made Core preinstall invoke the installed Host with a new `--inspect-input-source-registration` option. Exact public `755f696` (0.1.9 build 68) and historical `3a48e48` (0.1.10 build 27) do not implement that option; their default path enters `app.run()`, so a routine cross-version preinstall could wait on the long-lived InputMethodKit Host. | package-owned pre-payload registration inspector | Core now executes only the package's arm64, macOS-13-compatible read-only inspector. One shared `LinnetInputSourceRegistration` owner classifies missing/registered/duplicate/conflict/unknown states; `Main` exposes no inspection CLI, and the package lifecycle test locks both exact old-Host contracts and proves preinstall never invokes them. Package-byte verification remains required for the frozen candidate. |
| closed | P0 | At the `e6f5da1` audit base, Core treated a missing App as an in-place repair while Complete rejected an absent App whenever safe owned Active/state residue remained; neither path could authoritatively repair a supported missing-App or missing-registration installation. | Complete registration and repair boundary plus package-owned read-only TIS classification | Core accepts only a supported App identity with one exact source/bundle match; a missing App or registration fails before mutation and directs the user to Complete. Complete accepts a clean absent App or supported signed App only when Active/state links are safe and registration is missing or one exact match; duplicate/conflict/unknown TIS state and unsafe residue fail closed to the official uninstaller. Complete postinstall retains the sole registration mutation; the count-only interpretation and `missing-app-install` Core transition are retired. Exact installed repair rows remain pending. |
| closed | P1 | At the same audit base, Core preinstall invoked a JXA `osascript` quiescer because package code treated Settings process exit as a custom pre-payload action; this caused recurring system authorization prompts and made updates affect user applications. | Core pre-payload validation | the JXA file, copy/verification paths and all Core `osascript` calls are deleted. Custom Core code changes no process or TIS state; Apple Installer retains only its declared Settings `must-close` while replacing that embedded App. Application continuity is accepted only by installed UAT. |
| closed | P1 | App `CURRENT_PROJECT_VERSION` was classified as a language-pack source, so every Core build forced pack metadata/Catalog movement even when the four pack bytes were unchanged. | App/Core identity, per-pack metadata and `data-channel` Catalog commit/blob | App build no longer enters pack source-change detection. Data Release contains four immutable packs and can be reused by exact bytes across revisions; the raw candidate Catalog is a Core asset, and same-sequence promotion may change only its Core projection. |
| closed | P1 | Removing `digit_separators` was initially classified as disabling numeric punctuation, but librime supplies an implicit `.:` default; the focused engine path changed `3.14` to `31.4`. | deployed Rime punctuator configuration | one explicit empty `digit_separators` value disables the upstream default, while `digit_separator_action` and half-shape ownership of `/ , . : ; ' [ ] - =` are retired. The eight-profile matrix separates idle host keys, scheme spelling keys, active host punctuation and candidate paging. |
| closed | P1 | The rime-ice build projection admitted `best_guess` readings and calibrated all accepted rows without proving they could not outrank the Wanxiang core for the same code. | verified-only rime-ice build projection plus reviewed Linnet ledger | inferred/ambiguous/unverified and Wanxiang-owned rows are excluded; same-code weights remain below the Wanxiang maximum; length/frequency strata and reviewed exceptions are source-gated. “希尔瓦娜斯” is one regression row, not a one-off runtime patch. |
| closed | P1 | Candidate layout independently let long English details own width/height, and Settings retained five pages, duplicated activation buttons and page-mark helpers; these paths produced oversized panels, blank tails, hidden update actions and slow maintenance. | CandidateDetailGeometry and four-page Settings presentation contract | This closed row covers only candidate detail geometry, the four-page adaptive Settings hierarchy and its stable activation button: horizontal detail adds height but never width; vertical detail is 104–136 pt and clipped to candidate-owned height; POS groups wrap; dead ABC/mark and duplicate pack-label paths are deleted. Foreground ordering, minimized reopen, cross-Space behavior and real-window V evidence remain open under J10. |
| installed UAT pending | P1 | On 2026-08-30, installed revision `50348c7` showed blank highlights and candidate/definition overlap for `ok`, `ni` backspaced to `n`, and `niu`. Full-content rendering reproduced the failure: AppKit automatically shrank the candidate NSTextView to 30 pt at the bottom of a taller footer panel, while the highlight retained panel-owned top coordinates. Earlier component renders omitted the sibling text views. | SquirrelPanel frame assignment via CandidateDetailGeometry; SquirrelView disables NSTextView automatic height fitting | Competing frame owners drop from two to one; both candidate and detail surfaces retain their assigned frames, without word-specific offsets or new layout paths. The same red-to-green regression now renders the entire panel and compares every glyph with its hit/highlight cell and definition region. Component coverage includes edit/backspace/detail-removal transitions at 12/15/16/32 pt and the existing seven-theme Light/Dark horizontal/vertical matrix. This is component evidence, not installed visual acceptance. |
| component verified; installed UAT pending | P2 | On 2026-08-30 at `ab75439` plus the theme/update patch, Settings represented themes with tiny capsules; Moon and Slate also shared nearly identical visual structures. The actual-component OCR regression found zero candidate samples before the fix and all fourteen afterward at 680/900 pt in Aqua/Dark Aqua. | bundled Catalog → AppearancePreview candidate renderer → full preview and theme cards | The separate card selection renderer and capsule are retired: selection-rendering paths drop from two to one; palette authority stays one. Paper now uses amber underlines, Moon jade bars, and Slate opaque blue square tiles, all in the canonical YAML with existing theme IDs. No fallback, compatibility branch, per-theme geometry engine or input behavior was added. Contrast and structural distinction tests pass; component images were visually inspected, not claimed as installed Settings acceptance. |
| component verified; installed UAT pending | P1 | The same audit's installed screenshot advertised Chinese 32→31, English 21→20 and Extended 7→6 as updates. Catalog availability interpreted immutable-content inequality as an upgrade, while Registry rejected regressions only after downloading. | ActivationSet.updateSelection → Catalog availability and Registry download admission | The independent inequality inference is retired. One typed selector classifies exact, newer, locally ahead and same-sequence conflict for the whole atomic set; mixed upgrades/downgrades are not offered. Both consumers use that result. The existing final guard still protects staged-byte identity and Active-revision changes across the download boundary; it is not a second notification owner. Regression tests cover Standard/Full, missing/current/newer/ahead/mixed/conflicting packs and reject an old pack in a newer Catalog before creating a transaction/download directory. No wire-format, pack identity, recovery path or automatic download was added. |
| closed | P2 | A 131-entry SwiftLint baseline and path-rewrite script reported stale debt despite the same sources producing zero violations without the baseline; CI also repeated checkout, hydrate and build across quality/App/Swift/Rime runners. | strict lint and one serial macOS CI chain | the baseline and rewrite path are deleted, warnings are errors, Periphery uses one pinned cached binary, and commit/PR/candidate workflows each have one deterministic macOS product chain. `tests/swift_test_cache.sh` remains the only Swift compile/cache owner. No cloud speed claim exists until an actual run is measured. |
| component and App gate verified; installed UAT pending | P1 | On 2026-08-30 at `ab75439` plus the authorized Core-theme migration, Host lacked the UI resource and Registry rejected valid theme-free packs as `incompleteActiveView("squirrel.yaml")`. The legacy split made Core-only updates change previews but not actual panels. | `data/squirrel.yaml` → Core Host/Settings resources; ProjectionRenderer → Rime configuration compiler → panel | Publication owners 2→1 (Core); Rime loader/compiler and user-choice owner unchanged. New pack staging omits UI; existing immutable packs remain accepted. Before Rime initialization, Core projects its base configuration and invalidates only changed compiled UI output, including same-second/same-config-version updates. Identical bytes are not rewritten. Existing file checks protect the local cache-write boundary; manifest checks still protect immutable data, not theme choice. No registration, process restart, private catalog, fallback or new production file is added. The real-Rime fixture proves legacy/theme-free packs, continuous Core updates and retained user theme/32pt choice; the full App gate proves both bundled resources and package source hashes. Chinese 34 removes the old UI payload and requires Core 0.1.10; English/LTS/Extended hashes are unchanged. This one-time pack migration does not make later theme changes advance data identities. Installed acceptance remains pending; desktop automation returned a closed native pipe and is not reported as visual PASS. |
| gate | P0 | Source/package tests cannot prove that every already-running application's IMK client reconnects after a user-initiated Host activation; previous TextEdit failures show that one fresh-app success is not equivalent evidence. | exact installed Host activation workflow | before release, keep TextEdit, Teams, Codex, Chrome, Notes, Word, Terminal and VS Code open across the same candidate activation and prove input before/after without quitting or relaunching them. Any failed existing process blocks publication; no application-specific reconnect, kill or state-guessing patch is allowed. |

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

The macOS candidate Action assembles all eight product assets from the clean
exact-main checkout and signs exactly once; the eight-file set digest and
per-file hashes identify the only installable candidate. Installation acceptance
downloads and records those same Draft Release identities but does not itself
authorize publication. The maintainer then runs
`scripts/release-control authorize /absolute/release-directory`; its one
non-force SSH tag binds version, revision and set digest. The Ubuntu publisher
revalidates the tag and GitHub asset metadata, downloads only the Catalog,
advances the stable Catalog and publishes the already-staged Core/data/public
Releases.
An existing data or Core release must
be a prerelease with the same verified bytes; an existing stable product release
must retain the exact verified asset set. Any extra or differing asset is a hard
failure, while a byte-identical planned subset is the only retry state.

Until the remaining rows are complete, lower-class component evidence must not
be reported as installed-product acceptance.
