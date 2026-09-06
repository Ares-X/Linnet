#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${repo_root}"

ruby scripts/upstream-sync verify

weasel_commit="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("sources", "weasel", "commit")' upstreams.lock.json)"
gitlink="$(git ls-files --stage -- upstreams/weasel | awk '{print $2}')"
[[ "${gitlink}" == "${weasel_commit}" ]] || {
  echo "Windows frontend gitlink differs from the lock." >&2
  exit 1
}

while IFS= read -r locked_patch; do
  [[ "$(git check-attr eol -- "${locked_patch}")" == \
      "${locked_patch}: eol: lf" ]] || {
    echo "Locked patch checkout bytes are not fixed to LF: ${locked_patch}" >&2
    exit 1
  }
done < <(ruby -rjson -e '
  JSON.parse(File.read(ARGV.fetch(0))).fetch("downstream_patches").each_value do |item|
    puts item.fetch("path")
  end
' upstreams.lock.json)

scratch="$(mktemp -d "${TMPDIR:-/tmp}/linnet-weasel-verify.XXXXXX")"
cleanup() {
  find "${scratch}" -depth -delete
}
trap cleanup EXIT
git -C upstreams/weasel archive "${weasel_commit}" | tar -xf - -C "${scratch}"
git -C "${scratch}" apply --check --ignore-space-change \
  "${repo_root}/platforms/windows/patches/weasel-linnet.patch"
git -C "${scratch}" apply --ignore-space-change \
  "${repo_root}/platforms/windows/patches/weasel-linnet.patch"

projection_repo="${scratch}/projection-repo"
projection_root="${projection_repo}/build/windows/weasel"
git init --quiet "${projection_repo}"
mkdir -p "${projection_root}"
git -C upstreams/weasel archive "${weasel_commit}" | tar -xf - -C "${projection_root}"
git -C "${projection_repo}" apply --check --ignore-space-change \
  --directory=build/windows/weasel \
  "${repo_root}/platforms/windows/patches/weasel-linnet.patch"
git -C "${projection_repo}" apply --ignore-space-change \
  --directory=build/windows/weasel \
  "${repo_root}/platforms/windows/patches/weasel-linnet.patch"
git -C "${projection_repo}" apply --reverse --check --ignore-space-change \
  --directory=build/windows/weasel \
  "${repo_root}/platforms/windows/patches/weasel-linnet.patch"
rg -Fq 'if %build_data% == 1 goto linnet_data_error' \
  "${projection_root}/build.bat"

generated_weasel="${scratch}/linnet-generated-weasel.yaml"
generated_previews="${scratch}/linnet-theme-previews"
scripts/project-windows-weasel-config platforms/windows/weasel.base.yaml \
  data/squirrel.yaml "${generated_weasel}" "${generated_previews}"
ruby -ryaml -rzlib -e '
  source = YAML.safe_load(File.binread(ARGV.fetch(0)), aliases: false)
  windows = YAML.safe_load(File.binread(ARGV.fetch(1)), aliases: false)
  expected = source.fetch("preset_color_schemes").keys.grep(
    /\Alinnet_.+_(?:light|dark)\z/
  )
  actual = windows.fetch("preset_color_schemes").keys
  abort "Windows theme catalog differs from Linnet" unless actual == expected
  abort "Windows theme colors are not declared as canonical ARGB" unless
    actual.all? do |name|
      windows.fetch("preset_color_schemes").fetch(name).fetch("color_format") == "argb"
    end
  shared_colors = %w[
    back_color border_color text_color candidate_text_color label_color
    comment_text_color hilited_text_color hilited_back_color
    hilited_candidate_text_color hilited_candidate_back_color
    hilited_comment_text_color
  ]
  expected.each do |name|
    source_scheme = source.fetch("preset_color_schemes").fetch(name)
    windows_scheme = windows.fetch("preset_color_schemes").fetch(name)
    shared_colors.each do |key|
      next unless source_scheme.key?(key)
      abort "Windows theme color differs: #{name}/#{key}" unless
        windows_scheme.fetch(key) == source_scheme.fetch(key)
    end
    abort "Windows highlighted label differs: #{name}" unless
      windows_scheme.fetch("hilited_label_color") ==
        source_scheme.fetch("hilited_candidate_label_color")
  end
  expected.grep(/_light\z/).each do |name|
    png = File.binread(File.join(ARGV.fetch(2), "color_scheme_#{name}.png"))
    offset = 8
    compressed = +"".b
    while offset < png.bytesize
      length = png.byteslice(offset, 4).unpack1("N")
      type = png.byteslice(offset + 4, 4)
      compressed << png.byteslice(offset + 8, length) if type == "IDAT"
      offset += 12 + length
    end
    pixels = Zlib::Inflate.inflate(compressed)
    rgba = pixels.byteslice(10 * (1 + 320 * 4) + 1 + 10 * 4, 4).bytes
    color = source.fetch("preset_color_schemes").fetch(name).fetch("back_color")
    expected_rgba = [(color >> 16) & 0xff, (color >> 8) & 0xff, color & 0xff,
                     color > 0xffffff ? (color >> 24) & 0xff : 0xff]
    abort "Windows preview color channels differ: #{name}" unless
      rgba == expected_rgba
  end
  abort "Windows dark theme owner is missing" unless
    windows.dig("style", "color_scheme_dark") == "linnet_paper_dark"
' data/squirrel.yaml "${generated_weasel}" "${generated_previews}"
[[ "$(find "${generated_previews}" -type f -name 'color_scheme_linnet_*_light.png' | wc -l | tr -d ' ')" == 7 ]] || {
  echo "Windows theme preview catalog is incomplete." >&2
  exit 1
}
while IFS= read -r preview; do
  [[ "$(od -An -tx1 -N8 "${preview}" | tr -d ' \n')" == 89504e470d0a1a0a ]] || {
    echo "Invalid Windows theme preview: ${preview}" >&2
    exit 1
  }
done < <(find "${generated_previews}" -type f -name '*.png' | sort)
second_weasel="${scratch}/linnet-generated-weasel-second.yaml"
second_previews="${scratch}/linnet-theme-previews-second"
scripts/project-windows-weasel-config platforms/windows/weasel.base.yaml \
  data/squirrel.yaml "${second_weasel}" "${second_previews}"
cmp "${generated_weasel}" "${second_weasel}"
diff -qr "${generated_previews}" "${second_previews}" >/dev/null
# Linnet and upstream Weasel must remain separate installed products.
if rg -n 'win_sparkle_|check_update\(|L"/update"|rime-install\.bat' \
    "${scratch}/WeaselServer" "${scratch}/WeaselSetup" \
    "${scratch}/WeaselDeployer" "${scratch}/output/install.nsi"; then
  echo "An upstream updater or second data installer remains authoritative." >&2
  exit 1
fi
if rg -n 'Software\\\\Rime\\\\[Ww]easel|WeaselNamedPipe|rime\.weasel' \
    "${scratch}/RimeWithWeasel" "${scratch}/WeaselDeployer" \
    "${scratch}/WeaselServer" "${scratch}/WeaselSetup" \
    "${scratch}/WeaselTSF" "${scratch}/include"; then
  echo "An upstream Weasel identity namespace remains in the Linnet projection." >&2
  exit 1
fi
if rg -n 'WEASEL_WER_KEY|[Ww]easel-backup|[Ll]innet-backup|RIME_REG_KEY' \
    "${scratch}/WeaselSetup" "${scratch}/include" \
    "${scratch}/output/install.nsi"; then
  echo "A shared crash-dump, stale-data backup, or upstream registry owner remains." >&2
  exit 1
fi
for feature_source in \
  data/plum/linnet.smart.db \
  data/plum/linnet_en.schema.yaml \
  data/plum/linnet_zh.schema.yaml \
  data/plum/radical_pinyin.schema.yaml \
  data/plum/wanxiang-lts-zh-hans.gram \
  data/opencc/emoji.json \
  data/opencc/s2t.json; do
  [[ -s "${feature_source}" ]] || {
    echo "Portable feature source is missing: ${feature_source}" >&2
    exit 1
  }
done
ruby -ryaml -e '
  root = ARGV.fetch(0)
  dictionary = YAML.safe_load(File.binread(File.join(root, "linnet_zh.dict.yaml")),
                              aliases: false)
  missing = dictionary.fetch("import_tables").each_with_object([]) do |table, result|
    if table.start_with?("dicts/")
      relative = "#{table}.dict.yaml"
      result << relative unless File.file?(File.join(root, relative))
    end
  end
  abort "Chinese dictionary imports missing tables: #{missing.join(", ")}" unless
    missing.empty?
' data/plum
ruby -rjson -e '
  root = ARGV.fetch(0)
  referenced = []
  walk = lambda do |value|
    case value
    when Hash
      referenced << value["file"] if value["file"].is_a?(String)
      value.each_value { |child| walk.call(child) }
    when Array
      value.each { |child| walk.call(child) }
    end
  end
  Dir.glob(File.join(root, "*.json")).sort.each do |path|
    walk.call(JSON.parse(File.binread(path)))
  end
  missing = referenced.uniq.reject { |name| File.file?(File.join(root, name)) }
  abort "OpenCC package references missing data: #{missing.join(", ")}" unless
    missing.empty?
' data/opencc

# No Windows bytes may enter the public release before target-machine UAT.
if rg -n 'publish-windows:|Attach Windows installer|gh release upload.*[Ww]indows|windows-build.yml' \
    .github/workflows/release-ci.yml; then
  echo "Windows build or publication entered the macOS release workflow." >&2
  exit 1
fi
tests/verify_publication_owner.sh
echo "Windows lock, patch, theme and data projection: PASS"

# Exercise the Windows data/defaults with the same API probe used on Windows.
# This catches shared integration failures before an expensive target build;
# it does not exercise Weasel, TSF or installation on this macOS host.
shared="${scratch}/runtime-shared"
user="${scratch}/runtime-user"
mkdir -p "${shared}/opencc" "${user}"
cp -R data/plum/. "${shared}/"
cp -R data/opencc/. "${shared}/opencc/"
cp build/windows-inputs/linnet_windows_defaults.yaml "${shared}/"
ruby -e 'File.open(ARGV.fetch(0), "a") { |file|
  file.puts "\n__patch: linnet_windows_defaults:/patch"
}' "${shared}/default.yaml"
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror \
  -isystem librime/dist/include platforms/windows/runtime_smoke.cc \
  lib/librime.1.dylib -o "${scratch}/runtime-smoke"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${scratch}/runtime-smoke" "${shared}" "${user}"
echo "Windows shared input configuration on macOS librime: PASS (not Windows UAT)"
