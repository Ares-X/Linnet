#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${project_root}"

fail() {
  echo "runtime footprint: $1" >&2
  exit 1
}

test -x tests/verify_candidate_native_idle.sh ||
  fail "the exact candidate-native lifecycle owner is missing"
test -x tests/verify_candidate_native_idle_test.sh ||
  fail "the exact candidate-native lifecycle regression is missing"
tests/verify_candidate_native_idle_test.sh >/dev/null ||
  fail "the candidate-native lifecycle owner is not path-exact"
if rg -n '/bin/sleep' tests/verify_candidate_native_idle_test.sh; then
  fail "the candidate-native lifecycle fixture copied a sealed system binary"
fi
test "$(rg -F -l 'tests/verify_candidate_native_idle.sh' \
  tests/verify_product.sh tests/verify_chinese_learning_policy.sh | \
  wc -l | tr -d ' ')" -eq 2 ||
  fail "native product gates do not share one exact lifecycle owner"
if rg -n 'ps -axo pid=,comm=.*|/Linnet\$|/Squirrel\$|\[\[:space:\]\\/\]\(Linnet\|Squirrel\)' \
    tests/verify_product.sh tests/verify_chinese_learning_policy.sh; then
  fail "an installed Host can still be mistaken for the candidate native owner"
fi

# The lock owns the exact librime release; packaging must not duplicate that
# version in an output filename literal that goes stale on a standard update.
rg -Fq 'librime_version="$(lock_value sources.librime.tag)"' \
  scripts/build-rime-runtime ||
  fail "runtime build does not consume the locked librime version"
rg -Fq 'lib/librime.${librime_version}.dylib' scripts/build-rime-runtime ||
  fail "runtime artifact verification does not project the locked version"
if rg -n 'lib/librime\.[0-9]+\.[0-9]+\.[0-9]+\.dylib' \
    scripts/build-rime-runtime; then
  fail "runtime artifact verification duplicated a literal librime version"
fi
ruby -rjson -e '
  policy = JSON.parse(File.read(ARGV.fetch(0))).fetch("policy")
  abort "public source provenance is not lock-owned" unless
    policy.fetch("squirrel_provenance") == "locked-tag-and-sbom-variant"
' upstreams.lock.json ||
  fail "the public source snapshot lost its explicit Squirrel provenance"
if rg -Fq '"git", "merge-base", "--is-ancestor"' scripts/upstream-sync; then
  fail "the retired Git-ancestry provenance inference returned"
fi
rg -Fq 'work_root="$(mktemp -d /private/tmp/linnet-rime-runtime.XXXXXX)"' \
  scripts/build-rime-runtime ||
  fail "runtime scratch data can still be mutated through the browsed project tree"
rg -Fq 'is_safe_runtime_work_root "${work_root}"' scripts/build-rime-runtime ||
  fail "runtime scratch cleanup is not protected by its path owner"
if rg -Fq '${repo_root}/build/rime-runtime.XXXXXX' scripts/build-rime-runtime; then
  fail "the retired project-local runtime scratch owner returned"
fi

for retired_path in \
  sources/LinnetModeSwitcher.swift \
  sources/LinnetApplicationModeMemory.swift \
  sources/LinnetRuntimeLaunchGuard.swift; do
  [[ ! -e "${retired_path}" ]] ||
    fail "retired private input-mode owner returned: ${retired_path}"
done
if rg -n 'LinnetModeSwitcher|LinnetApplicationModeMemory|LinnetRuntimeLaunchGuard|ShiftKeyPreference|ShiftCompositionBehavior|applicationModeSnapshot|rimeCommitSelectedCandidate|rimeAPI\.commit_composition\(session\)|rimeAPI\.set_option\(session, "prediction", false\)' \
    sources Linnet.xcodeproj/project.pbxproj; then
  fail "a retired private input-mode contract returned"
fi
runtime_authority_files=(README.md tests/verify_package_lifecycle.sh)
while IFS= read -r runtime_authority_file; do
  runtime_authority_files+=("${runtime_authority_file}")
done < <(rg --files sources package docs)
if rg -n -i 'launch[M]arker|launch [Ss]tate|crash[- ]loop' \
    "${runtime_authority_files[@]}"; then
  fail "a retired runtime launch-marker consumer returned"
fi
ruby -e '
  source = File.read(ARGV.fetch(0))
  entry = source[/static func main\(\).*?let delegate = SquirrelApplicationDelegate\(\)/m]
  abort "Host runtime entry owner is missing" unless entry
  location = entry.index("SquirrelInstaller.hostMayStartRuntime")
  lifecycle = entry.index("let handled = autoreleasepool")
  server = entry.index("_ = IMKServer")
  setup = entry.index("let delegate = SquirrelApplicationDelegate()")
  abort "a non-installed executable can mutate the input-source lifecycle" unless
    location && lifecycle && location < lifecycle
  abort "a non-installed Host can initialize InputMethodKit or Rime" unless
    server && setup && location < server && server < setup
  startup = source[/let delegate = SquirrelApplicationDelegate\(\).*?app\.run\(\)/m]
  abort "Host startup owner is missing" unless startup
  run = startup.index("app.run()")
  %w[
    guard\ delegate.setupRime()\ else
    guard\ delegate.startRime(fullCheck:\ false)\ else
    guard\ delegate.loadSettings()\ else
  ].each do |marker|
    position = startup.index(marker)
    abort "Host can advertise an input source after #{marker} failed" unless
      position && position < run
  end
  abort "Host retained an intentionally input-disabled startup state" if
    startup.include?(%q{schemaLabel: "故障"})
' sources/Main.swift || fail "Host startup failure can still publish a fake input source"
ruby -e '
  source = File.read(ARGV.fetch(0))
  activation = source[/fileprivate func activateDataTransaction\(.*?\n  \}\n\n  fileprivate func startTransactionMonitor/m]
  resume = source[/fileprivate func resumeCurrentRuntime\(\).*?\n  \}\n\n  func runtimeHealth/m]
  abort "transaction runtime owners are missing" unless activation && resume
  abort "activation ignores Settings readiness" if
    activation.match?(/^\s*loadSettings\(\)\s*$/)
  abort "resume ignores Settings readiness" if
    resume.match?(/^\s*loadSettings\(\)\s*$/)
' sources/SquirrelApplicationDelegate.swift ||
  fail "a transaction path can report runtime success after Settings failed to load"
if ! ruby -e '
  panel = File.read(ARGV[0]) + File.read(ARGV[1])
  view = File.read(ARGV[2])
  controller = File.read(ARGV[3]) + File.read(ARGV[4])
  config = File.read(ARGV[5])
  show = panel[/  func show\(publication:.*?\n  \}\n\n  func show\(status message:/m]
  draw = view[/  override func draw\(_ dirtyRect: NSRect\) \{.*?\n  \}\n\n\}\n\nextension SquirrelView/m]
  commit = controller[/  private func commit\(string: String, to targetClient: IMKTextInput\?\) \{.*?\n  \}\n\n  private func show\(/m]
  abort "candidate panel owners are missing" unless show && draw && commit
  size = show.index("textContainer.size =")
  layout = show.index("ensureLayout(for:")
  geometry = show.index("var contentRect = view.contentRect")
  abort "TextKit geometry can be read before the upstream layout boundary" unless
    size && layout && geometry && size < layout && layout < geometry &&
      show.include?("scrollToBeginningOfDocument(nil)")
  shadow = show.index("invalidateShadow()")
  front = show.index("orderFrontRegardless()")
  abort "the nonactivating candidate panel can be ordered beneath its active client" unless
    shadow && front && shadow < front && !show.include?("orderFront(nil)")
  abort "candidate background still follows an incremental dirty rectangle" unless
    draw.include?("let contentFrame = LinnetPanelGeometry.pagingLayout(") &&
      draw.include?("var containingRect = NSRect(origin: .zero, size: contentFrame.size)") &&
      !draw.include?("dirtyRect.height")
  marked = commit.index("targetClient.setMarkedText(")
  inserted = commit.index("targetClient.insertText(")
  abort "direct commits lack the upstream marked-text client opt-in" unless
    commit.include?(%q{get_option(session, "force_marked_text_for_direct_commit")}) &&
      marked && inserted && marked < inserted &&
      config.match?(/org\.alacritty:\s*\n\s+force_marked_text_for_direct_commit: true/)
' sources/SquirrelPanel.swift sources/SquirrelPanel+CandidatePresentation.swift \
    sources/SquirrelView.swift sources/SquirrelInputController.swift \
    sources/SquirrelInputController+RimeSession.swift data/squirrel.yaml; then
  fail "mature upstream candidate layout or direct-commit fixes are missing"
fi
test "$(rg -n '^ascii_composer:' data/linnet --glob '*.yaml' | wc -l | tr -d ' ')" -eq 1 ||
  fail "ascii_composer must have one distribution owner"
test "$(rg -F -n 'linnet_mode_switch_processor' \
  data/linnet/linnet_zh.schema.yaml data/linnet/linnet_en.schema.yaml | \
  wc -l | tr -d ' ')" -eq 2 ||
  fail "the direct Shift mapping must follow ascii_composer in both product roots"
if rg -n 'Shift\+space|Shift\+Space' data/linnet README.md; then
  fail "the retired Shift+Space product shortcut returned"
fi
rg -Fq 'class ModeSwitchProcessor : public Processor' \
  plugins/smart_english/smart_english.cc ||
  fail "the native direct-Shift mapping owner is missing"
ruby -e '
  source = File.read("plugins/smart_english/smart_english.cc")
  first = source.index("ProcessResult ProcessPredictionArrow")
  last = source.index("ProcessResult ProcessTab", first || 0)
  abort "the passive-prediction arrow boundary is missing" unless first && last
  owner = source[first...last]
  abort "prediction arrows no longer delegate movement to stock Selector" unless
    source.include?("prediction_selector_(ticket)") &&
      source.include?("Selector prediction_selector_") &&
      owner.include?("prediction_selector_.ProcessKeyEvent(key)")
  abort "prediction arrows regained a second layout or target inference owner" if
    ["_linear", "_horizontal", "_vertical", "page_size", "GetCandidateAt",
     "numeric_limits", "previous_candidate", "next_candidate"].any? do |token|
      owner.include?(token)
    end
' || fail "passive-prediction arrow ownership regressed"
rg -Fq 'context->get_option("ascii_mode")' \
  plugins/smart_english/smart_english.cc ||
  fail "direct Shift no longer consumes ascii_composer classification"
ruby -e '
  source = File.read("plugins/smart_english/smart_english.cc")
  owner = source[/class ModeSwitchProcessor : public Processor \{.*?\n\};/m]
  abort "the direct Shift transition owner is missing" unless owner
  apply = owner.index("engine_->ApplySchema")
  abort "direct Shift regained a second composition-commit owner" unless
    apply && !owner.include?("context->Commit()")
' || fail "direct Shift raw-code ownership regressed"
rg -Fq 'kModeReturnSchemaProperty[] = "linnet/mode_return_schema_v1"' \
  plugins/smart_english/smart_english.cc ||
  fail "direct Shift lost its session-owned Chinese return identity"
test "$(rg -F -c '  chinese_schema: linnet_zh_pinyin' data/linnet/linnet_en.schema.yaml)" -eq 1 ||
  fail "Smart English lost its single bundled Chinese return profile"
rg -Fq '"linnet_mode_switch/chinese_schema", quoted(input.chineseProfile.schemaID)' \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift ||
  fail "the selected Chinese profile stopped driving direct Smart English return"
rg -Fq '"linnet_mode_switch/chinese_schema", &direct_chinese_schema_' \
  plugins/smart_english/smart_english.cc ||
  fail "direct Smart English sessions stopped consuming the selected Chinese profile"
if rg -n 'kDefaultChineseSchema' plugins/smart_english/smart_english.cc; then
  fail "the native mode switch regained a duplicated Chinese-profile default"
fi
if rg -n 'SelectNextSchema|#include <rime/switcher.h>' \
    plugins/smart_english/smart_english.cc; then
  fail "direct Shift regained global schema-history inference"
fi
if ! ruby -ryaml -e '
  default = YAML.load_file("data/linnet/default.yaml")
  abort "the bundled pack regained the product Caps policy" unless
    default.dig("ascii_composer", "switch_key", "Caps_Lock") == "clear"
  abort "pending letters can again select a translated candidate on Shift" unless
    default.dig("ascii_composer", "switch_key", "Shift_L") == "commit_code" &&
      default.dig("ascii_composer", "switch_key", "Shift_R") == "commit_code"
  renderer = File.read("sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift")
  %w[Caps_Lock Shift_L Shift_R].each do |key|
    abort "the Core renderer does not own effective #{key} raw-code preservation" unless
      renderer.scan(%Q{"ascii_composer/switch_key/#{key}"}).length == 1
  end
  abort "a projected mode-switch key can still select translated text" if
    renderer.include?(%q{"commit_text"})
  abort "the Core renderer does not project all mode-switch keys as raw code" unless
    renderer.scan(%q{"commit_code"}).length == 3
  schemas = default.fetch("schema_list").map { |entry| entry.fetch("schema") }
  abort "full pinyin is not first" unless schemas.first == "linnet_zh_pinyin"
  abort "profile inventory changed" unless schemas == %w[
    linnet_zh_pinyin linnet_zh linnet_zh_flypy linnet_zh_mspy
    linnet_zh_sogou linnet_zh_abc linnet_zh_ziguang linnet_zh_jiajia linnet_en
  ]
  english = YAML.load_file("data/linnet/linnet_en.schema.yaml")
  abort "English pinyin prism is not the full-pinyin default" unless
    english.dig("linnet_pinyin", "prism") == "linnet_zh_pinyin"
  abort "Shift return is not the full-pinyin default" unless
    english.dig("linnet_mode_switch", "chinese_schema") == "linnet_zh_pinyin"
'; then
  fail "fresh installs no longer use one full-pinyin-first profile owner"
fi
if ! ruby -e '
  controller = File.read("sources/SquirrelInputController.swift")
  builder = File.read("sources/LinnetRimeCandidateSnapshotBuilder.swift")
  delegate = File.read("sources/SquirrelApplicationDelegate.swift")
  abort "controller does not consume the typed mode-transition label" unless
    controller.include?("inputModeTransitionLabel(") &&
      controller.include?("InputModeIdentity(") &&
      controller.include?("panel.updateStatus(") &&
      controller.include?("controller: self")
  abort "idle Shift feedback no longer reaches the normal caret panel" unless
    builder.include?("LinnetCandidatePresentation.candidateMenuPage(") &&
      builder.include?("guard menuPage.pageSize > 0 else")
  schema = delegate[/if messageType == "schema".*?\n  \}/m]
  abort "generic schema notification still owns caret feedback" if
    schema&.include?("showStatusMessage")
'; then
  fail "Shift mode feedback lost its single caret-presentation owner"
fi
if rg -n '^[[:space:]]+space:[[:space:]]+confirm$' \
    data/linnet/linnet_en.schema.yaml; then
  fail "Smart English regained a second Space owner in the inherited editor"
fi
rg -Fq 'key.keycode() == XK_space' plugins/smart_english/smart_english.cc ||
  fail "Smart English lost its native immediate-Space interaction owner"
rg -Fq 'linnet_english_interaction/space_adds_trailing_space' \
  plugins/smart_english/smart_english_domain.h ||
  fail "Smart English lost the typed trailing-space setting boundary"
rg -Fq 'options_.space_adds_trailing_space' \
  plugins/smart_english/smart_english.cc ||
  fail "the Space owner no longer consumes the trailing-space setting"
test "$(rg -F -c 'CommitSpaceSelection(' plugins/smart_english/smart_english.cc)" -eq 3 ||
  fail "active and focused-prediction Space paths diverged from one policy owner"

test "$(rg -F -c '  page_size: 9' data/linnet/default.yaml)" -eq 1 ||
  fail "the shipped candidate page default is not owned once as nine"
if rg -n '^[[:space:]]*save_options:' data/linnet; then
  fail "a Settings-owned new-session default returned to persisted save_options"
fi
ruby -e '
  source = File.read(ARGV.fetch(0))
  switches = source[/^switches:\n.*?(?=^\S)/m]
  abort "Chinese switch owner is missing" unless switches
  {"ascii_punct" => "0", "traditionalization" => "0",
   "emoji" => "1", "search_single_char" => "0"}.each do |name, expected|
    entry = switches[/^  - name: #{Regexp.escape(name)}\n.*?(?=^  - name:|\z)/m]
    abort "missing switch #{name}" unless entry
    actual = entry[/^\s+reset:\s*([01])\s*$/, 1]
    abort "#{name} reset #{actual.inspect}, expected #{expected}" unless actual == expected
  end
' data/linnet/linnet_zh.schema.yaml ||
  fail "the four Settings-owned new-session defaults diverged"
rg -Fq '  digit_separators: ",.:"' data/linnet/default.yaml ||
  fail "the Chinese punctuator lost the standard numeric separators"
rg -Fq '  digit_separator_action: commit' data/linnet/default.yaml ||
  fail "numeric punctuation regained a delayed next-key commit"
ruby -e '
  source = File.read(ARGV.fetch(0))
  half = source[/^  half_shape:\n.*?(?=^\S|^  [A-Za-z_])/m]
  abort "half-shape punctuation owner is missing" unless half
  abort "half-shape punctuator still owns idle Space" if
    half.match?(/^\s+[\x27\x22] [\x27\x22]\s*:/)
' data/linnet/default.yaml ||
  fail "the Chinese half-shape punctuator still consumes idle Space"
if rg -n 'candidate_list_layout|text_orientation' \
    data/linnet/linnet_en.schema.yaml; then
  fail "the English schema regained a private candidate-layout default"
fi
rg -Fq "  alphabet: zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA'" \
  data/linnet/linnet_en.schema.yaml ||
  fail "Smart English lost word-internal apostrophe spelling"
rg -Fq '  initials: zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA' \
  data/linnet/linnet_en.schema.yaml ||
  fail "Smart English again allows punctuation to start hidden spelling"
ruby -e '
  document, renderer, views, preview = ARGV.map { |path| File.read(path) }
  layout = document[/enum CandidateLayout:.*?\n  \}/m]
  browsing = document[/enum CandidateBrowsingMode:.*?\n  \}/m]
  abort "candidate layout owner is missing" unless layout
  abort "candidate layout must own only horizontal and vertical" unless
    layout.scan(/^    case ([A-Za-z]+)/).flatten == %w[horizontal vertical]
  abort "candidate browsing capability owner is missing" unless browsing
  abort "candidate browsing capability must own exactly scrollingOnly and expandable" unless
    browsing.scan(/^    case ([A-Za-z]+)/).flatten == %w[scrollingOnly expandable]
  abort "fresh v10 settings must default to native expandable disclosure" unless
    document.include?("candidateBrowsingMode: .expandable")
  abort "v9 expanded layout cleanup is missing" unless
    document.include?(%q{== "expanded"}) && document.include?(".scrollingOnly")
  abort "Settings lost the independent global candidate-browsing control" unless
    views.include?("candidateBrowsingMode") && views.include?("Scrolling only") &&
      views.include?("Expandable")
  abort "candidate preview lost the disclosure capability" unless
    preview.include?("candidateBrowsingMode")
  abort "Settings preview retained static expanded layout ownership" if
    preview.include?("case .expanded") ||
      preview.include?("LinnetCandidatePresentation.rowRanges(")
  abort "renderer retained the retired static expanded layout" if
    renderer.include?("case .expanded") || renderer.include?("linnet_expand_candidate_rows")
