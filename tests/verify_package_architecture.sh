#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

fail() {
  echo "verify_package_architecture: $1" >&2
  exit 1
}

for script in package/build_data_pack package/build_activation_profile \
    package/make_package package/make_archive \
    package/verify_package; do
  [[ -x "${script}" ]] || fail "missing executable: ${script}"
  bash -n "${script}"
done

ruby -rrexml/document -e '
  root = REXML::Document.new(File.read("package/Distribution.xml")).root
  abort "Complete repair forces another logout" unless
    root.get_elements("pkg-ref").all? { |item| item.attributes["onConclusion"].nil? }
  core = REXML::Document.new(File.read("package/Distribution-Core.xml")).root
  complete_ids = root.get_elements("choice/pkg-ref").map { |item| item.attributes["id"] }
  core_ids = core.get_elements("choice/pkg-ref").map { |item| item.attributes["id"] }
  abort "Core and Complete share a PackageKit payload receipt" unless (complete_ids & core_ids).empty?
  retired = /io\.github\.ares-x\.inputmethod\.Linnet\.(?:core|profile|data\.(?:chinese|english|lts|extended))\.pkg/
  abort "an installer still owns a legacy live-payload receipt" if
    (complete_ids + core_ids).any? { |identifier| retired.match?(identifier) } ||
      retired.match?(File.read("package/make_package"))
  abort "pack identity is inferred from an Installer receipt" if
    File.read("package/verify_package").include?(%q{receipt.delete_suffix(".pkg")})
' || fail "Installer conclusion or receipt ownership is invalid"

ruby -e '
  source = File.read("package/make_package")
  core_builder = source.split(/^pkgbuild /, 2).fetch(1).split(/^pkgbuild /, 2).first
  abort "normal Core update still carries the complete App payload" if
    core_builder.include?(%q{--root "${core_payload}"})
  abort "Core update is not a scripts-only differential component" unless
    core_builder.include?("--nopayload")
' || fail "Core differential payload boundary is missing"
if rg -n 'expected_core_scripts=|def manifest\(root\)' package/verify_package; then
  fail "package verification regained a duplicate inventory or tree-digest owner"
fi

if [[ "${1:-}" == --native-receipt-upgrade ]]; then
  mkdir -p "${repo_root}/build"
  fixture="$(mktemp -d "${repo_root}/build/receipt-upgrade.XXXXXX")"
else
  fixture="$(mktemp -d /tmp/linnet-package-architecture.XXXXXX)"
