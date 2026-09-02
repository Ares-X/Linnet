# Linnet product acceptance

## 2026-09-02 Complete transport input-source identity (candidate)

Exact rejected installed candidate: version `0.1.11`, build `77`, source
`644530f938bcc64c5af3bf1501e7c3f36b04aa78`. At 01:43:59 +08, native
PackageKit classified the temporary Complete payload at
`~/Library/Application Support/Linnet/.linnet-complete/App/Linnet.app` as the
production parent bundle and reported that it would be atomically shoved. At
01:44:02 it touched that App and its Settings bundle after postinstall had
already published the bytes and removed the temporary path; Installer then
failed to resolve both deleted bundle URLs. The permanent App itself remained
valid, but macOS no longer offered Linnet in the input menu until the next real
login. The first wrong owner was the Complete payload and PackageInfo bundle
mapping, not Rime, the Host connection name, TIS observation, or Core update.

Build `78` makes Complete transport the signed App bytes as an opaque
`Linnet.payload` directory with zero PackageKit bundle, upgrade, strict or
Distribution mappings. Postinstall remains the only publication owner and
exchanges only the permanent App's `Contents`, preserving the registered App
directory and system authorization. The old component plist is deleted. Input
source identities remain 1→1; temporary discoverable App identities and bundle
mapping owners go 1→0; registration and enablement mutation paths remain one
first-install-only path and zero update paths. No fallback registration,
LaunchServices cleanup, application restart or logout-based repair is added.

Focused PackageInfo, lifecycle, DirectoryDelta and publication-owner tests,
the complete Swift/App/Rime gates, strict lint and Periphery pass on the source
candidate. The eight schema matrix passes 1,776 candidate cases. The native
incremental-sync probe passes 8,819 input samples with sync-step p99 0.344 ms
and input p99 1.604 ms, without entering input maintenance. Exact clean package
construction, native Complete upgrade, absence of PackageKit bundle discovery,
menu continuity, multi-application typing, data update and public-byte
publication remain `NOT_EXERCISED` until the clean candidate is built and
installed below.

## 2026-09-01 community installer identity recovery (in progress)

Exact rejected local candidate: source `77687efc8c186681a089661bc87da4f79b2a640d`.
Its Complete preinstall classified the installed App as an invalid code signature
while the fixed maintainer Keychain was locked. The same App bytes passed strict
verification immediately after that Keychain alone was unlocked. The first wrong
owner was `candidate-app-identity.sh`: it used system-trust-dependent
`codesign --verify --deep --strict` in the ordinary user installation boundary.
For this manual-trust distribution, that result describes the current trust-store
state, not whether the packaged App bytes are corrupt.

The correction keeps strict CMS-chain and nested-code verification in the build,
staging and publication owners. Installer identity now uses the fixed designated
requirement plus release metadata; Core retains its exact published delta baseline,
and both Core and Complete require the installed/staged App to match the packaged
target tree SHA-256 before success. Certificate extraction, temporary identity
directories and the user trust-store verification path are retired. Authoritative
installation identity paths remain 1→1; trust-store inference and temporary
certificate extraction each go 1→0. No input-source registration, Host lifecycle,
user application or language-data owner changes.

Focused package-lifecycle fixtures pass, including exact target acceptance and
tampered-target rejection. The obsolete package built from `77687ef` remains
rejected and must not be installed. A clean new revision still requires package
architecture/composite gates, a locked-Keychain real preflight, exact Complete
installation, read-only identity/runtime checks, and user-confirmed menu and real
input before this row or the release can be accepted.

## 2026-09-01 Installer receipt migration (in progress)

Exact rejected candidate: `6bd253c90c99f54ef49803375169a42aefcca0b5`, Core
SHA-256 `a884a518a976834d5909a7b9c1fc763c5cf517af71538fb93724c35513bcd360`.
At 2026-08-31 23:58:09 +08, native PackageKit selected receipt-based obsoleting
for the shipped `Linnet.core.pkg` receipt, whose 0.1.10 BOM owns the live App.
The new scripts-only component reused that receipt. Preinstall passed; at
23:58:12 PackageKit removed the omitted App payload, before postinstall could
apply its delta. Postinstall rejected the absent App at 23:58:13. The first
wrong owner is package receipt identity, not delta reconstruction or TIS.
The private native Installer regression repeats this deletion without touching
the product installation. Script fixtures and archive expansion did not exercise
PackageKit receipt migration and cannot count as installed acceptance.

Recovery restored the already verified public 0.1.10 App from its immutable
baseline (tree `414b00491ebb8c1b1741c94f86defa1094309a1de744833577de377458c7dd96`).
The original Complete postinstall repair entry then reported the source already
registered. Runtime stayed healthy; activation SHA-256
`336602598224759103e7eac5d8da4543a373fd0ded35efe5ba364efc22ae1b7b`, Host PID 83075
and Settings PID 84783 remained unchanged. No application was closed, no Host
restart or manual input-source activation was performed. Public 0.1.11 remains
blocked; the rejected Draft must never be promoted.

Frozen correction: five production files (`make_package`, both Distribution
templates, `verify_package`, `uninstall-linnet`), under 150 non-mechanical lines,
one correction followed by native receipt, package/lifecycle and exact installed
acceptance. No App, Rime, data sequence, signing credential or input-source
changes. Existing `release/0.1.11` remains the implementation branch.

Authority/subtraction ledger: PackageKit may deliver only scripts or hidden
Complete staging; the existing postinstall transaction alone publishes live
App/data. Competing live-payload mutation paths go 2→1. The six legacy payload
receipts retire from all builders; seven stable, disjoint update/staging receipts
describe their actual payload locations (Core update and Complete are different
operations). Legacy IDs remain only in uninstaller cleanup for shipped installs,
never as installation or Runtime authority. The pack-ID-from-receipt inference
goes 1→0; the verified pack manifest remains authoritative. The obsolete
must-close-template/removal path goes 1→0. No wrappers, fallback, runtime
compatibility branch or second mutation lease is added. Retained checks protect
distinct boundaries: package metadata, signed target bytes, atomic publication,
and native PackageKit execution. The native matrix covers legacy→delta,
delta reinstall, legacy→Complete staging, Complete→delta and Complete reinstall;
real product activation/input still requires fresh user acceptance.

Focused evidence: the native regression first failed with `PackageKit deleted
live payload: core`; the same matrix passed after receipt separation, including
Complete reinstall after its staging directory had been consumed. Existing
package architecture and lifecycle fixtures passed. The bounded read-only
review found no P0/P1 source defect; actual corrected-package installation and
real input remain NOT_EXERCISED. Removing the previous template close mapping
also retired its old characterization test; the governing assertion now rejects
must-close in both Core and Complete rather than requiring and then stripping it.

## 2026-08-31 post-release repair candidate (in progress)

Historical repair baseline: `05dce7b`; the latest delivery freeze below uses
`c53df52` plus the working candidate. These records do not supersede published
`0.1.10` acceptance. The later user decisions authorize local verification,
remote publication and installed acceptance, including Chinese-first ordering
before ambiguous English corrections. They do not authorize input-source
re-registration. Smart English correction/fuzzy matching remains a core
capability, not a switch.

2026-08-31 live-sync repair, base `05dce7b` plus the accepted uncommitted
post-release candidate: the hourly main-run-loop callback enters
`performRimeUserDataSync -> sync_user_data -> CleanupAllSessions / StartMaintenance`
and then joins that worker. The first wrong owner transition is treating a
learning merge as input-runtime maintenance; moving only the join off-thread
would leave input unavailable. This repair replaces that runtime path, not the
Rime merge rule or the hourly schedule. Cloud I/O must stay off the input thread,
active database work must yield in bounded slices, and reversible learning must
not be committed or aborted by synchronization. Live sessions and the input gate
must remain unchanged throughout success, failure, cancellation and offline retry.

Scope: the existing pinned librime interaction patch and its digest, the Host's
sync call, and its existing scheduler (no new dependency version, daemon,
registration, application restart or merge implementation). One sync scheduler
and one Rime merge authority remain one each; the maintenance/join input path
goes from one to zero. Work is bounded to eight tracked production paths and
about 500 non-mechanical lines before redesign. Reuse `UserDbMerger` and the
upstream snapshot format; retain the transaction boundary for reversible local
learning, cancellation at the runtime lifetime boundary, and atomic cloud-file
publication. Acceptance requires a RED/ GREEN live-session regression, slow-sync
concurrent typing, merge/undo/clock/cancel checks and the integrated local gates.
Installed IMK behavior is not established by native or scheduler fixtures.

