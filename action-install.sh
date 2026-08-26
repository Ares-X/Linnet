#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${project_root}"
lock_file="upstreams.lock.json"

build_started_at="$(date +%s)"
build_stage_started_at="${build_started_at}"
build_stage_number=0
build_stage_label=""

build_stage() {
    local now
    now="$(date +%s)"
    if [[ "${build_stage_number}" -gt 0 ]]; then
        printf '<== Linnet build stage %s/6 complete in %ss: %s\n' \
            "${build_stage_number}" "$((now - build_stage_started_at))" \
            "${build_stage_label}" >&2
    fi
    build_stage_number="$1"
    build_stage_label="$2"
    build_stage_started_at="${now}"
    printf '==> Linnet build stage %s/6: %s\n' "$1" "$2" >&2
}

finish_build_stages() {
    local now
    now="$(date +%s)"
    printf '<== Linnet build stage %s/6 complete in %ss: %s\n' \
        "${build_stage_number}" "$((now - build_stage_started_at))" \
        "${build_stage_label}" >&2
    printf 'Linnet locked build preparation: PASS (%ss total)\n' \
        "$((now - build_started_at))" >&2
}

lock_value() {
    local key_path="$1"
    local value
    value="$(/usr/bin/plutil -extract "${key_path}" raw -o - "${lock_file}")" || {
        echo "Missing upstream lock value: ${key_path}" >&2
        exit 1
    }
    [[ -n "${value}" ]] || {
        echo "Empty upstream lock value: ${key_path}" >&2
        exit 1
    }
    printf '%s\n' "${value}"
}

content_sha256() {
    shasum -a 256 < "$1" | awk '{print $1}'
}

lock_projection_sha256() {
    local key_path
    local projection
    projection="$({
        for key_path in "$@"; do
            printf '%s\t' "${key_path}"
            if ! /usr/bin/plutil -extract "${key_path}" raw -o - "${lock_file}" 2>/dev/null; then
                /usr/bin/plutil -extract "${key_path}" json -o - "${lock_file}" || exit 1
            fi
            printf '\n'
        done
    })" || return 1
    printf '%s' "${projection}" | shasum -a 256 | awk '{print $1}'
}

rime_git_commit="$(lock_value sources.librime.commit)"
plum_git_commit="$(lock_value sources.plum.commit)"
rime_ice_path="$(lock_value sources.rime_ice.submodule_path)"
rime_ice_git_commit="$(lock_value sources.rime_ice.commit)"
rime_ice_git_tree="$(lock_value sources.rime_ice.tree)"
hallelujah_path="$(lock_value sources.hallelujah.submodule_path)"
hallelujah_git_commit="$(lock_value sources.hallelujah.commit)"
hallelujah_git_tree="$(lock_value sources.hallelujah.tree)"
wanxiang_path="$(lock_value sources.rime_wanxiang.submodule_path)"
wanxiang_git_commit="$(lock_value sources.rime_wanxiang.commit)"
wanxiang_git_tree="$(lock_value sources.rime_wanxiang.tree)"
octagram_data_path="$(lock_value sources.rime_octagram_data.submodule_path)"
octagram_data_git_commit="$(lock_value sources.rime_octagram_data.commit)"
octagram_data_git_tree="$(lock_value sources.rime_octagram_data.tree)"
octagram_license_path="$(lock_value sources.rime_octagram_data.license_path)"
octagram_license_sha="$(lock_value sources.rime_octagram_data.license_sha256)"
lmdg_model_name="$(lock_value sources.rime_lmdg_grammar.asset)"
lmdg_asset_download_url="$(lock_value sources.rime_lmdg_grammar.asset_download_url)"
lmdg_pack_name="$(lock_value sources.rime_lmdg_grammar.linnet_pack.asset)"
lmdg_pack_download_url="$(
    lock_value sources.rime_lmdg_grammar.linnet_pack.asset_download_url)"
product_version="$(sed -n \
    's/^MARKETING_VERSION = \([^[:space:]]*\)$/\1/p' \
    config/LinnetProduct.xcconfig | LC_ALL=C sort -u)"
