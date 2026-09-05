# Linnet Engineering Discipline

This file applies to the whole Linnet repository. Its purpose is to keep the
product small, direct, testable, and fast to change. User instructions override
it. A closer path-specific `AGENTS.md` may add constraints but must not weaken
these rules.

## 1. Failure Pattern This Document Prevents

Previous work became slow and over-engineered because uncertainty was converted
into code: another guard, wrapper, fallback, parser, compatibility branch,
state machine, test harness, or release gate. Local desktop inputs were treated
like hostile network traffic, tests were used as evidence of product quality,
and builds were repeatedly started before the code change was complete.

These are process failures, not acceptable safety margins. Linnet must prefer a
small correct product path over speculative resilience.

## 2. Product First

Before editing production code, write one compact milestone containing:

- the user-visible behavior to deliver;
- the current authoritative owner and every directly affected caller/consumer;
- the earliest proven cause of the defect;
- the old path, branch, helper, or layer that will be deleted or de-authorized;
- the allowed files and the focused acceptance command;
- whether loaded macOS behavior, local iCloud, or VM lifecycle UAT is required.

Do not start implementation while the cause is only a screenshot-level
hypothesis. Trace input event -> Linnet owner -> Rime/AppKit boundary -> visible
result. Fix the earliest wrong owner, not a downstream symptom.

Normal typing is the primary acceptance boundary. Candidate selection, input
continuity, input-menu visibility, application connections, and no-logout Core
updates take priority over internal abstractions and defensive checks.

## 3. One Owner, One Path

Each fact or state transition has one authoritative owner. A change must not add
a second producer, fallback, alias, UI inference, compatibility reader, or
pass-through adapter for an existing fact.

For every production change, record before/after counts for:

- authoritative paths;
- pass-through layers;
- fallback and compatibility branches;
- duplicated defaults and raw inference sites.

The default accepted result is flat or lower. A helper or new file is allowed
only when it owns a new invariant/external boundary or removes an existing
branch, interpretation site, or call-chain hop in the same change.

Do not add a wrapper around behavior that already has an owner. Do not retain an
old implementation “just in case.” If a shipped external contract truly needs
temporary compatibility, name the contract, owner, expiry, and removal test.

## 4. Complexity Control

For an ordinary bug or behavior correction:

- freeze the design before editing;
- use at most two corrective implementation loops;
- finish the code edit as one batch before building.

File count, line count, and elapsed time are diagnostic signals, not acceptance
limits. A large diff should prompt one scope review, but must not be split,
compressed, or rewritten merely to satisfy a number. Never trade readable,
complete behavior for fewer files or lines. Accept or reject a design by whether
it has one owner, removes replaced paths, avoids duplicated decisions, and
preserves the complete product contract.

When a change grows unexpectedly, stop adding code and re-read the complete
owner/call chain. Continue with the current design when the size is inherent to
the requested behavior; redesign only when the growth comes from duplicated
owners, speculative branches, adapters, or unrelated scope.

Do not create custom parsers, package formats, IPC protocols, daemons, caches,
transaction systems, layout frameworks, or recovery state machines when a
standard Foundation/AppKit/Rime facility satisfies the actual product contract.
Existing public formats may be retained, but must not grow without a new
user-facing requirement.

Prefer deletion and direct calls. File splitting is not a refactor when total
logic, branches, and ownership remain unchanged or grow.

## 5. Proportionate Safety

Every retained safety check must state:

- the concrete trust, time, or mutation boundary it protects;
- the actual input and credible failure mode;
- the action it blocks;
- why an existing check does not already protect that boundary.

User-owned local settings and personal dictionaries are not public hostile
network services. Do not add anti-DoS parsers, arbitrary quotas, repeated full
hashing, recursive normalization, or multi-layer validation without measured
evidence and a real boundary.

Downloaded release metadata, packages, filesystem ownership transitions,
cross-process mutations, code signing, and publication are distinct external or
mutation boundaries and may be validated once by their canonical owner. Later
consumers must not repeat or reinterpret the same decision.

Restarting, clearing caches, or deleting state is not diagnosis. Preserve the
earliest evidence first.

## 6. UI And Performance

Use AppKit's normal lifecycle and lightweight frame/layout facilities before
introducing delegate proxies, runtime forwarding, nested view bridges, or custom
rendering infrastructure. Keep Rime as the candidate/order/selection owner; UI
code only projects and interacts with that state.