' sources/LinnetSettings/LinnetSettingsDocument.swift \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift \
  sources/LinnetSettings/SettingsViews.swift \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift ||
  fail "candidate layout and browsing capability ownership regressed"
if rg -n 'style/linnet_expand_candidate_rows' sources data/squirrel.yaml; then
  fail "the retired static expanded-row setting returned"
fi
if rg -n 'isExpanded[[:space:]]*\?[[:space:]]*\.footer|expanded[[:space:]]*\?[[:space:]]*LinnetCandidatePresentation\.DetailPlacement\.footer' \
    sources/SquirrelPanel.swift \
    sources/LinnetSettings/LinnetSettingsAppearancePreview.swift; then
  fail "candidate disclosure regained authority over horizontal/vertical detail placement"
fi
rg -Fq 'let detailGeometry = LinnetCandidatePresentation.candidateDetailGeometry(' \
  sources/SquirrelPanel.swift ||
  fail "the live panel bypassed the shared candidate-detail geometry owner"
rg -Fq 'return LinnetCandidatePresentation.candidateDetailGeometry(' \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift ||
  fail "the Settings preview bypassed the shared candidate-detail geometry owner"
test "$(rg -F -l 'style/linnet_candidate_expansion_allowed' \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift \
  sources/SquirrelTheme.swift | wc -l | tr -d ' ')" -eq 2 ||
  fail "candidate expansion capability must have one projection and one Host consumer"
rg -Fq 'linnet_candidate_expansion_allowed: true' data/squirrel.yaml ||
  fail "fresh installs do not default to native expandable disclosure"
rg -Fq '"style/linnet_candidate_expansion_allowed", "false"' \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift ||
  fail "scrolling-only mode lost its single global capability projection"
rg -Fq 'candidateExpansionAllowed ?= config.getBool(' sources/SquirrelTheme.swift &&
  rg -Fq '"style/linnet_candidate_expansion_allowed")' sources/SquirrelTheme.swift ||
  fail "the Host stopped consuming the global disclosure capability"

for iterator_contract in candidate_list_from_index candidate_list_next \
    candidate_list_end 'select_candidate(session'; do
  rg -Fq "${iterator_contract}" sources/SquirrelInputController.swift \
    sources/SquirrelInputController+RimeSession.swift \
    sources/LinnetRimeCandidateSnapshotBuilder.swift ||
    fail "expanded candidate iteration lost ${iterator_contract}"
done
rg -Fq 'LinnetCandidatePresentation.expandedCandidateRange(' \
  sources/LinnetRimeCandidateSnapshotBuilder.swift ||
  fail "expanded candidate iteration bypassed the three-page/27-item bound"
if rg -Fq 'select_candidate_on_current_page(session' \
    sources/SquirrelInputController.swift sources/SquirrelInputController+RimeSession.swift \
    sources/SquirrelPanel.swift sources/SquirrelPanel+CandidatePresentation.swift \
    sources/LinnetCandidateAccessibility.swift; then
  fail "candidate-window clicks regained a second page-local selection owner"
fi
test "$(rg -F -o 'selectCandidate(' \
  sources/SquirrelInputController.swift sources/SquirrelInputController+RimeSession.swift \
  sources/SquirrelPanel.swift sources/SquirrelPanel+CandidatePresentation.swift | \
  wc -l | tr -d ' ')" -ge 2 ||
  fail "expanded candidate clicks do not retain an absolute selection path"
ruby -e '
  panel = File.read(ARGV.fetch(0))
  state = "candidateExpansionRequested"
  abort "Panel transient expansion state is missing" unless
    panel.include?("private(set) var #{state} = false")
  hide = panel[/  func hide\(\) \{.*?\n  \}/m]
  update = panel[/  func update\(\n.*?\n  \}/m]
  binding = panel[/  func bind\(.*?\n  \}/m]
  controls = panel[/  func performControl\(.*?\n  \}/m]
  abort "Panel hide does not reset disclosure" unless hide&.include?("#{state} = false")
  abort "new composition does not start collapsed" unless
    update&.include?("#{state} = candidates.isExpanded") &&
      binding&.include?("hide()")
  abort "candidate disclosure actions do not own both transient transitions" unless
    controls&.include?("case .expand") && controls.include?("#{state} = true") &&
      controls.include?("case .collapse") && controls.include?("#{state} = false") &&
      controls.scan("refreshCandidatePresentation(").length == 2
' sources/SquirrelPanel.swift ||
  fail "candidate disclosure is not Panel-transient"
rg -Fq 'candidateRanges[itemIndex] =' sources/SquirrelPanel.swift ||
  fail "visual candidate reordering stopped writing geometry back by item offset"
rg -Fq 'candidate.absoluteIndex' sources/LinnetCandidateAccessibility.swift ||
  fail "candidate accessibility stopped selecting absolute Rime indices"
if rg -n 'accept: (minus|equal|bracketleft|bracketright), send: Page_(Up|Down)' \
    data/linnet/default.yaml; then
  fail "printable paging keys regained unconditional Rime bindings"
fi
if rg -n 'accept: Control\+Shift\+[34], toggle: (ascii_punct|traditionalization)' \
    data/linnet/default.yaml; then
  fail "Settings-owned punctuation or traditional-output defaults regained hidden session shortcuts"
fi
if rg -n 'PrintablePagingKey|printablePagingAction|printablePagingKey\(' \
    sources/SquirrelInputController.swift sources/LinnetCandidatePresentation.swift; then
  fail "printable punctuation regained a second candidate-paging owner"
fi
rg -Fq "alternative_select_keys: '123456789'" data/linnet/default.yaml ||
  fail "nine-candidate pages stopped excluding the unusable zero selection key"
