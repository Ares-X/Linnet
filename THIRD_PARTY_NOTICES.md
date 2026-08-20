# Linnet third-party notices

This repository page is a stable, unversioned guide to Linnet's third-party
families. It deliberately does not copy release versions, commits or checksums.
For an installed build, the authoritative inventory is inside the App at:

- `Contents/Resources/LinnetRelease/NOTICE.md` — exact release identities and
  human-readable attribution;
- `Contents/Resources/LinnetRelease/SBOM.spdx.json` — exact SPDX packages,
  licenses and dependency relationships;
- `Contents/Resources/LinnetRelease/VERSION.json` — product identity and the
  SHA-256 binding to that SBOM;
- `Contents/Resources/LinnetRelease/LICENSES/` — shipped third-party license
  texts;
- `Contents/Resources/LICENSE.txt` — Linnet's GNU GPL text, also reused for the
  byte-identical Squirrel and librime-octagram GPL text.

## Shipped application and runtime

Linnet is an independent macOS distribution derived from
[Squirrel](https://github.com/rime/squirrel) and powered by
[librime](https://github.com/rime/librime). The shipped runtime also contains:

- [librime-lua](https://github.com/hchunhui/librime-lua), its embedded Lua
  runtime and compatibility code;
- [librime-octagram](https://github.com/lotem/librime-octagram), the shipped
  grammar plugin code;
- [librime-predict](https://github.com/rime/librime-predict);
- glog, LevelDB, marisa-trie, OpenCC, yaml-cpp and Boost static components;
- Darts-clone embedded by librime; and
- RapidJSON vendored by OpenCC. The RapidJSON license source URL is not a
  second runtime source owner.

The generated SBOM records Darts-clone once under librime and RapidJSON under
OpenCC. Exact license expressions and license files belong to the generated
release metadata, not this unversioned guide.

## Shipped language data

Linnet uses selected, pinned inputs from:

- [rime-ice](https://github.com/iDvel/rime-ice) for selected English, radical,
  symbol, emoji/OpenCC and Lua inputs—not its Chinese candidate dictionaries or
  runtime schemas;
- [HallelujahIM](https://github.com/dongyuwei/hallelujahIM) for Smart English
  frequency, pronunciation and definition inputs;
- [Rime Wanxiang](https://github.com/amzxyz/rime-wanxiang) for the Chinese
  dictionary core and the eight full-/double-pinyin source layouts selected
  from its locked `base` algebra; and
- [RIME-LMDG](https://github.com/amzxyz/RIME-LMDG) for the offline Wanxiang LTS
  grammar model.

The generated release notice identifies the exact locked versions and describes
Linnet's reviewed pronunciation corrections, algebra projection and other
transformations. Wanxiang and RIME-LMDG attribution texts are included in the
App's generated `LICENSES/` directory.

The App-level GNU GPL version 3 text also supplies the applicable GPL terms for
the selected rime-ice and Hallelujah inputs; their exact locked source-license
bytes are verified when release metadata is generated.

## Development-only input

[rime-octagram-data](https://github.com/lotem/rime-octagram-data) is a locked
grammar regression fixture only. It is distinct from the shipped
`librime-octagram` plugin. Its model and license are not included in the App,
language packs, installer metadata, generated release NOTICE or generated SBOM.