fi
cleanup() {
  exit_code=$?
  trap - EXIT INT TERM HUP
  chmod -R u+w "${fixture}" 2>/dev/null || true
  find "${fixture}" -depth -delete 2>/dev/null || true
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ "${1:-}" == --native-receipt-upgrade ]]; then
  # Execute PackageKit itself in a private current-user destination. Running
  # pre/postinstall directly cannot reproduce receipt-based payload obsoleting.
  ruby -rfileutils -rrexml/document -e '
    root, project = ARGV
    home = Dir.home
    abort "ENVIRONMENT_INVALID: fixture must be below the current user home" unless root.start_with?(home + "/")
    prefix = "io.github.ares-x.inputmethod.Linnet."
    private_prefix = "io.github.ares-x.linnet-receipt-test.#{File.basename(root)}."
    receipts = []
    run = ->(*args) { system(*args) || abort("native receipt command failed: #{args.first}") }
    private_id = ->(identifier) {
      abort "unexpected product receipt" unless identifier.start_with?(prefix)
      private_prefix + identifier.delete_prefix(prefix)
    }
    component = ->(name, identifier, location, payload) {
      receipt = private_id.call(identifier)
      receipts << receipt unless receipts.include?(receipt)
      path = File.join(root, name + ".pkg")
      args = ["/usr/bin/pkgbuild", "--identifier", receipt, "--version", "1.0",
              "--install-location", location]
      args += payload ? ["--root", payload] : ["--nopayload"]
      run.call(*args, path)
      [receipt, path]
    }
    product = ->(name, components) {
      xml = REXML::Document.new
      doc = xml.add_element("installer-gui-script", {"minSpecVersion" => "2"})
      doc.add_element("title").text = "Linnet isolated receipt test"
      doc.add_element("options", {"customize" => "never", "require-scripts" => "false"})
      doc.add_element("domains", {"enable_localSystem" => "false",
        "enable_currentUserHome" => "true", "enable_anywhere" => "false"})
      outline = doc.add_element("choices-outline")
      components.each_with_index do |(receipt, path), index|
        choice = "item-#{index}"
        outline.add_element("line", {"choice" => choice})
        doc.add_element("choice", {"id" => choice, "visible" => "false"})
          .add_element("pkg-ref", {"id" => receipt})
        doc.add_element("pkg-ref", {"id" => receipt, "version" => "1.0", "auth" => "none"})
          .text = File.basename(path)
      end
      distribution = File.join(root, name + ".xml")
      File.write(distribution, xml.to_s)
      package = File.join(root, name + ".pkg")
      run.call("/usr/bin/productbuild", "--distribution", distribution,
        "--package-path", root, package)
      package
    }
    install = ->(package) {
      run.call("/usr/sbin/installer", "-pkg", package, "-target", "CurrentUserHomeDirectory")
    }
    kinds = %w[core chinese english lts extended profile]
    live = File.join(root, "live")
    location = "/" + live.delete_prefix(home + "/")
    preserve = ->(label) {
      missing = kinds.reject { |kind| File.read(File.join(live, kind)) == kind rescue false }
      abort "#{label}: PackageKit deleted live payload: #{missing.join(",")}" unless missing.empty?
      puts "#{label}: live App, packs and activation preserved"
    }
    begin
      legacy = kinds.map do |kind|
        identifier = prefix + (kind == "core" || kind == "profile" ? kind : "data.#{kind}") + ".pkg"
        payload = File.join(root, "payload-#{kind}")
        FileUtils.mkdir_p(payload)
        File.write(File.join(payload, kind), kind)
        component.call("old-#{kind}", identifier, location, payload)
      end
      install.call(product.call("legacy", legacy))
      preserve.call("legacy seed")
      core = REXML::Document.new(File.read(File.join(project, "package/Distribution-Core.xml"))).root
      core_id = core.elements["choice/pkg-ref"].attributes["id"]
      delta = product.call("delta", [component.call("new-core", core_id, location, nil)])
      install.call(delta)
      preserve.call("legacy to differential")
      install.call(delta)
      preserve.call("same-leaf differential reinstall")
      complete = REXML::Document.new(File.read(File.join(project, "package/Distribution.xml"))).root
      staged = complete.get_elements("choice").map do |choice|
        kind = choice.attributes["id"]
        component.call("staged-#{kind}", choice.elements["pkg-ref"].attributes["id"],
          location.sub(/live\z/, "staged"), File.join(root, "payload-#{kind}"))
      end
      complete_package = product.call("complete", staged)
      install.call(complete_package)
      preserve.call("legacy to staged Complete")
      staged_root = File.join(root, "staged")
      kinds.each { |kind| abort "Complete staging payload missing" unless File.read(File.join(staged_root, kind)) == kind }
      FileUtils.remove_entry_secure(staged_root)
      install.call(delta)
      preserve.call("Complete to differential")
      install.call(complete_package)
      preserve.call("differential to Complete reinstall")
      kinds.each { |kind| abort "Complete reinstall payload missing" unless File.read(File.join(staged_root, kind)) == kind }
    ensure
      receipts.each do |receipt|
        abort "unsafe fixture receipt" unless receipt.start_with?(private_prefix)
        system("/usr/sbin/pkgutil", "--volume", home, "--forget", receipt,
          out: File::NULL, err: File::NULL)
      end
    end
  ' "${fixture}" "${repo_root}"
  echo "Native current-user Installer receipt migration: PASS"
  exit 0
fi

mkdir "${fixture}/resources"
for resource in WELCOME.md LICENSE.txt NOTICE.md Conclusion-summary.txt; do
  printf 'Installer structure fixture\n' >"${fixture}/resources/${resource}"
done
ruby -e 'File.write(ARGV.fetch(1), File.read(ARGV.fetch(0)).gsub("@CORE_VERSION@", "0.1.0"))' \
  package/Distribution-Core.xml "${fixture}/Distribution.xml"
pkgbuild --info package/PackageInfo --compression latest --min-os-version 13.0 --nopayload \
  --identifier io.github.ares-x.inputmethod.Linnet.update.core.pkg --version 0.1.0 \
  --install-location '/Library/Input Methods' --scripts package/core-installer-scripts \
  "${fixture}/Linnet-Core.component.pkg" >/dev/null