ruby -e '
  plugin = File.read("plugins/smart_english/smart_english.cc")
  owner = plugin[/class LinnetInteractionProcessor.*?^};/m]
  abort "the canonical Linnet key-interaction owner is missing" unless owner
  translator = plugin[/class SmartEnglishTranslator.*?^};/m]
  abort "the Smart English translator is missing" unless translator
  abort "unhandled key intent has more than one subscriber" unless
    plugin.scan("unhandled_key_notifier().connect").length == 1
  abort "the unified key owner lost the unhandled-key boundary" unless
    owner.include?("unhandled_key_notifier().connect") &&
      owner.include?("OnUnhandledKey")
  abort "the translator still reads unhandled key intent" if
    translator.include?("unhandled_key_notifier") ||
      translator.include?("OnUnhandledKey") ||
      translator.include?("key.keycode()") ||
      translator.include?("key.modifier()")
  abort "normal candidates still bypass librime layout and caret semantics" if
    owner.include?("key.keycode() == XK_Left || key.keycode() == XK_Up") &&
      owner.include?("key.keycode() == XK_Right || key.keycode() == XK_Down")
  abort "the unified key owner stopped terminating raw-like fallback" unless
    owner.include?("IsRawLikeSegment(segment)")
  host_shortcut = owner.index(
    "if (HasHostShortcutModifier(key)) {"
  )
  prediction = owner.index(
    %q{context->composition().back().HasTag("prediction")}
  )
  abort "host shortcut rejection no longer precedes prediction/candidate policy" unless
    host_shortcut && prediction && host_shortcut < prediction
  abort "host shortcut policy no longer closes both processor boundaries" unless
    owner.scan("HasHostShortcutModifier(key)").length == 2
  abort "trailing Delete can again reach Editor handled-noop" unless
    owner.include?("key.keycode() == XK_Delete && IsPlainKey(key)") &&
      owner.include?("context->caret_pos() >= context->input().size()")
  %w[raw zz_code_token text_expander].each do |tag|
    abort "the raw-like boundary lost #{tag}" unless
      plugin.include?(%Q{segment.HasTag("#{tag}")})
  end
  abort "the unified key owner stopped de-authorizing passive prediction" unless
    owner.include?(%q{context->composition().back().HasTag("prediction")}) ||
      owner.include?(%q{segment.HasTag("prediction")})
  abort "the unified key component registration count changed" unless
    plugin.scan(%q{Register("linnet_interaction_processor"}).length == 1
  abort "a retired split key owner returned" if
    plugin.include?("CandidateNavigationProcessor") ||
      plugin.include?("SmartEnglishInteractionProcessor") ||
      plugin.include?(%q{Register("linnet_candidate_navigation_processor"}) ||
      plugin.include?(%q{Register("linnet_english_interaction_processor"})
  %w[data/linnet/linnet_en.schema.yaml data/linnet/linnet_zh.schema.yaml].each do |path|
    schema = File.read(path)
    abort "#{path} retained dead Control-modified editor bindings" if
      schema.match?(/^\s+Control(?:\+Shift)?\+(?:Return|BackSpace|Delete):/)
  end
  predict_patch = File.read(
    "patches/librime-predict-linnet-session-state.patch"
  )
  predictor_sections = predict_patch.scan(
    /^diff --git a\/src\/predictor\.(?:cc|h).*?(?=^diff --git|\z)/m
  ).join
  abort "the canonical Predictor patch sections are missing" if
    predictor_sections.empty?
  predictor_lines = predictor_sections.lines(chomp: true)
  added_predict = predictor_lines.reject { |line| line.start_with?("+++") }
                               .select { |line| line.start_with?("+") }
                               .join("\n")
  abort "Predictor regained key-intent policy" if
    %w[DismissesPrediction last_action_ kSuppress ProcessKeyEvent].any? do |token|
      added_predict.include?(token)
    end
  deleted_predict = predictor_lines.reject { |line| line.start_with?("---") }
                                 .select { |line| line.start_with?("-") }
                                 .join("\n")
  abort "the canonical patch no longer removes Predictor key handling" unless
    deleted_predict.include?("ProcessResult Predictor::ProcessKeyEvent") &&
      deleted_predict.include?("ProcessResult ProcessKeyEvent") &&
      deleted_predict.include?("last_action_")
  %w[data/linnet/linnet_zh.schema.yaml data/linnet/linnet_en.schema.yaml].each do |path|
    schema = File.read(path)
    recognizer_index = schema.index("- recognizer")
    owner_index = schema.index("- linnet_interaction_processor")
    predictor_index = schema.index("- predictor")
    selector_index = schema.index("- selector")
    abort "#{path} bypasses recognizer precedence or the unified key owner" unless
      recognizer_index && owner_index && predictor_index && selector_index &&
        recognizer_index < owner_index && owner_index < predictor_index &&
        owner_index < selector_index
  end
  default = File.read("data/linnet/default.yaml")
  abort "the retired global Tab key binder returned" if
    default.match?(/accept: (?:Shift\+)?Tab, send:/)
  abort "the generic separator recognizer again captures a bare trailing symbol" if
    default.include?(%q{[A-Za-z]+[._/@:+-][0-9A-Za-z._/@:+?&=%#~-]*})
' || fail "unified Linnet key-interaction ownership regressed"
ruby -ryaml -e '
  source = YAML.load_file("data/linnet/default.yaml")
  abort "the language pack regained an effective raw recognizer" unless
    source.dig("linnet", "recognizer_patterns", "zz_code_token") == "^$"
  renderer = File.read("sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift")
  pattern = renderer[/private static let codeTokenRecognizerPattern =\s*\n\s*"([^"]+)"/, 1]
  abort "the Core-owned raw recognizer is missing" unless pattern.is_a?(String)
  regex = Regexp.new(pattern)
  keep = ["https:", "www.", "mailto:", "file:",
          "URLSession", "README.md", "EMA20", "v1.16.0"]
  retire = ["/tmp", "~/", "shi@", "hello@", "src/", "snake_",
            "hello.", "hello-"]
  abort "an explicit or unambiguous raw prefix stopped matching" unless
    keep.all? { |value| regex.match?(value) }
  returned = retire.select { |value| regex.match?(value) }
  abort "ordinary word punctuation regained raw capture: #{returned.join(", ")}" unless
    returned.empty?
' || fail "raw-code and immediate-punctuation ownership regressed"
test ! -e patches/librime-punctuator-genuine-candidate.patch ||
  fail "the retired one-off punctuator patch returned"
git -C librime apply --check \
  ../patches/librime-linnet-core-interactions.patch ||
  fail "the locked core interaction patch no longer applies exactly to pinned librime"
ruby -e '
  project = File.read("Linnet.xcodeproj/project.pbxproj")
  units = File.read("tests/verify_swift_units.sh")
  abort "application targets do not share the staged Rime API header owner" unless
    project.scan(%q{HEADER_SEARCH_PATHS = "$(SRCROOT)/librime/dist/include";}).length == 2 &&
      units.scan("-I librime/dist/include").length == 4
  abort "an unpatched source header can shadow the staged Rime API" if
    project.include?("librime/src") || project.include?("librime/include") ||
      units.match?(/-I librime\/(?:src|include)(?:\s|$)/)
' || fail "staged Rime API header ownership regressed"
ruby -e '
  patch = File.read("patches/librime-linnet-core-interactions.patch")
  added = patch.lines.reject { |line| line.start_with?("+++") }
               .select { |line| line.start_with?("+") }.join
  deleted = patch.lines.reject { |line| line.start_with?("---") }
                 .select { |line| line.start_with?("-") }.join
  abort "Punctuator stopped reading the genuine candidate origin" unless
    added.include?("Candidate::GetGenuineCandidates(cand)") &&
      added.include?(%q{genuine->type() == "punct"})
  abort "Punctuator still special-cases the wrapped punct_number tag" if
    added.include?(%q{if (tag != "punct")})
  abort "the erroneous outer candidate-type inference was not retired" unless
    deleted.include?(%q{cand && cand->type() == "punct"})
  abort "AsciiComposer no longer cancels modifier gestures on composition abort" unless
    added.include?("engine_->context()->abort_notifier().connect") &&
      added.include?("engine_->context()->commit_notifier().connect") &&
      added.include?("connection commit_connection_") &&
      added.include?("connection abort_connection_") &&
      added.scan("ResetModifierState();").length == 8
  abort "zero-input prediction can again be accepted by a mode switch" unless
    added.include?("ctx->input().empty()") &&
      added.include?("ctx->AbortComposition()") &&
      added.include?("ctx->ConfirmCurrentSelection()")
  abort "lifecycle raw input has no versioned Rime API owner" unless
    added.include?("Bool (*commit_raw_input)(RimeSessionId session_id)") &&
      added.include?("bool Session::CommitRawInput()") &&
      added.include?("static Bool RimeCommitRawInput") &&
      added.include?("s_api.commit_raw_input = &RimeCommitRawInput")
  abort "raw commit semantics remain duplicated across Rime processors" unless
    added.include?("bool Context::CommitRawInput()") &&
      added.scan("ctx->CommitRawInput();").length == 4 &&
      deleted.scan("ctx->ClearNonConfirmedComposition();").length == 3
  abort "active switcher exit bypasses the Session lifecycle owner" unless
    added.include?("Context* Session::PrepareCompositionExit()") &&
      added.include?("dynamic_cast<Switcher*>(active_engine)") &&
      added.include?("switcher->Deactivate();") &&
      added.include?("Context* ctx = PrepareCompositionExit();")
  abort "stale cleanup can erase a pending root or alternate-engine composition" unless
    added.include?("bool Session::HasPendingClientState() const") &&
      added.include?("!commit_text_.empty()") &&
      added.include?("!engine_->context()->input().empty()") &&
      added.include?("!active_engine->context()->input().empty()") &&
      added.include?("!it->second->HasPendingClientState()")
  abort "the lifecycle API changed librime C++ virtual ABI" if
    added.include?("virtual bool CommitRawInput") ||
      added.include?("virtual void ClearComposition")
  abort "grammar can again erase the canonical system dictionary weight" unless
    added.include?("system_lexical_weight_(std::move(system_lexical_weight))") &&
      added.include?("system_lexical_weight() const") &&
      added.include?("FindSystemLexicalWeight") &&
      added.include?("FindRemainingEntry(text)") &&
      added.include?("dictionary::MakeEntry(chunk, chunk.cursor)")
  abort "the retired duplicate lexical-weight field returned" if
    added.include?("lexical_weight_(entry->weight)") ||
      added.include?("double lexical_weight() const")
  abort "Smart English can again infer the main translator spelling path" unless
    added.include?("SpellingType spelling_type = kInvalidSpelling") &&
      added.include?("SpellingType spelling_type() const") &&
      added.include?("const SpellingType spelling_type_") &&
      added.include?("syllabifier_->SpellingTypeAt(phrase_code_length)")
' || fail "the pinned core input-interaction repair regressed"
ruby -e '
  callers = []
  Dir["librime/src/rime/**/*.{cc,h}"].each do |path|
    File.readlines(path).each_with_index do |line, index|
      next unless line.include?("set_active_engine(")
      next if path.end_with?("engine.h")
      callers << "#{path}:#{index + 1}"
    end
  end
  abort "an unreviewed alternate engine can bypass lifecycle exit: #{callers.join(", ")}" unless
    callers.length == 3 && callers.all? { |entry| entry.include?("/switcher.cc:") }
' || fail "pinned librime gained an alternate-engine owner without exit semantics"
ruby -e '
  mapping = File.read("sources/MacOSKeyCodes.swift")
  controller = File.read("sources/SquirrelInputController.swift")
  physical = mapping.index("keycodeMappings[Int(keycode)]")
  nil_guard = mapping.index("guard let keychar else")
  inferred = mapping.index("additionalCodeMappings[Int(keycode)]")
  abort "characterless events can bypass physical special-key mapping" unless
    physical && nil_guard && inferred && physical < nil_guard && nil_guard < inferred
  abort "InputMethodKit can still drop a characterless physical arrow" unless
    controller.include?("keychar: keyChars?.first") &&
      controller.include?("rimeKeycode != UInt32(XK_VoidSymbol)") &&
      !controller.include?("if let char = keyChars?.first")
  abort "keypad Enter no longer shares the ordinary Return contract" unless
    mapping.include?("kVK_ANSI_KeypadEnter: XK_Return")
  abort "Command shortcuts can still bypass passive-prediction cleanup" if
    controller.match?(/if modifiers\.contains\(\.command\) \{\s*break\s*\}/m)
' || fail "physical special-key ingress regressed"
test "$(rg -F -c 'inputController.page' sources/SquirrelPanel.swift \
  sources/SquirrelPanel+CandidatePresentation.swift | \
  awk -F: '{ total += $NF } END { print total + 0 }')" -ge 3 ||
  fail "wheel or paging controls stopped changing Rime pages"
ruby -e '
  panel = File.read("sources/SquirrelPanel.swift") +
    File.read("sources/SquirrelPanel+CandidatePresentation.swift")
  state = File.read("sources/LinnetCandidateInteractionState.swift")
  abort "candidate scroll no longer cancels an armed mouse press" unless
    state.match?(/func processScroll\(.*?cancelPress\(\)/m)
  abort "candidate publications do not retire pointer and wheel state" unless
    panel.scan("candidateInteraction.advancePublication()").length == 2 &&
      state.include?("publicationGeneration &+= 1") &&
      state.include?("pressedHit = nil") &&
      state.include?("scrollTime = .distantPast")
  abort "phased scroll gestures lost publication identity" unless
    state.include?("scrollPublicationGeneration = publicationGeneration") &&
      state.scan("scrollPublicationGeneration == publicationGeneration").length == 2
  abort "SquirrelPanel regained a competing pointer or scroll state owner" if
    %w[pressedHit scrollDirection scrollTime scrollPublicationGeneration
       publicationGeneration].any? { |token| panel.include?(token) }
  abort "the interaction owner no longer projects one paging intent to Rime" unless
    panel.include?("candidateInteraction.processScroll") &&
      panel.include?("pagingIntent == .previousPage")
' || fail "candidate pointer/scroll publication ownership regressed"
test "$(rg -F -c '.livePanelProjection' \
  sources/LinnetSettings/SettingsMain.swift)" -eq 3 &&
  test "$(rg -F -c '.livePanelProjection' \
  sources/LinnetSettings/SettingsDataCoordinator.swift)" -eq 2 ||
  fail "live appearance boundaries stopped consuming the canonical session projection"
if rg -n 'previewableAppearance|currentDocument\.appearance\.pageSize == document\.appearance\.pageSize' \
    sources/LinnetSettings/SettingsMain.swift \
    sources/LinnetSettings/SettingsDataCoordinator.swift; then
  fail "a handwritten lightweight-appearance field list returned"
fi
if rg -n 'linnet_detail_placement' sources data/squirrel.yaml; then
  fail "a theme regained ownership of candidate-detail placement"
fi
rg -Fq 'newTemplate.replace(/%@/, with: "[candidate] [comment]")' \
  sources/SquirrelTheme.swift ||
  fail "the standard Squirrel %@ candidate/comment contract was removed"
test "$(rg -F -c 'LinnetCandidatePresentation.usesInlineComments(' \
  sources/SquirrelPanel.swift)" -eq 1 &&
  rg -Fq 'candidateFormat: theme.candidateFormat' sources/SquirrelPanel.swift ||
  fail "the candidate panel stopped preserving standard inline comments"
ruby -ryaml -e '
  expected = %w[
    linnet_zh_pinyin linnet_zh linnet_zh_flypy linnet_zh_mspy
    linnet_zh_sogou linnet_zh_abc linnet_zh_ziguang linnet_zh_jiajia linnet_en
  ]
  default = YAML.load_file("data/linnet/default.yaml")
  declared = default.fetch("schema_list").map { |entry| entry.fetch("schema") }
  abort "the product schema inventory is not the canonical nine" unless declared == expected
  schema_paths = Dir["data/linnet/linnet_*.schema.yaml"].sort
  actual = schema_paths.map { |path| File.basename(path, ".schema.yaml") }
  abort "the staged schema source set is not exactly the canonical nine" unless
    actual == expected.sort
  runtime = File.read("tests/verify_rime_runtime.sh")
  staging = runtime[/for schema in data\/linnet\/\*\.schema\.yaml; do.*?\ndone/m]
  abort "native runtime acceptance no longer stages every canonical schema" unless
    staging && staging.include?(%q{cp "${schema}" "${shared}/$(basename "${schema}")"})

  wrappers = expected.grep(/\Alinnet_zh_/)
  abort "the Chinese wrapper inventory changed" unless wrappers.length == 7
  wrappers.each do |schema_id|
    path = "data/linnet/#{schema_id}.schema.yaml"
    source = File.read(path)
    abort "#{path} stopped inheriting the shared Chinese root" unless
      source.scan("__include: linnet_zh.schema.yaml:/").length >= 1
    duplicated = source.scan(/^(engine|ascii_composer|punctuator|recognizer):/).flatten
    abort "#{path} duplicated shared pipeline owners: #{duplicated.join(", ")}" unless
      duplicated.empty?
  end
  chord_owners = schema_paths.select do |path|
    File.read(path).match?(/^\s*(?:-\s*)?chord_composer(?:@|:|\s|$)/)
  end
  abort "a product schema regained chord_composer: #{chord_owners.join(", ")}" unless
    chord_owners.empty?
' || fail "schema staging or shared wrapper ownership regressed"
test "$(rg -l '^date_translator:' data/linnet/linnet_zh*.schema.yaml | wc -l | tr -d ' ')" -eq 2 ||
  fail "the product must have one double-pinyin date-command owner and one full-pinyin override"
for mapping in 'date: date' 'time: time' 'week: week' 'datetime: datetime' \
  'timestamp: timestamp' 'datezh: datezh' 'dateen: dateen'; do
  rg -Fq "  ${mapping}" data/linnet/linnet_zh.schema.yaml ||
    fail "the double-pinyin root lost its non-colliding date command: ${mapping}"
done
for mapping in 'date: rq' 'time: sj' 'week: xq' 'datetime: dt' \
  'timestamp: ts' 'datezh: rqzh' 'dateen: rqen'; do
  rg -Fq "  ${mapping}" data/linnet/linnet_zh_pinyin.schema.yaml ||
    fail "the full-pinyin profile lost its reviewed date command: ${mapping}"
done
test "$(rg -l -F 'affix_segmentor@linnet_pinyin' \
  data/linnet/linnet_zh*.schema.yaml | wc -l | tr -d ' ')" -eq 1 ||
  fail "active-profile pinyin lookup must have one standard affix owner"
rg -Fq 'pinyin_reverse_lookup: "^;[a-z;'"'"']*$"' data/linnet/default.yaml ||
  fail "the bundled reverse-lookup trigger lost its prefix and inner-semicolon states"
rg -Fq 'text_expander: "^x;[-0-9A-Za-z_]*$"' data/linnet/default.yaml ||
  fail "the Settings-owned explicit x; command lost its recognizer"
rg -Fq '__include: default.yaml:/linnet/pinyin_reverse_lookup' \
  data/linnet/linnet_zh.schema.yaml ||
  fail "the Chinese root lost the shared reverse-lookup affix contract"
rg -Fq 'affix_segmentor@linnet_pinyin' data/linnet/linnet_en.schema.yaml ||
  fail "Smart English lost the standard explicit pinyin segmentor"
test "$(rg -F -c '__include: default.yaml:/linnet/pinyin_reverse_lookup' \
  data/linnet/linnet_en.schema.yaml)" -eq 1 ||
  fail "Smart English must reuse exactly one shared pinyin namespace"
for decoder_contract in 'dictionary: linnet_zh' 'prism: linnet_zh' 'delimiter: " '\''"'; do
  rg -Fq "  ${decoder_contract}" data/linnet/linnet_en.schema.yaml ||
    fail "Smart English lost its bundled natural-code decoder: ${decoder_contract}"
done
if rg -Fq "front() == ';'" plugins/smart_english/smart_english.cc; then
  fail "the native translator regained a private semicolon parser"
fi
for schema_id in linnet_zh_flypy linnet_zh_mspy linnet_zh_sogou \
  linnet_zh_abc linnet_zh_ziguang linnet_zh_jiajia; do
  if rg -Fq "${schema_id}" plugins/smart_english/smart_english.cc; then
    fail "the native translator hard-coded a profile algebra: ${schema_id}"
  fi
done
smart_english_main=plugins/smart_english/smart_english.cc
smart_english_domain=plugins/smart_english/smart_english_domain.h
smart_english_filter_header=plugins/smart_english/smart_english_filter.h
smart_english_filter=plugins/smart_english/smart_english_filter.cc
smart_english_mixed_header=plugins/smart_english/smart_english_mixed_decoder.h
smart_english_mixed_decoder=plugins/smart_english/smart_english_mixed_decoder.cc
test "$(wc -l < "${smart_english_main}" | tr -d ' ')" -lt 1500 ||
  fail "the Smart English module owner again exceeds 1500 lines"
for extracted_owner in \
  "${smart_english_domain}" \
  "${smart_english_filter_header}" \
  "${smart_english_filter}" \
  "${smart_english_mixed_header}" \
  "${smart_english_mixed_decoder}"; do
  test -f "${extracted_owner}" ||
    fail "the Smart English candidate owner extraction is missing ${extracted_owner}"
  test "$(wc -l < "${extracted_owner}" | tr -d ' ')" -lt 500 ||
    fail "the extracted Smart English owner exceeds 500 lines: ${extracted_owner}"
done
rg -Fq 'plugins/smart_english/smart_english_filter.cc' Makefile ||
  fail "the extracted Smart English filter is absent from the plugin build"
rg -Fq 'plugins/smart_english/smart_english_mixed_decoder.cc' Makefile ||
  fail "the modeless mixed decoder is absent from the plugin build"
for extracted_header in smart_english_domain.h smart_english_filter.h \
  smart_english_mixed_decoder.h; do
  rg -Fq "plugins/smart_english/${extracted_header}" Makefile ||
    fail "the extracted Smart English contract is absent from build dependencies: ${extracted_header}"
done
test "$(rg -l '^class ModelessMixedDecoder' plugins/smart_english | wc -l | tr -d ' ')" -eq 1 ||
  fail "modeless mixed generation no longer has one typed owner"
test "$(rg -F --no-filename 'mixed_decoder_.Query(' plugins/smart_english | wc -l | tr -d ' ')" -eq 1 ||
  fail "modeless mixed generation gained a second runtime entrypoint"
for mixed_contract in \
  'entry->IsExactMatch() && entry->text == uppercase' \
  'if (start == 0 && length == input.size()) continue;' \
  'for (const auto& range : ChineseRanges(entities, input.size()))' \
  'target_ends.count(end.first)' \
  'user_dictionary->Lookup(syllable_graph, range.first,' \
  'dictionary->Lookup(syllable_graph, range.first, &blacklist)' \
  'poet_->MakeSentences(' \
  'input.size() > kMaximumInputLength' \
  'result.size() == kMaximumMixedCandidates'; do
  rg -Fq "${mixed_contract}" "${smart_english_mixed_decoder}" ||
    fail "modeless mixed generation lost its bounded canonical contract: ${mixed_contract}"
done
test "$(rg -F -c 'BuildSyllableGraph(' "${smart_english_mixed_decoder}")" -eq 1 ||
  fail "modeless mixed generation no longer builds exactly one Chinese SyllableGraph"
if rg -Fq 'const string suffix = input.substr(start);' \
    "${smart_english_mixed_decoder}"; then
  fail "modeless mixed generation regained per-start suffix graph rebuilding"
fi
if rg -Fq 'for (const auto& vertex : syllable_graph.edges)' \
    "${smart_english_mixed_decoder}"; then
  fail "modeless mixed generation regained duplicate all-vertex dictionary lookup"
fi
rg -Fq 'mixed->model_weight() - best_chinese_sentence_weight' \
  "${smart_english_filter}" ||
  fail "mixed and canonical Chinese sentences no longer share one model comparison owner"
rg -Fq 'return has_exact ? !item.mixed : item.preferred_mixed;' \
  "${smart_english_filter}" ||
  fail "whole exact English no longer closes before contextual mixed ranking"
if rg -n 'process_key|ProcessKey|keycode|XK_[0-9]|SelectionIndex|select_keys' \
    "${smart_english_mixed_header}" "${smart_english_mixed_decoder}"; then
  fail "modeless mixed generation attempted to own digit or key interaction"
fi
for retired_mixed_owner in \
  plugins/smart_english/smart_english_mixed_projection.h \
  plugins/smart_english/smart_english_mixed_projection.cc; do
  [[ ! -e "${retired_mixed_owner}" ]] ||
    fail "the retired lossy mixed projection returned: ${retired_mixed_owner}"
done
if rg -n 'xuexicsjiting|liaojieaijishu|shiyongcpuxingneng|学习CS急停|了解AI技术|使用CPU性能' \
    plugins/smart_english; then
  fail "a mixed-input acceptance fixture leaked into production code"
fi
if rg -n \
  'ProjectSmartEnglishCandidate|class SmartEnglishTailTranslation|class SmartEnglishFilter' \
  "${smart_english_main}"; then
  fail "the retired in-module Smart English candidate owner returned"
fi
for extracted_symbol in \
  'ProjectSmartEnglishCandidate' \
  'class SmartEnglishTailTranslation' \
  'SmartEnglishFilter::Apply'; do
  rg -Fq "${extracted_symbol}" "${smart_english_filter}" ||
    fail "the extracted Smart English candidate owner lost ${extracted_symbol}"
done
test "$(rg -F -c \
  'Register("linnet_english_filter", new rime::Component<linnet::SmartEnglishFilter>)' \
  "${smart_english_main}")" -eq 1 ||
  fail "Smart English filter registration is no longer one direct module boundary"
if rg -n \
  'CreateSmartEnglishFilter|RegisterSmartEnglishFilter|SmartEnglishFilterImpl|SmartEnglishFilter::Impl' \
  plugins/smart_english; then
  fail "the extracted Smart English owner gained a factory, wrapper, or PImpl"
fi
test "$(rg -l '^struct InteractionOptions' plugins/smart_english | wc -l | tr -d ' ')" -eq 1 ||
  fail "Smart English interaction options no longer have one source owner"
test "$(rg -l '^class SessionBigrams' plugins/smart_english | wc -l | tr -d ' ')" -eq 1 ||
  fail "Smart English session bigrams no longer have one source owner"
test "$(rg -l '^struct SpacingState' plugins/smart_english | wc -l | tr -d ' ')" -eq 1 ||
  fail "Smart English spacing state no longer has one source owner"
rg -Fq 'punct: "^V([0-9]|10|[A-Za-z]+)$"' \
  data/linnet/linnet_zh.schema.yaml ||
  fail "the Chinese root lost its explicit Shift+V symbol command"
for command in \
  'radical_lookup: "^uU[a-z]+$"' \
  'unicode: "^U[a-f0-9]+"' \
  'calculator: "^cC.+"'; do
  rg -Fq "    ${command}" data/linnet/linnet_zh.schema.yaml ||
    fail "the Chinese root lost explicit command ${command}"
done
rg -Fq '__include: symbols_caps_v:/symbols' \
  data/linnet/linnet_zh.schema.yaml ||
  fail "the Chinese root no longer consumes the standard Shift+V symbol table"
test "$(rg -F --no-filename '    - echo_translator' \
  data/linnet/linnet_zh.schema.yaml data/linnet/linnet_en.schema.yaml | wc -l | tr -d ' ')" -eq 2 ||
  fail "the two product roots lost the standard fallback-only echo translator"
rg -Fq 'inline constexpr char kForcedRawCandidateType[] = "linnet_forced_raw";' \
  "${smart_english_domain}" ||
  fail "the Smart English forced-raw origin lost its typed marker"
test "$(rg -F --no-filename 'ShouldDropRawCandidate(' \
  "${smart_english_domain}" "${smart_english_filter}" | wc -l | tr -d ' ')" -eq 3 ||
  fail "the Smart English prefix and tail no longer share one raw-fallback rule"
if rg -n 'kForcedRawQuality|forced_raw\s*=|quality\(\)\s*==|==\s*.*quality\(\)' \
    plugins/smart_english; then
  fail "Smart English regained numeric inference for forced-raw identity"
fi
if rg -n \
    'InspectChineseSpelling|InitializeChineseSpellingDecoder|chinese_dictionary_|Dictionary::Require|Syllabifier' \
    "${smart_english_filter_header}" "${smart_english_filter}"; then
  fail "Smart English regained a second Chinese dictionary or spelling owner"
fi
if ! ruby -e '
  owner = File.read(ARGV.fetch(0))
  %w[
    phrase->is_exact_match()
    phrase->spelling_type()<kAbbreviation
    phrase->system_lexical_weight()
    *system_weight>=kEstablishedChinesePhraseMinimumLexicalWeight
    strong_chinese_collision
    has_same_span_chinese
    input_word.size()==1
    single_letter_chinese_input
    std::exchange(pending_segment_input_,std::nullopt)
    composition().input()
    pending_segment_input_=composition_input.substr(segment->start,segment->end-segment->start)
  ].each do |contract|
    compact = owner.gsub(/\s+/, "")
    abort "exact-English collision contract is missing #{contract}" unless
      compact.include?(contract)
  end
  abort "the retired spelling-only demotion returned" if
    owner.include?("direct_chinese_spelling") ||
      owner.include?("HasUnabbreviatedChineseSpelling")
  abort "the retired syllable-count collision heuristic returned" if
    owner.include?("phrase->code().size()")
  abort "learned Chinese candidates are still rejected by runtime type" if
    owner.include?(%q["user_phrase"])
  abort "cross-language numeric ranking returned" if
    owner.match?(/quality\(\)/) || owner.include?("phrase->weight()")
  abort "whole-composition bilingual ranking returned" if
    owner.gsub(/\s+/, "").include?("ranking_input=context->input()") ||
      owner.include?("composition().back()")
  abort "a partial-selection fixture leaked into the production ranker" if
    %w[xwvb 下周].any? { |literal| owner.include?(literal) }
' "${smart_english_filter}"; then
  fail "exact-English ranking lost its single typed collision owner"
fi
rg -Fq '  contextual_suggestions: false' data/linnet/linnet_zh.schema.yaml ||
  fail "Chinese lexical collision weight is no longer isolated from contextual grammar"
if rg -Fq 'IsLinnetChinesePhrase' plugins/smart_english; then
  fail "Smart English regained its retired unconditional Chinese demotion helper"
fi
test "$(rg -F --no-filename 'const auto bigrams = options_.learning_enabled' \
  "${smart_english_main}" "${smart_english_filter}" | wc -l | tr -d ' ')" -eq 2 ||
  fail "English learning no longer gates both native bigram readers"
rg -Fq 'if (options_.learning_enabled && !previous.empty())' \
  "${smart_english_main}" ||
  fail "English learning no longer gates the native bigram writer"
rg -Fq 'kPinyinTraversalLimit = 4096' \
  plugins/smart_english/smart_english.cc ||
  fail "active-profile pinyin decoding lost its total traversal budget"
rg -Fq 'kPinyinInputByteLimit = 96' \
  plugins/smart_english/smart_english.cc ||
  fail "active-profile pinyin decoding lost its pre-graph input budget"
rg -Fq 'TranslatorOptions(translator_ticket).delimiters();' \
  plugins/smart_english/smart_english.cc ||
  fail "active-profile pinyin decoding stopped using the standard delimiter owner"
rg -Fq 'Syllabifier syllabifier(pinyin_delimiters_, false, false);' \
  plugins/smart_english/smart_english.cc ||
  fail "active-profile pinyin decoding lost the standard profile delimiter"
if rg -Fq 'Syllabifier(""' plugins/smart_english; then
  fail "active-profile pinyin decoding regained a private empty delimiter"
fi
rg -Fq -- '- xform/m̀/m/' data/linnet/default.yaml ||
  fail "the pinyin key projection lost its decomposed m-grave normalization"
rg -Fq -- '- xlit/āáǎàōóǒòēéěèīíǐìūúǔùǖǘǚǜüńňǹḿ/aaaaooooeeeeiiiiuuuuvvvvvnnnm/' \
  data/linnet/default.yaml ||
  fail "the pinyin key projection lost its one-codepoint tone mapping"
if rg -n 'xlit/.*m̀' data/linnet/default.yaml; then
  fail "the pinyin xlit regained the two-codepoint m-grave duplication"
fi
if rg -n 'kPinyinSyllableLimit' plugins/smart_english/smart_english.cc; then
  fail "active-profile pinyin decoding regained a private syllable cutoff"
fi
rg -Fq 'std::vector<bool> normal_reachable(input.size() + 1, false);' \
  plugins/smart_english/smart_english.cc ||
  fail "active-profile pinyin decoding lost its exact canonical Prism proof"
test "$(rg -F -l 'seg:has_tag("linnet_pinyin")' \
  patches/rime-ice-linnet-pinyin-tag-boundary.patch | wc -l | tr -d ' ')" -eq 1 ||
  fail "the embedded Lua command owners lost their pinyin tag boundary patch"
test "$(rg -F -c 'seg:has_tag("linnet_pinyin")' \
  patches/rime-ice-linnet-pinyin-tag-boundary.patch)" -eq 2 ||
  fail "date and UUID no longer share the exact pinyin tag boundary"
rg -Fq 'class SmartEnglishTailTranslation : public Translation' \
  "${smart_english_filter}" ||
  fail "Smart English lost lazy projection for candidate 65 and beyond"
if rg -Fq 'RawFallbackTailTranslation' plugins/smart_english; then
  fail "Smart English regained an unprojected candidate tail"
fi

test "$(rg -F -c 'NSVisualEffectView()' sources/SquirrelPanel.swift)" -eq 1 ||
  fail "candidate-window material must reuse one native visual-effect surface"
rg -Fq 'back.material = LinnetCandidatePresentation.candidateMaterial' \
  sources/SquirrelPanel.swift ||
  fail "the live panel stopped consuming the shared native material owner"
test "$(rg -F -c 'view.material = LinnetCandidatePresentation.candidateMaterial' \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift)" -eq 2 ||
  fail "the Settings preview stopped consuming the shared native material owner"
rg -Fq 'static let candidateMaterial = NSVisualEffectView.Material.popover' \
  sources/LinnetCandidatePresentation.swift ||
  fail "candidate-window material is not the shared native popover material"
if rg -n '\.thinMaterial' \
    sources/LinnetSettings/LinnetSettingsAppearancePreview.swift \
    sources/LinnetSettings/LinnetSettingsThemeFamilyPicker.swift; then
  fail "the candidate preview regained a competing SwiftUI material owner"
fi
test "$(rg -F -c 'static func platformFont(' \
  sources/LinnetCandidatePresentation.swift)" -eq 1 ||
  fail "candidate typography lost its single platform-font owner"
rg -Fq 'LinnetCandidatePresentation.platformFont(' sources/SquirrelTheme.swift ||
  fail "the live candidate theme stopped consuming the platform-font owner"
rg -Fq 'LinnetCandidatePresentation.platformFont(' \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift ||
  fail "the Settings preview stopped consuming the platform-font owner"
if rg -n 'NSFont\.userFont|LinnetSettingsFontProjection' \
    sources/SquirrelTheme.swift \
    sources/LinnetSettings/LinnetSettingsAppearancePreview.swift \
    sources/LinnetSettings/LinnetSettingsThemeFamilyPicker.swift \
    sources/LinnetSettings/SettingsViews.swift; then
  fail "candidate typography regained a competing live or preview owner"
fi
test "$(rg -F -c 'candidateFormat: "[comment]"' \
  sources/SquirrelPanel+CandidatePresentation.swift)" -eq 1 &&
  test "$(rg -F -c 'candidateFormat: "[comment]"' \
    sources/LinnetSettings/LinnetSettingsAppearancePreview.swift)" -eq 1 ||
  fail "live and preview detail stopped sharing the candidate-line compositor"
rg -Fq 'placement: .standaloneDetail' sources/SquirrelTheme.swift &&
  rg -Fq 'placement: .standaloneDetail' \
    sources/LinnetSettings/LinnetSettingsAppearancePreview.swift ||
  fail "standalone candidate detail regained the inline optical baseline"
if rg -n 'NSAttributedString\(string: comment, attributes: theme\.commentAttrs\)|\.italic\(\)' \
    sources/SquirrelPanel.swift sources/SquirrelPanel+CandidatePresentation.swift \
    sources/LinnetSettings/LinnetSettingsAppearancePreview.swift; then
  fail "candidate detail regained a live or preview-only text owner"
fi
rg -Fq 'string: LinnetCandidatePresentation.inlineCandidateSeparator' \
  sources/SquirrelPanel.swift ||
  fail "the live candidate row stopped consuming the shared separator owner"
rg -Uq 'LinnetCandidatePresentation\.inlineCandidateSeparatorWidth\(\s*font: candidateFont\s*\)' \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift ||
  fail "the Settings preview stopped consuming the shared separator metric"
test "$(rg -F -c 'NSTrackingArea(' sources/SquirrelView.swift)" -eq 1 ||
  fail "candidate press tracking no longer has exactly one AppKit owner"
for option in '.inVisibleRect' '.mouseEnteredAndExited' '.mouseMoved' '.activeAlways'; do
  rg -Fq "${option}" sources/SquirrelView.swift ||
    fail "candidate press tracking lost ${option}"
done
rg -Fq 'self.acceptsMouseMovedEvents = true' sources/SquirrelPanel.swift ||
  fail "candidate hover stopped requesting event-local mouse movement"
if rg -n 'acceptsMouseMovedEvents = false|NSEvent\.mouseLocation' \
    sources/SquirrelPanel.swift sources/SquirrelPanel+CandidatePresentation.swift \
    sources/SquirrelView.swift sources/SquirrelView+CandidateDrawing.swift; then
  fail "candidate press regained a disabled or global-pointer inference path"
fi
ruby -e '
  panel = File.read(ARGV.fetch(0))
  hover = panel[/func moveCandidatePointer\(.*?\n  \}/m]
  abort "candidate hover presentation owner is missing" unless hover
  abort "candidate hover can mutate Rime selection" if
    hover.include?("inputController") || hover.include?("selectCandidate") ||
      hover.include?("page(")
' sources/SquirrelPanel+CandidatePresentation.swift ||
  fail "candidate hover regained an engine mutation path"
rg -Fq 'view.convert(event.locationInWindow, from: nil)' \
  sources/SquirrelPanel+CandidatePresentation.swift ||
  fail "candidate press stopped consuming the event-local pointer position"
ruby -e '
  view = File.read("sources/SquirrelView.swift")
  panel = File.read("sources/SquirrelPanel.swift") +
    File.read("sources/SquirrelPanel+CandidatePresentation.swift")
  hit = view[/enum CandidateHit: Equatable \{.*?\n  \}/m]
  click = view[/func click\(at clickPoint: NSPoint\).*?\n  \}/m]
  path_owner = view[/static func candidateIndex\(.*?\n  \}/m]
  press = panel[/func finishCandidatePress\(.*?\n  \}/m]
  abort "candidate pointer owners are missing" unless hit && click && path_owner && press
  abort "preedit regained a candidate-window mouse action" if
    hit.include?("case preedit") || press.include?(".preedit") ||
      panel.include?("moveCaret(") || view.include?("moveCaret(")
  abort "candidate hit-testing no longer uses the exact path drawn for the cell" unless
    click.include?("paths: candidateInteractionPaths") &&
      path_owner.include?("paths.firstIndex { $0?.contains(point) == true }")
  abort "candidate hit-testing regained a rectangular or text-position fallback" if
    click.include?("candidateInteractionFrames") ||
      click.include?("characterIndex") || path_owner.include?("boundingBox")
' || fail "candidate hit-testing regained a preedit/caret or inexact fallback path"
rg -Fq 'candidateFrames: candidateInteractionFrames' \
  sources/LinnetCandidateAccessibility.swift ||
  fail "candidate accessibility stopped consuming the canonical drawn cell frames"
if rg -n 'contentRect\(' sources/LinnetCandidateAccessibility.swift; then
  fail "candidate accessibility regained an independent text-geometry owner"
fi
ruby -e '
  panel = File.read("sources/SquirrelPanel.swift") +
    File.read("sources/SquirrelPanel+CandidatePresentation.swift")
  accessibility = File.read("sources/LinnetCandidateAccessibility.swift")
  update = panel[/func update\(.*?\n  \}\n\n  func updateStatus/m]
  show = panel[/func show\(publication: Publication\).*?\n  \}/m]
  status = panel[/func show\(status message: String, publication: Publication\).*?\n  \}/m]
  abort "candidate publication owners are missing" unless update && show && status
  shown = update.index("guard show(publication: currentPublication)")
  published = update.index("candidateAccessibility.publish(")
  frame = show.index("self.setFrame(panelRect, display: false)")
  front = show.index("orderFrontRegardless()")
  abort "candidate accessibility can publish before final window geometry" unless
    shown && published && shown < published && frame && front && frame < front
  abort "status accessibility can publish before final window geometry" unless
    status.index("guard show(publication: publication)") <
      status.index("candidateAccessibility.publishStatus(")
  abort "candidate AX actions strongly retain the controller" unless
    update.include?("[weak self, weak publishedController]")
  abort "AX element actions lost their weak publication owner" unless
    accessibility.scan("element.performPress = { [weak self]").length == 2
  abort "AX layout changes stopped identifying the replaced elements" unless
    accessibility.include?("elements: newElements,") &&
      accessibility.include?("userInfo: [.uiElements: elements]")
  abort "AX selection changes stopped notifying assistive clients" unless
    accessibility.include?("notification: .selectedChildrenChanged") &&
      accessibility.include?("selectedAbsoluteIndex != nextSelectedAbsoluteIndex")
' || fail "candidate geometry or accessibility publication ownership regressed"
rg -Fq '"style/linnet_material_appearance"' \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift ||
  fail "fixed candidate appearance no longer projects its native material mode"
rg -Fq 'style/linnet_material_appearance' sources/SquirrelTheme.swift ||
  fail "the Host theme no longer consumes the fixed native material mode"
rg -Fq 'resolveMaterial(' sources/SquirrelPanel+CandidatePresentation.swift ||
  fail "the live panel material stopped consuming the resolved appearance mode"
rg -Fq 'LinnetCandidatePresentation.windowInset(verticalText: vertical)' \
  sources/SquirrelTheme.swift ||
  fail "candidate-window padding regained a theme-derived owner"
test "$(rg -F -c 'LinnetCandidatePresentation.candidateWindowInset.' \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift)" -eq 2 ||
  fail "the candidate preview stopped consuming both axes of the live compact inset owner"
if rg -n 'border(Height|Width) \+ cornerRadius' sources/SquirrelTheme.swift; then
  fail "theme corner radius regained authority over candidate-window padding"
fi
if rg -n 'preeditLinespace / 2 [+-] .*hilitedCornerRadius / 2' \
  sources/SquirrelTheme.swift sources/SquirrelView.swift; then
  fail "theme highlight radius regained authority over candidate text spacing"
fi
ruby -ryaml -e '
  source = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
  style = source.fetch("style")
  expected = {
    "candidate_format" => "[label] [candidate]",
    "border_width" => 1,
    "border_height" => 1,
    "shadow_size" => 0,
  }
  expected.each do |key, value|
    abort "global candidate metric #{key} drifted" unless style[key] == value
  end
  ids = source.fetch("preset_color_schemes").keys.grep(
    /\Alinnet_(paper|moon_jade|sidecar|clay|mist_jade|glass|ink_cinnabar)_(light|dark)\z/
  )
  abort "expected exactly fourteen paired Linnet schemes" unless ids.length == 14
  forbidden = %w[
    candidate_format border_width border_height line_spacing spacing shadow_size
    font_face font_point label_font_face label_font_point
    comment_font_face comment_font_point base_offset
    candidate_list_layout text_orientation inline_preedit inline_candidate
    show_paging memorize_size surrounding_extra_expansion
  ]
  ids.each do |identifier|
    duplicates = source.fetch("preset_color_schemes").fetch(identifier).keys & forbidden
    abort "#{identifier} regained theme-owned metrics: #{duplicates.join(", ")}" unless duplicates.empty?
  end

  def rime_rgb(value)
    integer = Integer(value)
    alpha = (integer >> 24) & 0xff
    blue = (integer >> 16) & 0xff
    green = (integer >> 8) & 0xff
    red = integer & 0xff
    [red, green, blue, alpha]
  end

  def luminance(channel)
    value = channel / 255.0
    value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055)**2.4
  end

  def relative_luminance(rgb)
    0.2126 * luminance(rgb[0]) +
      0.7152 * luminance(rgb[1]) +
      0.0722 * luminance(rgb[2])
  end

  %w[linnet_glass_light linnet_glass_dark].each do |identifier|
    scheme = source.fetch("preset_color_schemes").fetch(identifier)
    background = rime_rgb(scheme.fetch("hilited_candidate_back_color"))
    foreground = rime_rgb(scheme.fetch("hilited_candidate_text_color"))
    abort "#{identifier} selected tile must be opaque over native material" unless background[3] == 0xff
    lighter, darker = [relative_luminance(background), relative_luminance(foreground)].minmax.reverse
    contrast = (lighter + 0.05) / (darker + 0.05)
    abort "#{identifier} selected text contrast #{contrast.round(2)} is below 4.5" unless contrast >= 4.5
  end
' data/squirrel.yaml || fail "bundled themes do not share one candidate metric owner"
test "$(rg -F -c '.environment(\.colorScheme, isDark ? .dark : .light)' \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift)" -eq 1 ||
  fail "the shared material surface stopped owning fixed Light/Dark mode"
rg -Fq 'role: presentationRole' sources/SquirrelPanel+CandidatePresentation.swift ||
  fail "candidate and status geometry lost their shared typed presentation owner"
rg -Fq 'view.applyPresentationMetrics(metrics)' \
  sources/SquirrelPanel+CandidatePresentation.swift ||
  fail "the drawing surface stopped consuming the panel presentation metrics"
rg -Fq 'guard let presentationMetrics else { return }' sources/SquirrelView.swift ||
  fail "the drawing surface regained an implicit candidate-geometry fallback"
rg -Fq 'presentationMetrics.role == .candidate' sources/SquirrelView.swift ||
  fail "the status notice regained candidate highlight drawing"
rg -Fq 'presentationMetrics.cornerRadius' sources/SquirrelView.swift ||
  fail "the status notice regained candidate corner geometry"
if rg -n '(theme|currentTheme)\.pagingOffset' \
    sources/SquirrelView.swift sources/SquirrelView+CandidateDrawing.swift; then
  fail "the drawing surface bypassed the shared presentation paging offset"
fi
rg -Fq 'attributes: theme.statusAttrs' \
  sources/SquirrelPanel+CandidatePresentation.swift ||
  fail "the status notice regained candidate typography"
rg -Fq 'value: theme.statusParagraphStyle' \
  sources/SquirrelPanel+CandidatePresentation.swift ||
  fail "the status notice regained candidate paragraph spacing"
rg -Fq 'view.textView.setLayoutOrientation(.horizontal)' \
  sources/SquirrelPanel+CandidatePresentation.swift ||
  fail "the status notice regained candidate text orientation"
test "$(rg -F -c 'NSPanel' sources/SquirrelPanel.swift)" -eq 1 ||
  fail "the status notice added a second panel"
if rg -n 'SettingsThemeModifier|themePresentation|preferredColorScheme|palette\.controlTint|LinnetSettingsThemeSurface' \
    sources/LinnetSettings/SettingsMain.swift; then
  fail "candidate-window themes regained authority over the native Settings window"
fi
if rg -n 'Product appearance|appearance preview|Appearance preview' \
    sources/LinnetSettings/SettingsViews.swift \
    sources/LinnetSettings/SettingsPresentationStatus.swift \
    sources/LinnetSettings/SettingsMain.swift; then
  fail "candidate-window publishing regained ambiguous product or preview wording"
fi
rg -Fq 'GroupBox("Candidate window")' sources/LinnetSettings/SettingsViews.swift ||
  fail "the appearance controls lost their candidate-window scope"
if rg -Fq '$(LINNET_PRODUCT_NAME) Settings' Linnet.xcodeproj/project.pbxproj; then
  fail "the Settings bundle regained a non-localized English display-name suffix"
fi
test "$(rg -F -c 'INFOPLIST_KEY_CFBundleDisplayName = "$(LINNET_PRODUCT_NAME)";' \
  Linnet.xcodeproj/project.pbxproj)" -eq 2 ||
  fail "the Settings bundle display name must use the single language-neutral product identity"
if rg -n 'linnet_settings_tint_color' data/squirrel.yaml \
    sources/LinnetSettings/LinnetSettingsAppearancePreview.swift \
    sources/LinnetSettings/LinnetSettingsThemeFamilyPicker.swift; then
  fail "a retired Settings-only tint remained in the candidate theme owner"
fi
rg -Fq 'LinnetSettingsAppearancePreviewView(appearance:' \
  sources/LinnetSettings/SettingsViews.swift ||
  fail "the Settings appearance page lost its candidate-window preview"
test "$(rg -F -c 'if isTranslucent' \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift)" -eq 1 ||
  fail "the candidate preview regained a second material projection owner"
test "$(rg -F -o 'LinnetSettingsThemeSurface(' \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift \
  sources/LinnetSettings/LinnetSettingsThemeFamilyPicker.swift | wc -l | tr -d ' ')" -eq 2 ||
  fail "the theme cards and candidate preview stopped sharing one material surface"
if rg -n 'textformat\.abc' sources/LinnetSettings/SettingsMain.swift \
    sources/LinnetSettings/SettingsRootView.swift \
    sources/LinnetSettings/SettingsViews.swift; then
  fail "the English Settings mark regained a locale-dependent SF Symbol"
fi
test "$(rg -F -c 'Text(verbatim: "ABC")' sources/LinnetSettings/LinnetSettingsPage.swift)" -eq 1 ||
  fail "the Settings ABC mark regained a second glyph owner"
test "$(rg -F -o 'mark: .latinABC' sources/LinnetSettings/SettingsMain.swift \
  sources/LinnetSettings/SettingsRootView.swift \
  sources/LinnetSettings/SettingsViews.swift | wc -l | tr -d ' ')" -eq 2 ||
  fail "the Settings tab and English page must share the fixed ABC mark"
test "$(rg -F -c 'NSSelectorFromString("windowEffectiveAppearance")' \
  sources/LinnetClientAppearance.swift)" -eq 1 ||
  fail "the optional InputMethodKit client-appearance capability lost its single owner"
test "$((
  $(rg -F -c 'panel.updateAppearance(client: activatingClient as? NSObjectProtocol)' \
    sources/SquirrelInputController.swift) +
  $(rg -F -c 'panel.updateAppearance(client: expectedClient as? NSObjectProtocol)' \
    sources/SquirrelInputController.swift)
))" -eq 2 ||
  fail "the candidate panel stopped resolving appearance from the active text client"