[[ "${product_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]] || {
    echo "Invalid Linnet product version: ${product_version}" >&2
    exit 1
}

verify_git_clean() {
    local repo_path="$1"
    local dirty_paths

    dirty_paths="$(git -C "${repo_path}" status \
        --porcelain \
        --untracked-files=all \
        --ignore-submodules=none)"
    if [[ -n "${dirty_paths}" ]]; then
        echo "Refusing dirty dependency checkout: ${repo_path}" >&2
        exit 1
    fi
}

remove_dependency_metadata() {
    local repo_path="$1"
    [[ -d "${repo_path}" ]] || return 0
    find "${repo_path}" -type f -name .DS_Store -delete
}

verify_git_snapshot() {
    local repo_path="$1"
    local expected_commit="$2"
    local expected_tree="${3:-}"
    local actual_commit
    local actual_tree

    actual_commit="$(git -C "${repo_path}" rev-parse HEAD)"
    if [[ "${actual_commit}" != "${expected_commit}" ]]; then
        echo "Unexpected Git commit in ${repo_path}: ${actual_commit}" >&2
        exit 1
    fi
    if [[ -n "${expected_tree}" ]]; then
        actual_tree="$(git -C "${repo_path}" rev-parse 'HEAD^{tree}')"
        if [[ "${actual_tree}" != "${expected_tree}" ]]; then
            echo "Unexpected Git tree in ${repo_path}: ${actual_tree}" >&2
            exit 1
        fi
    fi
    verify_git_clean "${repo_path}"
}

linnet_make=make
if [[ -x /Library/Developer/CommandLineTools/usr/bin/make ]]; then
    linnet_make=/Library/Developer/CommandLineTools/usr/bin/make
fi

dependency_repos=(
    librime
    plum
    "${rime_ice_path}"
    "${hallelujah_path}"
    "${wanxiang_path}"
    "${octagram_data_path}"
)
build_stage 1 "hydrate and verify locked upstream snapshots"
for dependency_repo in "${dependency_repos[@]}"; do
    remove_dependency_metadata "${dependency_repo}"
    if [[ -e "${dependency_repo}/.git" ]]; then
        verify_git_clean "${dependency_repo}"
    fi
done
if [[ -n "${no_download:-}" ]]; then
    for dependency_repo in "${dependency_repos[@]}"; do
        if [[ ! -e "${dependency_repo}/.git" ]]; then
            echo "Missing initialized dependency checkout in offline mode: ${dependency_repo}" >&2
            exit 1
        fi
    done
else
    git submodule update --init --depth 1 --jobs 6 --progress -- "${dependency_repos[@]}"
fi
verify_git_snapshot librime "${rime_git_commit}"
verify_git_snapshot plum "${plum_git_commit}"
verify_git_snapshot \
    "${rime_ice_path}" "${rime_ice_git_commit}" "${rime_ice_git_tree}"
verify_git_snapshot \
    "${hallelujah_path}" "${hallelujah_git_commit}" "${hallelujah_git_tree}"
verify_git_snapshot \
    "${wanxiang_path}" "${wanxiang_git_commit}" "${wanxiang_git_tree}"
verify_git_snapshot \
    "${octagram_data_path}" "${octagram_data_git_commit}" "${octagram_data_git_tree}"

# The accepted upstream digest owns the product grammar content. Linnet's
# fixed same-repository data pack is its sole build transport, so an upstream
# release asset replaced in place cannot alter or strand cold builds.
# The separate octagram-data checkout remains a pinned development/runtime-test
# fixture only.
build_stage 2 "fetch and verify the locked grammar model"
fetch_grammar_model() (
    local target="$1"
    local download_dir="" pack_file="" pack_tool="" extracted_dir=""
    local extracted_model="" inventory="" expected_inventory=""
    local cleanup_status=0 status

    cleanup_grammar_download() {
        status=$?
        trap - EXIT INT TERM
        if [[ -n "${download_dir}" ]]; then
            if [[ "${download_dir}" != \
                  "${project_root}/build/linnet-grammar."?????? ]]; then
                echo "Refusing unsafe grammar download cleanup: ${download_dir}" >&2
                cleanup_status=1
            elif [[ -d "${download_dir}" && ! -L "${download_dir}" ]]; then
                chmod -R u+w "${download_dir}" || cleanup_status=$?
                find "${download_dir}" -depth -delete || cleanup_status=$?
            elif [[ -e "${download_dir}" || -L "${download_dir}" ]]; then
                echo "Refusing non-directory grammar download cleanup: ${download_dir}" >&2
                cleanup_status=1
            fi
        fi
        if [[ "${status}" -eq 0 && "${cleanup_status}" -ne 0 ]]; then
            status="${cleanup_status}"
        fi
        exit "${status}"
    }
    trap cleanup_grammar_download EXIT INT TERM

    mkdir -p "${project_root}/build"
    download_dir="$(mktemp -d "${project_root}/build/linnet-grammar.XXXXXX")"
    pack_file="${download_dir}/${lmdg_pack_name}"
    pack_tool="${download_dir}/linnet-pack"
    extracted_dir="${download_dir}/extracted"
    extracted_model="${extracted_dir}/${lmdg_model_name}"
    echo "Restoring the locked Wanxiang LTS grammar from Linnet data:" >&2
    echo "  ${lmdg_pack_download_url}" >&2
    scripts/fetch-locked-release-asset \
        "${lock_file}" rime_lmdg_grammar.linnet_pack "${pack_file}"
    xcrun swiftc -warnings-as-errors \
        sources/LinnetPackContract.swift \
        sources/LinnetDataChannel.swift \
        sources/LinnetDataRegistry.swift \
        tools/LinnetDataCatalogBuilder.swift \
        tools/LinnetPackTool.swift -o "${pack_tool}"
    "${pack_tool}" extract \
        --pack "${pack_file}" \
        --core-version "${product_version}" \
        --output "${extracted_dir}" >/dev/null
    inventory="$(cd "${extracted_dir}" &&
        find . -mindepth 1 -print | LC_ALL=C sort)"
    expected_inventory="$(printf '%s\n' \
        "./${lmdg_model_name}" ./manifest.json | LC_ALL=C sort)"
    [[ "${inventory}" == "${expected_inventory}" &&
       -f "${extracted_model}" && ! -L "${extracted_model}" ]] || {
        echo "Locked Linnet LTS pack inventory is unexpected." >&2
        exit 1
    }
    scripts/verify-linnet-grammar-model "${extracted_model}" >/dev/null
    chmod u+w "${extracted_dir}"
    chmod 600 "${extracted_model}"
    mkdir -p "$(dirname "${target}")"
    mv -f "${extracted_model}" "${target}"
)

