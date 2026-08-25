#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
generator="${project_root}/scripts/generate-release-metadata"
signer="${project_root}/scripts/linnet-code-identity"
provisioner="${project_root}/scripts/provision-community-signing"
lock="${project_root}/upstreams.lock.json"
leaf_sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
revision='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
scratch_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
scratch="$(mktemp -d "${scratch_root}/linnet-release-metadata.XXXXXX")"

cleanup() {
  if [[ "${scratch%/*}" == "${scratch_root}" &&
    "${scratch##*/}" == linnet-release-metadata.* ]]; then
    /bin/rm -rf -- "${scratch}"
  fi
}
trap cleanup EXIT

if rg -Fq -- '-quiet $(BUILD_SETTINGS) build' "${project_root}/Makefile"; then
  echo 'The App build still hides xcodebuild progress.' >&2
  exit 1
fi
rg -Fq -- '-showBuildTimingSummary $(BUILD_SETTINGS) build' \
  "${project_root}/Makefile" || {
  echo 'The App build lost its visible timing summary.' >&2
  exit 1
}

retired_identity_owner_paths=(
  "${project_root}/scripts/linnet-code-identity"
  "${project_root}/Makefile"
  "${project_root}/action-build.sh"
  "${project_root}/scripts/generate-release-metadata"
  "${project_root}/tests/verify_product.sh"
)
if rg -ni 'uat|LINNET_CODE_SIGN_(IDENTITY|PROFILE)|candidate-verified|^candidate[[:space:]]*:' \
    "${retired_identity_owner_paths[@]}"; then
  echo 'The retired installable UAT identity path returned.' >&2
  exit 1
fi

if rg -n '(linnet-code-identity|CODE_IDENTITY_TOOL).*preflight' \
    "${project_root}/Makefile" "${project_root}/action-build.sh"; then
  echo 'A build entrypoint regained the retired standalone signing preflight.' >&2
  exit 1
fi
if rg -Fn 'Library/Application Support/Linnet/Signing' \
    "${signer}" "${provisioner}" \
    "${project_root}/docs/development.md" "${project_root}/docs/release.md"; then
  echo 'Maintainer signing material returned to purgeable product user data.' >&2
  exit 1
fi
[[ -x "${provisioner}" ]] || {
  echo 'The one-time community signing provisioner is not executable.' >&2
  exit 1
}
bash -n "${provisioner}"
set +e
provisioning_usage="$(bash "${provisioner}" unexpected 2>&1)"
provisioning_status=$?
set -e
[[ "${provisioning_status}" -eq 2 &&
  "${provisioning_usage}" == 'usage: scripts/provision-community-signing' ]] || {
  echo 'The provisioner negative CLI did not fail before Keychain access.' >&2
  exit 1
}