test "$(rg -F -c 'updateAppearance(client: nil)' \
  sources/SquirrelPanel.swift)" -eq 1 ||
  fail "the candidate panel stopped clearing a deactivated client's appearance"
test "$(rg -F -c 'updateAppearance(client: inputController?.activeClient as? NSObjectProtocol)' \
  sources/SquirrelPanel.swift)" -eq 1 ||
  fail "a live Settings theme refresh stopped re-resolving the active client's appearance"
if rg -F 'inputController?.client()' sources/SquirrelPanel.swift; then
  fail "the candidate panel regained InputMethodKit's stored client as a second appearance owner"
fi
rg -Fq 'view.applyClientAppearance(isDark: resolution.isDark)' sources/SquirrelPanel.swift ||
  fail "the candidate theme stopped consuming the resolved client appearance"
if rg -n 'NSApp\.effectiveAppearance' sources/SquirrelView.swift; then
  fail "the candidate view regained a competing Host-process appearance owner"
fi
if rg -n 'AppleInterfaceStyle|CFPreferences|clientBundleIdentifier.*[Dd]ark' \
  sources/LinnetClientAppearance.swift sources/SquirrelPanel.swift \
  sources/SquirrelInputController.swift; then
  fail "client appearance regained preference or application-list inference"
fi

production=(sources plugins resources data/squirrel.yaml Linnet.xcodeproj/project.pbxproj)

if rg -n 'LINNET_PRIVATE_BUILD_OUTPUT|ruby|scripts/upstream-sync verify' action-install.sh; then
  fail "ordinary builds still recurse or run the release-only Ruby upstream audit"
fi

test "$(rg -c 'for: \.applicationSupportDirectory' sources/LinnetDataRegistry.swift)" -eq 1 ||
  fail "the Linnet Application Support root owner count changed"