grammar_model="${project_root}/data/chinese/grammar/${lmdg_model_name}"
octagram_license="${octagram_data_path}/${octagram_license_path}"
if [[ (-e "${grammar_model}" || -L "${grammar_model}") &&
      (! -f "${grammar_model}" || -L "${grammar_model}") ]]; then
    echo "Unsafe locked Rime grammar cache path: ${grammar_model}" >&2
    exit 1
fi
if ! scripts/verify-linnet-grammar-model "${grammar_model}" >/dev/null 2>&1; then
    if [[ -n "${no_download:-}" ]]; then
        echo "Missing or stale Rime grammar model in offline mode: ${grammar_model}" >&2
        echo "Restore it from ${lmdg_pack_download_url}." >&2
        echo "The reviewed upstream identity is ${lmdg_asset_download_url}." >&2
        exit 1
    fi
    fetch_grammar_model "${grammar_model}"
fi
[[ -f "${octagram_license}" && ! -L "${octagram_license}" ]] || {
    echo "Missing locked octagram development fixture license." >&2
    exit 1
}
scripts/verify-linnet-grammar-model "${grammar_model}" >/dev/null
[[ "$(shasum -a 256 "${octagram_license}" | awk '{print $1}')" == "${octagram_license_sha}" ]] || {
    echo "Locked octagram development fixture license differs from upstreams.lock.json." >&2
    exit 1
}

# This is the sole byte owner for librime, its static dependencies, and the
# upstream plugins. It performs an exact arm64 source build and atomically
# replaces the generated runtime roots; no prebuilt-runtime fallback exists.
build_stage 3 "build the locked native Rime runtime"
no_download="${no_download:-}" bash scripts/build-rime-runtime
BOOST_INCLUDE_DIR=build/dependencies/boost "${linnet_make}" copy-rime-binaries