productbuild --distribution "${fixture}/Distribution.xml" --resources "${fixture}/resources" \
  --package-path "${fixture}" "${fixture}/Core.pkg" >/dev/null
pkgutil --expand-full "${fixture}/Core.pkg" "${fixture}/expanded"
ruby -rrexml/document -e '
  root = ARGV.fetch(0)
  component = File.join(root, "Linnet-Core.component.pkg")
  abort "scripts-only Core gained payload bytes" if File.exist?(File.join(component, "Payload"))
  info = REXML::Document.new(File.read(File.join(component, "PackageInfo"))).root
  abort "scripts-only Core gained payload or bundle mappings" if
    info.elements["payload"] || info.elements["bundle"] || info.elements["upgrade-bundle/bundle"]
  distribution = REXML::Document.new(File.read(File.join(root, "Distribution"))).root
  abort "Core Distribution retained a must-close mapping" unless
    distribution.get_elements("pkg-ref/must-close").empty?
  ref = distribution.get_elements("pkg-ref").find { |item| item.attributes["version"] }
  abort "scripts-only Core product shape mismatch" unless
    ref.attributes["installKBytes"] == "0" && ref.attributes["updateKBytes"] == "0" &&
    ref.get_elements("bundle-version/bundle").empty?
' "${fixture}/expanded" || fail "Apple scripts-only Core metadata changed"
if [[ "${1:-}" == --core-delta-structure ]]; then
  echo "Core differential Installer structure: PASS"
  exit 0
fi

if rg -n -i 'installation-uat|\buat\b' \
    package/make_package package/verify_package; then
  fail "the installable package path retained the retired UAT identity"
fi
rg -Fq 'verification_scope=publication' package/make_package ||
  fail "package assembly has no single public community verification scope"
rg -Fq 'case "${verification_scope}" in publication)' package/verify_package ||
  fail "package verification accepts a non-public identity scope"
[[ "$(rg -c 'package/verify_package' package/make_package)" -eq 2 ]] ||
  fail "package assembly must verify Core and Complete exactly once"
if rg -n 'package/verify_package' package/make_archive; then
  fail "archive assembly repeated the package owner's completed verification"
fi
rg -q '^archive:[[:space:]]+package$' Makefile ||
  fail "archive no longer consumes the package owner's verified output"
[[ "$(rg -c 'package/verify_package' package/verify_publication_artifacts)" -eq 1 ]] ||
  fail "final publication lost its distinct byte-consumer verification boundary"

tests/verify_lean_data_trust.sh

if rg -n -i 'python|\.py([[:space:]"]|$)' \
    sources resources package/installer-scripts package/uninstall-linnet; then
  fail "the installed product or lifecycle scripts gained a Python runtime dependency"
fi

if rg -n 'runtime_is_minimally_repairable|validate_complete_repair_state' \
    package/core-installer-scripts/preinstall; then
  fail "Complete regained a shell-owned Runtime repair classifier"
fi
if rg -n 'case validate|probe\|validate' tools/LinnetRuntimeInspector.swift ||
    rg -n '"\$\{runtime_inspector\}" validate' \
      package/installer-scripts/postinstall; then
  fail "the package Runtime inspector retained a mutating validation command"
fi
rg -Fq '"${runtime_inspector}" probe' package/installer-scripts/postinstall ||
  fail "postinstall does not consume the read-only committed Runtime probe"
rg -Fq -- "-name '*.py'" package/stage_language_pack_sources ||
  fail "language-pack staging can admit Python source"

if rg -n 'LINNET_SIGNED_PACKS_ROOT|LINNET_SIGNED_RELEASE_ROOT|manifest\.ed25519|pack-signing-request|signing-request-set' \
    package/build_data_pack package/make_package \
    tools/LinnetPackEncoder.swift tools/LinnetPackTool.swift; then
  fail "local packaging or data release regained the retired pack-signing path"
fi
if rg -n 'candidate_revision|candidate-revision' \
    package/build_data_pack tools/LinnetPackEncoder.swift tools/LinnetPackTool.swift; then
  fail "data-pack identity is coupled to an App revision"
fi
if rg -n 'compressZlib|writeContainer' sources --glob '*.swift'; then
  fail "offline pack encoding returned to an App runtime target"