ruby -e '
  provisioner, signer = ARGV.map { |path| File.binread(path) }
  required = [
    "Library/Application Support/Linnet Maintainer/Signing/community-cms",
    "Library/Keychains/Linnet-Community-CMS.keychain-db",
    "require_owned_mode \"${p12_path}\" 600",
    "require_owned_mode \"${p12_password_path}\" 600",
    "/usr/bin/security create-keychain -p",
    "/usr/bin/security import \"${p12_path}\" -k \"${keychain_path}\"",
    "-P \"${p12_password}\" -T /usr/bin/codesign",
    "/usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign:",
    "/usr/bin/security list-keychains -d user -s",
    "/usr/bin/codesign --force --sign \"${expected_sha1}\"",
    "/usr/bin/codesign --verify --strict",
    "probe_sha256",
    "/usr/bin/security lock-keychain \"${keychain_path}\"",
    "/bin/ln \"${temporary_keychain_password}\" \"${keychain_password_path}\"",
  ]
  missing = required.reject { |fragment| provisioner.include?(fragment) }
  abort "provisioner contract is incomplete: #{missing.join(", ")}" unless missing.empty?
  abort "provisioner accepts an identity or path override" if
    provisioner.match?(/LINNET_[A-Z0-9_]+|getopts|case[[:space:]].*\$\{1/)
  abort "provisioner gained a replace/delete CLI" if
    provisioner.match?(/--(replace|delete|repair)/)
  abort "cleanup no longer owns the sole Keychain deletion" unless
    provisioner.scan("/usr/bin/security delete-keychain").length == 1 &&
      provisioner.index("original_keychains[@]") <
        provisioner.index("/usr/bin/security delete-keychain")
  abort "daily signer took over Keychain provisioning" if
    signer.match?(/security (create-keychain|import|set-key-partition-list)/)
  abort "daily signer and provisioner disagree on their fixed local paths" unless
    signer.include?("Library/Application Support/Linnet Maintainer/Signing/community-cms/keychain-password")
  abort "daily signer can report success while leaving its Keychain unlocked" unless
    signer.include?("local original_status=$?") &&
      signer.include?("if [[ \"${final_status}\" -eq 0 ]]; then final_status=1; fi") &&
      signer.include?("trap lock_prepared_keychain EXIT") &&
      signer.include?("trap - EXIT INT TERM HUP") &&
      !signer.match?(/lock-keychain[^\n]*\|\|[[:space:]]*true/)
  abort "daily signer lost explicit signal exits" unless
    %w[130 143 129].all? { |status| signer.include?("trap \x27exit #{status}\x27") }
' "${provisioner}" "${signer}"

[[ "$(rg -Fc '$(call remove-linnet-local-residue,$${app_path},$${settings_app_path},$${embedded_settings_app_path})' \
  "${project_root}/Makefile")" == 2 ]] || {
  echo 'Development and the community finalizer do not share the residue owner.' >&2
  exit 1
}
rg -Fq 'release_metadata_root="$${app_path}/Contents/Resources/LinnetRelease";' \
  "${project_root}/Makefile" || {
  echo 'The candidate metadata producer lost its explicit Host resource path.' >&2
  exit 1
}
if rg -n '^[[:space:]]*security find-identity' \
  "${project_root}/scripts/linnet-code-identity"; then
  echo 'The community preflight regained a persistent trust-settings dependency.' >&2
  exit 1
fi
rg -Fq 'verify_signing_key "${identity}" "${canonical_keychain}"' \
  "${project_root}/scripts/linnet-code-identity" || {
  echo 'The community preflight stopped proving the external key at the codesign boundary.' >&2
  exit 1
}
rg -Fq 'actual_identity="$(shasum "${certificate}0"' \
  "${project_root}/scripts/linnet-code-identity" || {
  echo 'The community signing probe stopped binding its certificate to the pinned SHA-1.' >&2
  exit 1
}

generate() {
  local destination="$1"
  local projection
  projection="$(printf \
    '{"format":4,"profile":"community-cms","leaf_certificate_sha256":"%s","candidate_revision":"%s"}' \
    "${leaf_sha256}" "${revision}")"
  "${generator}" "${lock}" "${destination}" 0.1.1 1 1704067200 \
    "${projection}"
}

generate "${scratch}/first"
generate "${scratch}/second"
diff -qr "${scratch}/first" "${scratch}/second" >/dev/null

ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  abort "release metadata format is stale" unless document.fetch("format") == 2
  distribution = document.fetch("distribution")
  abort "community distribution shape is invalid" unless distribution == {
    "application_code_signature" => {
      "profile" => "community-cms",
      "kind" => "external-cms",
      "leaf_certificate_sha256" => ARGV.fetch(1),
      "hardened_runtime" => true,
      "host_settings_same_leaf" => true,
    },
    "artifact_scope" => "public-community",
    "notarized" => false,
    "publication_eligible" => true,
    "trust_model" => "manual-user-approval",
  }
  %w[developer_id_signed notarized bundle_integrity_signature].each do |retired|
    abort "retired signing field returned: #{retired}" if document.key?(retired)
  end
  abort "unexpected source projection" unless
    document.fetch("source") == {"candidate_revision" => ARGV.fetch(2)}
' "${scratch}/first/VERSION.json" "${leaf_sha256}" "${revision}"
rg -Fq 'public community build uses an explicit external CMS identity' \
  "${scratch}/first/PRIVACY.md"
rg -Fq 'SHA-256 files and approve the package' \
  "${scratch}/first/PRIVACY.md"

if "${generator}" "${lock}" "${scratch}/retired-community-identity" \
    0.1.1 1 1704067200 \
    "$(printf \
      '{"format":3,"profile":"community-adhoc","candidate_revision":"%s"}' \
      "${revision}")" >/dev/null 2>&1; then
  echo 'The retired community ad-hoc identity was accepted for publication.' >&2
  exit 1
fi

ruby -rjson -rdigest -ropen3 -e '
  sbom_path, version_path, licenses_path, lock_path, librime_root = ARGV
  sbom = JSON.parse(File.binread(sbom_path))
  version = JSON.parse(File.binread(version_path))
  abort "VERSION does not bind the exact SBOM" unless
    version.fetch("sbom_sha256") == Digest::SHA256.file(sbom_path).hexdigest

  runtime_license_root = File.join(
    librime_root, "dist", "share", "linnet-licenses"
  )
  runtime_licenses = Dir.children(runtime_license_root).sort
  expected_licenses = (runtime_licenses + %w[
    RIME-LMDG-CC-BY-4.0.txt Rime-wanxiang-CC-BY-4.0.txt
  ]).sort
  actual_licenses = Dir.children(licenses_path).sort
  abort "release license inventory differs" unless actual_licenses == expected_licenses
  abort "unsafe release license projection" unless expected_licenses.all? do |name|
    path = File.join(licenses_path, name)
    File.file?(path) && !File.symlink?(path)
  end
  runtime_licenses.each do |name|
    source = File.join(runtime_license_root, name)
    release = File.join(licenses_path, name)
    abort "runtime license bytes differ: #{name}" unless
      File.file?(source) && !File.symlink?(source) &&
        File.binread(source) == File.binread(release)
  end

  package_rows = sbom.fetch("packages")
  packages = package_rows.to_h { |item| [item.fetch("SPDXID"), item] }
  abort "SBOM package IDs are duplicated" unless packages.length == package_rows.length
  abort "SBOM package names are duplicated" unless
    package_rows.map { |item| item.fetch("name") }.uniq.length == package_rows.length
  runtime_packages = package_rows.select do |item|
    item.key?("primaryPackagePurpose")
  end
  abort "a shipped runtime package has an unknown license" if runtime_packages.any? do |item|
    [item.fetch("licenseDeclared"), item.fetch("licenseConcluded")].include?("NOASSERTION")
  end

  actual_relationships = sbom.fetch("relationships").map do |item|
    [item.fetch("spdxElementId"), item.fetch("relationshipType"),
     item.fetch("relatedSpdxElement")]
  end.sort
  abort "SBOM relationships are duplicated" unless
    actual_relationships.uniq.length == actual_relationships.length

  lock = JSON.parse(File.binread(lock_path))
  sources = lock.fetch("sources")
  librime = sources.fetch("librime")
  locked_librime = lock.dig("sources", "librime", "commit")
  git = lambda do |*arguments|
    output, error, status = Open3.capture3("git", "-C", librime_root, *arguments)
    abort "cannot read pinned librime metadata: #{error}" unless status.success?
    output.strip
  end
  package_for_vcs = lambda do |repository, commit, expected_version = nil|
    expected_version ||= commit
    locator = "git+#{repository}@#{commit}"
    matches = package_rows.select do |package|
      package.fetch("versionInfo") == expected_version &&
        package.fetch("externalRefs", []).any? do |item|
          item.fetch("referenceLocator") == locator
        end
    end
    abort "SBOM VCS identity is absent or duplicated: #{locator}" unless matches.one?
    matches.fetch(0)
  end
  require_edge = lambda do |owner, type, component|
    edge = [owner.fetch("SPDXID"), type, component.fetch("SPDXID")]
    abort "SBOM relationship is missing: #{edge.join(" ")}" unless
      actual_relationships.include?(edge)
  end

  linnet = packages.fetch(sbom.fetch("documentDescribes").fetch(0))
  abort "Linnet package does not bind the candidate revision" unless
    linnet.fetch("comment").include?(ARGV.fetch(5)) &&
      sbom.fetch("documentNamespace").include?(ARGV.fetch(5))
  squirrel = package_for_vcs.call(
    sources.dig("squirrel", "repository"), sources.dig("squirrel", "commit"),
    sources.dig("squirrel", "tag")
  )
  librime_package = package_for_vcs.call(
    librime.fetch("repository"), locked_librime, librime.fetch("tag")
  )
  abort "Squirrel license differs from the lock" unless
    squirrel.fetch("licenseDeclared") == sources.dig("squirrel", "declared_license")
  abort "librime license differs from the lock" unless
    librime_package.fetch("licenseDeclared") == librime.fetch("declared_license")
  require_edge.call(linnet, "VARIANT_OF", squirrel)
  require_edge.call(linnet, "DYNAMIC_LINK", librime_package)

  %w[rime_ice hallelujah rime_wanxiang].each do |name|
    source = sources.fetch(name)
    package = package_for_vcs.call(
      source.fetch("repository"), source.fetch("commit"), source.fetch("tag")
    )
    abort "#{name} license differs from the lock" unless
      package.fetch("licenseDeclared") == source.fetch("declared_license")
    require_edge.call(linnet, "DEPENDS_ON", package)
  end

  plugin_packages = librime.fetch("bundled_plugins").to_h do |name, plugin|
    package = package_for_vcs.call(plugin.fetch("repository"), plugin.fetch("commit"))
    abort "plugin license differs from the lock" unless
      package.fetch("licenseDeclared") == plugin.fetch("declared_license")
    require_edge.call(linnet, "DYNAMIC_LINK", package)
    require_edge.call(package, "DYNAMIC_LINK", librime_package)
    [name, package]
  end

  static_packages = librime.fetch("static_dependencies").to_h do |name, dependency|
    entry = git.call("ls-tree", locked_librime, "--", "deps/#{name}")
    commit = entry.split.fetch(2)
    repository = git.call(
      "config", "--blob", "#{locked_librime}:.gitmodules",
      "--get", "submodule.#{name}.url"
    )
    package = package_for_vcs.call(repository, commit)
    abort "static dependency license differs for #{name}" unless
      package.fetch("licenseDeclared") == dependency.fetch("declared_license")
    require_edge.call(librime_package, "STATIC_LINK", package)
    [name, package]
  end

  one_package = lambda do |name|
    matches = package_rows.select { |item| item.fetch("name") == name }
    abort "SBOM component is absent or duplicated: #{name}" unless matches.one?
    matches.fetch(0)
  end
  lua = one_package.call("Lua")
  darts = one_package.call("Darts-clone")
  rapidjson = one_package.call("RapidJSON")
  boost = one_package.call("Boost")
  require_edge.call(plugin_packages.fetch("lua"), "CONTAINS", lua)
  require_edge.call(librime_package, "CONTAINS", darts)
  require_edge.call(static_packages.fetch("opencc"), "CONTAINS", rapidjson)
  require_edge.call(plugin_packages.fetch("octagram"), "STATIC_LINK", darts)
  require_edge.call(plugin_packages.fetch("predict"), "STATIC_LINK", darts)
  [linnet, librime_package, plugin_packages.fetch("lua"),
   plugin_packages.fetch("octagram"), plugin_packages.fetch("predict")].each do |owner|
    require_edge.call(owner, "STATIC_LINK", boost)
  end
  darts_owner_edges = actual_relationships.select do |(_, type, target)|
    type == "CONTAINS" && target == darts.fetch("SPDXID")
  end
  abort "Darts-clone has a second runtime owner" unless darts_owner_edges == [
    [librime_package.fetch("SPDXID"), "CONTAINS", darts.fetch("SPDXID")]
  ]
  abort "RapidJSON license URL became a runtime source owner" if
    rapidjson.fetch("downloadLocation") != "NOASSERTION"
' "${scratch}/first/SBOM.spdx.json" "${scratch}/first/VERSION.json" \
  "${scratch}/first/LICENSES" "${lock}" "${project_root}/librime" "${revision}"

rg -Fq 'explicit external CMS identity' "${scratch}/first/PRIVACY.md"
rg -Fq 'Apple Developer ID and is not notarized.' \
  "${scratch}/first/PRIVACY.md"
rg -Fq 'canonical GitHub HTTPS Catalog' "${scratch}/first/PRIVACY.md"
rg -Fq 'container byte count and SHA-256' "${scratch}/first/PRIVACY.md"
rg -Fq 'manifest and every file hash' "${scratch}/first/PRIVACY.md"
if rg -qi 'signed Catalog|Ed25519|publisher identity' \
    "${scratch}/first/PRIVACY.md"; then
  echo 'Retired private Catalog-signing claims returned.' >&2
  exit 1
fi
! rg -qi 'ad-hoc signed|training checkpoints' \
  "${scratch}/first/PRIVACY.md" "${scratch}/first/NOTICE.md"
rg -Fq 'historical model-size labels' "${scratch}/first/NOTICE.md"
if rg -qi 'rime-octagram-data|octagram_data|Rime octagram data' \
    "${scratch}/first/NOTICE.md" "${scratch}/first/VERSION.json" \
    "${scratch}/first/SBOM.spdx.json"; then
  echo 'Build/test-only octagram model data entered release metadata.' >&2
  exit 1
fi
[[ ! -e "${scratch}/first/LICENSES/Rime-octagram-data-LGPL-3.0.txt" ]] || {
  echo 'Build/test-only octagram model license entered release metadata.' >&2
  exit 1
}

if "${generator}" "${lock}" "${scratch}/old-shape" 0.1.1 1 1704067200 \
    >/dev/null 2>&1; then
  echo 'The retired release-metadata argument shape was accepted.' >&2
  exit 1
fi
if "${generator}" "${lock}" "${scratch}/invalid-leaf" 0.1.1 1 1704067200 \
    '{"format":4,"profile":"community-cms","leaf_certificate_sha256":"bad","candidate_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' \
    >/dev/null 2>&1; then
  echo 'An invalid code-signing leaf digest was accepted.' >&2
  exit 1
fi
if "${generator}" "${lock}" "${scratch}/retired-test-profile" 0.1.1 1 1704067200 \
    "$(printf \
      '{"format":4,"profile":"test","leaf_certificate_sha256":"%s","candidate_revision":"%s"}' \
      "${leaf_sha256}" "${revision}")" >/dev/null 2>&1; then
  echo 'The retired component-test signing profile was accepted.' >&2
  exit 1
fi
if "${generator}" "${lock}" "${scratch}/retired-uat-profile" 0.1.1 1 1704067200 \
    "$(printf \
      '{"format":2,"profile":"uat","leaf_certificate_sha256":"%s","candidate_revision":"%s"}' \
      "${leaf_sha256}" "${revision}")" >/dev/null 2>&1; then
  echo 'The retired installation-UAT signing profile was accepted.' >&2
  exit 1
fi
if "${generator}" "${lock}" "${scratch}/old-identity-shape" 0.1.1 1 1704067200 \
    '{"format":4,"profile":"community-cms","leaf_certificate_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' \
    >/dev/null 2>&1; then
  echo 'The retired code-identity source shape was accepted.' >&2
  exit 1
fi

echo 'Release metadata: PASS (one stable community CMS projection)'