# The English projection contains dictionary and metadata facts only. The
# active Rime candidate stream owns Chinese/English overlap ranking, so Chinese
# dictionaries, schemas and profile algebra cannot invalidate this cache.
build_stage 4 "project Linnet-owned English data"
english_fingerprint_stamp="${project_root}/build/linnet-english.fingerprint"
compute_english_fingerprint() {
    {
        printf '%s\n' 'linnet-english-fingerprint-v6-swift'
        lock_projection_sha256 \
            sources.hallelujah.repository \
            sources.hallelujah.tag \
            sources.hallelujah.commit \
            sources.hallelujah.tree \
            sources.hallelujah.m2_inputs \
            sources.rime_ice.repository \
            sources.rime_ice.tag \
            sources.rime_ice.commit \
            sources.rime_ice.tree
        for input in \
            tools/LinnetEnglishDataSources.swift \
            tools/LinnetEnglishDataGenerator.swift \
            data/linnet/linnet_en_zh_decisions_final.tsv \
            data/linnet/linnet_en_zh_new_words.tsv \
            data/linnet/linnet_en_ipa_overrides.tsv \
            data/chinese/reports/pinyin_embargo_remove.tsv \
            data/chinese/reports/enriched_pinyin_english.json \
            librime/dist/bin/build_predict; do
            printf '%s\t%s\n' "${input}" "$(content_sha256 "${input}")"
        done
    } | shasum -a 256 | awk '{print $1}'
}
english_fingerprint="$(compute_english_fingerprint)"
english_cache="${project_root}/build/linnet-english-cache"
if [[ -f "${english_fingerprint_stamp}" &&
      "$(cat "${english_fingerprint_stamp}")" == "${english_fingerprint}" &&
      -s "${english_cache}/linnet_en.dict.yaml" &&
      -s "${english_cache}/linnet.smart.db" &&
      -f "${english_cache}/linnet.english-data-manifest.json" ]]; then
    echo "generate-linnet-english-data: SKIP (inputs unchanged; cached projection reused)"
else
    rm -rf -- "${english_cache}"
    "${linnet_make}" english-data-generator
    build/linnet-english-data-generator \
        --source "${hallelujah_path}" \
        --rime-ice-source "${rime_ice_path}" \
        --translation-decisions data/linnet/linnet_en_zh_decisions_final.tsv \
        --new-words-frequency data/linnet/linnet_en_zh_new_words.tsv \
        --ipa-overrides data/linnet/linnet_en_ipa_overrides.tsv \
        --lock upstreams.lock.json \
        --enriched-pinyin data/chinese/reports/enriched_pinyin_english.json \
        --pinyin-embargo data/chinese/reports/pinyin_embargo_remove.tsv \
        --output "${english_cache}" \
        --build-predict librime/dist/bin/build_predict
    printf '%s\n' "${english_fingerprint}" > "${english_fingerprint_stamp}"
fi
build_stage 5 "stage the canonical Linnet language data"
bash scripts/stage-linnet-data "${english_cache}"

# Pre-compile dictionaries during build so the user never waits for
# compilation at first launch.  rime_deployer --build produces .table.bin,
# .prism.bin and .reverse.bin files that librime would otherwise
# generate synchronously in start_maintenance.  The compilation is
# deterministic in the staged data and runtime, so it is skipped when the
# fingerprint of those inputs matches the previous run. The deployed data
# filenames and bytes plus the exact compiler/runtime binaries are the complete
# input set; unrelated lock or build-script changes cannot invalidate it.
build_stage 6 "precompile deployable Rime dictionaries"
precompiled_fingerprint_stamp="${project_root}/build/precompiled.fingerprint"
expected_precompiled_artifacts() {
    printf '%s\n' \
        linnet_en.prism.bin \
        linnet_en.reverse.bin \
        linnet_en.table.bin \
        linnet_zh.prism.bin \
        linnet_zh.reverse.bin \
        linnet_zh.table.bin \
        linnet_zh_abc.prism.bin \
        linnet_zh_flypy.prism.bin \
        linnet_zh_jiajia.prism.bin \
        linnet_zh_mspy.prism.bin \
        linnet_zh_pinyin.prism.bin \
        linnet_zh_sogou.prism.bin \
        linnet_zh_ziguang.prism.bin \
        radical_pinyin.prism.bin \
        radical_pinyin.reverse.bin \
        radical_pinyin.table.bin | LC_ALL=C sort
}

verify_precompiled_artifacts() {
    local root="$1"
    local expected actual artifact
    [[ -d "${root}" && ! -L "${root}" ]] || return 1
    expected="$(expected_precompiled_artifacts)"
    actual="$(find "${root}" -mindepth 1 -maxdepth 1 \
        -exec basename {} \; | LC_ALL=C sort)"
    [[ "${actual}" == "${expected}" ]] || return 1
    while IFS= read -r artifact; do
        [[ -f "${root}/${artifact}" && ! -L "${root}/${artifact}" && \
           -s "${root}/${artifact}" ]] || return 1
    done <<< "${expected}"
}

