SHELL := /bin/bash

.PHONY: all release debug community community-verified

all: release

RIME_BIN_DIR = librime/dist/bin
RIME_LIB_DIR = librime/dist/lib
DERIVED_DATA_PATH = build
LOCAL_DERIVED_DATA_PATH = $(abspath $(DERIVED_DATA_PATH)/Local)
LOCAL_RELEASE_PRODUCTS = $(LOCAL_DERIVED_DATA_PATH)/Build/Products/Release
CANDIDATE_RELEASE_PRODUCTS = $(abspath $(DERIVED_DATA_PATH)/Candidate.noindex/Release)
CANDIDATE_RELEASE_APP = $(CANDIDATE_RELEASE_PRODUCTS)/Linnet.candidate
CANDIDATE_RELEASE_SETTINGS = $(CANDIDATE_RELEASE_PRODUCTS)/Settings.candidate
ARCHIVE_OUTPUT_DIR ?= $(abspath package/release)

RIME_LIBRARY_FILE_NAME = librime.1.dylib
RIME_LIBRARY = lib/$(RIME_LIBRARY_FILE_NAME)
RIME_UPSTREAM_PLUGINS = lib/rime-plugins/librime-lua.dylib \
	lib/rime-plugins/librime-octagram.dylib \
	lib/rime-plugins/librime-predict.dylib
RIME_TOOLS = bin/rime_deployer bin/rime_dict_manager
SMART_ENGLISH_PLUGIN = lib/rime-plugins/librime-smart-english.dylib
SMART_ENGLISH_SOURCES = plugins/smart_english/smart_english.cc \
	plugins/smart_english/smart_english_filter.cc \
	plugins/smart_english/smart_english_index.cc
SMART_ENGLISH_HEADERS = plugins/smart_english/smart_english_domain.h \
	plugins/smart_english/smart_english_filter.h \
	plugins/smart_english/smart_english_index.h
SMART_ENGLISH_SDK_HEADERS = librime/dist/include/rime/predict/predict_engine.h \
	librime/dist/include/rime/gear/selector.h \
	librime/dist/include/glog/logging.h \
	librime/dist/include/marisa.h \
	librime/dist/include/marisa/stdio.h
ENGLISH_DATA_GENERATOR = build/linnet-english-data-generator
ENGLISH_DATA_GENERATOR_SOURCES = tools/LinnetEnglishDataSources.swift \
	tools/LinnetEnglishDataGenerator.swift
LINNET_DATA_REGISTRY_SOURCES = sources/LinnetPackContract.swift \
	sources/LinnetDataChannel.swift \
	sources/LinnetDataRegistry.swift \
	sources/LinnetDirectoryDelta.swift \
	sources/LinnetDataRegistryTransactions.swift \
	sources/LinnetDataRegistryStorage.swift
LINNET_PACK_TOOL = build/linnet-pack
LINNET_PACK_TOOL_SOURCES = $(LINNET_DATA_REGISTRY_SOURCES) \
	sources/LinnetSettings/LinnetSettingsMutationLease.swift \
	tools/LinnetDataCatalogBuilder.swift \
	tools/LinnetPackEncoder.swift \
	tools/LinnetPackTool.swift
LINNET_RUNTIME_INSPECTOR = build/linnet-runtime-inspector
LINNET_RUNTIME_INSPECTOR_SOURCES = $(LINNET_DATA_REGISTRY_SOURCES) \
	tools/LinnetRuntimeInspector.swift
INPUT_SOURCE_REGISTRATION_INSPECTOR = build/input-source-registration-inspector
INPUT_SOURCE_REGISTRATION_INSPECTOR_SOURCES = \
	sources/LinnetInputSourceRegistration.swift \
	tools/LinnetInputSourceRegistrationInspector.swift
DEPS_CHECK = $(RIME_LIBRARY) $(SMART_ENGLISH_PLUGIN)

CXX ?= $(shell xcrun --find clang++)
SWIFTC ?= $(shell xcrun --find swiftc)
MACOS_SDK ?= $(shell xcrun --show-sdk-path)
BOOST_INCLUDE_DIR ?= build/dependencies/boost
PRIVATE_CXX_FLAGS = "-ffile-prefix-map=$(abspath .)=Linnet/Workspace" \
	"-fmacro-prefix-map=$(abspath .)=Linnet/Workspace" \
	"-fdebug-prefix-map=$(abspath .)=Linnet/Workspace" \
	"-ffile-prefix-map=$(MACOS_SDK)=Linnet/SDK" \
	"-fmacro-prefix-map=$(MACOS_SDK)=Linnet/SDK" \
	"-fdebug-prefix-map=$(MACOS_SDK)=Linnet/SDK" \
	-ffile-prefix-map=/private/tmp=Linnet/Temp \
	-fmacro-prefix-map=/private/tmp=Linnet/Temp \
	-fdebug-prefix-map=/private/tmp=Linnet/Temp \
	-fdebug-compilation-dir=.