Do not rewrite a UI subsystem because code looks heavy. First measure the exact
typing, expansion, navigation, pointer, horizontal, and vertical scenarios.
Optimize the measured owner and preserve all product behavior.

An allocation, layer rebuild, hash, layout pass, or view count is a hypothesis
until a focused measurement shows material user impact. Memory-leak claims need
allocation/lifetime evidence, not class names or line counts.

Do not restore the removed custom candidate VoiceOver subsystem unless the user
explicitly reverses that product decision.

## 7. Test Selection And Build Discipline

Editing and validation are separate phases:

1. inspect and freeze the whole affected path;
2. make the complete coherent edit;
3. run the narrow owner test once;
4. correct at most twice;
5. run the affected composite once;
6. run the full local/release matrix once only after source freeze.

Never build after each small edit. Never run the full matrix for a local change
when a focused selector covers its owner. Keep a documented mapping from source
owners to focused selectors.

Independent suites may run in parallel only when they do not share build
directories, Rime state, ports, fixtures, application processes, or VM state.
Cap ordinary local parallelism at two suites. Suites sharing those resources run
serially.

Tests must prove behavior or a real boundary. Do not add:

- tests that test another test runner or workflow text;
- source wording, variable-name, line-count, README phrasing, or YAML-shape
  policing;
- duplicate tests that exercise the same owner/input/action;
- production APIs used only by tests;
- a broad matrix when a representative equivalence class is already proven.

Exact guards for deliberately retired files, forbidden competing owners, or
release mutation boundaries are allowed. They must not prescribe implementation
names or formatting.

If the user says not to build or test, that is a hard stop: do not compile,
lint, execute tests, install, reload, or trigger Actions. Read-only inspection
and `git diff --check` are allowed unless the user also forbids them.

## 8. Acceptance Levels

Report these separately and never promote one into another:

- `CODE`: source change and focused static evidence;
- `TEST`: exact executed selectors;
- `RUNTIME_LOADED`: the built candidate is actually loaded;
- `PRODUCT`: real typing/settings/update workflow passed;
- `VM_LIFECYCLE`: install, upgrade, uninstall, reinstall, login, and reboot rows;
- `RELEASED`: published artifacts and online update path verified.

Unrun rows are `NOT_EXERCISED`, never PASS.

Local macOS is the normal owner for typing, candidate UI, Settings, performance,
and iCloud two-way behavior. The dedicated VM is primarily for clean install,
upgrade, uninstall/reinstall, login/logout, reboot, and previous-release
compatibility. Do not repeat locally proven deterministic suites in GitHub
Actions unless Actions owns a distinct compiler, signing, packaging, or
publication boundary.

Development exploration may use a locally built, fixed-community-signed test
package in the dedicated VM; it does not require an Action candidate or authorize
publication. Keep component, layout, Settings and performance checks on the
development Mac with isolated data. Use the VM for actual keyboard input,
installation/upgrades, potentially logout-requiring lifecycle cases, and the
second iCloud endpoint. Batch guest observations and use SSH for shell work.
Do not replace the development Mac's daily input method for these tests.
Record the exact tested source and bytes. Formal release acceptance still uses
the Action-built artifact bytes; local exploration is not a substitute for it.

## 9. Review And Documentation

Treat external audit findings as hypotheses. Verify the cited source, current
dirty diff, owner contract, caller, and one real consumer before accepting a
claim. Classify each finding as verified, disproved, stale, or unknown.

Do one consolidated architecture review before implementation and one final
review after focused validation. Do not use repeated reviewers to discover the
same call chain one patch at a time.

README and user documentation describe meaningful behavior, installation,
updates, limitations, and recovery. Do not document ordinary input-method
behavior, internal defenses, test gates, or implementation trivia.

## 10. Stop Conditions And Handoff

Stop and redesign when any of these occurs:

- two corrective implementations fail;
- a new layer is proposed without a retired path;
- a safety check cannot name a distinct boundary;
- validation time exceeds implementation time without a release-boundary reason;
- the requested product behavior cannot be verified at the required acceptance
  level.

Elapsed time alone is not a reason to rewrite working code. If work runs much
longer than expected, report where time was spent and choose the next smallest
useful objective; do not churn the implementation to satisfy a time budget.

The handoff must state changed files, behavior owner, removed paths, before/after
authority counts, tests run/not run, runtime/product status, and remaining risk.
Do not claim completion because the code compiles or a large suite passed.