compute_precompiled_fingerprint() {
    {
        printf '%s\n' 'linnet-precompiled-fingerprint-v4-stock-corrector-disabled'
        while IFS= read -r -d '' input; do
            printf '%s\t%s\n' "${input}" "$(content_sha256 "${input}")"
        done < <(find data/plum -mindepth 1 -type f \
            -not -path 'data/plum/build/*' -print0 | LC_ALL=C sort -z)
        while IFS= read -r -d '' runtime_input; do
            printf '%s\t%s\n' "${runtime_input}" \
                "$(content_sha256 "${runtime_input}")"
        done < <(
            printf '%s\0' bin/rime_deployer lib/librime.1.dylib
            find lib/rime-plugins -mindepth 1 -maxdepth 1 \
                -type f -name '*.dylib' -print0 | LC_ALL=C sort -z
        )
    } | shasum -a 256 | awk '{print $1}'
}
precompiled_fingerprint="$(compute_precompiled_fingerprint)"
if [[ -f "${precompiled_fingerprint_stamp}" &&
      "$(cat "${precompiled_fingerprint_stamp}")" == "${precompiled_fingerprint}" ]] &&
      verify_precompiled_artifacts "${project_root}/data/plum/build" \
        >/dev/null 2>&1; then
    echo "precompiled artifacts: SKIP (staged data unchanged)"
else
(
precompiled="$(mktemp -d "${project_root}/build/linnet-precompiled.XXXXXX")"
precompiled_user="${precompiled}/user"
precompiled_build="${precompiled_user}/build"
precompiled_shared="${precompiled}/shared"
precompiled_candidate="${precompiled}/candidate-build"
precompiled_previous="${precompiled}/previous-build"
precompiled_target="${project_root}/data/plum/build"
precompiled_stamp_candidate="${precompiled}/precompiled.fingerprint"
precompiled_publishing=0
precompiled_had_target=0
precompiled_new_target=0
cleanup_precompiled() {
  status=$?
  trap - EXIT
  if [[ "${status}" -ne 0 && "${precompiled_publishing}" -eq 1 ]]; then
    [[ "${precompiled_new_target}" -eq 0 ]] || rm -rf -- "${precompiled_target}"
    [[ "${precompiled_had_target}" -eq 0 ]] || \
      mv "${precompiled_previous}" "${precompiled_target}"
  fi
  rm -rf -- "${precompiled}"
  exit "${status}"
}
trap cleanup_precompiled EXIT
mkdir -p "${precompiled_user}" "${precompiled_shared}"
# Never expose the prior immutable prebuilt directory to the compiler. If it
# is visible, librime legitimately reuses those binaries and emits no staging
# output, while this branch specifically needs a fresh projection for the new
# fingerprint. A symlink view keeps the 700+ MiB source data zero-copy.
while IFS= read -r -d '' source; do
  ln -s "${source}" "${precompiled_shared}/$(basename "${source}")"
done < <(find "${project_root}/data/plum" -mindepth 1 -maxdepth 1 \
  ! -name build -print0 | LC_ALL=C sort -z)
DYLD_LIBRARY_PATH="${project_root}/lib:${project_root}/lib/rime-plugins" \
  bin/rime_deployer --build "${precompiled_user}" "${precompiled_shared}" "${precompiled_build}"
# Publish one verified, complete binary directory. The compiler's generated
# YAML carries temporary absolute paths and never enters this candidate. A
# directory rename retires every prior artifact at once, so a missing new file
# cannot be masked by an old prism, table, or reverse database.
mkdir -p "${precompiled_candidate}"
while IFS= read -r -d '' artifact; do
  cp -X "${artifact}" "${precompiled_candidate}/"
done < <(find "${precompiled_build}" -mindepth 1 -maxdepth 1 \
  -type f -name '*.bin' -print0 | LC_ALL=C sort -z)
verify_precompiled_artifacts "${precompiled_candidate}" || {
  echo "Precompiled artifact candidate is incomplete, stale, or invalid." >&2
  exit 1
}
[[ ! -e "${precompiled_target}" || \
   ( -d "${precompiled_target}" && ! -L "${precompiled_target}" ) ]] || {
  echo "Precompiled artifact target is unsafe." >&2
  exit 1
}
printf '%s\n' "${precompiled_fingerprint}" > "${precompiled_stamp_candidate}"
precompiled_publishing=1
if [[ -d "${precompiled_target}" ]]; then
  mv "${precompiled_target}" "${precompiled_previous}"
  precompiled_had_target=1
fi
mv "${precompiled_candidate}" "${precompiled_target}"
precompiled_new_target=1
mv "${precompiled_stamp_candidate}" "${precompiled_fingerprint_stamp}"
precompiled_publishing=0
)
fi
finish_build_stages