Final-review correction freeze: a sync step must only borrow a naturally loaded
Db, never open or retain it across input callbacks. Cold dictionaries are
explicitly deferred until naturally used; one cold dictionary must not prevent
other active dictionaries from syncing. Export uses the Db's actual write
generation (including deletion, not the learning clock) to reject a snapshot
changed between slices. A source merge retains its original local learning
clock across slices while never lowering the current durable clock. Every
batch aborts on exceptions. One background worker owns snapshot destruction as
well as file I/O until cancellation/publication is acknowledged. The obsolete
Swift installation-file projection is deleted, not protected by another lock.

Focused evidence on 2026-08-31, native patch SHA-256
`c3c184fefeb0d2dc50a466ea4b060f8227b9746edb83cb6fc80ce3c65ccc316c`:
the original offline API failed the live-session invariant; an early sliced
candidate failed 65/129 pre-existing-word comparisons against one real upstream
merge. Both regressions now pass. `--live-sync-probe` passed 1,116 continuous
Chinese/English input samples, 4,096 imported rows, all 129 reference rows,
pending-learning rollback, learning-clock increments, unchanged-file identity,
cold-Db deferral/natural activation, injected second-write exception rollback,
malformed-file rejection and cancellation. Step p99 was 0.157 ms, maximum
0.817 ms; paired-key p99 was 1.251 ms (`build/live-sync-native.x9b8oT`). The
Swift scheduler suite passed slow configuration I/O, cancellation, unchanged
installation bytes, hourly limits and deferred scheduling. Final source review
closed the five identified boundaries above. These are component/isolated-engine
results; only a fresh complete source receipt can establish composite acceptance,
and neither establishes installed IMK or two-Mac iCloud transport acceptance.

Sync subtraction: merge authority and Db pool remain 1→1; automatic maintenance
and joins, cold-Db open paths, cross-callback live-Db retention, and Swift
installation writes are each 1→0. The LevelDb write-generation owner is a new
single provider fact for export consistency, not a second learning clock.

Pre-install review on 2026-08-31 blocks the previously verified source tree
`f9e77ffd0ce02b80b1c632c485b9468b5494b1ab` from installation. A real native RED
cancelled after 64 committed merge rows: both retry with the Db still loaded and
retry after natural close/reopen changed 65/129 reference rows from `d=5` to
`d=1`. The earliest wrong owner is the merge clock: the database tick was already
advanced, but cancellation discarded its original in-memory baseline. A second
RED published a 17,832,937-byte snapshot successfully, overwrote the old readable
snapshot, then rejected its own output on the next read (16 MiB reader limit).
The source receipt above proves its recorded suites, not these newly added rows.

The proposed per-peer clock marker was rejected before production edits: if B
merges before interrupted A resumes, B can already destroy the unprocessed local
weights using the raised clock. A later restoration of A's baseline is too late.
Thus recovery needs a Db-wide unfinished-merge order and stable resumable input,
including source changes/disappearance; a RAM marker or peer-keyed clock is not
a complete fix. This is a native transaction redesign boundary, not permission
to add another Swift compensation or restart. No implementation of that redesign
has been accepted yet. The size correction belongs in the existing worker:
apply the reader's exact serialized-size limit before cloud rename and preserve
the last readable snapshot on failure. Both real regressions must turn GREEN
before a new complete source receipt, commit or local install.

2026-08-31 authorized recovery redesign (same `05dce7b` dirty candidate):
the user authorized completing the native transaction repair before commit and
Core installation. The full state map is read -> stage -> activate -> materialize
-> complete. Stage holds only incoming records in a private namespace of the
existing LevelDb, with no live-record or learning-clock change. One small atomic
activation freezes the local/remote clocks and makes the original `UserDbMerger`
result visible. Existing Fetch/range accessors read this single logical view,
including remote-only keys. Physical materialization does not change that view.
User learning/deletion writes and consumes the corresponding pending record in
the same existing undo transaction. Cancellation drops incomplete staging or
leaves an activated transaction recoverable from the Db; source replacement,
disappearance and a different peer cannot replace its frozen input. No sidecar,
second Db, full local backup, background live-Db owner, or new merge formula.

Recovery authority/subtraction ledger: merge formula remains 1->1 (extract the
existing calculation, delete its old inline body); record-read authority remains
1->1 (upgrade the existing LevelDb Fetch/accessor, no outer wrapper); unfinished
merge authority moves RAM-only 1->0, durable Db transaction 0->1. Original clock
and pending remote rows form one native transaction, not independent clock
fallbacks. Sync's batch writer is replaced, not retained alongside the new path.
The existing local undo transaction, bounded input-thread work, worker-owned
cloud I/O and atomic cloud rename protect distinct mutation/time boundaries.
Serialized output must satisfy the same 16 MiB limit as input before rename.

Allowed implementation: native LevelDb, UserDbMerger and incremental manager in
the existing patch, its lock digest, focused native regressions and this ledger;
at most eight native production files/about 500 non-mechanical added lines and
three hours, with two corrective loops before another design review. No changes
to English/Chinese ranking policy, registration, user applications, or release
public versions. Internal build becomes 70 for the new durable merge capability;
the existing installer downgrade check then rejects old build-69 packages. There
is no automatic old-Core fallback. Manually replacing the App or opening an
active redo with an older native tool is not a supported rollback; restore/use
the same-capability Core so it can materialize that transaction first. Required
rows: staging/active cancellation, close/reopen, changed or
absent source, peer ordering, lookup of new keys, learning/deletion/undo before
materialization, failure rollback, unchanged cloud files, oversized output and
continuous input latency. Then one exact local composite/receipt, bounded final
review, commit, fixed-identity Core archive and typed installed activation.

Review keeps upstream's buffered-transaction visibility: reads do not expose
uncommitted WriteBatch writes. The acceptance oracle is the real uninterrupted
merger plus the same UserDictionary/Commit/Abort operations, not a new
read-your-writes isolation contract or a second transaction-value cache.

Recovery correction 1, 2026-08-31 14:49, native patch `1fbdaa60`: the first
two sync cycles finished in 2.536/5.864 seconds; the third exceeded the unchanged
20-second fixture deadline with 673 pending records. Process 59589 sampling
placed 947 main-thread samples in candidate lookup's pending LevelDb iterator
seek, scanning materialized-record tombstones. The earliest wrong boundary is
the redo range: after materializing a prefix, readers still seek from its old
start. Persist the monotonic remaining-range cursor in the same transaction as
materialization; both the existing accessor and drain start there. Cancellation
and reopen read that same cursor. This adds one progress fact to the existing
transaction, not a cache or another Db owner; consolidate the three journal
state writers into one. No forced compaction, retained live iterator, relaxed
deadline, or input/application restart is permitted.

Focused GREEN, 2026-08-31, patch SHA-256
`a3032c77a784260b1dc0ac44f4414a49861e2395aef0dc809b43683b72d7cbb1`:
`tests/verify_rime_runtime.sh --live-sync-probe` passed against the rebuilt
native library (`build/linnet-live-sync-cursor-green.log`). All 4,225 records
were visible as one uninterrupted merge at activation. Staging cancellation,
active cancellation, close/reopen, missing/replaced sources, interleaved peers,
learning/deletion/undo after partial materialization, quoted/Unicode cursors,
fault rollback and oversized-output preservation passed. The previously
timed-out repeated cycle finished in 3.371 seconds. Across 8,794 typing cycles,
all-key p95/p99 were 0.924/1.138 ms; sync-step p99 was 0.398 ms, observed maximum
7.336 ms. The fixture's 20-second deadline and input-latency limits were not
relaxed. This is isolated-engine/component evidence, not installed IMK or
second-Mac iCloud acceptance.

New user requirement, 2026-08-31: normal Core installation, backups and language
updates must become genuine differential operations. Core/whole-pack selection
does not satisfy file/block delta. Installation is paused while this additional
contract is designed; current source does not claim these three paths are
already differential. First installation or an explicitly requested repair may
need a complete baseline; normal updates must not silently fall back to full
copies/downloads. An isolated system-tool probe verified APFS `fclonefileat`
plus `/usr/bin/rsync` protocol-29 batch generation/replay: a 4 MiB binary with a
64-byte edit plus file addition/deletion produced a 10,530-byte batch and an
exact reconstructed tree without modifying its base. This establishes local
mechanism feasibility, not product-format, cross-macOS, install or backup
acceptance. No new dependency or resident updater was installed.