rg -Fq 'struct LinnetDataRegistry' sources/LinnetDataRegistry.swift ||
  fail "the language-data registry owner is missing"
for root in UserData Build Downloads Transactions Backups Runtime/Active State/active.json; do
  rg -Fq "${root}" sources/LinnetDataRegistry.swift ||
    fail "the registry no longer owns ${root}"
done
test "$(rg -c 'return try LinnetDataRegistry' sources/Main.swift)" -eq 1 ||
  fail "the host must consume one canonical registry"
test "$(rg -c 'runtimeSnapshot\(\)' sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "the runtime data snapshot owner count changed"
test "$(rg -c 'runtimeSnapshot\(\)' sources/LinnetSettings/SettingsDataCoordinator.swift)" -eq 1 ||
  fail "the Settings data snapshot owner count changed"
test "$(rg -c 'dataRegistry\.activeRevision\(\)' sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "the Host language-activation CAS owner count changed"
cas_line="$(rg -n -m1 'dataRegistry\.activeRevision\(\)' \
  sources/SquirrelApplicationDelegate.swift | cut -d: -f1)"
swap_line="$(rg -n -m1 'guard swapDirectories\(live, candidate\)' \
  sources/SquirrelApplicationDelegate.swift | cut -d: -f1)"
[[ -n "${cas_line}" && -n "${swap_line}" && "${cas_line}" -lt "${swap_line}" ]] ||
  fail "the Host CAS no longer occurs immediately before its first language-data swap"
for field in 'let expectedActiveGeneration: Int?' 'let expectedActiveStateSHA256: String?'; do
  test "$(rg -F -c "${field}" sources/LinnetSettings/SettingsContract.swift)" -eq 1 ||
    fail "the typed language-activation CAS field ${field} changed"
done
if rg -n 'expected_active_generation|expected_active_state_sha256' sources --glob '*.swift'; then
  fail "the retired distributed-notification CAS wire shape returned"
fi
test "$(rg -c 'dataRegistry\.commitDataChannelUpdate\(' \
  sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "post-health language publication is not owned exactly once by Host"
if rg -q 'commitDataChannelUpdate\(' sources/LinnetSettings/SettingsDataCoordinator.swift; then
  fail "Settings regained language-publication ownership"
fi
test "$(rg -c 'let downloadDirectory = update\.downloadDirectory' \
  sources/LinnetSettings/SettingsModelLanguageData.swift)" -eq 1 ||
  fail "Settings no longer consumes the Registry-owned update download directory"
if rg -q 'downloadsDirectory\.appending\([^)]*UUID\(\)' \
  sources/LinnetSettings/SettingsMain.swift \
  sources/LinnetSettings/SettingsModelLanguageData.swift; then
  fail "Settings regained an unowned random download directory"
fi
rg -Fq 'let createdAt: TimeInterval' sources/LinnetDataRegistry.swift ||
  fail "the durable language transaction lost its crash-expiry timestamp"
rg -Fq 'try removeOwnedDownloadDirectory(transactionID: cleanup.transactionID)' \
  sources/LinnetDataRegistry.swift ||
  fail "expired language transactions no longer retire their owned download directory"
if rg -n 'completeActivation\(' sources tests --glob '*.swift'; then
  fail "the retired pre-transaction publication API returned"
fi
test "$(rg -c 'tentativeRuntimeSnapshot\(' sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "tentative language health no longer has one non-reconciling snapshot owner"
test "$(rg -c 'recoverPreparedLanguageActivation\(' \
  sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "prepared crash recovery no longer has one Host startup caller"
if rg -n 'rimeSetupDone' sources/SquirrelApplicationDelegate.swift; then
  fail "manual restart can bypass authoritative setup and prepared recovery"
fi
if rg -n 'restartRuntime|运行时不可用|重新启动运行时' \
    sources/SquirrelApplicationDelegate.swift resources/Localizable.xcstrings; then
  fail "a manual runtime-restart owner can bypass the active Settings transaction"
fi
if rg -n 'abortDataChannelUpdate\(|discardActivation\(' sources --glob '*.swift'; then
  fail "a retired language cleanup owner returned"
fi
test "$(rg -c 'registry\.cancelDataChannelUpdate\(transactionID: update\.transactionID\)' \
  sources/LinnetSettings/SettingsModelLanguageData.swift)" -eq 1 ||
  fail "SettingsMain must cancel its one Registry transaction from one defer"
if rg -n 'cancelDataChannelUpdate\(' sources/LinnetSettings/SettingsDataCoordinator.swift; then
  fail "the transport coordinator regained language cleanup ownership"
fi
if rg -n 'PendingDataChannel|pendingDataChannel|Profiles|ProfileMarker|profilesDirectory|profileDirectory|data-channel\.json|rollback\.json' \
    sources/LinnetDataRegistry.swift; then
  fail "a retired second language state file or profile lifecycle returned"
fi
for field in 'var publication: Publication' 'let acceptedCatalog: DataChannelReceipt?' \
  'let rollbackPacks: [ActivePack]'; do
  rg -Fq "${field}" sources/LinnetDataRegistry.swift ||
    fail "Active lost its publication/catalog/rollback ownership field: ${field}"
done
rg -Fq 'https://raw.githubusercontent.com/Ares-X/Linnet/data-channel/Linnet-Data-Channel.json' \
  sources/LinnetSettings/LinnetSettingsDownloadSource.swift ||
  fail "the Settings network boundary lost its stable data-channel endpoint"
if rg -Fq 'https://raw.githubusercontent.com/Ares-X/Linnet/data-channel/Linnet-Data-Channel.json' \
    sources/LinnetSettings/SettingsMain.swift \
    sources/LinnetSettings/SettingsModelLanguageData.swift; then
  fail "SettingsMain regained catalog-endpoint ownership"
fi
if rg -n 'https?://' sources/LinnetDataChannel.swift; then
  fail "the shared catalog verifier regained a remote endpoint"
fi
rg -Fq 'static let service: Service = .published' sources/LinnetDataChannel.swift ||
  fail "the published update channel became unavailable"
rg -Fq 'dataChannelService == .published' \
  sources/LinnetSettings/SettingsModelLanguageData.swift ||
  fail "Settings stopped consuming the typed data-channel service state"
test "$(rg -c 'func check\(\)' sources/LinnetSettings/LinnetSettingsUpdateChecker.swift)" -eq 1 ||
  fail "Settings lost its single bounded update-check entrypoint"
rg -Fq 'LinnetDataChannel.verifyPublished(data)' \
  sources/LinnetSettings/LinnetSettingsUpdateChecker.swift ||
  fail "Settings stopped verifying the shared Core/data Catalog"
ruby -e '
  model = File.read("sources/LinnetSettings/SettingsMain.swift")
  updater = File.read("sources/LinnetSettings/LinnetSettingsUpdateChecker.swift")
  initializer = model[/  init\(bundle: Bundle = \.main\) \{.*?\n  \}\n\}/m]
  preparation = model[/  func prepareInitialState\(\) async \{.*?\n  \}\n\n  private func/m]
  update_initializer = updater[/  init\(\n.*?\n  \}\n\n  func check/m]
  abort "Settings startup owners are missing" unless
    initializer && preparation && update_initializer
  abort "Settings init can again hash the full data installation on the main actor" if
    initializer.include?("runtimeSnapshot()")
  abort "Settings initial data validation is no longer one deferred owner" unless
    preparation.scan("runtimeSnapshot()").length == 1 &&
      preparation.include?("Task.detached(priority: .userInitiated)")
  abort "UpdateChecker init regained an implicit network or runtime check" if
    update_initializer.match?(/\b(?:check|refreshRuntime|startCheck)\(\)/)
' || fail "Settings first-screen work escaped its deferred owner"
if rg -n 'Timer|LaunchAgent|UNUserNotification|startMonitoring' \
    sources/LinnetSettings/LinnetSettingsUpdateChecker.swift; then
  fail "the quiet Settings update check regained a background notification owner"
fi
ruby -e '
  contract = File.read("sources/LinnetSettings/SettingsContract.swift")
  host = File.read("sources/SquirrelApplicationDelegate.swift")
  lifecycle = File.read("sources/SquirrelApplicationPresentation.swift")
  controller = File.read("sources/SquirrelInputController.swift")
  settings = File.read("sources/LinnetSettings/LinnetSettingsUpdateChecker.swift")
  activation = lifecycle[/func activateInstalledCore\(.*?\n  \}/m]
  abort "the Core activation owner is missing" unless activation
  abort "Core activation can bypass Host readiness" unless
    activation.scan("coreActivationReadiness == .ready").length == 2 &&
      activation.scan("requestCanContinue(request)").length == 2 &&
      activation.scan("NSApp.terminate(nil)").length == 1 &&
      !activation.include?("forceTerminate")
  abort "connected InputMethodKit clients lost their lifecycle owner" unless
    controller.scan("markInputClientConnected()").length == 2 &&
      controller.scan("markInputClientDisconnected()").length == 2 &&
      controller.include?("connectedInputClientCount")
  abort "Settings can activate an unverified or substituted Host" unless
    settings.include?("health.productIdentity == installedIdentity") &&
      settings.include?("allowsRunningApplicationSubstitution = false") &&
      settings.include?("reply.code == .coreActivationAccepted")
  combined = contract + host + lifecycle + controller + settings
  abort "Core activation gained a second input-source mutation path" if
    combined.match?(/TIS(Register|Enable|Select|Disable)InputSource/)
' || fail "safe installed-Core activation ownership regressed"
retired_catalog_url='https://github.com/Ares-X/Linnet/releases/download/'\
'data-channel/Linnet-Data-Channel.json'
if rg -nF "${retired_catalog_url}" \
    sources tests --glob '*.swift' --glob '*.sh'; then
  fail "the retired mutable GitHub Release catalog endpoint returned"
fi
rg -Fq 'FileManager.default.temporaryDirectory' sources/Main.swift ||
  fail "the disposable log/launch-marker boundary moved"
test "$(rg -c 'reconcileLanguageStorage\(' sources/LinnetDataRegistry.swift)" -eq 4 ||
  fail "language storage reconciliation must have one owner and three lifecycle callers"
rg -Fq 'static let languageTransactionMarkerName = ".linnet-language-transaction.json"' \
  sources/LinnetDataRegistry.swift ||
  fail "the canonical language transaction marker changed"
rg -Fq 'private static let orphanSafetyAge: TimeInterval = 24 * 60 * 60' \
  sources/LinnetDataRegistry.swift ||
  fail "orphan reconciliation lost its explicit safety horizon"
rg -Fq 'static let personalScratchMarkerName = ".linnet-personal-scratch.json"' \
  sources/LinnetDataRegistry.swift ||
  fail "personal mutation scratch lost its typed Registry marker"
test "$(rg -c 'environment\.registry\.beginPersonalScratch' \
  sources/LinnetSettings/SettingsDataCoordinator.swift)" -eq 2 ||
  fail "full and quick Settings scratch must each be marked once by Registry"
test "$(rg -c 'validatedPersonalScratch\(' sources/LinnetDataRegistry.swift)" -eq 2 ||
  fail "personal scratch GC must have one Registry validator and one caller"
rg -Fq 'try? reconcileLanguageStorage(activeState: state)' sources/LinnetDataRegistry.swift ||
  fail "retryable reconciliation can block the validated runtime snapshot"
test "$(rg -c 'supersededPackCleanups\(' sources/LinnetDataRegistry.swift)" -eq 2 ||
  fail "immutable-pack cleanup owner is missing"
ruby -e '
  source = File.read(ARGV.fetch(0))
  method = source[/  func activateLanguage\(.*?\n  \}\n\}\n/m]
  abort "language activation owner is missing" unless method
  abort "language activation lost its canonical deadline" unless
    method.include?("Self.transactionRequestTimeout")
  abort "language activation reintroduced the generic reply timeout" unless
    method.scan("remainingTransactionTime(until: deadline)").length == 3
' sources/LinnetSettings/SettingsDataCoordinator.swift ||
  fail "language activation no longer uses one absolute 300-second deadline"
rg -Fq 'validatedPackDeletion(at: entry, kind: kind)' sources/LinnetDataRegistry.swift ||
  fail "immutable-pack deletion bypasses manifest identity validation"
if rg -n 'contentsOfDirectory\(.*UserData|contentsOfDirectory\(.*Backups' \
  sources/LinnetDataRegistry.swift; then
  fail "language reconciliation traverses preserved personal-data roots"
fi
rg -Fq 'let scratch = fileManager.temporaryDirectory.appending(' \
  sources/LinnetSettings/SettingsDataCoordinator.swift ||
  fail "the Settings scratch boundary moved"
rg -Fq 'defer { try? fileManager.removeItem(at: scratch) }' \
  sources/LinnetSettings/SettingsDataCoordinator.swift ||
  fail "Settings scratch no longer has scoped cleanup"

test "$(rg -c 'to: \\.shared_data_dir' sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "librime shared-data owner count changed"
test "$(rg -c 'to: \\.user_data_dir' sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "librime user-data owner count changed"
test "$(rg -c 'to: \\.log_dir' sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "librime log owner count changed"

# startRime is the sole runtime-readiness owner. Maintenance makes librime's
# Service unavailable, so Host must join it, deploy the presentation config,
# and prepare the one retained resource session before publishing running.
test -f sources/LinnetRimeWarmSession.swift ||
  fail "the retained Rime resource-session owner is missing"
ruby -e '
  owner = File.read(ARGV.fetch(0))
  abort "the warm-session owner does not retain exactly one session" unless
    owner.scan("private(set) var identifier: RimeSessionId = 0").length == 1 &&
      owner.scan("api.create_session()").length == 1
  abort "the warm-session owner does not prime the real candidate path" unless
    owner.scan(%q{"ceshi".withCString}).length == 1 &&
      owner.scan(%q{api.simulate_key_sequence(created, $0)}).length == 1 &&
      owner.scan("api.clear_composition(created)").length == 1
  abort "the warm-session owner can be recycled as stale" unless
    owner.scan("api.find_session(identifier)").length == 1
  abort "warm-session failure cleanup is not owned locally" unless
    owner.scan("discard(using: api)").length == 1 &&
      owner.scan("api.destroy_session(discarded)").length == 1 &&
      owner.scan("api.destroy_session").length == 1
' sources/LinnetRimeWarmSession.swift ||
  fail "the retained Rime resource-session contract changed"
ruby -e '
  source = File.read(ARGV.fetch(0))
  method = source[/func startRime\(fullCheck: Bool\) -> Bool \{.*?\n  \}\n  private func startStaleSessionCleaner/m]
  abort "startRime owner is missing" unless method
  maintenance = method.index("rimeAPI.start_maintenance(fullCheck)")
  join = method.index("rimeAPI.join_maintenance_thread()")
  deploy = method.index(%q{rimeAPI.deploy_config_file("squirrel.yaml", "config_version")})
  prepare = method.index("warmRimeSession.prepare(using: rimeAPI)")
  publish = method.index("isRimeRunning = true")
  abort "runtime readiness order changed" unless
    [maintenance, join, deploy, prepare, publish].all? &&
      maintenance < join && join < deploy && deploy < prepare &&
      prepare < publish
  abort "runtime readiness no longer fails closed" unless
    method.include?(%q{guard rimeAPI.deploy_config_file("squirrel.yaml", "config_version") else}) &&
      method.include?("guard warmRimeSession.prepare(using: rimeAPI) != nil else")
  abort "runtime readiness gained retry or duplicate probes" unless
    method.scan("rimeAPI.join_maintenance_thread()").length == 1 &&
      method.scan("warmRimeSession.prepare(using: rimeAPI)").length == 1 &&
      !method.include?("rimeAPI.create_session") &&
      !method.include?("rimeAPI.destroy_session") &&
      !method.include?("runtimeHealth()")
  abort "runtime running gained a second publication path" unless
    method.scan("isRimeRunning = true").length == 1
' sources/SquirrelApplicationDelegate.swift ||
  fail "Host can publish runtime readiness before maintenance and session validation"

ruby -e '
  host = File.read(ARGV.fetch(0))
  cleaner = host[/private func startStaleSessionCleaner\(\) \{.*?\n  \}/m]
  invalidate = host[/private func invalidateRimeSessions\(\) \{.*?\n  \}/m]
  sync = host[/private func performRimeUserDataSync\(\).*?\n  \}/m]
  activation = host[/private func activatePublishedSettings\(.*?\n  \}\n\n  private func validConfigurationCandidate/m]
  reload = activation && activation[/case \.configuration:.*?\n      return true/m]
  abort "the warm-session lifecycle consumers are missing" unless
    cleaner && invalidate && sync && reload
  refresh = cleaner.index("warmRimeSession.refresh(using: rimeAPI)")
  cleanup_stale = cleaner.index("rimeAPI.cleanup_stale_sessions()")
  retire = invalidate.index("warmRimeSession.retire()")
  cleanup_all = invalidate.index("rimeAPI.cleanup_all_sessions()")
  abort "stale cleanup can recycle the retained resource owner" unless
    refresh && cleanup_stale && refresh < cleanup_stale
  abort "runtime invalidation can leave a recycled warm identifier" unless
    retire && cleanup_all && retire < cleanup_all
  sync_retire = sync.index("warmRimeSession.retire()")
  synchronize = sync.index("rimeAPI.sync_user_data()")
  sync_join = sync.index("rimeAPI.join_maintenance_thread()")
  sync_prepare = sync.index("warmRimeSession.prepare(using: rimeAPI)")
  sync_reopen = sync.index("reopenRimeInput()", sync_join || 0)
  abort "user-data sync can retain a destroyed warm identifier" unless
    [sync_retire, synchronize, sync_join, sync_prepare, sync_reopen].all? &&
      sync_retire < synchronize && synchronize < sync_join &&
      sync_join < sync_prepare && sync_prepare < sync_reopen
  abort "configuration reload regained a second readiness-session path" unless
    reload.scan("warmRimeSession.prepare(using: rimeAPI)").length == 1 &&
      reload.scan("warmRimeSession.discard(using: rimeAPI)").length == 1 &&
      !reload.include?("rimeAPI.create_session") &&
      !reload.include?("rimeAPI.destroy_session")
' sources/SquirrelApplicationDelegate.swift ||
  fail "the retained resource session is not governed by runtime lifecycle"

# Runtime diagnostics report deployed schema availability; they do not own the
# user's selected schema.  Selecting every schema in probe sessions writes
# `previously_selected_schema` into user.yaml, so the next real input session
# starts in whichever probe ran last.  Keep this boundary on librime's
# read-only schema-list API and forbid session or selection mutations here.
ruby -e '
  source = File.read(ARGV.fetch(0))
  method = source[/func runtimeHealth\(\) -> LinnetSettingsContract\.RuntimeHealth \{.*?\n  \}\n\n  fileprivate var requiredSchemas/m]
  abort "runtimeHealth owner is missing" unless method
  abort "runtimeHealth must read the deployed schema list exactly once" unless
    method.scan("rimeAPI.get_schema_list").length == 1 &&
      method.scan("rimeAPI.free_schema_list").length == 1
  abort "runtimeHealth regained a selected-schema mutation path" if
    method.include?("rimeAPI.create_session") ||
      method.include?("rimeAPI.select_schema") ||
      method.include?("rimeAPI.destroy_session")
' sources/SquirrelApplicationDelegate.swift ||
  fail "runtime diagnostics can mutate the user-selected schema"

