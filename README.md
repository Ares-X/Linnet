# Linnet product website

Static product site for `https://ares-x.github.io/Linnet/`. GitHub Pages serves
this directory from `gh-pages`. No dependency install or build step is required.

## Page owners

- `index.html`: product overview, real input recording, feature-to-guide links,
  theme gallery, installation summary and release links.
- `guide.html`: usage and configuration instructions. Common actions are visible;
  technical details and repair procedures use native disclosures.
- `style.css`: shared neutral light/dark appearance, responsive product layout,
  desktop guide sidebar and mobile chapter menu.
- `script.js`: accessible theme tabs, guide chapter highlighting, mobile navigation,
  fragment disclosure handling and clipboard feedback. Page content and navigation
  remain available without JavaScript; the theme gallery then shows all themes.

Keep the approved introduction: “Linnet 双韵 / 为 Mac 打造的开源双语输入法。
支持连续中英混输，内置离线英文辅助。” Feature descriptions should explain
specific behavior, without invented slogans or unsupported exclusivity claims.

## Content and media sources

Copy was checked against the main README and settings/schema owners at
`fb5317f7d479fd75f4ab33892d0efd1fdc220ee1`. Input settings, reverse lookup,
learning/sync scope and update steps must stay aligned with the product.
Code/documentation inspection does not establish new installed-product acceptance.

- `bilingual.png`, `input-modes.png`, `themes.png`: existing product renders from
  `resources/readme/`. CSS frames regions of the originals without changing the
  image files. Theme images retain the product's own colors.
- `mixed-align.mp4`: converted from `resources/readme/mixed-align.gif` at original
  speed (6.4 seconds), with `mixed-align-poster.png` taken from the recording.
  The recording shows 0.1.25 Preview in a macOS VM Safari field, Natural Code,
  with automated keystrokes. It is not a live browser input method.
- `settings-appearance.png`: unchanged copy of
  `tests/fixtures/settings-theme-cloud-dark-680.png`. The corresponding
  `LinnetSettingsAppearancePreviewTests.swift` identifies it as the unedited
  Action 33302408070 screenshot. This is the English theme-selection region,
  not a new screenshot of the current installed application.

Downloads use GitHub's `releases/latest/download/Linnet.pkg` redirect. The matching
release page owns current version details and SHA-256. Do not pair the moving
package link with a hard-coded version-specific checksum. Publication is separate
from local editing and previewing.

## Local preview and verification

Run `python3 -m http.server 8766 --bind 127.0.0.1` here, then open
`http://127.0.0.1:8766/` or `http://127.0.0.1:8766/guide.html`.

Check both pages at desktop and phone widths, including system light/dark mode:

- Header, local links, media, image descriptions and fragment destinations.
- Native video playback and pause. The recording does not autoplay.
- Theme click/Arrow/Home/End navigation, one selected tab and visible panel.
- Guide sticky navigation, current chapter and mobile menu closing on selection.
- Keyboard-operable disclosures, fragment links and copy status feedback.
- Narrow-screen wrapping and reduced-motion behavior.

Executed on 2026-09-13: browser checks at 1360, 390 and 320 CSS pixels, including a 620-pixel-high desktop viewport; light/dark
and reduced-motion styles; video playback; theme keyboard/click selection; guide
chapter links and mobile collapse; clipboard feedback; local asset/fragment audit;
`node --check script.js`; `git diff --check`. No native input-method build, install,
update or new typing acceptance was performed for these website changes.