### Differential delivery design freeze — 2026-08-31

User decisions confirmed on 2026-08-31, source `c53df52`: in Chinese schemas,
same-span Chinese candidates precede English spelling corrections; exact English
matches retain the accepted bilingual ranking. Smart English continues to offer
correction. Normal updates remain differential. Missing/damaged bases may offer
an explicit complete repair, but cannot trigger it automatically. An attempted
delta failure preserves the installed state and requires a new confirmation
before any complete repair. The user has authorized local verification, remote
publication and installed acceptance; the earlier no-Actions pause does not
authorize skipping the local gate.

The first differential release uses the exact published `v0.1.10` Complete bytes
as its named release baseline, with the release asset SHA-256 and fixed CMS leaf
verified before extraction. Older/locally modified installations are not claimed
as that baseline: they keep their App and receive the explicit repair route.
Complete repair reuses the replacement owner and does not re-register an already
registered input source. Published language containers stay readable by old
clients; optional Catalog delta descriptors add transport identities only.
New clients reuse unchanged packs, choose an exact installed base for changed
packs, and require confirmation before complete changed-pack repair. There is no
silent retry against a full asset after a failed delta.

The bounded implementation scopes are native ranking (one production owner),
Core installer/package (at most eight files), backup/archive (at most eight),
Catalog-to-Registry transport (at most eight), and the existing release publisher
chain (at most eight). Compiler source lists are mechanical. Each scope retains
its existing transaction, verification and publication owner, approximately 500
non-mechanical lines/three hours and at most two correction loops. The scopes
close together against one exact local composite; none is a separate release.
For existing decisions authoritative paths and pass-through hops remain flat.
The new directory-delta format has one decoder, and cloud recovery has one
archive/history owner; neither can bypass the existing portable import or pack
verification boundary. Full changed-pack downloads and whole cloud-archive
replacement are retired as normal-update paths and retained only as explicitly
named first-baseline/repair or portable-export contracts.

Baseline `61ed072` contains the preceding repairs. Its exact source tree
`b2fea6f041b4e4c5d1e9f858f74a12dbe11de1cd` passed `verify-local` (app, strict
lint, Swift, Rime/eight profiles, package-owner fixtures and Periphery).
Settings desktop UI and installed IMK remain NOT_EXERCISED. That receipt does
not cover this additional delivery migration, and no full Core installation
has been performed to bypass the new requirement.

The deliverable is one locally installed differential candidate, not merely a
new archive tool. Trace Core build/package -> package-owned preflight -> staged
reconstruction -> existing CMS identity -> atomic directory exchange -> typed
Host activation; trace Catalog -> existing downloader -> Registry staging ->
existing exhaustive pack verification -> atomic language activation. Keep
Complete as the explicit initial-baseline/repair owner, never an automatic
fallback from failed Core or pack deltas. A no-op reinstall verifies the exact
target and performs no replacement. Absent/mismatched bases, corrupt deltas,
unsupported clone filesystems and failed target validation leave the original
untouched; failed post-exchange validation restores the verified previous tree.

Reuse system rsync protocol-29 batch generation/replay and APFS clonefile, not
a new diff algorithm, download daemon or package manager. A single bounded
directory-delta boundary owns base/target tree hashes and batch framing. The
existing CLI creates it; Core scripts and Registry consume it. Generation must
receive explicit verified baseline bytes, not rebuild an old signed App or
infer a baseline from a version string. A single-base local package does not
prove multi-version public update coverage; public delivery additionally needs
explicit supported baselines and every delta in the publication hash manifest.

Local backup uses independent COW snapshots of stable files and the two closed
native learning databases. Retire the normal mutation path's TSV export/import
round trip: it cannot preserve dynamic weights, clocks or negative commits.
The Host's existing pause acknowledgement must precede cloning; Backups and
Transactions must share the live volume. Preserve v2/v3 backup restore and the
explicit portable import/export codec as shipped external contracts, not as a
fallback for normal v4 snapshots. Only selected imported/cleared languages are
replaced; other original databases remain intact. Identical settings/personal
file bytes must not be rewritten. Deleting an older snapshot must not invalidate
a newer snapshot. COW proves local write/storage incrementality, not iCloud
network delta; the manual cloud backup producer must be migrated separately
before the whole backup requirement can be called complete.

| Decision | Before -> after authoritative paths | Retired path / retained boundary |
| --- | --- | --- |
| Normal Core replacement | 1 -> 1 | full App payload -> validated delta + atomic swap; existing preflight/CMS and typed activation retain different install/runtime boundaries |
| Tree reconstruction | 0 -> 1 new transport contract | rsync batch with exact base/target, no alternate decoder or full-copy fallback |
| Local backup | 1 -> 1 | streaming full copies and local TSV round trip -> direct COW; manifest publication, closed-Db pause, restore and retention remain distinct boundaries |
| Settings/personal writes | 1 -> 1 | same-byte replacement -> no-op in the existing writers |
| Installed language update | 1 -> 1 | full changed-pack download -> base-bound delta; first missing pack still needs its baseline |
| Catalog pack identity | 1 -> 1 | delta transport metadata must not change pack sequence/content identity |
| Cloud backup | 1 -> 1, component verified | whole portable JSON replacement retired; immutable base/delta/head archive, explicit repair, no automatic full backup |

Differential permission regression, 2026-08-31, `c53df52` working candidate:
the canonical Registry's immutable 0444 pack reconstructed correct content but
failed exact target identity because `--inplace` kept staging's temporary 0644
mode. The same RED/GREEN test now preserves cloned file modes and uses rsync's
temporary-file replacement, deleting the extra chmod interpretation. The pack
suite passes changed/unchanged read-only files, nested 0555 directories,
add/delete/link, base isolation, rollback and corrupt-delta rejection; a 4 MiB
file with a 64-byte edit produces a 10,932-byte delta. This is component evidence,
not installed acceptance or cross-version rsync proof. Network transfer remains
block-differential; changed files require full temporary-file space locally,
while unchanged files retain their COW blocks.

Cross-implementation component evidence on the same working candidate:
official rsync 2.6.9 source built locally on macOS 26 and the system openrsync
both replayed the other's protocol-29 batch. Exact mode/type/link/content checks
passed for changed and unchanged 0444 files, nested 0555 directories, added and
removed files. Log SHA-256:
`be052d1a5f5614ec20dc9592b6703918a41b9807b6a98f4a8520c1c58462ad0c`.
The old sender emitted `select exception ... 0` diagnostics but returned zero;
the strict replay checks passed. This does not claim a physical macOS 13 or
Action run. No dependency lock or system installation was changed.

Each owner migration is bounded to at most eight non-mechanical production
files/about 500 lines and three hours, two corrective loops. Shared compiler
source-list wiring is mechanical and cannot introduce another cache owner.
Main owns the directory transport, CLI and build wiring; the backup and package
owners have disjoint file scopes. No edits to the accepted native patch,
upstream pins, TIS state, user applications, external releases or credentials.
Overlapping tests run serially. Require RED/ GREEN owner regressions, COW
base-isolation, raw learning-state fidelity, delta size and exact reconstruction,
add/delete/symlink and corruption/wrong-base/no-op/rollback rows, old backup
restore, then the exact local composite and installed workflow. Actual remote
transfer, second-Mac restore and unsupported-version cross-products remain
NOT_EXERCISED until explicitly run; no source fixture can promote them to PASS.

Working-candidate evidence on 2026-08-31 (base `c53df52`, uncommitted migration):
DirectoryDelta and Registry owner tests pass, including a 4 MiB file with a
64-byte edit reconstructed from a 10,865-byte delta, add/delete/relative links,
COW base isolation, corruption rejection and atomic rollback. The first failed
cloud replay was traced to `/var` versus `/private/var` relative inventories;
POSIX canonicalization fixes that owner, and the same alias regression passes.
Settings administrative `State` alone now remains a missing installation;
partial Data/Runtime still fails instead of being treated as a fresh baseline.