.PHONY: copy-rime-binaries verify-rime-binaries smart-english-plugin \
	english-data-generator linnet-pack-tool linnet-runtime-inspector \
	input-source-registration-inspector

copy-rime-binaries:
	@set -e; \
	test -f "$(RIME_LIB_DIR)/$(RIME_LIBRARY_FILE_NAME)"; \
	for plugin in librime-lua.dylib librime-octagram.dylib librime-predict.dylib; do \
		test -f "$(RIME_LIB_DIR)/rime-plugins/$${plugin}"; \
	done; \
	for tool in rime_deployer rime_dict_manager; do test -f "$(RIME_BIN_DIR)/$${tool}"; done; \
	rm -f "$(RIME_LIBRARY)" $(RIME_TOOLS); \
	rm -rf lib/rime-plugins; \
	mkdir -p lib/rime-plugins bin; \
	find lib bin -type f -name .DS_Store -delete; \
	cp -L "$(RIME_LIB_DIR)/$(RIME_LIBRARY_FILE_NAME)" "$(RIME_LIBRARY)"; \
	for plugin in librime-lua.dylib librime-octagram.dylib librime-predict.dylib; do \
		cp "$(RIME_LIB_DIR)/rime-plugins/$${plugin}" "lib/rime-plugins/$${plugin}"; \
	done; \
	cp "$(RIME_BIN_DIR)/rime_deployer" bin/rime_deployer; \
	cp "$(RIME_BIN_DIR)/rime_dict_manager" bin/rime_dict_manager; \
	$(MAKE) --no-print-directory smart-english-plugin; \
	$(MAKE) --no-print-directory verify-rime-binaries

verify-rime-binaries:
	@set -e; \
	cmp -s "$(RIME_LIB_DIR)/$(RIME_LIBRARY_FILE_NAME)" "$(RIME_LIBRARY)" || { echo "Staged librime is not the locked runtime build." >&2; exit 1; }; \
	for plugin in librime-lua.dylib librime-octagram.dylib librime-predict.dylib; do \
		cmp -s "$(RIME_LIB_DIR)/rime-plugins/$${plugin}" "lib/rime-plugins/$${plugin}" || { echo "Staged $${plugin} is not the locked runtime build." >&2; exit 1; }; \
	done; \
	expected_plugins="$$(mktemp)"; \
	actual_plugins="$$(mktemp)"; \
	trap 'rm -f "$${expected_plugins}" "$${actual_plugins}"' EXIT; \
	printf '%s\n' librime-lua.dylib librime-octagram.dylib librime-predict.dylib librime-smart-english.dylib | LC_ALL=C sort > "$${expected_plugins}"; \
	find lib/rime-plugins -mindepth 1 -maxdepth 1 -type f -name '*.dylib' -exec basename {} \; | LC_ALL=C sort > "$${actual_plugins}"; \
	cmp -s "$${expected_plugins}" "$${actual_plugins}" || { echo "Linnet runtime plugin allowlist mismatch." >&2; exit 1; }; \
	for binary in $(RIME_LIBRARY) $(RIME_UPSTREAM_PLUGINS) $(SMART_ENGLISH_PLUGIN) $(RIME_TOOLS); do \
		test "$$(lipo -archs "$${binary}")" = arm64 || { echo "Linnet runtime is not thin arm64." >&2; exit 1; }; \
	done; \
	test "$$(otool -L "$(SMART_ENGLISH_PLUGIN)" | awk '$$1 == "@rpath/librime-predict.dylib" { count += 1 } END { print count + 0 }')" -eq 1 || { \
		echo "Smart English plugin does not have one canonical librime-predict dependency." >&2; exit 1; }; \
	echo "Linnet runtime: PASS (arm64, exact plugins)"

smart-english-plugin: $(SMART_ENGLISH_PLUGIN)

english-data-generator: $(ENGLISH_DATA_GENERATOR)

linnet-pack-tool: $(LINNET_PACK_TOOL)

linnet-runtime-inspector: $(LINNET_RUNTIME_INSPECTOR)

input-source-registration-inspector: $(INPUT_SOURCE_REGISTRATION_INSPECTOR)

