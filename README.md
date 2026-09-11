# Linnet product website

Static product site for `https://ares-x.github.io/Linnet/`. GitHub Pages serves
the root of the `gh-pages` branch. No package install or build step is required.

- `index.html` owns product copy, navigation, download links, and screenshot captions.
- `style.css` owns responsive layout and system light/dark appearance.
- `script.js` owns the three-state illustration tabs and checksum-command copying.
- `assets/` retains the existing Linnet mark and real product renders. The galleries
  frame regions of the original images with CSS; source images remain unchanged and
  can be opened through the gallery links. The hero is explicitly an illustration,
  not a live input method or an acceptance recording.

Preview from this directory with `python3 -m http.server 8766 --bind 127.0.0.1`.
Open `http://127.0.0.1:8766/`. Check desktop/mobile layouts, system light/dark
appearance, tab clicks and Arrow/Home/End keyboard navigation, image disclosures,
installation anchors, and the clipboard success or failure message. Basic checks:
`node --check script.js` and `git diff --check`.

Downloads use GitHub's `releases/latest/download/Linnet.pkg` redirect. The matching
release page owns version details and SHA-256; do not duplicate a version-specific
hash next to a moving download link. Keep product and installation claims aligned
with the main branch's README and published releases.

Publishing requires updating `gh-pages`; local edits or previews do not publish.