Backup-store (14s), coordinator (97s), presentation, package lifecycle and
package architecture focused gates pass. Manual cloud fixtures cover no-op,
delta-only continuation, reconstruction, an older verified head after damage,
and explicit full repair when the chain is unusable. These are temporary local
fixtures, not actual iCloud or installed IMK acceptance. No source receipt or
release claim is issued until the final combined candidate passes the complete
local gate and exact installation workflow.

### Native learning-data upgrade handoff — 2026-08-31

Final cross-review, 2026-08-31, same working candidate: the MainActor Settings
initializer/toggle directly called the cloud filesystem provider, so those
calls executed on the UI executor instead of the existing data coordinator.
This proves the wrong execution boundary, not a measured provider-stall duration.
Move both preparation sites to one coordinator method; retain the one fixed
cloud-location provider and publish UI state only after its async result. A
transient preparation flag serializes the toggle, not input or Host maintenance.
No new service, thread registry or I/O fallback; direct UI provider paths 2->0,
Settings preparation owner 0->1, cloud-location authority 1->1. The centralized
retired-path guard is RED before the move; existing directory behavior and App
integration gates remain required afterward.

The Complete Distribution also unconditionally declared `RequireLogout`, even
for an already-registered App repair. Its template regression is RED. Remove
that declaration and the verifier's matching assumption; both package variants
must report `RestartAction=None`. First-install instructions still explicitly
request one manual logout. Core/App repair continues to preserve healthy packs;
explicit full language-pack repair is a separate Settings/Registry transaction,
not a request to overwrite healthy language data through Complete. Interrupted
Complete staging remains a separate unexercised row with explicit uninstall
guidance that preserves personal data; it is not normal Core-update recovery.

Before the `0.1.11` source freeze, the exact final corrections pass strict lint,
the centralized retired-path guard, Complete/Core lifecycle fixtures, package
architecture, an unsigned Release App build and Periphery. The full preceding
candidate passes Swift and Rime integration, including eight profiles and live
sync typing; the versioned source still requires a new complete receipt. The
configuration-observation method stays on SettingsModel and moves unchanged
beside its existing presentation consumers; no wrapper or new owner is added.
Logs are retained under `build/release-0.1.11.cOlf1m/`. No installed-product,
actual iCloud-provider, Action-artifact or publication PASS follows from these
local checks.

Signed-package preflight at `ae1283f`, 2026-08-31 22:47 CST, passed CMS and
candidate lifecycle but rejected Core at the Distribution verifier. A minimal
system `pkgbuild`/`productbuild` reproduction proves that after removing the
must-close reference, size attributes belong to the primary pkg-ref; the old
verifier still expected them on a second Core reference. Correct that one
artifact consumer and delete both Core-specific placement branches (2->0),
keeping exact attribute/value validation. This changes no App or Rime behavior;
full signed-package verification and a fresh source receipt are still required.

The `5d9eff2` signed preflight then passes both actual PKGs and differential
packs. Its final publication-byte gate exposes a Bash continuation error in the
inventory comparison, before it examines artifacts. Fix that continuation and
include this existing verifier in the centralized shell-syntax owner list;
the previous list omitted it. No manifest rule or byte check is relaxed.

The differential candidate's cross-version data boundary was corrected before
the final source freeze. On 2026-08-31, base `c53df52` plus this candidate,
an old Settings pause request was accepted by the new Host because IPC checked
peer identity but not its native learning-data capability. The new native
database can retain activated pending merge records after pause; the published
`56cb640` Settings exporter cannot see those records. Export can omit them and
a later old-format mutation can discard them. This is an upgrade handoff defect,
not justification to drain the whole database on the input thread or terminate
the Settings process.

The existing Settings contract now declares `nativeLearningDataVersion = 1`;
missing/unknown capability is rejected by the existing Host IPC owner before
the pause handler can release the database. The same old-readable rejection
reply is reused. Diagnosis and explicit Core activation remain available to old
clients. After a Core upgrade the user reopens only Linnet Settings before data
operations; old Settings displays its existing generic refusal, not new copy.
No application is force-closed. Pause admission remains one authoritative path
(1->1); unconditional old-client database grants go 1->0; capability is one new
contract fact (0->1), with no adapter, alternate endpoint or fallback. UID/PID
authentication and native-capability admission protect separate peer and data
interpretation boundaries. Two production files add 20 lines net.

The same two-process regression was RED with a missing capability (the Host
handler ran), then GREEN in 17.45s: missing and unknown versions are rejected
without calling the handler, current pause succeeds, old diagnosis and Core
activation still succeed. Contract decode/round-trip passed in 6.10s. These are
IPC/contract fixtures, not an installed cross-version workflow; the exact full
local gate and real upgrade acceptance remain required.

### English definition cross-review — 2026-08-31

Base `61ed072`, working-ledger SHA-256
`beaae14ac1cf6692418a0d43852a5b793f2cf62ef574da5d0033313979f11196`.
The prior 18-family review is not whole-dictionary acceptance. This milestone
profiles all 69,013 curated rows and 143,461 effective definitions, then assigns
frequency/risk-stratified batches to three independent `gpt-5.6-terra` / `high`
reviewers and rotates their proposed corrections for cross-review. A mechanical
flag is never a semantic verdict; legitimate shortening, proper-name omissions,
technical senses and valid verbal nouns must be preserved.

Only the existing final TSV owns translations (1 -> 1); the generator and
runtime consume it unchanged. No translation fallback, ranking rule, new
dictionary or service is added. Main alone applies agreed corrections against
the exact old text. The existing projection test, quality record, pack content
identity and unreleased changelog consume the same accepted batch. Core delta,
backup, installer and other dirty files are frozen. Target: one bounded review
window (up to three hours), zero production-code growth, existing data owners,
and no second review ledger loaded by the product. Uncertain and unreviewed
words remain explicit; no correction-count target justifies invented meanings.
Require red old-gloss cases, reviewed replacements, generated-index parity,
unchanged word/frequency bytes and pack-hash validation. Installed UI remains
NOT_EXERCISED; no install, release or remote CI follows from a data-audit PASS.

Data-only result: final TSV SHA-256
`56dadfe2b903dbc33938cfc1549afde7ed3dc374655291871a0093a23faefeb7`.
The unique semantic queue contains 9,849 entries; every adopted correction was
cross-reviewed, and 300 retained decisions were sampled independently. Adopted:
1,882 corrections (1,771 existing overrides and 111 existing fallback words
made explicit). Deferred unchanged: 264; these are not confirmed-defect claims.
The 133,612 entries outside this semantic queue were mechanically profiled only.
The existing 86-case source/index contract has 25 RED cases before correction
and zero afterward. Full projection comparison verifies all 1,882 replacements,
141,579 unchanged other glosses, and identical vocabulary, keys, weights,
pinyin, IPA, skip, fuzzy and next-word data. Generated smart DB size grew 0.105%.
Native English container build/verification and the package architecture gate
pass. That data-only milestone produced the unpublished `0.4.18` / sequence 23
identity. The later Smart English full-pinyin routing change altered the English
pack again, so the current owner advances it to `0.4.19` / sequence 24 and the
Catalog to sequence 46 instead of reusing the earlier immutable identity. No
fallback or same-sequence replacement is permitted.
Exact hashes, deferred terms and reference coverage are recorded in the existing
[translation quality record](../data/chinese/reports/translation_quality_audit.json).
Installed-product and complete-App acceptance remain NOT_EXERCISED for this batch.

| Fact / boundary | Canonical owner retained | Interpretation to retire |
| --- | --- | --- |
| Core activation | UpdateChecker + Host activation decision | read-only refresh cancels mutation; Host emits legacy UI blockers |
| Phrase learning | selected Rime Phrase code + existing userdb | shared text/comment-to-pronunciation cache |
| Rime lifetime | existing Host maintenance and session lease | leases surviving actual all-session maintenance cleanup |
| Learning sync | one Host scheduler + Rime UserDbMerger | sync as maintenance, main-thread cloud I/O/join, unchanged snapshot rewrites; unavailable directory equals disabled |
| Catalog acceptance | DataChannel + Registry receipt transaction | pack sequence requires identical whole-Catalog bytes |
| Draft retry | existing stage/publish owners | stage accepts identities final publish rejects |
| Source verification | local release-control, exact source identity | full source/UI suites repeated by candidate Action |
| Native test isolation | existing path-exact lifecycle check | inherited stdin/stdout/stderr logs treated as loaded runtime resources |