fi
rg -Fq 'enum LinnetPackEncoder' tools/LinnetPackEncoder.swift ||
  fail "the offline pack encoder owner is missing"
pack_compiler_owners="$(
  rg -l -F --hidden \
    -g '!build/**' -g '!librime/**' -g '!vendor/**' -g '!.git/**' \
    -g '!tests/verify_package_architecture.sh' \
    -g '!tests/verify_lean_data_trust.sh' \
    'tools/LinnetPackTool.swift' . | sed 's#^\./##' | LC_ALL=C sort
)"
[[ "${pack_compiler_owners}" == "Makefile" ]] ||
  fail "pack compiler owners: ${pack_compiler_owners:-none}"
ruby -e '
  paths = %w[
    Makefile action-install.sh package/make_package package/make_archive
    scripts/release-control tests/verify_package_architecture.sh
    tests/verify_data_channel_release.sh tests/verify_visible_settings_fixture.sh
  ]
  sources = paths.to_h { |path| [path, File.read(path)] }
  compiler_callers = %w[
    action-install.sh scripts/release-control tests/verify_data_channel_release.sh
    tests/verify_visible_settings_fixture.sh
  ]
  abort "a pack-tool compiler caller bypasses the canonical Make target" unless
    compiler_callers.all? { |path|
      sources.fetch(path).include?("linnet-pack-tool")
    }
  packaging_consumers = %w[package/make_package package/make_archive]
  abort "package assembly regained a second pack-tool compiler" unless
    packaging_consumers.all? { |path|
      source = sources.fetch(path)
      source.include?(%q{release_tool="${LINNET_RELEASE_TOOL:-}"}) &&
        !source.include?("linnet-pack-tool")
    }
  makefile = sources.fetch("Makefile")
  abort "Make did not pass one precompiled pack tool through both assemblies" unless
    makefile.include?("package: community-verified linnet-pack-tool") &&
    makefile.scan(%q{LINNET_RELEASE_TOOL="$(abspath $(LINNET_PACK_TOOL))"}).size == 2
' || fail "the pack CLI does not have one incremental compiler owner"
if rg -n 'LINNET_PACK_PRIVATE|private[_-]key|manifest\.ed25519' \
    package tools sources scripts/release-control; then
  fail "candidate-controlled production code can read a Catalog private key"
fi
rg -Fq 'build-container' package/make_archive ||
  fail "archive does not build deterministic pack containers"
rg -Fq 'build-catalog' package/make_archive ||
  fail "archive does not build the canonical data Catalog"
rg -Fq 'container_sha256' package/make_archive ||
  fail "archive does not bind pack containers to the Catalog"
rg -Fq 'verify-catalog' package/make_archive ||
  fail "archive does not verify the Catalog"

tool="${repo_root}/build/linnet-pack"
runtime_inspector="${repo_root}/build/linnet-runtime-inspector"
make -C "${repo_root}" --no-print-directory \
  linnet-pack-tool linnet-runtime-inspector

mkdir "${fixture}/sources" "${fixture}/packs" "${fixture}/containers"
for kind in chinese english lts extended; do
  source="${fixture}/sources/${kind}"
  mkdir "${source}"
  abi=2
  case "${kind}" in
    chinese)
      mkdir "${source}/build"
      for payload in default.yaml squirrel.yaml linnet_zh.schema.yaml linnet_zh.dict.yaml; do
        printf '%s\n' "${kind} ${payload} fixture" >"${source}/${payload}"
      done
      printf '%s\n' "${kind} build fixture" >"${source}/build/default.yaml"
      ;;
    english)
      abi=1
      printf '%s\n' "${kind} fixture" >"${source}/linnet_en.schema.yaml"
      ;;
    lts)
      printf '%s\n' "${kind} fixture" >"${source}/wanxiang-lts-zh-hans.gram"
      ;;
    extended)
      printf '%s\n' "${kind} fixture" >"${source}/linnet_zh_full.dict.yaml"
      ;;
  esac
  content_sha="$("${tool}" inspect-source --kind "${kind}" --source "${source}")"
  pack_root="${fixture}/packs/${kind}/1-fixture"
  mkdir "${fixture}/packs/${kind}"
  "${tool}" build-installed --kind "${kind}" --version fixture --sequence 1 \
    --data-abi "${abi}" --min-core 0.1.0 --content-sha256 "${content_sha}" \
    --source "${source}" --output "${pack_root}"
  asset_name="$("${tool}" asset-name --kind "${kind}")"
  "${tool}" build-container --root "${pack_root}" --core-version 0.1.0 \
    --output "${fixture}/containers/${asset_name}"
  "${tool}" verify --pack "${fixture}/containers/${asset_name}" \
    --core-version 0.1.0 >/dev/null
  extracted="${fixture}/extracted-${kind}"
  "${tool}" extract --pack "${fixture}/containers/${asset_name}" \
    --core-version 0.1.0 --output "${extracted}"
  cmp "${pack_root}/manifest.json" "${extracted}/manifest.json"
  if [[ "${kind}" == english ]]; then
    printf '%s\n' 'English fixture' >"${source}/linnet_en.schema.yaml"
    mutated_content_sha="$("${tool}" inspect-source --kind "${kind}" \
      --source "${source}")"
    [[ "${mutated_content_sha}" != "${content_sha}" ]] ||
      fail "source digest ignored a same-size English byte change"
  fi
