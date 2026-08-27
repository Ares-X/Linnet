SHELL := /bin/bash

.PHONY: all install deps release debug community community-verified

all: release
install: install-release

RIME_BIN_DIR = librime/dist/bin
RIME_LIB_DIR = librime/dist/lib
DERIVED_DATA_PATH = build
XCODE_DESTINATION ?= generic/platform=macOS
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
	plugins/smart_english/smart_english_index.cc \
	plugins/smart_english/smart_english_mixed_decoder.cc
SMART_ENGLISH_HEADERS = plugins/smart_english/smart_english_domain.h \
	plugins/smart_english/smart_english_filter.h \
	plugins/smart_english/smart_english_index.h \
	plugins/smart_english/smart_english_mixed_decoder.h
SMART_ENGLISH_SDK_HEADERS = librime/dist/include/rime/predict/predict_engine.h \
	librime/dist/include/rime/gear/selector.h \
	librime/dist/include/glog/logging.h \
	librime/dist/include/marisa.h \
	librime/dist/include/marisa/stdio.h
ENGLISH_DATA_GENERATOR = build/linnet-english-data-generator
ENGLISH_DATA_GENERATOR_SOURCES = tools/LinnetEnglishDataSources.swift \
	tools/LinnetEnglishDataGenerator.swift
PLUM_DATA = data/plum/default.yaml \
	data/plum/linnet_algebra.yaml \
	data/plum/linnet_zh.schema.yaml \
	data/plum/linnet_zh_pinyin.schema.yaml \
	data/plum/linnet_zh_flypy.schema.yaml \
	data/plum/linnet_zh_mspy.schema.yaml \
	data/plum/linnet_zh_sogou.schema.yaml \
	data/plum/linnet_zh_abc.schema.yaml \
	data/plum/linnet_zh_ziguang.schema.yaml \
	data/plum/linnet_zh_jiajia.schema.yaml \
	data/plum/symbols_v.yaml \
	data/plum/symbols_caps_v.yaml \
	data/plum/radical_pinyin.dict.yaml \
	data/plum/radical_pinyin.schema.yaml \
	data/plum/linnet_en.schema.yaml \
	data/plum/linnet_user.yaml \
	data/plum/linnet_en.dict.yaml \
	data/plum/linnet_zh.dict.yaml \
	data/plum/linnet_reviewed.dict.yaml \
	data/plum/dicts/zi.dict.yaml \
	data/plum/dicts/jichu.dict.yaml \
	data/plum/dicts/lianxiang.dict.yaml \
	data/plum/dicts/cuoyin.dict.yaml \
	data/plum/dicts/duoyin.dict.yaml \
	data/plum/dicts/shici.dict.yaml \
	data/plum/dicts/diming.dict.yaml \
	data/plum/dicts/yixue.dict.yaml \
	data/plum/dicts/huaxue.dict.yaml \
	data/plum/dicts/yaopin.dict.yaml \
	data/plum/dicts/mingren.dict.yaml \
	data/plum/dicts/yiren.dict.yaml \
	data/plum/dicts/wuzhong.dict.yaml \
	data/plum/dicts/renming.dict.yaml \
	data/plum/dicts/taifeng.dict.yaml \
	data/plum/dicts/fangyan.dict.yaml \
	data/plum/linnet.smart.db \
	data/plum/linnet.english-data-manifest.json \
	data/plum/wanxiang-lts-zh-hans.gram \
	data/plum/zh-hans-t-essay-bgw.gram
OPENCC_DATA = data/opencc/TSCharacters.ocd2 \
	data/opencc/TSPhrases.ocd2 \
	data/opencc/t2s.json
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
	english-data-generator

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

$(ENGLISH_DATA_GENERATOR): $(ENGLISH_DATA_GENERATOR_SOURCES)
	@mkdir -p $(@D)
	$(SWIFTC) -parse-as-library -warnings-as-errors -O \
		-sdk "$(MACOS_SDK)" -target arm64-apple-macosx13.0 \
		$(ENGLISH_DATA_GENERATOR_SOURCES) -o $(ENGLISH_DATA_GENERATOR)

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

.PHONY: data plum-data opencc-data

data: plum-data opencc-data

$(PLUM_DATA):
	$(MAKE) plum-data

$(OPENCC_DATA):
	$(MAKE) opencc-data

plum-data:
	@echo "Linnet data is pinned and assembled by ./action-install.sh"
	@false