Each boundary is limited to eight production files/about 500 non-mechanical
lines before redesign; runtime work has a three-hour budget, ordinary fixes one
hour, with at most two correction loops per defect. Focused regressions must
fail before the corresponding fix and pass afterwards. Shared suites run
serially once on the integrated candidate. Source, isolated engine, signed
artifact and installed-product results remain separate. Existing signing,
immutable published assets, atomic data rollback and input-source registration
boundaries stay in place; no new client ledger, fallback or signing identity.
Rollback is reverting the exact unshipped candidate, not resetting user data.

Current policy: except for the isolated cold-build `data-seed` boundary below,
the maintainer verifies one frozen source tree locally through the existing
build, lint, owner, app/Swift/Rime and Periphery entrypoints. The ignored local
receipt is a maintainer statement, not proof of a cloud test run. An annotated
candidate tag binds that receipt to the clean exact-main commit and its Git
tree. The macOS job validates the binding and history-sensitive metadata,
restores locked build inputs and builds the CMS-signed archive; it does not
repeat source tests recorded as PASS for that tree. Settings UI acceptance is
either a real local isolated-desktop PASS or explicitly NOT_EXERCISED; only
the latter runs in the candidate Action. No skipped row becomes a PASS.
A passing `package/verify_publication_artifacts` run freezes the exact manifest:
two Core-channel assets (Core PKG and raw Catalog), four immutable
language packs, their declared deltas and one public `Linnet.pkg`. The same job stages
or verifies the candidate-bound Core/Public Drafts and the byte-bound data
Draft. A data Draft already attached to any valid direct commit is reused
without mutation when its tag, title, prerelease state and declared data assets are
byte-identical. Real installed
Settings/InputMethodKit acceptance downloads and consumes those exact bytes
before any public-channel mutation. The maintainer then uses Git SSH to create
one lightweight control tag binding version, full revision and the manifest
set digest. That tag authorizes the Ubuntu Action's ordered
Core/data/Catalog/public publication chain without a large-asset redownload or
rebuild. Installation acceptance remains separate evidence and must name the
exact revision, build, set digest and file hashes exercised.

The data receipt remains the shipped v1 shape and whole-Catalog digest meaning.
New writers additionally record one pack-snapshot digest. Readers migrate its
absence only at begin/prepare from committed installed packs; ordinary reads
do not repair state. A published 0.1.10 Host may discard this optional field on
commit, so that handoff must remain visibly unmigrated. Registry owns this
compatibility until the minimum supported Core requires the new receipt writer.

Legacy activation blocker decoding is a separate compatibility boundary:
published `0.1.10` source `56cb640` still emits `core_activation_unknown_client`
for unknown TIS state. SettingsContract owns removal of these wire cases only
after every supported Host has the current input-source-unavailable producer;
merely raising the minimum Core to `0.1.10` is not sufficient. This does not
extend the older identity-free-health compatibility branch.

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
| input-source registration and damaged-install repair | first App creation in Complete plus user-owned System Settings repair | every existing-App register/enable/select path, installed-Host inspection CLI, missing-App Core repair, `osascript` authorization | focused owner and package-lifecycle gates pass; the already-disabled login session and exact installed Core row remain pending |
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

### Published 0.1.10 acceptance — 2026-08-30

Published source `56cb640678fa3e726d95c9e208505e2f90f71df9`, version 0.1.10 (69):
Action `33316501948` passed the complete candidate workflow, including all ten
Settings UI cases and unchanged real-home checks (546.220 s, zero failures).
The exact Core was installed twice successfully; the same Host, TextEdit and
Codex processes and Active metadata hash were retained. After being asked to
apply the installed update and check TextEdit/Teams/Codex, the user confirmed
“确认正常”. This is user-reported input acceptance, not automated local AX proof.

Action `33319136816` published the same assets without rebuilding. Latest is
`v0.1.10`, with only `Linnet.pkg`, SHA-256
`9d6068cda43e8dfc5f4538d4b9de6f6109ead570f06f837adb94bce865956a88`.
The eight-file set digest is
`267c599ce20cd2397fde77eb8910d11ba1c6b8fbec79f2843480637b6a6cd03d`;
data-channel commit `0374855c4325a24471c427d498ea173f393d9cdd` contains the
byte-identical accepted Catalog. The older rows below retain their dated scopes;
unexercised cross-device/accessibility cases are not promoted to PASS.

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

Maintainer release direction, 2026-08-30: preserve the working local installation
rather than downgrade it solely to repeat an update. System Installer records
show the local 0.1.9 Core candidate installed at 14:05 and the above 0.1.10
candidate at 15:47, followed by the user's successful-input report. For this
release, retain that local upgrade evidence and exercise the exact Action Core
over the working candidate, then reinstall the same bytes. This is a bounded
0.1.10 acceptance decision, not evidence that the public 0.1.9 package or every
application was exercised. Online update discovery remains a separate
post-publication check; no downgrade or publication is implied by a test PASS.

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
rendering path and production UI remain unchanged. At that checkpoint cloud
diagnosis and formal artifact publication were incomplete; no additional cloud
run had been authorized.

The subsequently authorized isolated diagnostic ran once as Action
`33302408070`, source `bee9c175f16ff67a13eb7e6691eee71c42887caa`, on
2026-08-30 at 08:46 UTC. Its macOS job took 36 seconds; hydration, build-cache
downloads, full product tests, packaging and publication were all skipped.
The same 680-point Dark Aqua assertion failed with 13 recognized samples.
The preserved 680×501 PNG has SHA-256
`69187fbd84f038977300d2da4aeb543cd810ee856384956d87fd38267a72ef6f`.
It is recoverable from the job's raw log marker
`LINNET_THEME_PREVIEW_FAILURE_PNG_BASE64`; the CLI's formatted failed-log view
omits that long line, so retrieval used the job-log API.

Visual inspection of those exact cloud pixels found all fourteen samples,
without missing candidate text. Replaying whole-image Vision recognition on
the same PNG locally reproduced 13: the Xuan dark sample was segmented into
“C 1” and “2候选”, omitting the visible “输入”. Restricting the same recognition
request to that sample's actual image region recognized “1输入 2候选” without
changing the pixels. The earliest wrong result is therefore the test's
whole-image OCR count being treated as proof of missing rendered content,
not a demonstrated product rendering failure or cloud-only Vision failure.

That run closed diagnosis, not the failing test or release gate. The diagnostic
entrypoint reuses the same fixture, source list and Swift cache owner (each
remains one). Its local run, release-automation gate, shell syntax and exact
default-flow equivalence checks passed. It changed no installed App and made
no release.

The subsequent authorized correction retains the unedited PNG at
`tests/fixtures/settings-theme-cloud-dark-680.png`. The new regression failed
with the original direct-bitmap OCR path. One canonical OCR boundary now
normalizes its input to sRGB at 2 pixels per layout point, removing dependence
on host backing-scale and bitmap format; the original capture remains the
saved evidence. The same fixture passes with all fourteen samples. Erasing
each of the fourteen samples separately, an entirely blank grid and a clipped
grid are all rejected. There are no retries, alternate recognition results or
lowered sample thresholds. The actual four Aqua/Dark Aqua × 680/900-point
component captures also pass locally. No production code or theme palette was
changed, and no second compiler/cache owner was added. Strict SwiftLint,
release-automation checks and the complete local Swift owner suite pass,
including candidate interaction and the two-process Settings IPC fixture.
Exact cloud verification passed on 2026-08-30 in Action `33302857559`, source
`0523dd55fbf6986ef37328b106d3668b67f7be36`. The macOS job ran from 08:57:50 to
08:59:08 UTC (78 seconds). It passed the retained cloud image, all sixteen
negative images and all four actual 1x captures; hydration, full product build,
packaging and publication were skipped. This closes the OCR test defect.
Production source and the installed input method remain unchanged; full
release-candidate and installed-product acceptance are separate, not claimed
by this focused run.

### Settings UI scroll incident — 2026-08-30

