# Linnet Changelog

[简体中文](CHANGELOG.md) · English

This file records application features, fixes, interaction improvements, and installation and update changes that users can experience after installing Linnet.
README, documentation, CI, build and release-script changes are not product version changes. For inherited Squirrel history, see the
[Squirrel changelog](https://github.com/rime/squirrel/blob/master/CHANGELOG.md).

## Unreleased

- Fixed the duplicated `.linnet-data` extension in the default personal-data export filename.

## 0.1.24 — 2026-09-11 (Preview)

### Chinese input

- Full pinyin and all seven double-pinyin layouts can compose Chinese sentences with whole English words, including multiple switches in phrases such as 跨region的migration and 我们需要align一下这个gap的solution.
- Added selectable English interpretations for ambiguous words such as size, mode and save while preserving Chinese choices and their consumed input ranges. Learned English boundaries carry across pinyin layouts.
- Preserved the existing CPU, DNS and HTTPS readings with Chinese correction enabled, and reduced accidental splits of complete English words into fragments.

## 0.1.23 — 2026-09-09

[Stable release 0.1.23 (105)](https://github.com/Ares-X/Linnet/releases/tag/v0.1.23) includes the settings improvements below and the Chinese correction and fuzzy-pinyin improvements from previews 0.1.21 and 0.1.22.

### Settings

- Chinese learning strategy, pinyin lookup and mode-switching help are now directly visible, removing unnecessary expansion for groups with few options. Fuzzy pinyin and Smart English remain collapsible.

## 0.1.22 — 2026-09-09 (Preview)

### Chinese input

- Fixed Chinese correction candidates taking priority over complete English words. Words such as `banana` regain their normal ranking.
- Reduced excessive adjacent-key correction searches to lower typing overhead. Each syllable supports one adjacent-key mistake, and multiple syllables can be corrected independently. Nasal-final and letter-transposition corrections remain available.

## 0.1.21 — 2026-09-09 (Preview)

### Chinese input

- Full pinyin and all seven double-pinyin layouts support adjacent-key and front/back nasal-final corrections. When the original code forms complete pronunciations, those readings retain priority, and pronunciation corrections rank ahead of adjacent-key corrections. Natural Code `hghk` offers “很好” and “更好” after candidates for the original reading.
- Added 12 optional fuzzy-pinyin pairs, including z/zh, n/l and en/eng, all disabled by default. They take effect after applying changes, without manual redeployment.
- Fixed correction candidates interfering with mixed Chinese/English sentence ranking, such as “检查CPU占用”.

### Settings

- Input settings use a single column of groups. Fuzzy pinyin, learning strategy and other detailed options can be expanded or collapsed. Fuzzy-pinyin pairs are organized by initials and finals, with selected pairs summarized when collapsed.
- Fixed a false application-failure report when rebuilding the fuzzy-pinyin index approached the request timeout.

## 0.1.20 — 2026-09-06

### Installation

- Fixed the installation helper incorrectly using the build machine's macOS version, causing installation on macOS 13–15 to fail because of missing Swift libraries.

- Fixed the complete installer rejecting first installations or reinstalls when a staging directory already existed. Existing staging contents are no longer mistaken for an old installation that must be uninstalled.

- The complete installer can repair an app with a missing `Contents` directory while preserving the app root referenced by the system. Input-source registration state no longer blocks installation.

### Recovery backups

- Removed fixed limits on cloud recovery history length and local delta size and file count. Uploading a backup requires no additional confirmation. When history is unusable, a new full backup is created while preserving existing files.

### Learning sync

- Chinese and English learning sync no longer requires prior use of the corresponding language or an open input document. The sync task prepares unloaded learning databases in the background.
- Sync handles learning data only; working copies of custom-word and text-expansion databases are no longer mistaken for learning databases to sync.

- Local snapshots are no longer imported repeatedly, and larger learning databases no longer stop syncing because of fixed size limits.

### Input and updates

- Language-data updates automatically download a full pack when no delta is available or a delta fails. Manual repair starts directly without a second confirmation.

- English words containing apostrophes retain prediction context after committing and participate in normal English ranking.
- Fixed candidate rendering with zero highlight corner radius and an expanded background.
- Core activation becomes usable again after cancellation. Old versions needed for recovery are no longer mistakenly removed by Settings startup cleanup.

## 0.1.19 — 2026-09-06

### Input and candidates

- The candidate context menu can add a word to custom words, prefilling the entry for saving after its code is confirmed. Forgetting another candidate's learning record no longer changes the original keyboard selection.
- Adding a candidate word reuses an already-open Settings window and preserves unsaved drafts.
- Lowercase Chinese/English mixed input uses the local model for whole-sentence ranking instead of forcibly inserting English abbreviations. Uppercase abbreviations explicitly typed with Shift remain unchanged.
- Fixed Chinese mode incorrectly splitting code identifiers such as `URLSession` into mixed sentences and intercepting arrow keys intended for the original text.

### Updates and sync

- Learning sync shows the last successful local sync time and distinguishes completion, pending retry, unavailability and failure. Normal waiting is no longer reported as the input method refusing an operation.
- Same-version language-data conflicts offer an explicit full repair, preserving personal data and unchanged packs.
- Fixed Core updates being incorrectly rejected when an app contains Finder display metadata. Updates and rollbacks preserve the identity of the input-method directory.
- When a cloud recovery backup cannot be extended, users can confirm creation of a new full baseline while retaining existing backups.

## 0.1.18 — 2026-09-05

### Candidate interaction

- In expandable mode, the first `]` or `=` expands candidates without moving the selection. Once expanded, `[]-=` moves to the actual adjacent row while preserving the column, rather than jumping to the end of the next row based on the compact page size.
- Moving upward to the first row preserves the current column. When no adjacent candidate row exists, paging symbols are handled as ordinary input.

## 0.1.17 — Preview

### Data and updates

- Fixed language-data delta updates being incorrectly rejected because of ordinary differences in directory read/write permissions. Pack completeness is still checked, and existing language-data updates can be retried.
- Core update downloads and retries now use the download source selected in Settings, matching language-data updates.

## 0.1.16 — Preview

### Smart English

- Common English prefixes offer completions by word frequency. Existing learning and contextual ranking also apply to ordinary prefixes, while paging still provides access to the complete candidate set.
- Fixed short uppercase prefixes being mistaken for complete words, preserving priority for original input and complete words.
- Unified score units for correction and dictionary candidates, improving completions such as `suppor → support` while retaining spelling corrections such as `mater → matter`.

### Chinese dictionaries

- Updated the Wanxiang dictionaries to v17.9.7, adding entries and updating frequencies while preserving Linnet's reviewed pronunciation corrections and candidate-ranking rules.
- Reduced garbage-collection pauses during continuous Chinese input and temporary allocations during pinyin-prefix expansion and syllable segmentation. Candidate order and selection rules remain unchanged.

### Candidate interaction

- Fixed the first arrow-key action after expanding vertical candidates jumping back to the first row. The selection from before expansion is preserved.
- Expanded columns fit complete words compactly and align vertically. Number labels and numeric selection follow the current row. When width is insufficient, fewer columns are shown instead of wrapping words.
- Expansion row and column settings appear only when expandable mode is selected. Switching back to scroll-only mode retains the chosen expansion settings.
- Horizontal expansion supports 3, 4 or 5 columns and maximum rows, defaulting to 5 columns and up to 3 rows. It shows only the rows needed, with a maximum of 5. Vertical expansion still supports 5, 6 or 7 candidates per row and up to 3 rows. Neither changes the compact page size.
- The English definition area shrinks to its actual content instead of reserving three blank lines for short definitions. It identifies the selected word at the bottom and uses higher-contrast definition text.

### In-Settings Core updates

- Fixed personal-data imports failing in installed Settings. Settings now includes the full set of Rime plugins needed to deploy input schemas.

- Users on 0.1.15 can download and apply new `.linnetcore` updates directly in Data & Updates, without opening Finder or Installer, entering a password, logging out or restarting.
- Stable and preview channels use their own Catalogs to select exact updates. After downloading, users must still explicitly click Apply Update…; Linnet does not replace Core automatically in the background.

## 0.1.15 — 2026-09-04

### Candidate grid

- Expandable candidates use a macOS-style multirow grid. Left/right moves one candidate at a time; up/down moves to the same column in an adjacent row. The window no longer repeatedly scrolls or shows only the first row while selection moves within the visible grid. It advances one row only when selection crosses the boundary.
- Numeric selection labels use consistent slots. Chinese and English candidate text remains aligned by column and baseline across adjacent pages, even where numbers are hidden. Incomplete final rows retain natural empty positions.
- Horizontal and vertical preferences retain their own compact layouts but share a row-based grid when expanded. Expanded English definitions stay below the grid and update with the highlighted candidate, rather than appearing on the right because of the original vertical preference.
- Smart English candidates explicitly identify English definitions. Chinese pronunciation corrections and pinyin comments no longer cause other Chinese candidates to incorrectly show a missing-definition placeholder.
- Candidates can still be expanded on the final page to view earlier entries. New input starts with compact candidates again.

### Core updates

- Version 0.1.15 continues to provide a Core PKG to older clients as a one-time bridge. After installing it, subsequent versions can download and apply a verified complete Core in Settings, without Finder, Installer, a password, logout or restart.
- The running Host continues to decide whether it can exit safely. Settings atomically swaps app contents only after checking the exact version, build, source revision, full code signature and fixed CMS identity. A failure preserves or restores the old Core.
- An identical version and build no longer prompts another update solely because the source revision differs. Releases must increment the build to identify a new Core.

## 0.1.14 — 2026-09-04

### Candidates and updates

- Shipped the candidate expansion and paging fix in a new Core version so installations still running early 0.1.11 builds can discover the update through either stable or preview channels. In expandable mode, candidates expand only after `[` / `]` or `-` / `=` actually changes the candidate page. New input starts compact again.
- Installed users only need to download the Core update in Data & Updates. Language data is unchanged, so neither the complete installer nor language packs need downloading again.

## 0.1.13 — 2026-09-04

### Core updates

- Core updates can be downloaded directly in Data & Updates. Settings shows progress, verifies size and SHA-256 against the Catalog, and reveals the package in Finder only after verification. Users no longer need to find the package on a release page or compare hashes manually.
- Clarified the message when installed and running Core share a version and build but differ in internal revision, explicitly identifying the pending internal revision change.
- Fixed the preview channel reporting “up to date” when the available Core had the same version and build but a different internal revision. A different Catalog revision continues to offer a verified update.

## 0.1.11 — 2026-09-03

### Input and definitions

- Fixed expandable candidates only scrolling between pages. Candidates start compact and automatically expand to at most three pages after `[` / `]` or `-` / `=` actually moves to another page. New input starts compact again.
- Fixed paging keys overwriting input on the first or last page. For example, typing `built-in` in Smart English no longer loses `built` at `-`.
- Fixed longer completions outranking explicitly entered text. Complete English words and uppercase abbreviations retain priority; for example, `WAFA` no longer ranks ahead of `WAF`.
- Continuous Chinese input supports uppercase abbreviations typed with Shift. Pinyin on either side continues matching and forming sentences without first switching to Smart English.
- Restored default Chinese punctuation: Chinese mode outputs `，。；：【】`. Corresponding half-width symbols are used only when English punctuation is explicitly selected.
- Expanded English definitions use a fixed detail area: below horizontal candidates and to the right of vertical candidates. The window stays the same size while switching candidates, long definitions are truncated to visible lines, and candidates without definitions show a clear placeholder.
- Smart English always offers correction and fuzzy matching, removing the inconsistent correction toggle. Expanded searches cover adjacent-key mistakes and adjacent-letter transpositions in long words while retaining original-input candidates.
- In Chinese mode, Chinese candidates for the same pinyin take priority over non-exact English corrections; for example, `the` no longer displaces `teh`. Exact English word matches retain their existing priority rules.
- Added common basic definitions for word families including agent, client, process, token and transformer, preventing technical senses from displacing meanings such as “代理人”, “过程”, “代币” and “变压器”. Corrected definitions for ordinary words, abbreviations and inflections: coast regains “海岸”, stats regains “统计数据”, watched no longer shows “手表”, and superlatives use corresponding Chinese expressions, while valid specialist meanings remain available.
- Automatic Chinese phrase learning uses the readings actually selected by the user, avoiding overwritten pronunciations from repeated polyphonic characters or interleaved input, and avoiding duplicate learning from whole-word selection.
- Smart English pinyin lookup needs no prefix and follows the current full- or double-pinyin layout without inheriting the Chinese lookup trigger. In English mode, `;` always passes directly to the current app. Chinese mode retains prefixed lookup using the current layout.

### Sync and backups

- Fixed Sync Now and the iCloud sync switch failing to reach the running Host. Requests now reuse authenticated Settings IPC and report success only after the Host accepts them.
- Fixed local custom-word and Text Expander databases being mistaken for learning databases, causing the Host to reject Sync Now. Incremental iCloud sync processes only actually loaded Rime learning databases.
- Sync settings are preserved when the sync directory is temporarily unavailable. Subsequent hourly checks retry instead of mistaking this condition for the user disabling sync.
- Opening Settings or enabling iCloud sync prepares the cloud directory in the background, avoiding blocked Settings windows when file services respond slowly.
- Learning sync no longer clears input sessions or waits for a full maintenance cycle. Cloud file I/O runs in the background, and local incremental merging yields the input thread, preserving current pinyin, candidates and undoable learning records. Unchanged cloud snapshots are not rewritten.
- Resuming a merge after cancellation, a database reopen or another device's snapshot change preserves word frequencies and learning results. Fixed candidate queries gradually slowing after repeated syncs. Oversized snapshots do not overwrite the last readable copy.
- Local recovery records preserve original learning databases through copy-on-write. Manual iCloud recovery backups create a baseline first, then upload only deltas, skipping uploads when nothing changes. Repairing damaged backups requires separate confirmation and does not automatically overwrite old records.
- Fixed intact recovery backups being incorrectly marked as damaged when iCloud Drive normalizes file permissions on another Mac. New baselines use consistent archive permissions across devices.
- Fixed custom words, disabled English words and text expansions failing to apply when Rime/LevelDB leaves a standard `lost` recovery quarantine directory. Incremental backups retain only the current learning-database state, neither copying obsolete recovery fragments nor deleting the original directory.
- Custom words, disabled English words and text expansions are written directly to local personal data. Ordinary Apply Changes rebuilds only changed personal dictionaries, reuses unchanged databases through incremental APFS cloning, and lets the running Host load them atomically instead of recompiling every input schema. Layout changes follow the selection in Settings rather than old Rime selection records.

### Installation and updates

- Data & Updates explicitly switches between stable and preview channels. Preview validates the same Core and language-data assets before stable publication. Stable remains the default, with no automatic fallback.
- Fixed first installation forcibly selecting an input source after submitting its enable request, causing Installer to fail with `OSStatus -50` and leave a partial installation. Selection remains under user and macOS control.
- Fixed Linnet disappearing from the system input menu and showing another enablement prompt after local builds, code analysis or complete repairs on a development Mac where Linnet was already installed and authorized. Temporary Hosts and frozen candidates no longer register as production input sources. The complete installer no longer exposes a second `Linnet.app` identity to PackageKit or Launch Services. Existing app authorization and selection remain unchanged, and builds no longer unregister system entries as cleanup.
- First installation still submits one standard enable request only after creating the unique `~/Library/Input Methods/Linnet.app`. Complete repairs of an existing app and routine Core updates do not register, enable or select input sources. Missing or disabled system registration is restored through macOS Keyboard settings, without repeated reinstalls or logouts.
- Fixed the community self-signed edition being incorrectly reported as damaged when the maintainer's Keychain was locked or a user had not trusted the development certificate. Installer verifies the frozen release identity and complete destination contents, without reading the maintainer's Keychain or requiring users to add a development certificate to system trust.
- Checking status or checking for updates no longer interrupts an ongoing Core activation. Success is shown only after the new Core reports that it is ready to run.
- Completed the Simplified Chinese text in the Core update confirmation page, removing English body text from that locale.
- Fixed Catalog conflicts when only Core changes and language packs remain unchanged, while keeping update records readable by older runtimes.
- Obsolete language packs can be cleaned up again. Current, rollback and pending data are retained, preventing read-only files from occupying disk space indefinitely.
- Core updates first verify the existing app's identity, integrity, version, input-source registration and language data, then atomically replace it with the complete packaged candidate. Stable releases and lower-build previews use the same online upgrade path. Language packs continue using deltas based on installed contents and reuse unchanged packs. Verification failures preserve the existing installation; complete repair requires explicit confirmation. Settings and other apps remain open during installation.
- The first transition from an older full installation to delta updates preserves the existing app and dictionaries, preventing the system installer from deleting files based on old installation receipts.
- Updates preserve the input-method app directory referenced by the system instead of moving the registered app entry to staging and deleting it.
- Fixed an open Settings window incorrectly reporting an unavailable version or an installation needing repair after upgrading, blocking access to applying the installed update.
- Complete-package repairs of existing installations no longer force a logout. First registration may still require one logout.
- After a Core upgrade, old Settings windows are prevented from modifying learning data using the old format, avoiding loss of records whose merges are incomplete. Reopening Linnet Settings allows work to continue without affecting typing in other apps.

## 0.1.10 — 2026-08-30

### Candidate windows and themes

- Interface themes update with Core. Settings previews and live candidate windows use the same themes without requiring language-pack updates. Selected themes, fonts and font sizes are preserved.
- Theme cards show real candidate styles, emphasizing differences in color and selection styling among 宣纸, 月华 and 青岩.
- Fixed candidate text overlapping English definitions and blank selection areas.

### Chinese input and English prediction

- Restored backward/forward paging with `[` / `]` and `-` / `=` while the candidate menu is open. Without a composition or candidate menu, `/ , . ; ' [ ] - =` passes directly to the current app. Schema-specific spelling keys retain their original meaning.
- Smart English next-word predictions show `1–9` labels matching numeric selection.
- Wanxiang remains the core Chinese dictionary and ranking source. Pinned rime-ice extension tables add missing entries of three or more characters, excluding duplicates, ambiguities and unverifiable readings, improving long proper names such as “希尔瓦娜斯”.

### Settings and updates

- Settings is organized into four pages: Appearance, Input, Dictionary, and Data & Updates. Chinese and Smart English options share the Input page.
- The Core update card always retains access to applying installed updates and separately shows installed and running versions. Users do not need to quit TextEdit, Teams, browsers or other apps.
- Fixed update prompts when local language data is ahead of the update channel. Downgrades and conflicting data with the same sequence are rejected before downloading.
- Core updates preserve installed language packs. Missing apps or input-source registration explicitly direct users to the complete installer for repair instead of Core attempting first registration.

## 0.1.9 — 2026-08-28

### Candidate windows and English definitions

- Redesigned Smart English definitions. Horizontal definitions stay within the compact candidate frame; vertical definitions use a separate narrow sidebar. Long definitions wrap automatically, with nouns, verbs, adjectives and names on separate lines to reduce screen usage.

### Settings and runtime status

- Language-pack and runtime status load asynchronously to reduce the wait when opening Settings. The version page separately shows installed and running Core versions, builds and revisions.
- Fixed newly opened Settings failing to connect to the still-running Linnet Host after Core files were updated.
- Opening an already-running Settings from the input menu brings its window to the foreground instead of leaving it behind other apps.
- During transition from 0.1.8, if the running Core cannot establish that old app connections were safely released, Settings explicitly requires a normal login or restart for this update and keeps immediate activation unavailable. This avoids another loss of keyboard input in apps such as TextEdit. After the new Core has run, later updates can still be applied directly.

### Updates and stability

- Installing Core updates no longer stops the current Host, re-registers input sources or disconnects existing app input connections. When safety conditions are met, users can apply installed updates explicitly. Otherwise, current input keeps working and the new Core takes effect at the next login or restart.
- The Host continues reusing process-wide Chinese dictionaries and prewarmed English data to reduce first-candidate latency in new apps, while preventing build or cache copies from accidentally starting as the production input Host.

### Upgrading from 0.1.8

- Installation itself requires neither logout nor closing active apps. The public 0.1.8 Host does not support the new safe-activation protocol. If Settings cannot apply the new Core immediately, the new code takes effect at the next login or restart. The new no-logout activation flow becomes available for subsequent updates after 0.1.9 has run.

## 0.1.8 — 2026-08-27

### Input experience

- Fixed noticeable candidate-window delay on the first Chinese input in a new app. The Linnet Host prewarms and reuses dictionary and model resources while preserving independent uncommitted text, cursor and candidate sessions for each app.
- Chinese mode supports continuous mixed phrases such as “学习 CS 急停”, “了解 AI 技术” and “使用 CPU 性能”. Ordinary Chinese pinyin retains priority, while standalone abbreviations keep both Chinese and English candidates.
- In Natural Code, standalone `a` ranks the common character “啊” first while preserving frequency learning when users choose other characters.
- Fixed selecting full pinyin in Settings while the status bar and actual input remained in double-pinyin mode. All eight layouts now follow the selected setting.
- Tapping Shift with uncommitted letters in Chinese or Smart English commits those letters unchanged before switching modes, rather than choosing the first Chinese candidate or accepting an English completion.
- Fixed leftover candidate-window height, blank space at the bottom and mismatches between pointer hit areas and actual drawing bounds after layout changes.
- Candidate hover, press, wheel paging and page buttons share the same interaction state. Clicking outside the candidate window still goes to the current app.

### Input-source and candidate stability

- Restored a single Linnet system input source. Full pinyin, double pinyin and Smart English remain internally managed by Linnet rather than registered as competing system input sources.
- Fixed occasional ASCII-only input, one-time input or disappearing candidates after switching to another input method, toggling Caps Lock or quickly returning to Linnet. Input-source activation and candidate publication for each text field are again managed by the macOS InputMethodKit lifecycle.
- Fixed old state overwriting current candidates when schema application, session disposal and delayed callbacks interleaved. Expired sessions no longer interfere with the active input field.

### Settings stability

- Fixed occasional crashes and wrong-row deletion while editing or deleting custom words, disabled words and Text Expander entries in Settings. Page switching and repeated additions/deletions no longer access deleted rows.
- Transiently incomplete layouts in the candidate appearance preview no longer terminate Settings.
- Fixed Discard Changes failing to close the window when unapplied changes existed. Continue Editing, Apply and Discard now perform their respective actions.
- The Input page's single-option Advanced group is now directly visible. The auxiliary-code character-priority switch no longer requires expansion.

### Installation and updates

- Core overwrite updates no longer terminate, start in the background or hide the Linnet Host serving apps. Existing input connections, candidate windows and mode indicators stay available. The new version takes effect when the Host next starts naturally.
- The fixed app path is registered only on first installation when no Linnet record exists. Later updates do not repeatedly register, enable or select the input source, require another logout or re-addition, or repeat authorization prompts.
- The Host, Settings and embedded libraries use a long-term fixed, free CMS identity. Installation and updates do not ask for a Keychain password.

## 0.1.7 — 2026-08-23

### Input experience

- Reduced unnecessary cursor-position queries and empty-text commits while input is idle, lowering latency and timeout risk during candidate dismissal, mode switching and cross-app input.

### Personal data

- iCloud Drive learning sync uses the fixed product directory `iCloud Drive/Linnet`. Users no longer need to choose a folder after enabling it. Incremental Rime sync continues at most once an hour.

## 0.1.6 — 2026-08-22

### Input experience

- Fixed Shift language switching failing to show the cursor-side mode indicator when no candidates were present.

### Personal data

- Added optional iCloud Drive learning sync in Settings, directly reusing Rime's multi-device incremental merging. Automatic checks run at most once an hour, and users can trigger sync immediately.
- Automatic sync handles only Rime learned words. It does not automatically upload full backups, settings, custom words, disabled words or Text Expander entries. Complete personal data still transfers through separate manual recovery archives.

## 0.1.5 — 2026-08-21

### English input

- Added a switch on the English settings page to append a space when committing a candidate with Space. It defaults to on to preserve continuous typing behavior. When off, Space commits only the selected candidate without appending a space.

## 0.1.3 — 2026-08-21

### Update experience

- Opening Settings reads the repository's fixed Catalog, showing Core updates, language-data updates or an up-to-date status, with manual rechecking available.
- Core notifications open only the same-repository update page bound by the Catalog, without silently installing unsigned software. Users who have completed first installation and one logout do not need to log out again for subsequent Core updates.
- Enabled the language-data update channel. Packs download only after an explicit user action, retaining verification, transactions, atomic activation and rollback on failure.

## 0.1.2 — 2026-08-21

### Installation experience

- First installation uses one complete installer. Users no longer need to identify or manually combine Core and language packs.

## 0.1.1 — 2026-08-20

Linnet's first public community release.

### Bilingual input experience

- One macOS input source supports Chinese, Smart English and raw ASCII modes.
- Tap either Shift key to switch between the current Chinese layout and Smart English. Caps Lock provides raw ASCII.
- Compact mode indicators, stable candidate navigation, and horizontal or vertical candidate layouts.

### Chinese input and pinyin lookup

- Eight layouts—full pinyin, Natural Code, Xiaohe, Microsoft, Sogou, Smart ABC, Ziguang and Pinyin Jiajia—share Chinese dictionaries and learning data.
- Chinese candidates use pinned Wanxiang data with auditable Linnet pronunciation and ranking corrections.
- Look up English words using the current full- or double-pinyin code, with `;` or `|` as the selectable trigger.
- Support for Simplified/Traditional Chinese, Emoji, Chinese/English punctuation, auxiliary codes, symbol commands, Unicode input and a local calculator.

### Smart English

- Prefix completion, spelling suggestions, IPA, Chinese definitions, contextual ranking and next-word prediction.
- Preserves capitalization, spaces in continuous English input, and original URLs, email addresses, paths, version numbers and code identifiers.
- Original input always remains available as a safe candidate. Tab can accept intelligently, navigate candidates or pass through to the current app.
- Custom words, disabled words, Text Expander and independent management of Chinese and English learning data.

### Appearance, settings and personal data

- Seven light/dark themes: 宣纸, 月华, 青岩, 陶印, 雾青, 原生玻璃 and 墨朱.
- Native Settings manages input, dictionaries, English, appearance, data and local candidate previews.
- Personal-data import/export, automatic backups, recovery and removal of Chinese and English learning data.
- Input processing stays offline. Language-data updates can be initiated only by the user in Settings.

### System support

- Apple Silicon Macs running macOS 13 or later.