done

release_sources="${fixture}/release-sources"
mkdir "${release_sources}"
package/stage_language_pack_sources "${release_sources}" >/dev/null
for kind in chinese english lts extended; do
  actual_content_sha="$("${tool}" inspect-source --kind "${kind}" \
    --source "${release_sources}/${kind}")"
  expected_content_sha="$(package/data_release_metadata get \
    config/linnet-data-releases.json "${kind}" content_sha256)"
  [[ "${actual_content_sha}" == "${expected_content_sha}" ]] ||
    fail "${kind} staged source differs from release metadata: actual=${actual_content_sha} expected=${expected_content_sha}"
done

runtime_support="${fixture}/support"
runtime_root="${runtime_support}/Linnet"
mkdir -p "${runtime_root}/Data/Packs"
for kind in chinese english lts extended; do
  mkdir "${runtime_root}/Data/Packs/${kind}"
  cp -R "${fixture}/packs/${kind}/1-fixture" \
    "${runtime_root}/Data/Packs/${kind}/1-fixture"
done
LINNET_RELEASE_TOOL="${tool}" LINNET_CORE_VERSION=0.1.0 \
  package/build_activation_profile complete "${runtime_root}" \
    "${runtime_root}/Data/Packs/chinese/1-fixture" \
    "${runtime_root}/Data/Packs/english/1-fixture" \
    "${runtime_root}/Data/Packs/lts/1-fixture" \
    "${runtime_root}/Data/Packs/extended/1-fixture"

snapshot_runtime_tree() {
  local root="$1"
  local output="$2"
  ruby -rdigest -e '
    root = File.realpath(ARGV.fetch(0))
    rows = Dir.glob("**/*", File::FNM_DOTMATCH, base: root)
      .reject { |path| path == "." || path == ".." }
      .sort.map do |relative|
        path = File.join(root, relative)
        stat = File.lstat(path)
        identity = [relative, stat.ftype, stat.mode, stat.size,
          stat.ino, stat.mtime.to_f, stat.ctime.to_f]
        if stat.symlink?
          identity << File.readlink(path)
        elsif stat.file?
          identity << Digest::SHA256.file(path).hexdigest
        end
        identity.join("\t")
      end
    File.binwrite(ARGV.fetch(1), rows.join("\n") + "\n")
  ' "${root}" "${output}"
}

probe_before="${fixture}/runtime-probe-before"
probe_after="${fixture}/runtime-probe-after"
snapshot_runtime_tree "${runtime_root}" "${probe_before}"
[[ "$("${runtime_inspector}" probe 0.1.0 "${runtime_support}")" == healthy ]] ||
  fail "installed Runtime probe rejected the canonical activation profile"
snapshot_runtime_tree "${runtime_root}" "${probe_after}"
cmp "${probe_before}" "${probe_after}" ||
  fail "installed Runtime probe changed product bytes or metadata"
if "${runtime_inspector}" validate 0.1.0 "${runtime_support}" >/dev/null 2>&1; then
  fail "the Runtime inspector retained the mutating validate command"
fi

absent_support="${fixture}/absent-support"
mkdir "${absent_support}"
[[ "$("${runtime_inspector}" probe 0.1.0 "${absent_support}")" == missing ]] ||
  fail "installed Runtime probe did not classify an absent product root as missing"