opencc-data:
	@echo "Linnet OpenCC data is pinned and assembled by ./action-install.sh"
	@false

deps: verify-rime-binaries data

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
	app_path="$(abspath $(DERIVED_DATA_PATH)/Build/Products/$(1)/Linnet.app)"; \
	settings_app_path="$(abspath $(DERIVED_DATA_PATH)/Build/Products/$(1)/Settings.app)"; \
	embedded_settings_app_path="$${app_path}/Contents/Applications/Settings.app"; \
	products_root="$(abspath $(DERIVED_DATA_PATH)/Build/Products)"; \
	local_app_cleanup='scripts/unregister-local-apps'; \
	trap '"$${local_app_cleanup}" "$${products_root}" "$${app_path}" "$${settings_app_path}" "$${embedded_settings_app_path}" >/dev/null 2>&1 || true' EXIT INT TERM HUP; \
		xcodebuild -project Linnet.xcodeproj -configuration $(1) -scheme Linnet \
			-destination '$(XCODE_DESTINATION)' -derivedDataPath $(DERIVED_DATA_PATH) \
			-showBuildTimingSummary $(BUILD_SETTINGS) build; \
	$(call remove-linnet-local-residue,$${app_path},$${settings_app_path},$${embedded_settings_app_path}); \
	scripts/build-privacy sanitize-localizations \
		"$${app_path}" "$${embedded_settings_app_path}" "$${settings_app_path}"; \
	"$${local_app_cleanup}" "$${products_root}" \
		"$${app_path}" "$${settings_app_path}" "$${embedded_settings_app_path}"; \
	trap - EXIT INT TERM HUP; \
	echo "Linnet $(1) App: BUILT (local, unsigned)"
endef

define finalize-linnet-candidate
	@set -e; \
	app_path="$(abspath $(DERIVED_DATA_PATH)/Build/Products/Release/Linnet.app)"; \
	settings_app_path="$(abspath $(DERIVED_DATA_PATH)/Build/Products/Release/Settings.app)"; \
	embedded_settings_app_path="$${app_path}/Contents/Applications/Settings.app"; \
	release_metadata_root="$${app_path}/Contents/Resources/LinnetRelease"; \
	code_identity_projection="$$(scripts/linnet-code-identity inspect-contract)"; \
	$(call remove-linnet-local-residue,$${app_path},$${settings_app_path},$${embedded_settings_app_path}); \
	product_version="$$(plutil -extract CFBundleShortVersionString raw -o - "$${app_path}/Contents/Info.plist")"; \
	product_build="$$(plutil -extract CFBundleVersion raw -o - "$${app_path}/Contents/Info.plist")"; \
	scripts/generate-release-metadata "$(abspath upstreams.lock.json)" \
		"$${release_metadata_root}" "$${product_version}" "$${product_build}" \
		1704067200 "$${code_identity_projection}"; \
	scripts/linnet-code-identity sign-product "$${app_path}" "$${settings_app_path}"; \
	scripts/build-privacy scan "$${app_path}"; \
	scripts/linnet-code-identity verify-product "$${app_path}" "$${settings_app_path}" >/dev/null; \
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

.PHONY: package archive install install-debug install-release

# The stable community PKG follows Squirrel's pkgbuild/component route, then
# wraps the component with visible license, upstream notice and privacy pages.
# Creation and static expansion do not install, launch or register the App.
package: community-verified
	mkdir -p "$(ARCHIVE_OUTPUT_DIR)"
	SOURCE_DATE_EPOCH=1704067200 bash package/make_package \
		"$(abspath $(DERIVED_DATA_PATH)/Build/Products/Release/Linnet.app)" \
		"$(ARCHIVE_OUTPUT_DIR)"

# Keep the portable ZIP as a second, manual per-user distribution. The PKG is
# the canonical normal-install artifact and is built first.
archive: package
	mkdir -p "$(ARCHIVE_OUTPUT_DIR)"
	SOURCE_DATE_EPOCH=1704067200 bash package/make_archive \
		"$(abspath $(DERIVED_DATA_PATH)/Build/Products/Release/Linnet.app)" \
		"$(ARCHIVE_OUTPUT_DIR)"

# No build target may mutate the developer machine. Users install the produced
# PKG explicitly with macOS Installer after checksum verification.
install install-debug install-release:
	@echo "Linnet build automation never installs, launches or registers the input method." >&2
	@false

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
	rm -rf package/release/*-Uninstall.command > /dev/null 2>&1 || true
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