# InputMethodKit callbacks, timers and controller teardown can all arrive while
# a Settings transaction has suspended input or finalized librime. One Host
# predicate owns runtime availability; controllers never reinterpret its bits.
test "$(rg -c 'var canAcceptRimeInput: Bool' sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "the Host runtime-input availability owner count changed"
rg -Fq 'isRimeRunning && !isRimeInputSuspended' sources/SquirrelApplicationDelegate.swift ||
  fail "runtime input is no longer gated by both running and suspension state"
test "$(rg -c 'rimeAPI\.cleanup_all_sessions\(\)' sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "session-generation invalidation gained a second cleanup implementation"
ruby -e '
  host = File.read("sources/SquirrelApplicationDelegate.swift")
  invalidate = host[/private func invalidateRimeSessions\(\) \{.*?\n  \}/m]
  shutdown = host[/func shutdownRime\(\) \{.*?\n  \}/m]
  abort "the canonical session invalidation owner is missing" unless
    invalidate && shutdown
  commit = invalidate.index("commitCurrentComposition()")
  suspend = invalidate.index("isRimeInputSuspended = true")
  hide = invalidate.index("panel?.hide()")
  cleanup = invalidate.index("rimeAPI.cleanup_all_sessions()")
  abort "session invalidation can discard marked text before committing it" unless
    commit && suspend && hide && cleanup &&
      commit < suspend && suspend < hide && hide < cleanup
  abort "active-composition commit gained a second runtime-invalidation owner" unless
    host.scan("commitCurrentComposition()").length == 1
  abort "shutdown can suspend input before canonical invalidation commits it" if
    (early_suspend = shutdown.index("isRimeInputSuspended = true")) &&
      early_suspend < shutdown.index("invalidateRimeSessions()")
' || fail "Host runtime invalidation can discard an active composition"
if rg -n 'isRimeRunning|isRimeInputSuspended' \
    sources/SquirrelInputController.swift \
    sources/SquirrelInputController+RimeSession.swift; then
  fail "the input controller bypasses the Host runtime-availability owner"
fi
# macOS owns physical Caps Lock state and Rime's ascii_composer owns the input
# mode transition.  The Host must not keep a private Caps/ASCII ledger or
# reconstruct that state when a controller/session is activated.
if rg -n \
    'capsLockBaseline|synchronizeCapsLockBaseline|_linnet_caps_lock_ascii_mode|readyActivationToken' \
    sources patches/librime-linnet-core-interactions.patch; then
  fail "the Host or patched runtime regained a second Caps/ASCII state owner"
fi
ruby -e '
  controller = File.read("sources/SquirrelInputController.swift") +
    File.read("sources/SquirrelInputController+RimeSession.swift")
  lease = File.read("sources/LinnetRimeSessionLease.swift")
  presentation = File.read("sources/SquirrelApplicationPresentation.swift")
  ensure_session = controller[/func ensureReadySession\(.*?\n  \}/m]
  current_session = controller[/func sessionIsCurrent\(\) -> Bool \{.*?\n  \}/m]
  current_lease = controller[/func currentSessionLease\(.*?\n  \}/m]
  owns_lease = controller[/func ownsCurrentSession\(.*?\n  \}/m]
  create_session = controller[/func createSession\(client .*?\) \{.*?\n  \}/m]
  chord_timer = controller[/func onChordTimer\(.*?\n  \}/m]
  recovered_mode = controller[/func synchronizeRecoveredInputMode\(.*?\n  \}/m]
  handle = controller[/override func handle\(.*?\n  \}/m]
  activation = controller[/override func activateServer\(.*?\n  \}/m]
  commit = controller[/override func commitComposition\(.*?\n  \}/m]
  active_commit_owner = controller[/func commitActiveComposition\(.*?\n  \}/m]
  raw_commit_owner = controller[/func commitRawComposition\(.*?\n  \}/m]
  update = controller[/func rimeUpdate\(\) \{.*?\n  \}\n\n  private func commit\(string:/m]
  status = presentation[/func updateStatusIcon\(session: RimeSessionId\).*?\n  \}/m]
  abort "the canonical live-session recovery owner is missing" unless
    ensure_session && current_session && handle && activation && commit &&
      active_commit_owner && raw_commit_owner && update && current_lease && owns_lease &&
      create_session && chord_timer && recovered_mode && status
  abort "a recycled raw session identifier can cross controller ownership" unless
    lease.include?("struct LinnetRimeSessionLease: Equatable") &&
      lease.include?("fileprivate let ownership: UInt64") &&
      lease.include?("private static let lock = NSLock()") &&
    lease.include?("owners[identifier] = nextOwnership") &&
      lease.include?("owners[lease.identifier] == lease.ownership") &&
      controller.scan(/^  var sessionLease: LinnetRimeSessionLease\?$/).length == 1 &&
      create_session.include?("LinnetRimeSessionLease.acquire(identifier: identifier)") &&
      current_session.include?("sessionLease.isCurrent(") &&
      current_lease.include?("sessionLease.isCurrent(") &&
      owns_lease.include?("expectedLease.isCurrent(") &&
      [current_session, current_lease, owns_lease].all? {
        |owner| owner.scan("rimeAPI.find_session").length == 1
      } && controller.scan("rimeAPI.find_session").length == 3
  abort "delayed callbacks no longer carry and revalidate the typed lease" unless
    chord_timer.include?("sessionLease: LinnetRimeSessionLease") &&
      chord_timer.include?("ownsCurrentSession(") &&
      status.include?("let sessionLease = controller.currentSessionLease(") &&
      status.include?("controller.ownsCurrentSession(") &&
      status.include?("sessionLease.identifier")
  abort "live-session recovery no longer validates and recreates one generation" unless
    ensure_session.scan("sessionIsCurrent()").length == 2 &&
      ensure_session.scan("createSession(client: expectedClient)").length == 1
  abort "key events bypass canonical live-session recovery" unless
    handle.include?("activeClient = senderClient") &&
      handle.include?("guard ensureReadySession(for: senderClient)")
  recover = activation.index("guard ensureReadySession(for: activatingClient)")
  baseline = activation.index("rimeUpdate()")
  publish = activation.index("inputSourceDidActivate(")
  abort "activation can publish a stale session before the first key" unless
    recover && publish && recover < publish
  abort "activation can mistake the first user mode switch for initial schema discovery" unless
    baseline && recover < baseline && baseline < publish
  abort "activation retained raw nonzero-session inference" if
    activation.include?("if session != 0")
  native_client = activation.index("activeClient = activatingClient")
  modifier_epoch = activation.index("resetModifierEpoch()")
  abort "activation can sample its modifier epoch after session recovery" unless
    native_client && modifier_epoch && recover &&
      native_client < modifier_epoch && modifier_epoch < recover
  recovered = ensure_session.index("let recoveredSession = !sessionIsCurrent()")
  recreate = ensure_session.index("createSession(client: expectedClient)")
  mode = ensure_session.index("synchronizeRecoveredInputMode(")
  abort "session recovery no longer restores presentation before readiness" unless
    recovered && recreate && mode && recovered < recreate && recreate < mode
  abort "session recovery can swallow the triggering modifier event" if
    ensure_session.include?("resetModifierEpoch()") ||
      ensure_session.include?("CGEventSource.flagsState")
  abort "recovered input mode bypasses the canonical identity owner" unless
    recovered_mode.include?("rimeAPI.get_status(session, &status)") &&
      recovered_mode.include?("applyInputModeIdentity(") &&
      recovered_mode.include?("announcesTransition: false")
  raw_commit = raw_commit_owner.index("rimeAPI.commit_raw_input(session)")
  consume = raw_commit_owner.index("rimeConsumeCommittedText(to: targetClient)")
  abort "InputMethodKit exit no longer reuses Rime commit_raw_input semantics" unless
    commit.scan("commitActiveComposition(").length == 1 &&
      active_commit_owner.scan("commitRawComposition(to: targetClient)").length == 1 &&
      raw_commit && consume && raw_commit < consume
  abort "InputMethodKit exit regained user-key or duplicate-clear semantics" if
    (commit + active_commit_owner + raw_commit_owner).include?("process_key") ||
      (commit + active_commit_owner + raw_commit_owner).include?("clear_composition")
  abort "InputMethodKit exit regained a second raw-input reconstruction owner" if
    (commit + active_commit_owner).include?("get_input") ||
      (commit + active_commit_owner).include?("commit(string:")
  idle = update.index("if preedit.isEmpty,")
  geometry = update.index("showPanel(")
  abort "idle activation can still request synchronous client geometry without visible feedback" unless
    update.include?("candidateSnapshot.items.isEmpty,") &&
      update.include?("!presentsModeTransition") && idle && geometry && idle < geometry
' || fail "live input-session recovery ownership regressed"
for boundary in \
  'override func handle' \
  'func selectCandidate' \
  'func page' \
  'func onChordTimer' \
  'func createSession' \
  'func destroySession' \
  'func rimeUpdate'; do
  location="$(rg -n -m1 -F "${boundary}" \
    sources/SquirrelInputController.swift \
    sources/SquirrelInputController+RimeSession.swift | head -1)"
  [[ -n "${location}" ]] || fail "runtime callback boundary is missing: ${boundary}"
  source_path="${location%%:*}"
  line_and_text="${location#*:}"
  line="${line_and_text%%:*}"
  sed -n "${line},$((line + 12))p" "${source_path}" |
    rg -Fq 'canAcceptRimeInput' ||
    fail "runtime callback bypasses availability: ${boundary}"
done
ruby -e '
  source = File.read(ARGV.fetch(0))
  callback = source[/override func commitComposition\(.*?\n  \}/m]
  active_owner = source[/func commitActiveComposition\(.*?\n  \}/m]
  raw_owner = source[/func commitRawComposition\(.*?\n  \}/m]
  abort "composition exit owners are missing" unless
    callback && active_owner && raw_owner
  abort "InputMethodKit commit bypasses the runtime-availability owner" unless
    callback.scan("commitActiveComposition(").length == 1 &&
      active_owner.scan("commitRawComposition(to: targetClient)").length == 1 &&
      raw_owner.include?("canAcceptRimeInput")
' sources/SquirrelInputController.swift ||
  fail "InputMethodKit composition exit bypasses runtime availability"
ruby -e '
  source = File.read(ARGV.fetch(0))
  recognized = source[/override func recognizedEvents\(.*?\n  \}/m]
  handle = source[/override func handle\(.*?\n  \}/m]
  sdk_mouse = source[/override func mouseDown\(.*?\n  \}/m]
  raw_mouse = source[/private func handleCompositionMouseDown\(.*?\n  \}/m]
  exit_owner = source[/private func commitCompositionIfClickIsOutside\(.*?\n  \}/m]
  abort "InputMethodKit mouse-exit owners are missing" unless
    recognized && handle && sdk_mouse && raw_mouse && exit_owner
  %w[.keyDown .flagsChanged .leftMouseDown .rightMouseDown .otherMouseDown].each do |event|
    abort "recognizedEvents lost #{event}" unless recognized.include?(event)
  end
  mouse_ingress = handle.index("if [.leftMouseDown, .rightMouseDown, .otherMouseDown]")
  session_recovery = handle.index("guard ensureReadySession(for: senderClient)")
  abort "raw mouse exit can touch or recreate Rime before click classification" unless
    mouse_ingress && session_recovery && mouse_ingress < session_recovery &&
      handle.include?("handleCompositionMouseDown(") &&
      handle.include?("return false")
  abort "raw mouse coordinates no longer use the client screen-space contract" unless
    raw_mouse.include?("event.window?.convertPoint(") &&
      raw_mouse.include?("toScreen: event.locationInWindow") &&
      raw_mouse.include?("targetClient.characterIndex(") &&
      raw_mouse.include?("tracking: kIMKNearestBoundaryMode") &&
      raw_mouse.include?("inMarkedRange: &insideMarkedRange") &&
      raw_mouse.include?("spatiallyInsideMarkedRange: insideMarkedRange.boolValue")
  abort "SDK mouse tracking can swallow the host click or bypass the shared exit" unless
    sdk_mouse.include?("keepTracking?.pointee = false") &&
      sdk_mouse.include?("commitCompositionIfClickIsOutside(") &&
      sdk_mouse.match?(/return false\s*\n  \}\z/)
  abort "mouse exit bypasses the typed click policy or regained proxy identity" unless
    exit_owner.include?("LinnetInputActivationPolicy.shouldCommitCompositionForClick(") &&
      exit_owner.include?("commitActiveComposition(") &&
      !exit_owner.include?("===")
' sources/SquirrelInputController.swift ||
  fail "raw InputMethodKit mouse composition exit regressed"
rg -Fq 'weak var inputController: SquirrelInputController?' sources/SquirrelPanel.swift ||
  fail "the candidate panel strongly retains an inactive input controller"
test "$(rg -c 'private var .*Observer: NSObjectProtocol\?' sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "the Host observer-token owner count changed"
for observer_owner in workspacePowerOffObserver; do
  test "$(rg -F -c "private var ${observer_owner}: NSObjectProtocol?" \
    sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
    fail "the distinct ${observer_owner} boundary lost its single token owner"
done
if rg -n 'inputSourceSelectionObserver' sources/SquirrelApplicationDelegate.swift; then
  fail "the retired block-token input-source observer returned"
fi
test "$(rg -F -c 'selector: #selector(inputSourceChanged(_:))' \
  sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "the input-source lifecycle lost its single upstream selector owner"
ruby -e '
  source = File.read(ARGV.fetch(0))
  registration = source[/selector: #selector\(inputSourceChanged\(_:\)\).*?\n\s*\)/m]
  abort "input-source selector registration is missing" unless registration
  abort "input-source lifecycle can be suspended while Linnet is inactive" unless
    registration.include?("suspensionBehavior: .deliverImmediately")
' sources/SquirrelApplicationDelegate.swift ||
  fail "the input-source lifecycle can be suspended while Linnet is inactive"
test "$(rg -F -c 'kTISNotifySelectedKeyboardInputSourceChanged as String' \
  sources/SquirrelApplicationDelegate.swift)" -eq 2 ||
  fail "the input-source selector registration/removal pair changed"
ruby -e '
  source = File.read(ARGV.fetch(0))
  controller = File.read(ARGV.fetch(1))
  delegate = File.read(ARGV.fetch(2))
  activation = source[/func inputSourceDidActivate\(.*?\n  \}/m]
  selection = source[/@objc func inputSourceChanged\(_:\s*Notification\) \{.*?\n  \}/m]
  fallback = source[/private func finalizeStrandedComposition\(\).*?\n  \}/m]
  activate = controller[/override func activateServer\(.*?\n  \}/m]
  deactivate = controller[/override func deactivateServer\(.*?\n  \}/m]
  teardown = controller[/deinit \{.*?\n  \}/m]
  abort "input-source presentation lifecycle owners are missing" unless
    activation && selection && fallback && activate && deactivate && teardown
  abort "activation can publish stale visibility from a deferred callback" if
    activation.include?("DispatchQueue.main.async")
  status = activation.index("updateStatusIcon(")
  visibility = activation.index("setStatusItemVisibility(inputSourceIsActive: true)")
  abort "activation no longer synchronously publishes the active source" unless
    status && visibility && status < visibility
  abort "selection fallback can run reentrantly inside the native IMK transition" unless
    selection.include?("DispatchQueue.main.async") &&
      selection.include?("updateStatusItemVisibility()") &&
      selection.include?("finalizeStrandedComposition()")
  abort "stranded-composition fallback no longer exits the panel-bound native client" unless
      fallback.scan("SquirrelInstaller.currentInputSourceID()").length == 1 &&
      fallback.include?("let inputController = panel?.inputController") &&
      fallback.include?("let activeClient = inputController.activeClient") &&
      fallback.include?("inputController.deactivateServer(activeClient)")
  combined = source + controller + delegate
  abort "the retired process-global activation owner returned" if
    combined.include?("LinnetInputActivationRegistry") ||
      combined.include?("inputActivationRegistry") ||
      combined.include?("beginInputActivation(") ||
      combined.include?("finishInputActivation(") ||
      combined.include?("terminateInputActivations(")
  abort "native activation can still be rejected by another controller" unless
    activate.include?("guard let activatingClient = sender as? IMKTextInput else { return }") &&
      activate.include?("activeClient = activatingClient") &&
      activate.include?("panel.unbind(controller: self)") &&
      activate.include?("panel.bind(controller: self)")
  retire = deactivate.index("activeClient = nil")
  commit_raw = deactivate.index("commitRawComposition(to: deactivatingClient)")
  abort "native deactivation can clear a replacement client" unless
    retire && commit_raw && retire < commit_raw && !deactivate.include?("===")
  abort "native deactivation regained input-source inference" if
    deactivate.include?("SquirrelInstaller.currentInputSourceID()")
  abort "controller teardown no longer destroys exactly its Rime session" unless
    teardown.scan("destroySession()").length == 1 &&
      !teardown.include?("Activation")
' sources/SquirrelApplicationPresentation.swift \
  sources/SquirrelInputController.swift sources/SquirrelApplicationDelegate.swift ||
  fail "InputMethodKit per-controller ownership or away/back transitions regressed"
test ! -e sources/LinnetInputActivationRegistry.swift ||
  fail "the retired process-global activation owner file returned"
