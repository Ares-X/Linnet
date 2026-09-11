# Linnet

[简体中文](README.md) · English

<p align="center">
  <img src="resources/branding/readme-banner.svg" width="680" alt="Linnet — Chinese and English, in one flow">
</p>

<p align="center">
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/License-GPL--3.0--or--later-blue" alt="License: GPL-3.0-or-later"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-blue" alt="Apple Silicon arm64">
  <a href="https://github.com/Ares-X/Linnet/actions/workflows/pull-request-ci.yml"><img src="https://github.com/Ares-X/Linnet/actions/workflows/pull-request-ci.yml/badge.svg?event=pull_request" alt="PR CI"></a>
</p>

Linnet (双韵) is an open-source bilingual input method for macOS. Chinese input and Smart English share a single system input source: tap Shift to switch between them, or use Caps Lock for raw, unconverted ASCII input.

**One input source. Two languages. One continuous typing experience.**

> [!NOTE]
> For a first installation, download `Linnet.pkg`. The community edition has no Apple Developer ID signature or notarization, so macOS may require you to approve it manually. Release notes include a SHA-256 checksum for verifying your download.

**[Download the latest Linnet.pkg](https://github.com/Ares-X/Linnet/releases/latest)**

The current stable release is **[0.1.23 (105)](https://github.com/Ares-X/Linnet/releases/tag/v0.1.23)**. It includes fuzzy pinyin, adjacent-key correction and related fixes, and keeps small groups of settings directly visible. See the [changelog](CHANGELOG.en.md) for changes in each version.

**[0.1.25 Preview (107)](https://github.com/Ares-X/Linnet/releases/tag/core-v0.1.25)** includes improved continuous Chinese/English composition and fixes for export filenames and interface language. Existing users can download and apply the Core update in **Settings → Data & Updates → Preview**.

[Features](#features) · [Installation](#installation) · [Usage](#usage) · [Updating and uninstalling](#updating-and-uninstalling) · [Privacy](#privacy) · [Contributing](#contributing)

## Why Linnet

- **Easy language switching:** Chinese and Smart English use one macOS input source, so you do not have to search the system input menu to switch languages.
- **Complete Chinese input:** Full pinyin and seven double-pinyin layouts share Chinese candidates, learning data and a local language model.
- **Mixed sentences in Chinese mode (Preview):** Type phrases such as 跨region的migration continuously. Whole English words join the surrounding Chinese in the same candidate, without switching modes mid-sentence.
- **English writing support:** Smart English offers completion, spelling suggestions, IPA, Chinese definitions, contextual prediction and continuous input handling, while always keeping your original text available.
- **Offline and under your control:** Personal words, learning data, Text Expander entries and backups stay on your Mac by default. When enabled, macOS syncs Rime learning data through the fixed `iCloud Drive/Linnet` folder.
- **Native macOS experience:** Menu bar status, candidate windows and Settings work together, with light and dark appearances and multiple candidate themes.
- **Separate application and language-data updates:** Application updates reuse installed dictionaries and models. Language packs prefer delta downloads. Versions supporting in-Settings Core updates can update without closing other apps or logging out again.
- **Quick access to reusable text:** Custom words participate in normal candidates and learning. Text Expander turns short codes into addresses, email addresses or standard replies. Dictionary changes reload only the personal entries that actually changed.

### Built on established projects, refined by Linnet

Linnet builds on Squirrel and librime, with data and capabilities from Rime Wanxiang, RIME-LMDG, rime-ice and Hallelujah. It adds reviewed Chinese corrections, a native Smart English extension, candidate interactions, and macOS settings and updates. See [third-party notices](THIRD_PARTY_NOTICES.md) for sources, modifications and licenses.

## Features

### One input source, three clear modes

| Mode | Menu bar | Use cases |
| --- | --- | --- |
| Chinese | `中` or `双` | Full pinyin or the selected double-pinyin layout, Chinese candidates and the local language model |
| Smart English | `En` | English completion, correction, definitions, pronunciation and contextual prediction |
| Raw ASCII | `A` | Code, passwords, terminals and any text you want to enter without conversion |

Tap either Shift key to switch between Chinese and Smart English. Caps Lock enters or leaves raw ASCII mode.

![Linnet cursor indicators for Chinese, Smart English and raw ASCII](resources/readme/input-modes.png)

_The indicator beside the cursor shows the current mode. The menu bar also displays `中`/`双`, `En` or `A`._

### Chinese input

Linnet starts with full pinyin. Settings also offers Natural Code (自然码), Xiaohe (小鹤), Microsoft, Sogou, Smart ABC, Ziguang (紫光) and Pinyin Jiajia (拼音加加) double-pinyin layouts. All eight layouts share the same Chinese dictionaries and learning data, so switching layouts does not reset your learned word frequencies. Candidate output supports both Simplified and Traditional Chinese.

Chinese input provides suggestions for adjacent-key mistakes and front/back nasal-final confusion by default. When the original code forms complete pronunciations, those pronunciations retain priority; pronunciation corrections rank ahead of adjacent-key corrections. For example, Natural Code `hghk` still prioritizes its original `heng hao` reading, followed by suggestions such as “很好” and “更好”. Full-pinyin input is interpreted as full pinyin.

Adjacent-key correction handles one mistyped key per syllable; multiple syllables may each receive a correction. Valid double-pinyin codes and abbreviated pinyin remain available.

Under the Chinese layout in **Settings → Input**, expand the fuzzy-pinyin group to select from 12 initial/final pairs, such as z/zh, n/l and in/ing. All are unchecked by default. The collapsed group summarizes your selection. Selected pairs participate as fuzzy readings rather than only weak correction suggestions, while preserving the original reading. Click **Apply Changes** to activate them.

For Chinese learning, choose standard Rime learning, Linnet enhanced learning or no learning. Enhanced learning reinforces uncommon phrases assembled character by character. English learning has its own switch. Turning learning off keeps existing records, which become available again when learning is re-enabled; delete them explicitly in **Data & Updates** if needed.

Chinese candidates support horizontal, vertical and expanded multirow layouts. Compact pages can contain 3, 5, 7 or 9 candidates. In the expanded grid, use the arrow keys to move between candidates, or choose to always scroll by page.

**Continuous Chinese/English composition (Preview, starting with 0.1.24):** Stay in Chinese mode, type Chinese using your selected pinyin layout, and type English words in their original spelling. You can switch languages several times within a sentence before committing, without changing modes. For example:

| Continuous keystrokes in Natural Code | Committed text |
| --- | --- |
| `kwregiondemigration` | 跨region的migration |
| `womfxuykalignyixwvegegapdesolution` | 我们需要align一下这个gap的solution |

![Real VM recording of continuous Natural Code input for 跨region的migration](resources/readme/mixed-region.gif)

![Real VM recording of continuous Natural Code input for 我们需要align一下这个gap的solution](resources/readme/mixed-align.gif)

_Real key events, native candidates and committed text in a Safari text field, recorded in a macOS VM running 0.1.25 Preview with Natural Code double pinyin and three candidates per page. Automated key events, played at the recorded speed. Full pinyin and the other six double-pinyin layouts use their own Chinese codes with the same English spelling._

Ambiguous words such as `size`, `mode` and `save` offer selectable English interpretations alongside Chinese candidates. With Chinese learning enabled, selected mixed phrases and English word boundaries carry across pinyin layouts. Context and learning still determine the order; choose another candidate when the input is ambiguous.

Hold Shift to type uppercase abbreviations such as `CPU`, `DNS` and `HTTPS`. They retain their spelling while the pinyin on either side continues to form Chinese sentences.

Additional input tools include:

- `Shift+V`: symbol commands;
- `U` + a hexadecimal code point: Unicode input;
- `cC` + an expression: local calculator;
- `uU` + full pinyin: character-component lookup;
- `|` + the current pinyin code: look up English words from Chinese mode. You can explicitly select `;` instead in Settings.

### Smart English

Smart English supports continuous English writing and entering occasional English terms while working in Chinese:

- Prefix completion, spelling correction, fuzzy matching and next-word prediction, ranked using word frequency, learning and context;
- Optional IPA and Chinese definitions;
- Preservation of initial capitalization and all-uppercase input;
- A setting to append a space when committing with Space;
- Preservation of URLs, email addresses, paths, version numbers and code identifiers where possible;
- Original input always remains available. Complete English words and clear all-uppercase abbreviations take priority over longer completions.

Configure Tab to accept intelligently, navigate candidates or pass through to the current app. Press `Esc` to dismiss the current prediction and clear the current English context.

![Linnet pinyin-to-English lookup and Smart English candidate windows](resources/readme/bilingual-features.png)

_Left: pinyin-to-English lookup in Chinese mode. Right: English completion with IPA and Chinese definitions._

### Appearance and customization

For horizontal expansion, choose 3, 4 or 5 columns and a maximum of 3, 4 or 5 rows; the default is 5 columns and up to 3 rows. Vertical expansion supports 5, 6 or 7 candidates per row, with up to 3 rows. Expansion settings do not change the compact candidate count.

Seven candidate-window themes are available: 宣纸, 月华, 青岩, 陶印, 雾青, 原生玻璃 and 墨朱, each with light and dark variants. Chinese and English can independently use horizontal or vertical compact layouts; expanded candidates use a multirow grid. English definitions appear below the grid, follow the highlighted candidate and resize to their content without reserving empty space. Fonts, font sizes, candidate counts and expansion behavior are also configurable.

![Light and dark renderings of Linnet's seven candidate themes](resources/readme/theme-gallery.png)

### Download size and disk usage

The complete installer includes the application, Chinese and English dictionaries, a local language model and supplementary data. Core updates replace only the application. The following are reference sizes for a fixed release, using decimal MB:

| Content | Size | Notes |
| --- | --- | --- |
| Complete installer | **About 428 MB** | `Linnet.pkg`, including offline language data |
| Core update | **About 7 MB** | Application only; reuses installed dictionaries and models |
| [Pinned LTS model](upstreams.lock.json) | **420.25 MB** | Uncompressed model size; already included in the complete installation, with no additional download required |

**Download size is not installed disk usage.** Your disk also stores extracted language data, generated input schemas, learning records and backups. Total usage varies over time. The model's file size does not mean it stays entirely resident in memory.

Separating Core and language packs lets routine application updates reuse large language assets. Language updates prefer deltas and reuse unchanged packs. If no suitable delta is available, or a delta fails, Linnet downloads the corresponding full pack automatically.

## System requirements

- An Apple Silicon Mac (arm64);
- macOS 13 or later.

## Installation

### Get the community edition

Download just one file, **`Linnet.pkg`**, from the project's **[Latest Release](https://github.com/Ares-X/Linnet/releases/latest)**. To verify it, run this command in your download folder:

```bash
shasum -a 256 Linnet.pkg
```

The result should match the SHA-256 in the same release's notes. Linnet installs in the current user's home directory, requires no administrator privileges and installs no daemon, startup item or privileged helper.

### Enable Linnet for the first time

1. In Finder, Control-click or right-click the downloaded `Linnet.pkg`, choose **Open**, and confirm **Open** again. If that option is unavailable, open **System Settings → Privacy & Security**, choose **Open Anyway** beside the Linnet warning, then return to Installer.
2. In macOS Installer, choose **Continue → Install** and wait for success. Linnet installs only at `~/Library/Input Methods/Linnet.app`. Do not manually move or copy the app elsewhere.
3. Save your work, log out of your macOS account and log back in. This first-install step lets macOS finish registering the input source. Subsequent Core updates do not require another logout.
4. Open **System Settings → Keyboard → Text Input → Edit**. If Linnet is listed, make sure it is enabled. Otherwise, click **+**, find **Linnet**, click **Add**, and approve the input source when macOS asks.
5. Select **Linnet**, with the bird icon, from the menu bar input menu. Selection is controlled by you and macOS; the installer does not switch for you. There is only one Linnet input source, so you do not need to add Chinese and English separately.
6. Check that the menu bar shows `中`/`双` and that pinyin produces Chinese candidates. Tapping Shift on its own should show `En` for English; Caps Lock should show `A`. **Settings** in the input menu should open the settings window.

After initial installation, check, download and apply Core updates in Settings without adding the input source again. Older versions need a one-time bridge upgrade; see [Updating and uninstalling](#updating-and-uninstalling). **A successful installation does not necessarily mean the new code is running:** legacy installers replace files on disk, after which you must apply the installed update in Settings. See [Applying a Core update](#applying-a-core-update).

Linnet does not automatically approve system permissions, select input sources or disable them. If macOS removes or disables Linnet, add or enable it again in **System Settings → Keyboard → Text Input → Edit**. Because the community package has no Apple Developer ID signature or notarization, an unidentified-developer warning is expected. Verify that the package came from this project's release before approving it manually. Do not disable Gatekeeper, clear quarantine attributes or run installation commands from unknown sources. Stop if the checksum differs or macOS reports that the file is damaged.

## Usage

### Look up English words using pinyin

If you remember a word's Chinese meaning, use pinyin to find its English equivalent without leaving the input window. In Chinese mode, enter the trigger selected in Settings, followed by the current full- or double-pinyin code. The default trigger is `|`; semicolon becomes a trigger only if you explicitly choose `;`.

```text
|suanfa  → algorithm
```

With Natural Code selected, the same example is `|srfa`. In Smart English, enter the current full- or double-pinyin code directly, without a lookup trigger. Ordinary English candidates remain ahead of pinyin results, and the original input stays available. Punctuation such as `;` always passes directly to the current app in Smart English.

### Custom words and Text Expander

Use **Settings → Dictionary** for frequently used names, phrases and fixed text:

- **Custom words** pair display text with a lowercase Rime code and participate in normal candidates and learning.
- **Disabled English words** hide whole-word matches without regard to case across static, learned, correction, pronunciation and prediction candidates.
- **Text Expander** triggers must begin with `x;`. Unknown triggers remain unchanged. Expanded text is not further modified by capitalization, spacing or definition handling.

Right-click a candidate and choose the option to add it to custom words. This fills a dictionary draft; confirm its code and click **Apply Changes** to save it. You can also forget a candidate's learning record from the context menu, though built-in words may still appear. To hide an English word, use the disabled-word list.

For example, create the trigger `x;addr` with your full address as its expansion. Typing that short code will insert the saved text.

Click **Apply Changes** to save.

## Settings

Open **Settings** from the macOS input menu. The interface supports English and Simplified Chinese. Settings is embedded in `Linnet.app`; it is not installed as a separate application and does not remain in the Dock.

| Tab | Controls |
| --- | --- |
| Appearance | Seven themes, light/dark appearance, fonts, font sizes, candidate counts, horizontal/vertical layouts and expansion |
| Input | Chinese: full/double pinyin, learning, Simplified/Traditional output, Emoji, punctuation, auxiliary codes and lookup. Smart English: capitalization, IPA, definitions, prediction, learning, trailing spaces and Tab behavior. English correction and fuzzy matching are always available |
| Dictionary | Custom words, disabled English words and Text Expander |
| Data & Updates | Core and language-pack versions, incremental learning sync through iCloud Drive, manual incremental recovery backups, transaction recovery records, import/export, learning-data removal and privacy-filtered diagnostics |

The appearance preview uses the selected theme, font size and layout. Input-behavior changes take effect when you click **Apply Changes**. Do not manually edit generated `linnet_user.custom.yaml`, `squirrel.custom.yaml`, `default.custom.yaml` or schema custom files.

In **Data & Updates**, choose the stable channel (default) or preview channel to see installed and available application and dictionary versions. Language updates prefer deltas and reuse unchanged packs. If no suitable delta exists or a delta fails, Linnet downloads the changed packs in full. Current data remains active until the new data is ready.

If Settings reports conflicting packs with the same version, use the language-data repair action to download changed or conflicting full packs from the selected channel. Repair preserves learned words, personal settings and unchanged packs. It does not downgrade packs or require reinstalling the input method.

## Updating and uninstalling

Linnet never modifies Core automatically in the background. When Settings finds an update, it downloads and verifies the exact file identified by the Catalog only after you click **Download Core Update**. Once the 0.1.15 bridge release is installed, subsequent Core updates can be applied with **Apply Update…** in Settings. Switch to another input source first and leave your other apps open. No Installer, password, logout or restart is needed.

Stable release pages provide only the complete installer. The `core-v<version>` prerelease pages supply no-logout updates for existing users; `data-<sequence>` prerelease pages supply language-data updates for Settings. Neither becomes the Latest Release.

Version 0.1.15 is a one-time bridge release. Versions 0.1.14 and earlier using the fixed CMS signing identity still download a legacy Core PKG and show **Open Legacy Installer…**. Follow the macOS prompts to complete this one upgrade. Afterward, download and apply Core updates in Settings without locating release assets or comparing hashes manually. For 0.1.7 or earlier ad-hoc-signed installations, or a missing or damaged app, use the complete `Linnet.pkg` to repair the installation.

### Applying a Core update

1. Open **Settings** from the Linnet input menu.
2. Go to **Data & Updates → Core update**. Check **Installed** and **Running**: the first is the on-disk version; the second is the version actually loaded by the input-method process.
3. If a Core update is available, click **Download Core Update** and wait for download and verification to finish.
4. Finish or cancel your current composition, then switch to another input source from the macOS input menu. Leave your application windows open.
5. For an online update, click **Apply Update…**. If you just completed the bridge through a legacy PKG, click **Apply Installed Update…**. These are separate from **Apply Changes**, which saves settings.
6. Switch back to Linnet and type a few characters to confirm that candidates work. Return to the Core update card and check that **Running** matches **Installed**.

If Settings still shows old information after upgrading, close its window and reopen it from the Linnet input menu. You do not need to quit other apps.

Online Core updates only install a higher version. To repair an app at the same version, use the complete `Linnet.pkg`. A disabled apply button is normal when no update is pending. If you have unsaved settings or an ongoing data operation, finish the action requested by the page first. If activation is blocked, follow the card's explanation and retry. Linnet will not switch input sources for you or force user apps to close. If an older Host cannot apply updates within the current session, it explicitly asks you to wait until the next normal login or restart; repeatedly reinstalling or deleting the input source is unnecessary. Hosts supporting in-session updates do not require logout.

Normal upgrades between fixed-CMS releases use only Core. Use the complete `Linnet.pkg` for 0.1.7 or earlier ad-hoc versions, or when the app is missing, damaged or has a mismatched release identity. The complete installer preserves healthy installed language packs and personal data. If the app already exists, it leaves input-source state alone. Resolve missing registration or a disabled source in **System Settings → Keyboard → Text Input → Edit**, rather than repeatedly requesting authorization through Installer. Reinstallation does not require uninstalling first or clearing system registration state.

### Uninstalling

Switch to another input source from the macOS input menu, log out and back in, then open only Terminal. The commands below run locally and do not download or execute network scripts. They permanently remove the local Linnet app, all local personal data, backups, preferences and installation receipts. Export anything you want to keep first.

```bash
/usr/bin/find -P "$HOME/Library/Application Support/Linnet" -x -type d -exec /bin/chmod u+rwx {} + 2>/dev/null || true
/bin/rm -rf -x -- "$HOME/Library/Input Methods/Linnet.app" "$HOME/Library/Application Support/Linnet"
/usr/bin/defaults delete io.github.ares-x.inputmethod.Linnet 2>/dev/null || true
/usr/bin/defaults delete io.github.ares-x.inputmethod.Linnet.settings 2>/dev/null || true
/bin/rm -f -- "$HOME/Library/Preferences/io.github.ares-x.inputmethod.Linnet.plist" "$HOME/Library/Preferences/io.github.ares-x.inputmethod.Linnet.settings.plist"
/usr/sbin/pkgutil --volume "$HOME" --pkgs | /usr/bin/grep '^io\.github\.ares-x\.inputmethod\.Linnet\..*\.pkg$' | while IFS= read -r receipt; do /usr/sbin/pkgutil --volume "$HOME" --forget "$receipt" >/dev/null; done
```

Log out and back in once more to refresh the macOS input-source list. Manage iCloud Drive sync data, recovery backups and files exported to other locations separately.

## Troubleshooting

### Linnet is missing from the system

- Confirm that it is installed at `~/Library/Input Methods/Linnet.app`.
- Complete an actual logout and login.
- Manually add and allow Linnet in **System Settings → Keyboard → Text Input → Edit**.
- Control-Space cycles only through input sources enabled by macOS. Linnet does not take over this system shortcut.

### Only Latin letters appear

- Menu bar shows `A`: turn Caps Lock off.
- Menu bar shows `En`: tap Shift to return to Chinese.
- Neither `中` nor `双` appears: choose and apply a Chinese layout in **Settings → Input**, then select Linnet again.

### Settings cannot apply changes

Do not manually edit generated YAML. Refresh and copy diagnostics in **Data & Updates → Diagnostics**. Review text and screenshots before publishing them to avoid disclosing personal information.

### Reporting an issue

Include your macOS version, Mac chip, Linnet version, downloaded file's SHA-256, current input mode, Rime schema, affected app and the smallest input that reproduces the problem. Do not submit personal dictionaries, learning databases, private keys, certificate passwords or your entire user directory.

## Privacy

Linnet has no account system, telemetry, ads or analytics SDK. It does not call online translation, spelling or generative-model services. Input processing happens locally. Personal dictionaries, learning data and local backups are stored by default in:

```text
~/Library/Application Support/Linnet/
```

If you enable iCloud sync or upload a backup manually, the corresponding personal data also enters your iCloud Drive.

Linnet reads other Rime or Hallelujah data only when you explicitly choose to import it in Settings. Exported files can contain personal data you selected; you are responsible for storing and deleting those files.

Optional iCloud learning sync shares Chinese and English learning records through `iCloud Drive/Linnet`. Automatic checks run at most once an hour, and you can also sync immediately. You can keep typing while it runs; neither prior use of both language modes nor an open input document is required.

Settings shows the last successful local merge and export times, along with failure or retry status. Local completion does not mean another Mac has received the data: iCloud Drive handles cross-device delivery.

Automatic sync covers learned words only. It does not sync custom words, disabled words, Text Expander entries or settings. For migration or recovery, use **Data & Updates** to upload and review recovery backups, or import/export personal data. Imports require confirmation and create a local backup first. If no usable cloud backup history exists, uploading creates a new full backup without deleting existing backups.

Settings handles update networking. Opening Settings requests a small update catalog from GitHub to check versions. Core and language-data files are downloaded only after you explicitly start the relevant update. Both use the download source selected in **Data & Updates**. Changing the source affects only subsequent downloads; sources do not switch or fall back automatically. Third-party download mirrors may see your IP address, request time and public file URL, but Linnet sends no personal dictionaries, learning data, backups, diagnostics or credentials to GitHub or mirrors.

## Contributing

Building Linnet requires an Apple Silicon Mac, macOS 13+, full Xcode, Git and `ripgrep`. The project primarily uses Swift/SwiftUI, C++, Shell and Ruby, and does not bundle a Python runtime.

```bash
./action-build.sh release
tests/verify_swift_units.sh --list
tests/verify_swift_units.sh --only OWNER
```

Ordinary development requires neither a signing certificate nor registering the local build as a system input method. See the [development guide](docs/development.md) for repository structure, data generation, upstream synchronization, test levels and local acceptance. See the [release guide](docs/release.md) for packaging, signing and publication.

## Versions, sources and licenses

See [Latest Release](https://github.com/Ares-X/Linnet/releases/latest) for the current stable version, and the [changelog](CHANGELOG.en.md) for preview versions and user-visible changes.

Linnet is an independent community distribution derived from Squirrel, not an official release of any upstream project. This repository modifies upstream code and data; its first public modified release was dated 2026-08-20. The main relationships are:

| Upstream | Use and modifications in Linnet | License summary |
| --- | --- | --- |
| [Squirrel](https://github.com/rime/squirrel) / [librime](https://github.com/rime/librime) | macOS input-method and Rime runtime foundations; modified product identity, single-source bilingual workflow, candidate interactions, native Settings and release packaging | GPL-3.0-only (Squirrel); BSD-3-Clause (librime) |
| [Rime Wanxiang](https://github.com/amzxyz/rime-wanxiang) | Core Chinese dictionaries and eight full-/double-pinyin layouts; pinned upstream tables with reviewed pronunciation, code and ranking corrections | CC BY 4.0 |
| [RIME-LMDG](https://github.com/amzxyz/RIME-LMDG) | Pinned Wanxiang LTS language model bundled for offline use | CC BY 4.0 |
| [rime-ice](https://github.com/iDvel/rime-ice) / [HallelujahIM](https://github.com/dongyuwei/hallelujahIM) | Selected rime-ice Chinese extension entries of three or more characters, English, components, symbols, Emoji/OpenCC and Lua inputs; selected Hallelujah frequency, pronunciation and definition inputs. Linnet data is generated through deterministic projection, normalization and manual review | GPL-3.0-only; see third-party notices for exact scope |
| librime-lua, librime-octagram, librime-predict and other runtime dependencies | Statically integrated or embedded in the app, rather than used as a second product source | See third-party notices, release NOTICE and SBOM |

See [third-party sources, modifications and licenses](THIRD_PARTY_NOTICES.md) for complete attribution and scope, and [`LICENSES/`](LICENSES/) for license texts. Stable distribution packages also carry `NOTICE.md`, `SBOM.spdx.json`, `VERSION.json` and license files tied to the exact version and commit, so the delivered contents have their own precise records beyond this README summary.

Linnet's own source code is licensed under [GPL-3.0-or-later](LICENSE.txt).