$(ENGLISH_DATA_GENERATOR): $(ENGLISH_DATA_GENERATOR_SOURCES)
	@mkdir -p $(@D)
	$(SWIFTC) -parse-as-library -warnings-as-errors -O \
		-sdk "$(MACOS_SDK)" -target arm64-apple-macosx13.0 \
		$(ENGLISH_DATA_GENERATOR_SOURCES) -o $(ENGLISH_DATA_GENERATOR)

$(LINNET_PACK_TOOL): $(LINNET_PACK_TOOL_SOURCES)
	@mkdir -p $(@D)
	$(SWIFTC) -warnings-as-errors -sdk "$(MACOS_SDK)" \
		$(LINNET_PACK_TOOL_SOURCES) -o $(LINNET_PACK_TOOL)

$(LINNET_RUNTIME_INSPECTOR): $(LINNET_RUNTIME_INSPECTOR_SOURCES)
	@mkdir -p $(@D)
	$(SWIFTC) -parse-as-library -warnings-as-errors -O \
		-sdk "$(MACOS_SDK)" -target arm64-apple-macosx13.0 \
		$(LINNET_RUNTIME_INSPECTOR_SOURCES) -o $(LINNET_RUNTIME_INSPECTOR)

$(INPUT_SOURCE_REGISTRATION_INSPECTOR): $(INPUT_SOURCE_REGISTRATION_INSPECTOR_SOURCES)
	@mkdir -p $(@D)
	$(SWIFTC) -parse-as-library -warnings-as-errors -O \
		-sdk "$(MACOS_SDK)" -target arm64-apple-macosx13.0 -framework Carbon \
		$(INPUT_SOURCE_REGISTRATION_INSPECTOR_SOURCES) \
		-o $(INPUT_SOURCE_REGISTRATION_INSPECTOR)

$(SMART_ENGLISH_PLUGIN): $(SMART_ENGLISH_SOURCES) $(SMART_ENGLISH_HEADERS) \
		$(SMART_ENGLISH_SDK_HEADERS) \
		$(RIME_LIB_DIR)/$(RIME_LIBRARY_FILE_NAME) \
		$(RIME_LIB_DIR)/rime-plugins/librime-predict.dylib
	@mkdir -p $(@D)
	@set -o pipefail; $(CXX) -std=c++17 -arch arm64 -mmacosx-version-min=13.0 \
		-isysroot "$(MACOS_SDK)" -Wall -Wextra -Werror \
		-Wno-missing-field-initializers \
		-DGLOG_USE_GLOG_EXPORT \
		$(PRIVATE_CXX_FLAGS) \
		-dynamiclib -Wl,-install_name,@rpath/$(notdir $(SMART_ENGLISH_PLUGIN)) \
		-isystem "$(BOOST_INCLUDE_DIR)" \
		-isystem librime/dist/include \
		$(SMART_ENGLISH_SOURCES) $(RIME_LIB_DIR)/$(RIME_LIBRARY_FILE_NAME) \
		$(RIME_LIB_DIR)/rime-plugins/librime-predict.dylib \
		-o $(SMART_ENGLISH_PLUGIN) \
		2>&1 | scripts/build-privacy redact

BUILD_SETTINGS += COMPILER_INDEX_STORE_ENABLE=YES

define remove-linnet-local-residue
for stale_path in \
	"$(1)/Contents/Resources/LinnetRelease" \
	"$(1)/Contents/_CodeSignature" \
	"$(2)/Contents/_CodeSignature" \
	"$(3)/Contents/_CodeSignature"; do \
	if [ -L "$${stale_path}" ]; then unlink "$${stale_path}"; \
	elif [ -e "$${stale_path}" ]; then \
		chmod -R u+w "$${stale_path}"; \
		/bin/rm -rf -- "$${stale_path}"; \
	fi; \
done
endef