ruby -e '
  controller = File.read(ARGV.fetch(0))
  update = controller[/func rimeUpdate\(\) \{.*?\n  \}\n\n  private func commit\(string:/m]
  commit = controller[/private func commit\(string: String, to targetClient: IMKTextInput\?\) \{.*?\n  \}\n\n  private func show\(/m]
  show = controller[/private func show\(\n.*?\n  \}\n\n  private func showPanel/m]
  panel = controller[/private func showPanel\(.*?\n  \}\n\}/m]
  abort "client-publication lifecycle owners are missing" unless
    update && commit && show && panel
  native_client = update.index("guard let updateClient = activeClient")
  consume = update.index("rimeConsumeCommittedText(to: updateClient)")
  abort "a Rime update no longer captures its event client before callbacks" unless
    native_client && consume && native_client < consume &&
      !update.include?("client === updateClient")
  abort "marked-text callbacks no longer publish to the captured event client" unless
    update.include?("client: updateClient") &&
      show.include?("client expectedClient: IMKTextInput") &&
      show.include?("expectedClient.setMarkedText(") &&
      !show.include?("===")
  abort "client geometry bypasses the controller-scoped panel boundary" unless
    panel.include?("client expectedClient: IMKTextInput") &&
      panel.include?("guard panel.inputController === self else { return }") &&
      !panel.include?("client === expectedClient") &&
      panel.include?("controller: self")
  reset = commit.index(%q{preedit = ""})
  marked = commit.index("targetClient.setMarkedText(")
  inserted = commit.index("targetClient.insertText(")
  abort "an old commit stack can clear or hide a replacement activation" unless
    reset && inserted && reset < inserted &&
      (!marked || reset < marked) && !commit.include?("hidePalettes()")
' sources/SquirrelInputController.swift ||
  fail "InputMethodKit client callback reentrancy can publish stale UI"
test "$(rg -F -c 'private var settingsTransactionHost: LinnetSettingsTransactionIPC.Host?' \
  sources/SquirrelApplicationDelegate.swift)" -eq 1 ||
  fail "the authenticated Settings transaction Host owner count changed"
ruby -e '
  project, settings, root, delegate, presentation, controller =
    ARGV.map { |path| File.read(path) }
  menu = delegate + presentation
  abort "retired Settings Info.plist reference returned" if project.include?("Settings-Info.plist")
  abort "retired nonexistent Frameworks search path returned" if
    project.include?("$(PROJECT_DIR)/Frameworks")
  abort "Settings must be an accessory app in Debug and Release" unless
    project.scan("INFOPLIST_KEY_LSUIElement = YES;").length == 2
  abort "Settings must exit after its last window closes" unless
    settings.match?(/applicationShouldTerminateAfterLastWindowClosed\(_:\s*NSApplication\)\s*->\s*Bool\s*\{\s*true\s*\}/m)
  abort "the Settings Scene does not consume the canonical window metrics" unless
    settings.include?("minWidth: LinnetSettingsLayoutMetrics.minimumWindowWidth") &&
      settings.include?("idealWidth: LinnetSettingsLayoutMetrics.defaultWindowWidth") &&
      settings.include?("minHeight: LinnetSettingsLayoutMetrics.windowHeight") &&
      settings.include?("height: LinnetSettingsLayoutMetrics.windowHeight") &&
      settings.scan("LinnetSettingsLayoutMetrics.windowHeight").length == 2
  abort "Settings root is missing" unless root.include?("struct SettingsRootView: View")
  conflict = root.index("if model.configuration.hasExternalConflict")
  tabs = root.index("TabView {")
  abort "the global configuration-conflict entry is missing" unless conflict && tabs && conflict < tabs
  items = menu[/private func inputMenuItems\(actionTarget: AnyObject\) -> \[NSMenuItem\] \{.*?\n  \}/m]
  abort "input menu owner is missing" unless items
  mode_item = items.index("let mode = NSMenuItem")
  settings_item = items.index("let settings = NSMenuItem")
  abort "the input menu lost its read-only live mode projection" unless
    mode_item && settings_item && mode_item < settings_item &&
      items.include?("mode.isEnabled = false") &&
      items.include?("settings.target = actionTarget") &&
      items.include?("return [mode, .separator(), settings]")
  abort "the input menu Settings title or action changed" unless
    items.include?(%q{NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"), action: #selector(openSettings), keyEquivalent: "")})
  abort "the IMK menu no longer targets its controller" unless
    controller.include?("makeInputMenu(actionTarget: self)") &&
      controller.include?("@objc func openSettings()")
  abort "the status-item menu no longer targets the application delegate" unless
    menu.include?("inputMenuItems(actionTarget: self)")
  apply_status = menu[/func applyStatusIcon\(asciiMode: Bool, schemaLabel: String\?\) \{.*?\n  \}/m]
  abort "status-label projection regained visibility ownership" unless
    apply_status && !apply_status.include?(".isVisible")
  abort "status and input menus no longer share the live Rime mode projection" unless
    menu.scan("var currentModeLabel = \"中\"").length == 1 &&
      menu.include?("currentModeLabel = label") &&
      menu.include?("button.title = label") &&
      menu.include?("private func setStatusItemVisibility(inputSourceIsActive: Bool)") &&
      menu.include?("statusItem?.isVisible = showStatusIcon && inputSourceIsActive") &&
      menu.include?("func inputSourceDidActivate(") &&
      menu.include?("func inputSourceDidActivate(session: RimeSessionId)") &&
      controller.include?("inputSourceDidActivate(") &&
      controller.include?("inputSourceDidActivate(session: session)")
' Linnet.xcodeproj/project.pbxproj sources/LinnetSettings/SettingsApplication.swift \
  sources/LinnetSettings/SettingsRootView.swift \
  sources/SquirrelApplicationDelegate.swift \
  sources/SquirrelApplicationPresentation.swift \
  sources/SquirrelInputController.swift ||
  fail "Settings surface lifecycle or input-menu ownership regressed"
if /usr/bin/plutil -extract TISInputSourceID raw -o - \
    resources/Info.plist >/dev/null 2>&1; then
  fail "the no-modes input method regained a competing explicit source identity"
fi
[[ "$(/usr/bin/plutil -extract TISIntendedLanguage raw -o - resources/Info.plist)" == \
  zh-Hans ]] || fail "the input source language is not Simplified Chinese"
[[ "$(/usr/bin/plutil -extract tsInputMethodCharacterRepertoireKey json -o - \
  resources/Info.plist)" == '["zh-Hans"]' ]] ||
  fail "the no-modes input source repertoire is not the exact zh-Hans contract"
[[ "$(/usr/bin/plutil -extract tsInputMethodIconFileKey raw -o - \
  resources/Info.plist)" == linnet.pdf ]] || fail "the input source icon is invalid"
for retired_input_mode_key in ComponentInputModeDict PrimaryInputModeIdentifier; do
  if /usr/bin/plutil -extract "${retired_input_mode_key}" raw -o - \
    resources/Info.plist >/dev/null 2>&1; then
    fail "a competing input-mode identity returned: ${retired_input_mode_key}"
  fi
done
[[ "$(/usr/bin/plutil -extract InputMethodConnectionName raw -o - \
  resources/Info.plist)" == '$(PRODUCT_NAME)_Connection' ]] ||
  fail "the stable upstream-style IMK connection contract is invalid"
ruby -e '
  page = File.read("sources/LinnetSettings/LinnetSettingsPage.swift")
  views = File.read("sources/LinnetSettings/SettingsViews.swift")
  input = views[/struct InputTabView: View \{.*?\n\}\n\n\/\/ MARK: - Dictionary/m]
  dictionary = views[/struct DictionaryTabView: View \{.*?\n\}\n\n\/\/ MARK: - English/m]
  english = views[/struct EnglishTabView: View \{.*?\n\}\n\n\/\/ MARK: - Data/m]
  appearance = views[/struct AppearanceTabView: View \{.*?\n\}\n\n\/\/ MARK: - Input/m]
  abort "Settings page sections are missing" unless input && dictionary && english && appearance
  abort "an editable Settings collection regained mutable-index identity" if
    dictionary.include?("disabledWords.indices") ||
      dictionary.include?("disabledWords[index]") ||
      dictionary.include?("removeDisabledWord(at:") ||
      dictionary.include?("ForEach($model.configuration.personalDraft")
  abort "editable Settings rows no longer resolve through stable model bindings" unless
    %w[customWordValueBinding customWordCodeBinding disabledWordBinding
       expansionValueBinding expansionTriggerBinding].all? { |owner| dictionary.include?(owner) }
  abort "the retired single-item Advanced disclosure returned" if
    input.include?(%q{DisclosureGroup("Advanced")})
  abort "the responsive two-column Settings owner count changed" unless
    page.scan("struct LinnetSettingsTwoColumnLayout").length == 1
  layout = page[/struct LinnetSettingsTwoColumnLayout.*?\n\}/m]
  abort "the Settings two-column owner is missing" unless layout
  abort "the Settings preview may still fall below the controls" if
    layout.include?("ViewThatFits") || layout.include?("VStack")
  abort "the Settings two-column owner no longer has one horizontal path" unless
    layout.scan("HStack").length == 1
  abort "Appearance, Input, and English must share the two-column layout owner" unless
    [appearance, input, english].all? { |section|
      section.scan("LinnetSettingsTwoColumnLayout").length == 1
    }
' || fail "Settings bilingual two-column layout ownership regressed"

test -f sources/LinnetSettings/SettingsWindowCloseGuard.swift ||
  fail "Settings has no native pending-change close boundary"

# Rime remains the only learned-word merge owner. Linnet contributes one Host
# scheduler and one learning-only installation projection, never a second
# userdb parser or an automatic portable/config backup path.
test "$(rg -F -o 'rimeAPI.sync_user_data()' sources | wc -l | tr -d ' ')" -eq 1 ||
  fail "Rime user-data synchronization regained another runtime caller"
rg -Fq 'rimeAPI.sync_user_data()' sources/SquirrelApplicationDelegate.swift ||
  fail "the Host stopped owning the single upstream Rime synchronization call"
rg -Fq 'static let automaticInterval: TimeInterval = 60 * 60' \
  sources/LinnetSettings/LinnetRimeSyncController.swift ||
  fail "automatic learning synchronization is no longer hourly"
test "$(rg -F -o 'backup_config_files: false' \
  sources/LinnetSettings/LinnetRimeSyncController.swift | wc -l | tr -d ' ')" -eq 1 ||
  fail "the installation projection no longer disables Rime automatic config backup"
if rg -Fq 'backup_config_files: true' \
    sources/LinnetSettings/LinnetRimeSyncController.swift; then
  fail "the learning-sync owner re-enabled Rime automatic config backup"
fi
if rg -n 'userdb[.]txt|UserDbMerger|commit_count|dynamic_weight' \
    sources/LinnetSettings/LinnetRimeSyncController.swift; then
  fail "Linnet regained a second user-dictionary merge implementation"
fi
if rg -n 'exportPortable|uploadCloudBackupArchive|cloudBackupArchive' \
    sources/LinnetSettings/LinnetRimeSyncController.swift \
    sources/SquirrelApplicationDelegate.swift \
    sources/SquirrelInputController.swift; then
  fail "the automatic learning-sync path regained a full recovery archive"
fi
test "$(rg -F -c 'LinnetRimeSyncController.swift in Linnet Sources' \
  Linnet.xcodeproj/project.pbxproj)" -eq 2 ||
  fail "the Rime sync scheduler is not compiled exactly once into the Host"
if rg -n 'stores one verified portable archive|Upload Current Data' \
    sources/LinnetSettings/SettingsViews.swift; then
  fail "the manual recovery archive is still presented as learning sync"
fi
ruby -e '
  app = File.read("sources/LinnetSettings/SettingsApplication.swift")
  model = File.read("sources/LinnetSettings/SettingsMain.swift")
  root = File.read("sources/LinnetSettings/SettingsRootView.swift")
  guard = File.read("sources/LinnetSettings/SettingsWindowCloseGuard.swift")
  session = File.read("sources/LinnetSettings/SettingsSessionState.swift")
  abort "Cmd-Q can still bypass pending Settings changes" unless
    app.include?("applicationShouldTerminate(") &&
      app.include?("SettingsPendingChangesPrompt")
  abort "the Settings window is not protected at the AppKit close boundary" unless
    guard.include?("windowShouldClose") &&
      guard.include?("SettingsPendingChangesPrompt") &&
      guard.include?(%q{localized: "Apply your changes before closing?"}) &&
      guard.include?("locale: Locale")
  abort "the AppKit close prompt no longer follows the selected Settings language" unless
    app.include?("interfaceLocale = Locale.autoupdatingCurrent") &&
      app.include?("locale: interfaceLocale") &&
      root.include?("SettingsWindowCloseGuard(model: model, locale: interfaceLanguage.locale)") &&
      root.include?("delegate.interfaceLocale = interfaceLanguage.locale")
  abort "pending drafts gained a second persistence owner" if
    guard.include?("linnet_settings.json") || guard.include?("UserDefaults")
  abort "the retired re-entrant close path returned" if
    guard.include?("allowCloseOnce") || guard.include?("performClose(")
  apply_completion = guard[/func completeApply\(.*?\n  \}/m]
  abort "the asynchronous Apply result lost its single terminal close transition" unless
    apply_completion &&
      apply_completion.include?("guard accepted, let sender else { return }") &&
      apply_completion.include?("updateDocumentEditedState()") &&
      apply_completion.scan("sender.close()").length == 1
  abort "the canonical in-memory discard transition is missing" unless
    session.include?("mutating func discardPendingChanges()")
  publish = model[/func publishAppearance\(.*?\n  \}/m]
  abort "Apply-only appearance fields can still enqueue a live refresh" unless
    publish &&
      publish.include?("let projectedAppearance =") &&
      publish.include?("guard projectedAppearance != baseline.appearance else") &&
      publish.include?("cancelPendingAppearancePublish()") &&
      publish.include?("pendingAppearance = projectedAppearance")
  terminal = model[/private func cancelPendingAppearancePublish\(\).*?\n  \}/m]
  abort "Settings has no single terminal owner for pending appearance work" unless
    terminal &&
      terminal.include?("appearanceDebounceTask?.cancel()") &&
      terminal.include?("appearanceDebounceTask = nil") &&
      terminal.include?("pendingAppearance = nil")
  discard = model[/func discardPendingChanges\(\).*?\n  \}/m]
  abort "Discard can still leave a queued appearance publish behind" unless
    discard&.include?("cancelPendingAppearancePublish()")
  accepted = model[/case \.accepted:\n(.*?)case \.conflict:/m, 1]
  abort "a successful Apply can still start a second appearance refresh" unless
    accepted&.include?("if kind == .apply") &&
      accepted.include?("cancelPendingAppearancePublish()")
' || fail "Settings pending-change lifecycle regressed"

ruby -rjson -e '
  catalog = JSON.parse(File.read("resources/Localizable.xcstrings"))
  retired_keys = [
    "Deploy", "Logs...", "Advanced", "Change Folder…",
    "Choose a folder inside iCloud Drive to connect this Mac.", "Choose Folder…",
    "Disconnect", "No sync folder selected",
    "This replaces Linnet-Full-Backup.linnet-data in the selected folder. Local data is not changed."
  ]
  returned = retired_keys & catalog.fetch("strings", {}).keys
  abort "retired localization keys returned: #{returned.join(", ")}" unless returned.empty?
  required_cloud_keys = [
    "Sync learned words with iCloud Drive", "Location",
    "iCloud Drive is unavailable. Check iCloud Drive in System Settings.",
    "Linnet always uses iCloud Drive/Linnet; no folder selection is required.",
    "This replaces iCloud Drive/Linnet/Linnet-Full-Backup.linnet-data. Local data is not changed."
  ]
  absent_cloud_keys = required_cloud_keys - catalog.fetch("strings", {}).keys
  abort "fixed iCloud localization keys are missing: #{absent_cloud_keys.join(", ")}" unless absent_cloud_keys.empty?
  missing = catalog.fetch("strings", {}).each_with_object([]) do |(key, entry), result|
    unit = entry.dig("localizations", "zh-Hans", "stringUnit")
    result << key unless unit.is_a?(Hash) && unit["state"] == "translated" &&
      !unit["value"].to_s.strip.empty?
  end
  abort "Simplified Chinese localization is missing or empty: #{missing.join(", ")}" unless missing.empty?
' || fail "Settings localization coverage regressed"
ruby -e '
  source = File.read("sources/InputSource.swift")
  register = source[/func register\(\) throws \{.*?\n  \}/m]
  abort "the sole first-install registration owner is missing" unless
    register && register.scan("TISRegisterInputSource").length == 1 &&
      register.include?("inputSources(identifier:") &&
      register.include?("already registered")
  forbidden = %w[
    TISDisableInputSource
    refreshAfterCoreUpdate desiredInputSourceAfterCoreUpdate
    inputSourceToRestoreAfterRegistration
  ]
  returned = forbidden.select { |name| source.include?(name) }
  abort "user-owned input-source mutations returned: #{returned.join(", ")}" unless
    returned.empty?
  abort "TIS registration gained a second owner" unless
    source.scan("TISRegisterInputSource").length == 1
  forbidden_mutations = %w[TISEnableInputSource TISSelectInputSource]
  returned_mutations = forbidden_mutations.select { |name| source.include?(name) }
  abort "programmatic input-source activation returned: #{returned_mutations.join(", ")}" unless
    returned_mutations.empty?
' || fail "install-boundary input-source availability regressed"
if rg -n 'community-adhoc|sign_adhoc_code|verify_community_code|inspect-community-contract|sign-community-product|verify-publication-product|unsigned-community' \
    scripts/linnet-code-identity scripts/generate-release-metadata \
    Makefile action-build.sh package/make_archive package/make_package \
    package/verify_package package/verify_publication_artifacts \
    scripts/release-control package/publish_github_release; then
  fail "the retired public ad-hoc signing path returned"
fi
ruby -rjson -e '
  identity = JSON.parse(File.binread(ARGV.fetch(0)))
  abort unless identity.keys.sort ==
    %w[certificate_sha1 certificate_sha256 format legacy_migration_acceptance profile] &&
    identity.fetch("format") == 2 && identity.fetch("profile") == "community-cms" &&
    identity.fetch("certificate_sha1").match?(/\A[0-9A-F]{40}\z/) &&
    identity.fetch("certificate_sha256").match?(/\A[0-9a-f]{64}\z/) &&
    identity.fetch("legacy_migration_acceptance").is_a?(Hash)
' config/linnet-community-signing.json ||
  fail "the fixed community CMS leaf and migration-acceptance owner is invalid"
ruby -e '
  delegate = File.read("sources/SquirrelApplicationDelegate.swift") +
    File.read("sources/SquirrelApplicationPresentation.swift")
  controller = File.read("sources/SquirrelInputController.swift")
  update = delegate[/func updateStatusIcon\(session: RimeSessionId\) \{.*?\n  \}/m]
  option_notification = delegate[/if messageType == "option".*?\n    return\n  \}/m]
  schema_notification = delegate[/if messageType == "schema".*?\n  \}\n\}/m]
  activation = controller[/override func activateServer\(.*?\n  \}/m]
  abort "live status owner is missing" unless
    update && option_notification && schema_notification && activation
  abort "live status must query the current session option and abbreviated label" unless
    update.include?("let controller = panel?.inputController") &&
      update.scan("currentSessionLease(").length == 1 &&
      update.scan("ownsCurrentSession(").length == 1 &&
    update.include?(%q{get_option(sessionLease.identifier, "ascii_mode")}) &&
      update.include?("get_state_label_abbreviated(") &&
      update.include?(%q{sessionLease.identifier, "ascii_mode", asciiMode, true})
  abort "ascii-mode option changes must refresh the live status" unless
    option_notification.include?(%q{if optionName == "ascii_mode" { delegate.updateStatusIcon(session: sessionId) }})
  abort "schema changes must refresh the live status" unless
    schema_notification.include?("delegate.updateStatusIcon(session: sessionId)")
  abort "client activation must seed the live status" unless
    activation.include?("inputSourceDidActivate(") &&
      activation.include?("inputSourceDidActivate(session: session)")