Current complete UI evidence: Action [33310223404](https://github.com/Ares-X/Linnet/actions/runs/33310223404),
source `1a4d414d52f62ec471cfbd959c7c4dc97771ef88`, ran all ten cases:
**nine PASS, one FAIL**. No product source, installed App, version, pack or
publication identity changed during this harness repair. This is isolated
Settings workflow evidence, not exact signed-package installation acceptance.

Focused Data replay: Action [33311506249](https://github.com/Ares-X/Linnet/actions/runs/33311506249),
source `8e423f471f80ae16f8e695b07912127239ca28a2`, **PASS**, one test,
zero failures, 156.754 s, completed at 12:40:53 UTC. This closes the remaining
Data interaction failure. The nine passes above and this focused pass are
separate runs; no single exact ten-case PASS or installed acceptance is claimed.

Release Action `33312706703` at `e781b916b709520d8012ad37b37af75c9471acf8`
stopped before compilation/signing at 13:01:14 UTC: the publication source guard
counted the focused UI command as a second full suite. Its tools check also still
required the former literal quality command. The guard now requires exactly one
unfiltered full-suite entry and the profile-specific tools command. Local contract
probes accept the current workflow and reject removing the full suite or giving
the full profile only release tools; the complete publication-owner gate passes.
No release gate, product code, version or package identity was relaxed or changed.

Action `33313241996` at `8832754d5dc0350003fd53c48f70ea0b8d9b48cf`
passed strict/source, Swift, Rime, Periphery, signed-package verification and all
ten Settings UI cases (zero failures, 556.382 s), but failed the post-test home
isolation check. The real runner Linnet/UserData/Transactions directories appeared
at 13:37:17 UTC, exactly when the cold NSWorkspace-open case began. XCTRunner's
generated entitlements contain `com.apple.security.app-sandbox=1`;
[Apple documents](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/environment)
that a sandboxed caller's launch environment is ignored. The test's HOME override
therefore did not establish isolation. This is an environment/fixture failure,
not an overall release PASS; no Draft or local installation was produced.

The correction moves cold/reopen requests to the existing unsandboxed foreground
fixture, using launch arguments to reach it and one NSWorkspace environment owner
there. The two direct Settings-open implementations in XCTRunner are retired;
the real-home metadata/content checks remain unchanged. Product code and signing
are unchanged. Local compilation passes, but the focused dynamic replay failed:
Action `33315502196`, source `13fb7cb6ee8598d2cee8ab1283edb31cdfc59795`,
on 2026-08-30 at 14:02:46–14:03:42 UTC returned `reopenFailed` in all three
cold/covered/minimized cases. AppKit's installed `NSWorkspace.h` explicitly
states that sandboxed callers' `arguments` are ignored too. Therefore forwarding
arguments through the same sandboxed NSWorkspace caller did not establish the
intended fixture command. This correction is NOT accepted and is not merged;
there was no subsequent full candidate run, installation or publication.

The two failed assumptions were that sandboxed NSWorkspace could forward HOME,
then that it could forward a helper command through arguments. The unchanged
failing boundary is XCTRunner → NSWorkspace launch configuration. Further patches
and Action dispatches are stopped pending a complete fixture launch redesign:
XCTest should operate the existing foreground fixture through its normal UI,
with that unsandboxed fixture owning the exact isolated Settings open request.
Cold, covered and minimized states must each observe the real Settings window;
launch failure must remain a failure, and real-home protection must remain intact.
No production activation workaround, sandbox relaxation or new runtime owner is
authorized by this test-fixture diagnosis.

After renewed user authorization, the redesign uses an ordinary “Open Settings”
button in the existing foreground fixture. XCTest launches/observes it through
XCUIApplication, clicks the button, and waits for the real NSWorkspace completion
before checking the exact Settings process/window. Command forwarding, forced
helper instances, helper-exit polling and all NSWorkspace calls in XCTRunner are
removed. One unsandboxed fixture owns launch arguments/environment; product code
and all real-home checks are unchanged. Local Swift typecheck, fixture compilation,
fixed-home dry-run and publication-owner checks pass. Local desktop automation
returns a closed native pipe; it does not provide local visual acceptance.
Isolated Action `33316110481`, source
`f86bb0b84acba83ebf66421ff7f922f6e6e2f4b4`, passes all three real UI cases on
2026-08-30 at 14:16 UTC: cold open 7.726 s, covered reopen 11.966 s and minimized
reopen 12.360 s (32.051 s total, zero failures). The unchanged real-home metadata
and content checks also pass; the script reaches `Visible Settings isolated UI
suite: PASS`. This closes the fixture launch/isolation incident. It is not yet
the complete candidate suite, signed-artifact installation or publication.

| Case | Exact complete-run result |
| --- | --- |
| Appearance controls, theme previews and popup selections | PASS, 99.659 s |
| Pending-change close/discard | PASS, 36.356 s |
| Cold Host-like Settings open | PASS, 2.595 s |
| Data controls and cancellation | FAIL, 143.607 s; diagnostic Refresh hit testing |
| Progressive Cloud/Manual/Diagnostics disclosure | PASS, 31.275 s |
| Focused dictionary-row deletion | PASS, 130.998 s |
| Four-page navigation | PASS, 20.424 s |
| Chinese and English input settings | PASS, 89.565 s |
| Reopen above a separate foreground application | PASS, 8.844 s |
| Reopen after minimizing | PASS, 6.781 s |

Confirmed causes and retired paths:

- **Scrolling:** official candidate Action `33303649630` at `064ad67`
  failed Xuan at 09:51:44 UTC: target `(73,704,208,105)`, viewport
  `(32,112,960,523)`. Fixed 600-pt jumps could skip the 418-pt visible interval.
  The sole manual scroll owner now centers the observed target with bounded
  steps. Appearance repeatedly passes, including the current complete run.
- **Cold-open identity:** Action `33305873514` opened the exact embedded App,
  but the bundle-ID-only XCTest observer could select its standalone sibling.
  All observers now use the exact embedded URL (target-selection paths 2→1).
  Neither launch nor reopen assertions activate Settings on its behalf.
- **Disclosure:** two unsuccessful positioning attempts stopped further guessing.
  Action `33308803451` at `fcfe211` retained the decisive screenshot and
  synthesized event: at 11:34:03, click `(51,548)` missed the painted arrow
  at `(69,548)`; the AX frame begins at x=43. The string-value hypothesis
  was falsified by `__NSCFBoolean(0)`. This fixed-system-font macOS-26 fixture
  uses the measured 26-pt inset and still requires true expanded state and
  actual descendants; no alternate clicks or product offsets exist.
- **Visible controls:** Action `33309486828` at `406dd9f` proved Retention
  was enabled and visibly exposed at `(143,468,247,26)`, despite false
  `isHittable`. The scroll owner now proves containment only. Actual centered
  popup clicks, menu items and selected values prove interaction. The current
  full run passed all retention choices and subsequent cancellation paths.
- **Foreground fixture:** XCTRunner is LSBackgroundOnly. Both changing its
  policy and activating NSApplication failed to make it foreground. The
  in-runner panel and policy mutations are retired. One minimal regular AppKit
  fixture owns the separate-app boundary: Settings active → fixture active and
  Settings inactive → NSWorkspace reopen → Settings active and visible.
  This now passes. Exact-path cleanup covers only the two disposable apps,
  their bundle registrations and UAT preferences; no user application is used.
- **Data interaction failure:** at 12:14:17 the native Refresh click attempted
  implicit scrolling even though its frame was already within the viewport,
  then failed `Not hittable` three times. The affected diagnostic and file-panel
  buttons now use the same visible-frame mouse primitive as the verified popup
  path. Enabled-state, operation completion, dialog appearance and cancellation
  assertions remain. Full-path review also separates the fixed language footer
  from scrollable popups: it is tested against the window bounds on every
  language change, not against a scroll viewport that cannot contain it.
  The focused replay above passed the complete Data workflow, including file
  panels, diagnostic Refresh and all three interface-language choices.

XCTest's `continueAfterFailure=false` stops each failed test; the retired
global skip flag no longer suppresses independent workflows (failure owners
2→1). The manual `settings-ui` profile accepts one selected-method batch or
the default full suite. It reuses locked preparation and the existing build
owner, without release signing or packaging. Native xcresults survive fixture
cleanup under unique `build/settings-ui-results/` directories; manual CI
retains only these synthetic reports for three days, not App/package transport.
A failed declared-tool setup in Action `33305751531` was
`ENVIRONMENT_INVALID`, not product evidence. It was corrected before UI replay.

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
  exact-tree local source acceptance and final candidate artifact verification.
  Core/Public Drafts remain bound to that exact candidate revision. Each data
  pack is instead owned by its immutable bytes and metadata; a data Draft may be
  reused across candidate revisions when its target is a valid direct commit and
  its tag, title, prerelease state, filenames, sizes and SHA-256 digests match
  exactly. The Catalog is the candidate's snapshot of the current Core plus
  those existing immutable packs. The manifest set digest freezes that exact
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
| Pinyin-to-English reverse lookup | one reviewed JSON snapshot owns candidate order; direct validation enforces byte-sorted keys, case-insensitive deduplication, the 64-candidate cap and exact embargo parity | Smart English automatically resolves the current profile's reviewed full- or double-pinyin code without inheriting its trigger; every Chinese profile resolves the same code after the default `|` or user-selected `;` trigger, including codes with an internal semicolon. Smart English semicolon remains application-owned | committed quality cases are all green; a confirmed non-word cannot appear in any key |
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
| Input | Chinese profile (full pinyin or one of seven double-pinyin schemes), Emoji default, simplified/traditional output default, Chinese/English punctuation default, auxiliary-code single-character preference, default `\|` or explicit `;` pinyin-reverse trigger, enhanced/standard/off Chinese learning strategy, plus Smart English capitalization, IPA, definitions, prediction, learning, Space and Tab behavior. English correction and fuzzy matching are always-on capabilities, not configurable switches. The typed Settings document is the one profile owner: a fresh document defaults to full pinyin, while an existing explicit profile is preserved. Configuration Apply deterministically places it first in the Rime schema list and projects the same value to Smart English reverse lookup and direct-Shift return. `user.yaml` history is non-authoritative | native engine acceptance proves all eight profile projections and fresh-session ownership, direct Shift into Smart English and exact same-profile return, including two interleaved sessions, plus Shift+letter, held Shift, Caps Lock raw ASCII and Caps-on Shift pass-through. The document projection is exercised through deploy and fresh sessions for traditional output, reverse trigger, sentence capitalization and Tab; the separate personal runtime writer is exercised for disabled words. Installed fresh-default/profile preservation, key handling and the other seven profiles' learning rows remain UAT / `NOT_EXERCISED` |
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
| J02 | Clean install, add/enable Linnet and coexist with Squirrel | I | `NOT_EXERCISED`. Installation acceptance must use the exact verified manifest-bound Draft Release set produced by the candidate Action; rebuilding or re-signing creates different evidence. The record can change to `passed` only after this row and the full required matrix succeed. |
| J03 | First Chinese input and candidate commit | E, I | E covers same-event commit for ordinary Chinese punctuation and ASCII `,`/`.`/`:` inside numbers, plus idle `/` and `~` as ordinary symbols; installed workflow remains pending. |
| J04 | left/right Shift tap, chord, hold and active composition | C, E, I | replay/engine covers exact-once raw-letter commit rather than candidate/completion selection in every Chinese profile and Smart English; active full-pinyin composition explicitly exercises both `Shift_L` and `Shift_R`. The required six-application installed workflow (Terminal, VS Code, Chrome, Apple Notes, Word and Teams) is `NOT_EXERCISED` |
| J05 | Caps Lock, passwords, URLs, paths and code identifiers | E, I | The E regression gate covers Caps Lock down/type/up entering and leaving raw ASCII in both Chinese and Smart English. Current exact serial E execution and installed Terminal/password-field behavior remain pending. |
| J06 | full pinyin and all seven double-pinyin profiles, including the live Chinese/English candidate boundary | E, I | The local freeze passes the complete serial Release/development composite, all eight 222-case Golden profiles, the native overlap/key/page-tail matrix and its mapping-mutation negative. Warm p95 is 0.510 ms for English and 1.392 ms for Chinese. E is passed for this source freeze; installed profile selection remains `NOT_EXERCISED`. |
| J07 | Smart English completion, always-on correction/fuzzy matching and ranking; independently configurable IPA/definition, prediction and selection learning | C, E, I | The local freeze passes the complete serial owner and native rows for Space behavior, arrow and `1–9` selection, passive-prediction labels, `Esc`, selection learning and static-context spacing. Current C/E are passed; installed interaction remains `NOT_EXERCISED`. |
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
| J20 | artifact names, sizes, checksums, notices, SBOM, update URLs and README agree | P, R | The candidate Action accepts one clean exact-main revision and its local source receipt, signs once on macOS, and freezes the manifest's verifier-approved Draft Release files. Only Settings UI rows not exercised locally run again. Installation consumes that exact set before any public-channel mutation. Only the SSH control tag binding version, full revision and manifest set digest may let the Ubuntu publisher route Core/data/Catalog and the unchanged `Linnet.pkg` to public Release / Latest. Candidate Draft bytes and final Release-page evidence remain distinct R rows. |

## Finding ledger

| Status | Priority | Finding | Earliest owner | Required closure |
| --- | --- | --- | --- | --- |
| component and local composites verified; installed recovery pending | P0 | 2026-09-01, source `39d1768a2388e856aa0d18db583d1511069de3bc`: after native Core installation, the user's input menu omitted Linnet and the already-open Settings reported both identities unavailable. Fresh read-only IPC still returned healthy Host `0.1.10 (69)` / `56cb640`; the disk contained verified `0.1.11 (70)` / `39d1768`. TIS reported enabled, so neither registration nor PID liveness proved the actual menu. At 01:38:33 LaunchServices registered the replacement launch-disabled; the flag alone does not prove the menu's cause. | Core App publication; Settings installed-identity reader | Red→green regressions prove whole-App exchange changed its inode/bookmark and cached Bundle Info.plist mixed with fresh VERSION.json lost installed identity. The correction keeps the App root, swaps Contents atomically, and reads installed metadata from disk. Scope: DirectoryDelta, PackTool, installer postinstall and SettingsContract, plus the package verifier; within 8 production files / 500 non-mechanical lines. Generic tree-exchange authority for Core is retired (one App publication owner before/after, no added fallback or registration path); cached installed-version reads are retired (one identity parser before/after). Staged-byte/CMS checks, mutation lease and final Runtime check retain their distinct boundaries. Exact update/rollback, inode/bookmark preservation and open-Settings regressions, package lifecycle fixtures, strict lint, Periphery and full App/Swift/IPC composites pass. No TIS writes, user-app exits, forced restarts or publication are authorized by a test PASS. Installed recovery/continuity remains NOT_EXERCISED; the menu cause must not be declared closed by component evidence. |
| closed | P0 | An embedded hardened Settings process could pass static code-sign verification but crash while loading the ad-hoc parent `librime` because the nested signature lacked the library-validation entitlement. | Release App nested signing boundary | Release build now signs Settings inside-out and verifies its entitlement, dependency, RPATH and nested signature. Headless gates no longer launch the regular GUI merely to observe two seconds of liveness; real Settings launch remains one installed-product UAT row. |
| evidence-gap | — | Settings has an always-visible local candidate preview that consumes the canonical bundled Squirrel theme source. Component and projection tests pass, but the safe hidden-window attempt produced incomplete pixels and a root-only AX tree, so it is `ENVIRONMENT_INVALID` rather than accepted V evidence. | Settings appearance preview and visible accessibility presentation | inspect all theme/layout/font extremes, unavailable/error states, keyboard traversal and VoiceOver in the controlled App/installed UAT; compare the real candidate renderer with the preview |
| evidence-gap | — | The complete Settings state matrix has no valid current real-window screenshot or accessibility-tree evidence; the rejected offscreen harness rendered blank pixels and a root-only AX tree. | Settings presentation and accessibility contracts | inspect Appearance, Input, Dictionary and Data & Updates in English and Simplified Chinese from the next frozen candidate; include wide two-column and compact stacked layouts, all three download sources and their disabled/error/privacy states, and record hierarchy, copy, focus and controls without counting the invalid offscreen evidence |
| evidence-gap | — | No installed-product evidence exists for input-source discovery, the required six-application focus behavior (Terminal, VS Code, Chrome, Apple Notes, Word and Teams), upgrade, rollback, uninstall or residue. | current-user Installer and InputMethodKit lifecycle | complete one controlled clean-install-to-purge UAT only after every non-install blocker is closed |
| superseded | P0 | At `b5cf850`, Core/manual activation treated Controller teardown as client disconnection, stopped the existing IMKServer while TextEdit PID 20213 retained its old endpoint, and left that TextEdit without Host activation or key events; fresh TextEdit PID 73247 connected to the replacement Host. The later append-only application-history containment avoided that race but made normal updates require quitting every app that had used Linnet. | Core package Host lifecycle | Installer-owned replacement and the process-history containment are both retired. Core installation leaves the Host and TIS state untouched. The explicit Host transition now requires Linnet to be inactive, composition and data mutation to be idle, and the requester to remain alive; it rechecks the same live boundaries before its sole graceful exit. Settings launches and verifies only the canonical installed Host. Focused contract/build evidence must be followed by exact installed TextEdit/Teams/Codex reconnect rows before this candidate is accepted. |
| closed | P1 | At `b5cf850`, Host startup created and immediately destroyed its readiness session without traversing a real candidate query. Once the last client session was gone, a new application's first Chinese lookup paid about 541 ms for dictionary paging, followed by about 149 ms on the first lazy English-dictionary access. | Host runtime readiness and shared Rime resource lifetime | One composition-free session now primes the selected schema's real candidate path and remains owned by the Host process; per-application composition sessions stay independent. The same owner refreshes before stale cleanup, retires before every all-session cleanup, and is restored after user-data sync or configuration reload. The isolated independent-client probe measured 6 ms against a 100 ms contract; installed cold-start evidence remains J18 pending. |
| closed | P0 | At exact `94e7c6f`, Shift down/up on `linnet_zh` changed `ascii_mode` to true while `schema_id` remained `linnet_zh`; Smart English had instead been placed behind a Shift-plus-space binding. The wrong product transition was caused by treating a convenient standard key binding as the user contract. | direct Chinese/Smart-English transition after upstream gesture classification | `ascii_composer` still owns tap/chord/hold and composition commit; one native Rime processor maps only its accepted isolated-Shift result to the other schema. The focused engine probe covers all eight Chinese profiles, default round trip, Shift+letter, held Shift and Caps Lock raw ASCII, while source guards reject the retired chord shortcut and private Swift mode owners |
| closed | P0 | Packaging exact `bb368e1` rejected the Chinese pack before emitting artifacts because the direct-Shift schemas and Glass `squirrel.yaml` changed pack bytes while the release manifest still named the preceding content digests. | `config/linnet-data-releases.json` language-pack identity | At that historical `bb368e1` milestone, Chinese advanced to `0.5.9` / sequence 17, English to `0.4.7` / sequence 12 and the Catalog to sequence 10, each bound to the source inventory digest computed by the existing pack owner. Those values are retained only as the historical rejection closure and are not the current release identity; current identity comes solely from `config/linnet-data-releases.json`. |
| open; installed recovery requires macOS user action | P0 | At exact source `320db8547ffffebd3ce0f2b88cec87024a37e50a`, Complete installed build 72 at 22:18 and unconditionally called `TISEnableInputSource`, producing another “Allow Linnet to enable Linnet?” sheet. At 22:54 the installed App kept inode `405566251` while its Contents were atomically restored to the exact public `v0.1.10` bytes (SHA-256 `9d6068cda43e8dfc5f4538d4b9de6f6109ead570f06f837adb94bce865956a88`). The public registration command then reported “already registered,” but the package-owned inspector with the correct bundle ID returned `registered:enablement-required:path-unknown`; `AppleEnabledInputSources` and the real menu still contained no Linnet. This proves that registration and process-local TIS observation cannot stand in for durable menu enablement. | first-App authorization boundary versus existing-App update boundary | First App creation is now the only caller of the renamed `--request-first-install-authorization` command. Existing-App Complete repair and every Core update only preserve/exchange bytes and then read availability; they never register, enable, select or resubmit authorization. The ambiguous old CLI and unconditional Complete enable path are retired. Focused structure, Swift owner and package-lifecycle tests are red on build 72 and green on the current source. The already-disabled login session cannot be silently repaired by an Installer without crossing macOS's user authorization boundary; real menu visibility and multi-application typing remain required before publication. |
| superseded by build 72 installed rejection | P0 | On 2026-09-01 at source `c5681b8`, the user had already approved Linnet and TIS reported enabled. A normal local Xcode build first registered a pre-CMS Host and then unregistered it; the replacement initially retained one path that switched from local to production identity. Both paths were retired, but installed build 71 exposed the next earliest error: at 21:12 Complete replaced the App while the Host launched on August 30 remained alive. The TIS object still reported `enabled-observation`, so `requestAuthorization()` skipped `TISEnableInputSource`; the persistent `AppleEnabledInputSources` list contained no Linnet and the real menu could neither display nor select it. LaunchServices also retained three production App paths: the retired Xcode path, the frozen candidate and the installed App. The component/API PASS was therefore a false product result. | Complete input-source authorization request, Core package lifecycle, local Xcode construction and production-candidate staging | Build 72's attempt to resubmit enablement on every Complete boundary was rejected by the next installed UAT because an ordinary update produced another authorization sheet. The full state redesign is owned by the current open row; this historical approach is no longer authoritative. |
| closed | P0 | During exact `83e7adb` default-uninstall UAT, the old App and generated data were removed but the preserved `linnet_zh.userdb` rotated its LevelDB log and manifest after the uninstaller invoked `--disable-input-source`; the pre-action and post-action byte manifests differed while the already-quiesced Host had no pending user input. | default uninstaller lifecycle sequence | Both the TIS-disable transition and installed Host cleanup commands are retired. The user first selects another input source; exact Host or Settings presence makes uninstall fail closed and instructs logout/retry. Default uninstall preserves UserData, Backups, Transactions and preferences byte-for-byte while removing Registry-owned Runtime logs with Runtime. Purge removes remaining persistent data and preferences; no system temporary path is inferred. Real default/purge rows remain required. |
| closed | P1 | Caps Lock lacked an automated key-event proof across Chinese and Smart English. | input-event engine acceptance | `rime_smoke_test` now proves Caps Lock down/type/up enters and leaves raw ASCII in both schemas; installed Terminal/password-field coverage remains in J05 |
| gate | P1 | Every publication candidate requires a fresh revision-bound Core/complete projection after source, LTS identity or Settings bytes change; uninstall remains source-owned at the exact version tag rather than becoming a separate asset. | App/Core identity, immutable pack identity and exact Action candidate | before candidate build/sign, require exact current main and a matching local full-gate receipt; then freeze one Action-built manifest set accepted by `package/verify_publication_artifacts` and staged as Draft Releases. Before pushing its SSH control tag, pass installed Settings/InputMethodKit acceptance on those same bytes. Full `verify_product release`, independent expansion, code-sign policy, checksums, zero build/debug files, Full Active and source-to-packaged-Settings byte parity remain candidate gates. |
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
| closed | P0 | The first registration repair on top of `e6f5da1` made Core preinstall invoke the installed Host with a new `--inspect-input-source-registration` option. Exact public `755f696` (0.1.9 build 68) and historical `3a48e48` (0.1.10 build 27) do not implement that option; their default path enters `app.run()`, so a routine cross-version preinstall could wait on the long-lived InputMethodKit Host. | package-owned pre-payload registration inspector | Core now executes only the package's arm64, macOS-13-compatible read-only inspector. One shared `LinnetInputSourceRegistration` owner classifies missing, disabled, available, selected, duplicate, conflict and unknown states; `Main` exposes no inspection CLI, and the package lifecycle test locks both exact old-Host contracts and proves preinstall never invokes them. Package-byte verification remains required for the frozen candidate. |
| closed | P0 | At the `e6f5da1` audit base, Core treated a missing App as an in-place repair while Complete rejected an absent App whenever safe owned Active/state residue remained; neither path could authoritatively repair a supported missing-App or missing-registration installation. | Complete registration and repair boundary plus package-owned read-only TIS classification | That historical closure moved missing-App repair to Complete and retired the count-only `registered` interpretation plus the `missing-app-install` Core transition. Its later register/enable/select transition is superseded by the current open P0 row: Complete may register and request authorization, while macOS and the user own durable approval and selection. Exact installed repair rows remain pending. |
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

The macOS candidate Action assembles the manifest-owned product assets from the clean
exact-main checkout and signs exactly once; the asset-set digest and
per-file hashes identify the only installable candidate. Installation acceptance
downloads and records those same Draft Release identities but does not itself
authorize stable publication. After offline installation and workflow acceptance,
the maintainer runs `scripts/release-control preview /absolute/release-directory`;
the byte-bound Preview tag publishes only Core/data prereleases and the exact
`preview-channel` Catalog for online-update UAT. It cannot advance the stable
Catalog, public release or Latest. After that online UAT passes, the maintainer runs
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