define build-linnet-app
	@set -e; set -o pipefail; \
	app_path="$(LOCAL_DERIVED_DATA_PATH)/Build/Products/$(1)/Linnet.app"; \
	settings_app_path="$(LOCAL_DERIVED_DATA_PATH)/Build/Products/$(1)/Settings.app"; \
	embedded_settings_app_path="$${app_path}/Contents/Applications/Settings.app"; \
	build_stamp="$(LOCAL_DERIVED_DATA_PATH)/Build/Products/$(1)/.linnet-build-complete"; \
	production_bundle_identifier="$$(sed -n 's/^LINNET_BUNDLE_IDENTIFIER = //p' config/LinnetProduct.xcconfig)"; \
	[[ "$${production_bundle_identifier}" =~ ^[A-Za-z0-9.-]+$$ ]] || { \
		echo 'Linnet build: canonical bundle identifier is unavailable' >&2; exit 1; \
	}; \
	local_bundle_identifier="$${production_bundle_identifier}.local-build"; \
	rewrite_bundle_identifier() { \
		local bundle_path="$$1" identifier="$$2" info_path; \
		if [ ! -e "$${bundle_path}" ] && [ ! -L "$${bundle_path}" ]; then return 0; fi; \
		info_path="$${bundle_path}/Contents/Info.plist"; \
		[ -d "$${bundle_path}" ] && [ ! -L "$${bundle_path}" ] && \
			[ -f "$${info_path}" ] && [ ! -L "$${info_path}" ] || { \
			echo "Linnet build: unsafe App identity boundary: $${bundle_path}" >&2; return 1; \
		}; \
		/usr/bin/plutil -replace CFBundleIdentifier -string "$${identifier}" "$${info_path}"; \
		[ "$$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$${info_path}")" = \
			"$${identifier}" ]; \
	}; \
	if [ -L "$${build_stamp}" ]; then unlink "$${build_stamp}"; \
	else /bin/rm -f -- "$${build_stamp}"; fi; \
	$(call remove-linnet-local-residue,$${app_path},$${settings_app_path},$${embedded_settings_app_path}); \
	rewrite_bundle_identifier "$${app_path}" "$${local_bundle_identifier}"; \
	rewrite_bundle_identifier "$${settings_app_path}" "$${local_bundle_identifier}.settings"; \
	rewrite_bundle_identifier "$${embedded_settings_app_path}" "$${local_bundle_identifier}.settings"; \
	scripts/build-linnet-app "$(1)" "$(LOCAL_DERIVED_DATA_PATH)" \
		$(BUILD_SETTINGS) LINNET_BUNDLE_IDENTIFIER="$${local_bundle_identifier}"; \
	scripts/build-privacy sanitize-localizations \
		"$${app_path}" "$${embedded_settings_app_path}" "$${settings_app_path}"; \
	[ "$$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$${app_path}/Contents/Info.plist")" = \
		"$${local_bundle_identifier}" ]; \
	[ "$$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$${settings_app_path}/Contents/Info.plist")" = \
		"$${local_bundle_identifier}.settings" ]; \
	[ "$$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$${embedded_settings_app_path}/Contents/Info.plist")" = \
		"$${local_bundle_identifier}.settings" ]; \
	/usr/bin/touch "$${build_stamp}"; \
	echo "Linnet $(1) App: BUILT (local, unsigned)"
endef

define finalize-linnet-candidate
	@set -e; set -o pipefail; \
	local_products="$(LOCAL_RELEASE_PRODUCTS)"; \
	candidate_products="$(CANDIDATE_RELEASE_PRODUCTS)"; \
	candidate_parent="$${candidate_products%/*}"; \
	candidate_intermediates="$${candidate_parent}/Intermediates.noindex"; \
	production_bundle_identifier="$$(sed -n 's/^LINNET_BUNDLE_IDENTIFIER = //p' config/LinnetProduct.xcconfig)"; \
	[[ "$${production_bundle_identifier}" =~ ^[A-Za-z0-9.-]+$$ ]] || { \
		echo 'Linnet candidate: canonical bundle identifier is unavailable' >&2; exit 1; \
	}; \
	mkdir -p "$${candidate_intermediates}"; \
	[ -d "$${candidate_intermediates}" ] && [ ! -L "$${candidate_intermediates}" ] || { \
		echo 'Linnet candidate: unsafe candidate intermediates' >&2; exit 1; \
	}; \
	staging_products="$$(mktemp -d "$${candidate_intermediates}/Release.XXXXXX")"; \
	cleanup_staging() { \
		if [[ -n "$${staging_products:-}" && \
			"$${staging_products}" == "$${candidate_intermediates}/Release."* ]]; then \
			chmod -R u+w "$${staging_products}" 2>/dev/null || true; \
			/bin/rm -rf -- "$${staging_products}"; \
		fi; \
	}; \
	trap cleanup_staging EXIT INT TERM HUP; \
	scripts/stage-linnet-candidate "$${local_products}" "$${staging_products}" \
		"$${production_bundle_identifier}"; \
	app_path="$${staging_products}/Linnet.candidate"; \
	settings_app_path="$${staging_products}/Settings.candidate"; \
	embedded_settings_app_path="$${app_path}/Contents/Applications/Settings.app"; \
	release_metadata_root="$${app_path}/Contents/Resources/LinnetRelease"; \
	code_identity_projection="$$(scripts/linnet-code-identity inspect-contract)"; \
	product_version="$$(plutil -extract CFBundleShortVersionString raw -o - "$${app_path}/Contents/Info.plist")"; \
	product_build="$$(plutil -extract CFBundleVersion raw -o - "$${app_path}/Contents/Info.plist")"; \
	scripts/generate-release-metadata "$(abspath upstreams.lock.json)" \
		"$${release_metadata_root}" "$${product_version}" "$${product_build}" \
		1704067200 "$${code_identity_projection}"; \
	scripts/linnet-code-identity sign-product "$${app_path}" "$${settings_app_path}"; \
	scripts/build-privacy scan "$${app_path}"; \
	scripts/linnet-code-identity verify-product "$${app_path}" "$${settings_app_path}" >/dev/null; \
	if [ -L "$${candidate_products}" ]; then \
		echo 'Linnet candidate: refusing to replace a symlink candidate' >&2; exit 1; \
	elif [ -e "$${candidate_products}" ]; then \
		[ -d "$${candidate_products}" ] || { \
			echo 'Linnet candidate: existing candidate is not a directory' >&2; exit 1; \
		}; \
		chmod -R u+w "$${candidate_products}"; \
		/bin/rm -rf -- "$${candidate_products}"; \
	fi; \
	/bin/mv "$${staging_products}" "$${candidate_products}"; \
	staging_products=''; \
	trap - EXIT INT TERM HUP; \
	echo "Linnet Release Candidate: PASS (community-cms signed, metadata bound, privacy scanned)"