' || fail "live input-mode status projection regressed"
ruby -e '
  host = File.read("sources/SquirrelApplicationDelegate.swift")
  publication = host[/private func publishSettingsCandidate\(.*?\n  \}\n\n  private func rollbackSettingsPublication/m]
  rollback = host[/private func rollbackSettingsPublication\(.*?\n  \}\n\n  private func activatePublishedSettings/m]
  activation = host[/private func activatePublishedSettings\(.*?\n  \}\n\n  private func validConfigurationCandidate/m]
  startup = host[/private func reconcileLiveSettings\(\).*?\n  \}/m]
  runtime_start = host[/func startRime\(fullCheck: Bool\).*?\n  \}/m]
  abort "atomic settings publication owner is missing" unless
    publication && rollback && activation && startup && runtime_start
  abort "Host publication did not validate one typed candidate" unless
    publication.include?("validConfigurationCandidate(candidate)") &&
      publication.include?("expectedSettingsRevision")
  abort "Host publication lost its single atomic document exchange" unless
    publication.scan("exchangeCandidateDocument(").length == 1 &&
      rollback.scan("exchangeCandidateDocument(").length == 1
  abort "Host publication no longer rebuilds projection caches from the document" unless
    publication.scan("LinnetSettingsProjectionRenderer.reconcile(").length == 1 &&
      rollback.scan("LinnetSettingsProjectionRenderer.reconcile(").length == 1 &&
      startup.scan("LinnetSettingsProjectionRenderer.reconcile(").length == 1
  abort "Rime can initialize before the Core-owned projection is reconciled" unless
    (reconcile = runtime_start.index("reconcileLiveSettings()")) &&
      (initialize = runtime_start.index("rimeAPI.initialize(nil)")) &&
      reconcile < initialize
  abort "Host can publish success without the activated document revision" unless
    publication.include?("activeSettingsRevision = published.revision") &&
      publication.index("activeSettingsRevision = published.revision") <
        publication.index("status: .activated")

  target_source = host[/private static let configurationReloadTargets.*?\n  \]/m]
  abort "the configuration reload deployment plan is missing" unless target_source
  actual_targets = target_source.scan(/fileName: "([^"]+)", versionKey: "([^"]+)"/)
  expected_targets = [
    ["default.yaml", "config_version"],
    ["linnet_en.schema.yaml", "schema/version"],
    ["linnet_zh.schema.yaml", "schema/version"],
    ["linnet_zh_pinyin.schema.yaml", "schema/version"],
    ["linnet_zh_flypy.schema.yaml", "schema/version"],
    ["linnet_zh_mspy.schema.yaml", "schema/version"],
    ["linnet_zh_sogou.schema.yaml", "schema/version"],
    ["linnet_zh_abc.schema.yaml", "schema/version"],
    ["linnet_zh_ziguang.schema.yaml", "schema/version"],
    ["linnet_zh_jiajia.schema.yaml", "schema/version"],
    ["squirrel.yaml", "config_version"],
  ]
  abort "configuration reload must deploy the exact 11 files in canonical order" unless
    actual_targets == expected_targets
  deployment = host[/private func deployConfigurationReloadTargets\(\).*?\n  \}/m]
  abort "the exact reload deployment owner is missing" unless deployment
  abort "the reload deployment owner does not use the direct public config API" unless
    deployment.scan("rimeAPI.deploy_config_file").length == 1
  reload_owner = activation + deployment
  %w[shutdownRime setupRime startReadyRuntime start_maintenance
     join_maintenance_thread finalize deploy_schema].each do |forbidden|
    abort "configuration reload crossed the #{forbidden} boundary" if
      reload_owner.include?(forbidden)
  end
  abort "configuration reload bypasses canonical session invalidation" unless
    activation.scan("invalidateRimeSessions()").length == 1
  abort "configuration reload regained a second commit/suspension owner" if
    activation.include?("commitComposition") ||
      activation.include?("isRimeInputSuspended = true")
  abort "configuration reload can publish success before fresh-schema validation" unless
    activation.include?("LinnetSettingsDocumentStore.snapshot(from: live)") &&
      activation.include?("settingsSnapshot.document.input.chineseProfile") &&
      activation.include?("rimeAPI.get_current_schema") &&
      activation.include?("activeSchemaID == selectedProfile.schemaID")
  abort "configuration reload inferred intent from its own compiled output" if
    activation.include?("ChineseProfile(schemaID:") ||
      activation.include?("linnet_mode_switch/chinese_schema")

  coordinator = File.read("sources/LinnetSettings/SettingsDataCoordinator.swift")
  apply = coordinator[/private func applyConfiguration\(.*?\n  \}\n\n  \/\/\/ Lightweight appearance apply/m]
  appearance = coordinator[/private func applyAppearance\(.*?\n  \}\n\n  private func stageConfigurationCandidate/m]
  stage = coordinator[/private func stageConfigurationCandidate\(.*?\n  \}\n\n  private func restoreConfigurationRuntime/m]
  abort "configuration-only Settings owner is missing" unless apply
  abort "the shared typed configuration candidate boundary is missing" unless
    appearance && stage &&
      apply.scan("stageConfigurationCandidate(").length == 1 &&
      appearance.scan("stageConfigurationCandidate(").length == 1 &&
      stage.scan("LinnetSettingsDocumentStore.write(").length == 1
  forbidden_quick_writes = ["writePersonalFiles(", "writeRuntimeSettings(",
    "LinnetSettingsProjectionRenderer.reconcile(", "OwnedFileSnapshot"]
  abort "a quick Settings path still mutates live-derived files" if
    forbidden_quick_writes.any? { |needle| apply.include?(needle) || appearance.include?(needle) }
  abort "configuration-only apply must issue one Host-owned reload" unless
    apply.scan("reloadConfigurationRuntime(").length == 1 &&
      apply.scan("restoreConfigurationRuntime(").length == 1
  abort "appearance apply must issue one Host-owned refresh" unless
    appearance.scan("refreshAppearanceRuntime(").length == 1 &&
      appearance.scan("restoreConfigurationRuntime(").length == 1
  abort "the retired Settings per-file rollback owner returned" if
    coordinator.include?("struct OwnedFileSnapshot") ||
      coordinator.include?("restoreOwnedFiles(")

  personal = File.read("sources/LinnetSettings/PersonalDataStore.swift")
  abort "runtime settings are not a standard custom patch" unless
    personal.include?(%q{static let userSettingsFile = "linnet_user.custom.yaml"}) &&
      personal.include?(%q{static let legacyUserSettingsFile = "linnet_user.yaml"}) &&
      personal.scan(/static func writePersonalFiles\(/).length == 1 &&
      personal.scan(/static func writeRuntimeSettings\(/).length == 1 &&
      personal.scan(/static func writeBackupNormalization\(/).length == 1
  runtime_writer = personal[/static func writeRuntimeSettings\(.*?\n  \}/m]
  abort "the personal runtime writer is missing" unless runtime_writer
  abort "document-owned English behavior returned to the personal patch" if
    runtime_writer.include?("sentenceCapitalization") ||
      runtime_writer.include?("tabBehavior")

  renderer = File.read("sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift")
  abort "document-owned English behavior is no longer projected to schemas" unless
    renderer.include?(%q{"linnet_english_interaction/sentence_capitalization"}) &&
      renderer.include?(%q{"linnet_english_interaction/tab_behavior"})
  abort "the retired projection writer returned" if renderer.include?("writeProjections(")

  backup = File.read("sources/LinnetSettings/LinnetBackupStore.swift")
  abort "backup normalization has more than one caller" unless
    backup.scan("writeBackupNormalization(").length == 1
  mutate = coordinator[/private func mutate\(.*?\n  \}\n\n  private func diagnose/m]
  abort "candidate materialization owner is missing" unless mutate
  abort "candidate materialization must write personal and runtime settings exactly once" unless
    mutate.scan("LinnetPersonalDataStore.writePersonalFiles(").length == 1 &&
      mutate.scan("LinnetPersonalDataStore.writeRuntimeSettings(").length == 1 &&
      mutate.scan("LinnetSettingsProjectionRenderer.reconcile(").length == 1
' || fail "configuration apply/reload and runtime writer ownership regressed"
if rg -n 'removeObserver\(self\)' sources/SquirrelApplicationDelegate.swift; then
  fail "block observers are still incorrectly removed by delegate identity"
fi
test "$(rg -c '\[weak self\]' sources/SquirrelApplicationDelegate.swift)" -ge 4 ||
  fail "Host callback observers regained a strong delegate capture"

if rg -n \
  'LaunchAgents|LaunchDaemons|SMAppService|ServiceManagement|SMLoginItem|privileged helper|/usr/local/|/opt/' \
  "${production[@]}"; then
  fail "a forbidden persistent runtime path or service was introduced"
fi

if rg -n '~/Library/Linnet|Library/Linnet|\.DataTransactions|sharedSupportPath|Contents/SharedSupport.*gram|userDir.*\.gram' \
  sources; then
  fail "a retired runtime-data path or grammar fallback returned"
fi

if rg -n 'cloudSyncFolderBookmark|setCloudSyncFolderBookmark|chooseCloudSyncFolder|disconnectCloudSyncFolder|cloudSyncFolderSelected|cloudSyncDisconnected|LinnetCloudSyncLocation\.(select|resolve)' \
    sources README.md; then
  fail "the retired user-selected iCloud sync-folder path returned"
fi
rg -Fq 'component: "com~apple~CloudDocs"' \
  sources/LinnetSettings/LinnetCloudSyncLocation.swift ||
  fail "the product-owned iCloud Drive root is missing"
rg -Fq 'component: "Linnet"' \
  sources/LinnetSettings/LinnetCloudSyncLocation.swift ||
  fail "the fixed Linnet iCloud Drive directory is missing"

rg -Fq 'to: \.prebuilt_data_dir' sources/SquirrelApplicationDelegate.swift ||
  fail "librime prebuilt data is not explicit"
rg -Fq 'to: \.staging_dir' sources/SquirrelApplicationDelegate.swift ||
  fail "librime staging data is not explicit"
if rg -n 'stagePrecompiledArtifacts|configureGrammarModel' sources; then
  fail "a retired runtime copy or grammar inference path returned"
fi

# The input-method process, plugins and resources stay fully offline. The
# only sanctioned network path in the product is the user-initiated signed
# language-pack download owned by the Settings app. The complete installer
# activates Chinese, English, LTS and Extended as independent data units.
if rg -n 'URLSession|NWConnection|NWPathMonitor|CFNetwork|SUUpdater|SPUUpdater' \
  $(find sources -maxdepth 1 -type f) plugins resources; then
  fail "a runtime network or updater path was introduced"
fi

if rg -n \
  'NWConnection|NWPathMonitor|CFNetwork|SUUpdater|SPUUpdater|URLSessionWebSocketTask' \
  sources/LinnetSettings; then
  fail "the Settings network surface exceeds signed language-data downloads"
fi

settings_urlsession="$(rg -l 'URLSession' sources/LinnetSettings || true)"
[[ "${settings_urlsession}" == \
  "sources/LinnetSettings/LinnetSettingsDownloadTransport.swift" ]] ||
  fail "URLSession escaped the single Settings external-transport owner"

if rg -n 'inputRuntimePreferences|chineseProfileKey|setChineseProfile|applyPreferredChineseProfileIfIdle|rimeAPI\.select_schema' \
    sources/SquirrelApplicationDelegate.swift sources/SquirrelInputController.swift \
    sources/LinnetSettings; then
  fail "the input frontend regained a selected-schema owner outside typed Settings Apply"
fi
if rg -n "Rime's menu|Rime 菜单" \
    README.md sources/LinnetSettings resources/Localizable.xcstrings; then
  fail "user guidance still advertises the retired Rime options menu"
fi
if rg -n 'func install\(\)|afterRegistration|Thread\.sleep' sources/InputSource.swift ||
    rg -n -- '--install-input-source' sources/Main.swift package/installer-scripts/postinstall; then
  fail "a combined or delayed private input-source installation path remains"
fi
if rg -n 'struct Source|sourceProvider|registerInputSource:' sources/InputSource.swift; then
  fail "a test-only adapter remains between the input lifecycle owner and HIToolbox"
fi
rg -Fq -- '--register-input-source' sources/Main.swift ||
  fail "install-boundary input-source registration command is missing"
if rg -n -- '--activate-input-source|--select-input-source|--disable-input-source|--refresh-core-input-source' \
    sources/Main.swift package/installer-scripts; then
  fail "Installer regained an activation, selection, disablement, or refresh command"
fi
test "$(rg -F -c -- '"${executable}" --register-input-source' \
  package/installer-scripts/postinstall)" = 1 ||
  fail "postinstall no longer ensures the installed input source exactly once"
rg -Fq 'if [[ "${install_mode}" == complete ]]' \
  package/installer-scripts/postinstall ||
  fail "input-source registration escaped the Complete-only boundary"
if rg -n -- '--quit-host-clean' sources/Main.swift package/installer-scripts; then
  fail "Core update regained a live InputMethodKit Host termination path"
fi
test "$(rg -F -c -- 'scripts/unregister-local-apps' Makefile)" = 1 ||
  fail "local App registration cleanup has multiple Makefile owners"
test "$(rg -F -c -- '"$${local_app_cleanup}" "$${products_root}"' Makefile)" = 2 ||
  fail "local builds do not clean exact App registrations on success and failure"
if rg -n 'REGISTER_WITH_LAUNCH_SERVICES|launch_services_register|unregister_local_builds|lsregister' \
    Makefile; then
  fail "local builds regained an ineffective or duplicated registration owner"
fi
[[ -x scripts/unregister-local-apps ]] ||
  fail "the local App registration cleanup owner is not executable"
rg -Fq '[[ "${products_root}" == /*/Build/Products' scripts/unregister-local-apps ||
  fail "local App cleanup lost its Build/Products boundary"
rg -Fq 'grep -Fqx -- "${app}"' scripts/unregister-local-apps ||
  fail "local App cleanup does not verify final LaunchServices state"
rg -Fq '"${lsregister}" -u -R "${app}"' scripts/unregister-local-apps ||
  fail "local App cleanup is not symmetric with Xcode recursive registration"
rg -Fq 'for pass in 1 2' scripts/unregister-local-apps &&
  rg -Fq '[[ "${pass}" -eq 2 ]] || sleep 1' scripts/unregister-local-apps ||
  fail "local App cleanup does not retire delayed embedded registrations"
rg -Fq 'unregister_fixture_apps' tests/verify_visible_settings_fixture.sh ||
  fail "Settings UI tests can leave fixture Apps registered with LaunchServices"
# The live Rime session is the sole mode owner. Do not restore the locally
# invented cross-process CLI/notification bridge that duplicated it and failed
# even while an InputMethodKit session was active.
if rg -n -- '--ascii|--nascii|--getascii|asciiModeToggleNotification|asciiModeQueryNotification|asciiModeResponseNotification|setASCIIModeNotification|reportASCIIModeNotification|LinnetToggleASCIIModeNotification|LinnetGetASCIIModeNotification|LinnetASCIIModeResponse|LinnetSetASCIIModeNotification|LinnetReportASCIIModeNotification' \
    sources README.md; then
  fail "a non-upstream cross-process ASCII mode bridge returned"
fi
rg -Fq 'applyStatusIcon(asciiMode: false, schemaLabel: nil)' \
  sources/SquirrelApplicationPresentation.swift ||
  fail "status initialization is not derived from the standard live Rime state"
if rg -n 'schemaLabel: "双"|asciiMode \? "EN"' \
    sources/SquirrelApplicationDelegate.swift \
    sources/SquirrelApplicationPresentation.swift; then
  fail "the status item retains a hard-coded or ambiguous language state"
fi
if rg -n 'NSLocalizedString\("Deploy"|NSLocalizedString\("Logs\.\.\."|#selector\(deploy\)|openLogFolder' \
    sources/SquirrelApplicationDelegate.swift \
    sources/SquirrelApplicationPresentation.swift \
    sources/SquirrelInputController.swift; then
  fail "maintenance-only Deploy or Logs actions returned to the user input menu"
fi
rg -Fq 'selection: $model.configuration.documentDraft.input.chineseProfile' \
  sources/LinnetSettings/SettingsViews.swift ||
  fail "Settings lost the sole Chinese-profile picker"
if rg -n 'LinnetSettingsDocumentStore\.load\(from: candidate\).*chineseProfile|selectedChineseProfile' \
    sources/LinnetSettings/RimeUserDataBridge.swift; then
  fail "candidate smoke deployment regained selected-profile ordering side effects"
fi
rg -Fq 'fix_schema_list_order: true' data/linnet/default.yaml ||
  fail "fresh sessions can still defer to stale user.yaml schema selection"
rg -Fq 'renderDefaultCustom(' sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift ||
  fail "the document-selected Chinese profile lost its default-config projection"
rg -Fq -- '-DENABLE_TIMESTAMP=OFF' scripts/build-rime-runtime ||
  fail "same-second targeted config reloads can be skipped by timestamp comparison"
if rg -n 'LookupPinyin\(normalized\)' plugins/smart_english/smart_english.cc; then
  fail "Smart English regained its fixed raw-full-pinyin lookup path"
fi
rg -Fq 'Ticket(engine_, "linnet_pinyin")' plugins/smart_english/smart_english.cc ||
  fail "Smart English stopped decoding pinyin through its selected Prism namespace"
if rg -n 'F4|Control\+grave|Control\+Shift\+grave' data/linnet/default.yaml; then
  fail "the product switcher regained global system-key hotkeys"
fi
rg -Fq 'rimeAPI.commit_raw_input(session)' \
  sources/SquirrelInputController.swift ||
  fail "the Rime-owned raw composition exit is missing"
if rg -n 'commit\(string: pendingInput\)|commit\(string: String\(cString: input\)\)' \
    sources/SquirrelInputController.swift; then
  fail "the InputMethodKit boundary regained a second raw reconstruction owner"
fi

# SquirrelPanel alone owns the lifetime of a visible mode transition. Passive
# empty Rime updates must reach that owner instead of bypassing its status timer.
if ruby -e '
  source = File.read(ARGV.fetch(0))
  abort if source.match?(/if preedit\.isEmpty,\s*\n\s*candidateSnapshot\.items\.isEmpty,\s*\n\s*!presentsModeTransition \{\s*\n\s*_ = rimeAPI\.free_context\(&ctx\)\s*\n\s*hidePalettes\(\)/m)
' sources/SquirrelInputController.swift; then
  :
else
  fail "the controller still hides a timed mode transition on an empty Rime update"
fi
rg -Fq 'else if statusTimer == nil {' sources/SquirrelPanel.swift ||
  fail "the candidate panel lost timed mode-transition retention"
rg -Fq 'func handlePassiveEmptyUpdate(' sources/SquirrelPanel.swift ||
  fail "passive empty updates no longer defer to the candidate panel"

# The Settings process owns activation of its own window. Reopening Settings
# must never depend on cross-process window inference in the input-method host.
rg -Fq 'applicationShouldHandleReopen' \
  sources/LinnetSettings/SettingsApplication.swift ||
  fail "Settings lost its reopen activation owner"
rg -Fq 'makeKeyAndOrderFront' sources/LinnetSettings/SettingsApplication.swift ||
  fail "Settings no longer brings its window to the front"

# Per-application Rime options remain in Squirrel's canonical session owner.
# Do not defer or reinterpret that lifecycle through a Linnet transition layer.
test "$(rg -F -o 'func updateAppOptions()' \
  sources/SquirrelInputController.swift \
  sources/SquirrelInputController+RimeSession.swift | wc -l | tr -d ' ')" -eq 1 ||
  fail "upstream Squirrel app-option owner is missing"
if rg -n 'transitionApplication|replacingSession' \
    sources/SquirrelInputController.swift \
    sources/SquirrelInputController+RimeSession.swift; then
  fail "a private application-transition policy returned"
fi
test "$(rg -F -o 'updateAppOptions()' \
  sources/SquirrelInputController.swift \
  sources/SquirrelInputController+RimeSession.swift | wc -l | tr -d ' ')" -eq 3 ||
  fail "Squirrel app options no longer flow through create-session and app-change events"

if rg -n 'JSON\.parse\(File\.read' scripts/build-rime-runtime; then
  fail "the deterministic C-locale runtime build still parses UTF-8 locks as US-ASCII"
fi
test "$(rg -F -c 'force_encoding(Encoding::UTF_8)' \
  scripts/build-rime-runtime)" -eq 4 ||
  fail "runtime lock readers do not own an explicit UTF-8 boundary"

ruby -e '
  source = File.read(ARGV.fetch(0))
  owner = source[/^materialize_git\(\) \{.*?^\}/m]
  abort "locked Git cache owner is missing" unless owner
  probe = owner.index(%q{git -C "${directory}" cat-file -e "${commit}^{commit}"})
  fetch = owner.index(%q{run git -C "${directory}" fetch --no-tags --depth=1})
  abort "a verified locked commit still triggers an upstream fetch" unless
    probe && fetch && probe < fetch &&
      owner.include?(%q{if ! git -C "${directory}" cat-file -e})
' scripts/build-rime-runtime ||
  fail "locked Git sources are not cache-first"

echo "Linnet runtime footprint: PASS (one registry, immutable Active data, separate mutable roots)"