[[ ! -e "${absent_support}/Linnet" && ! -L "${absent_support}/Linnet" ]] ||
  fail "installed Runtime probe created an absent product root"

preserved_support="${fixture}/preserved-support"
preserved_root="${preserved_support}/Linnet"
mkdir -p "${preserved_root}/UserData" "${preserved_root}/Backups" \
  "${preserved_root}/Transactions" "${preserved_root}/State"
preserved_before="${fixture}/preserved-probe-before"
preserved_after="${fixture}/preserved-probe-after"
snapshot_runtime_tree "${preserved_root}" "${preserved_before}"
[[ "$("${runtime_inspector}" probe 0.1.0 "${preserved_support}")" == missing ]] ||
  fail "installed Runtime probe rejected a root containing only preserved data"
snapshot_runtime_tree "${preserved_root}" "${preserved_after}"
cmp "${preserved_before}" "${preserved_after}" ||
  fail "missing Runtime probe changed preserved data or metadata"

for preserved_name in UserData Backups Transactions State; do
  unsafe_preserved_support="${fixture}/unsafe-preserved-${preserved_name}"
  mkdir -p "${unsafe_preserved_support}/Linnet" \
    "${unsafe_preserved_support}/external"
  ln -s "${unsafe_preserved_support}/external" \
    "${unsafe_preserved_support}/Linnet/${preserved_name}"
  if "${runtime_inspector}" probe 0.1.0 "${unsafe_preserved_support}" \
      >/dev/null 2>&1; then
    fail "installed Runtime probe accepted symbolic-link ${preserved_name}"
  fi

  file_preserved_support="${fixture}/file-preserved-${preserved_name}"
  mkdir -p "${file_preserved_support}/Linnet"
  printf 'unsafe\n' >"${file_preserved_support}/Linnet/${preserved_name}"
  if "${runtime_inspector}" probe 0.1.0 "${file_preserved_support}" \
      >/dev/null 2>&1; then
    fail "installed Runtime probe accepted non-directory ${preserved_name}"
  fi

  writable_preserved_support="${fixture}/writable-preserved-${preserved_name}"
  mkdir -p "${writable_preserved_support}/Linnet/${preserved_name}"
  chmod 0777 "${writable_preserved_support}/Linnet/${preserved_name}"
  if "${runtime_inspector}" probe 0.1.0 "${writable_preserved_support}" \
      >/dev/null 2>&1; then
    fail "installed Runtime probe accepted writable ${preserved_name}"
  fi
done

for generated_root in Data Runtime Build Downloads Profiles; do
  incomplete_support="${fixture}/incomplete-${generated_root}"
  mkdir -p "${incomplete_support}/Linnet/${generated_root}"
  if "${runtime_inspector}" probe 0.1.0 "${incomplete_support}" \
      >/dev/null 2>&1; then
    fail "installed Runtime probe classified incomplete ${generated_root} as missing"
  fi
done
unsafe_support="${fixture}/unsafe-support"
mkdir -p "${unsafe_support}/Linnet" "${fixture}/external-data"
ln -s "${fixture}/external-data" "${unsafe_support}/Linnet/Data"
if "${runtime_inspector}" probe 0.1.0 "${unsafe_support}" >/dev/null 2>&1; then
  fail "installed Runtime probe accepted an unsafe generated root"
fi
if "${runtime_inspector}" probe 0.0.9 "${runtime_support}" >/dev/null 2>&1; then
  fail "installed Runtime probe accepted packs requiring a newer Core"
fi

active_grammar="${runtime_root}/Runtime/Active/linnet_grammar_active.yaml"
cp "${active_grammar}" "${fixture}/active-grammar"
grammar_mode="$(stat -f '%Lp' "${active_grammar}")"
chmod u+w "${active_grammar}"
printf 'invalid\n' >"${active_grammar}"
if "${runtime_inspector}" probe 0.1.0 "${runtime_support}" >/dev/null 2>&1; then
  fail "installed Runtime probe accepted a corrupted Active projection"
fi
cp "${fixture}/active-grammar" "${active_grammar}"
chmod "${grammar_mode}" "${active_grammar}"
[[ "$("${runtime_inspector}" probe 0.1.0 "${runtime_support}")" == healthy ]] ||
  fail "installed Runtime probe did not recover after fixture restoration"

tests/verify_data_channel_release.sh

echo "Linnet lean package architecture: PASS"