endef

release: $(DEPS_CHECK) verify-rime-binaries
	mkdir -p $(DERIVED_DATA_PATH)
	$(call build-linnet-app,Release)

debug: $(DEPS_CHECK) verify-rime-binaries
	mkdir -p $(DERIVED_DATA_PATH)
	$(call build-linnet-app,Debug)

community: release
	$(call finalize-linnet-candidate)

community-verified: community
	./tests/verify_product.sh release

.PHONY: package archive

# The stable community PKG follows Squirrel's pkgbuild/component route, then
# wraps the component with visible license, upstream notice and privacy pages.
# Creation and static expansion do not install, launch or register the App.
package: community-verified linnet-pack-tool linnet-runtime-inspector \
	input-source-registration-inspector
	mkdir -p "$(ARCHIVE_OUTPUT_DIR)"
	LINNET_RELEASE_TOOL="$(abspath $(LINNET_PACK_TOOL))" \
	SOURCE_DATE_EPOCH=1704067200 bash package/make_package \
		"$(CANDIDATE_RELEASE_APP)" \
		"$(ARCHIVE_OUTPUT_DIR)"

# Keep the portable ZIP as a second, manual per-user distribution. The PKG is
# the canonical normal-install artifact and is built first.
archive: package
	mkdir -p "$(ARCHIVE_OUTPUT_DIR)"
	LINNET_RELEASE_TOOL="$(abspath $(LINNET_PACK_TOOL))" \
	SOURCE_DATE_EPOCH=1704067200 bash package/make_archive \
		"$(CANDIDATE_RELEASE_APP)" \
		"$(ARCHIVE_OUTPUT_DIR)"

.PHONY: clean clean-deps

clean:
	rm -rf build > /dev/null 2>&1 || true
	rm build.log > /dev/null 2>&1 || true
	rm bin/* > /dev/null 2>&1 || true
	rm lib/* > /dev/null 2>&1 || true
	rm lib/rime-plugins/* > /dev/null 2>&1 || true
	rm data/plum/* > /dev/null 2>&1 || true
	rm data/opencc/* > /dev/null 2>&1 || true

clean-package:
	rm -rf package/*appcast.xml > /dev/null 2>&1 || true
	rm -rf package/*.pkg > /dev/null 2>&1 || true
	rm -rf package/release/*.pkg > /dev/null 2>&1 || true
	rm -rf package/sign_update > /dev/null 2>&1 || true

clean-deps:
	$(MAKE) -C plum clean
	$(MAKE) -C librime clean
	rm -rf librime/dist > /dev/null 2>&1 || true

# ── Chinese data pipeline ───────────────────────────────────────────────────

.PHONY: verify-chinese-golden

# Golden candidate-quality test: record against data/plum and compare with
# the committed baseline (requires ./action-install.sh to have staged data).
verify-chinese-golden:
	ruby tests/verify_profile_golden.rb
