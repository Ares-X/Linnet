// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include <rime/algo/algebra.h>
#include <rime/algo/syllabifier.h>
#include <rime/candidate.h>
#include <rime/composition.h>
#include <rime/config.h>
#include <rime/context.h>
#include <rime/dict/dictionary.h>
#include <rime/engine.h>
#include <rime/filter.h>
#include <rime/gear/selector.h>
#include <rime/gear/translator_commons.h>
#include <rime/key_event.h>
#include <rime/language.h>
#include <rime/menu.h>
#include <rime/predict/predict_engine.h>
#include <rime/processor.h>
#include <rime/registry.h>
#include <rime/schema.h>
#include <rime/segmentation.h>
#include <rime/translation.h>
#include <rime/translator.h>
#include <rime_api.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <functional>
#include <limits>
#include <memory>
#include <set>
#include <sstream>
#include <tuple>
#include <unordered_set>
#include <utility>
#include <vector>

#include "smart_english_domain.h"
#include "smart_english_filter.h"
#include "smart_english_index.h"

namespace linnet {
namespace {

using namespace rime;
using namespace smart_english_domain;

constexpr char kSuppressFollowingSpaceProperty[] = "linnet/suppress_following_space_v1",
               kPredictionNavigationProperty[] = "linnet/prediction_navigation_v1",
               kModeReturnSchemaProperty[] = "linnet/mode_return_schema_v1",
               kCandidateExpansionRequestProperty[] =
                   "linnet/candidate_expansion_request_v1";
constexpr std::size_t kPinyinKeyLimit = 64,
                      kPinyinInputByteLimit = 96,
                      kPinyinTraversalLimit = 4096;
constexpr double kRawTransportPriority = 1000.0;
// Table completion quality is exp(weight) - 1, so -2 keeps pinyin behind every
// ordinary completion while remaining well above Rime's raw echo fallback.
constexpr double kPinyinTransportPriority = -2.0;

string NormalizeDisabledValue(string value, bool strip_spacing_projection) {
  if (strip_spacing_projection && !value.empty() && value.front() == ' ') value.erase(value.begin());
  for (char& byte : value) if (byte >= 'A' && byte <= 'Z') byte = static_cast<char>(std::tolower(static_cast<unsigned char>(byte)));
  return value;
}

bool IsDisabledSegment(const Segment* segment) {
  return segment && !segment->HasTag("zz_code_token") && !segment->HasTag("text_expander") && (segment->HasTag("abc") || segment->HasTag("zz_english") || segment->HasTag("linnet_pinyin") || segment->HasTag("prediction"));
}

bool IsOrdinarySegment(const Segment& segment) { return segment.HasTag("abc") && !segment.HasTag("zz_code_token") && !segment.HasTag("text_expander") && !segment.HasTag("linnet_pinyin"); }

bool IsSmartEnglishCandidate(const Segment& segment, const an<Candidate>& candidate) {
  return candidate && candidate->start() == segment.start && candidate->end() == segment.end && !segment.HasTag("zz_code_token") &&
         !segment.HasTag("text_expander") && !segment.HasTag("linnet_pinyin") && IsSmartEnglishCandidateOrigin(candidate);
}

void SetSentenceBoundary(Context* context, bool observed) {
  if (context) context->set_property(kSentenceBoundaryProperty, observed ? "1" : "");
}

bool IsSentenceEndingPunctuation(char punctuation) { return punctuation == '.' || punctuation == '!' || punctuation == '?'; }

void ClearPredictionContext(Context* context,
                            const an<PredictEngine>& predict_engine) {
  if (!context) return;
  context->set_property(kPredictionNavigationProperty, "");
  context->set_property(rime::predict::kContextProperty, "");
  if (predict_engine) predict_engine->Clear(context);
}

void ResetContinuationState(Context* context,
                            const an<PredictEngine>& predict_engine) {
  if (!context) return;
  ClearPredictionContext(context, predict_engine);
  context->set_property(kSpacingProperty, "");
  SetSentenceBoundary(context, false);
  context->set_property(kSuppressFollowingSpaceProperty, "");
  context->set_property(kCandidateExpansionRequestProperty, "");
}

char ShiftedAscii(char key) {
  static const string kNormal = "`1234567890-=[]\\;',./";
  static const string kShifted = "~!@#$%^&*()_+{}|:\"<>?";
  const auto position = kNormal.find(key);
  return position == string::npos ? key : kShifted[position];
}

bool IsModifierKey(int keycode) {
  return keycode == XK_Shift_L || keycode == XK_Shift_R || keycode == XK_Control_L || keycode == XK_Control_R || keycode == XK_Alt_L || keycode == XK_Alt_R || keycode == XK_Super_L || keycode == XK_Super_R || keycode == XK_Caps_Lock;
}

bool HasHostShortcutModifier(const KeyEvent& key) {
  return (key.modifier() &
          (kControlMask | kAltMask | kSuperMask | kMetaMask | kHyperMask)) !=
         0;
}

// `ascii_composer` immediately precedes this processor and remains the sole
// owner of Shift tap/chord/hold classification and raw-code commit policy.
// A true ascii_mode on Shift release therefore means librime accepted one
// isolated Shift tap. Linnet maps only that accepted transition to its Smart
// English schema; Caps Lock remains the explicit raw-ASCII path.
class ModeSwitchProcessor : public Processor {
 public:
  explicit ModeSwitchProcessor(const Ticket& ticket)
      : Processor(ticket),
        predict_engine_(PredictEngineComponent::Shared()->GetInstance(ticket)) {
    if (ticket.schema) {
      ticket.schema->config()->GetString(
          "linnet_mode_switch/chinese_schema", &direct_chinese_schema_);
    }
    if (direct_chinese_schema_ == kSmartEnglishSchema) {
      direct_chinese_schema_.clear();
    }
  }

  ProcessResult ProcessKeyEvent(const KeyEvent& key) override {
    if (!engine_ || !key.release() ||
        (key.keycode() != XK_Shift_L && key.keycode() != XK_Shift_R)) {
      return kNoop;
    }
    Context* context = engine_->context();
    if (!context || !context->get_option("ascii_mode")) return kNoop;
    const string current_schema = engine_->schema()->schema_id();
    string return_schema;
    if (current_schema == kSmartEnglishSchema) {
      return_schema = context->get_property(kModeReturnSchemaProperty);
      if (return_schema.empty() || return_schema == kSmartEnglishSchema) {
        return_schema = direct_chinese_schema_;
      }
      if (return_schema.empty()) return kNoop;
    }

    // Do not expose ascii_composer's transient classification state after the
    // schema change. Each context owns its paired Chinese return identity;
    // process-global schema history must not couple simultaneous sessions.
    context->set_option("ascii_mode", false);
    ResetContinuationState(context, predict_engine_);
    if (current_schema == kSmartEnglishSchema) {
      context->set_property(kModeReturnSchemaProperty, "");
      engine_->ApplySchema(new Schema(return_schema));
    } else {
      context->set_property(kModeReturnSchemaProperty, current_schema);
      engine_->ApplySchema(new Schema(kSmartEnglishSchema));
    }
    return kAccepted;
  }

 private:
  const an<PredictEngine> predict_engine_;
  string direct_chinese_schema_;
};

bool IsEditBoundary(int keycode) {
  switch (keycode) {
    case XK_BackSpace: case XK_Delete: case XK_Return: case XK_Tab:
    case XK_Left: case XK_Right: case XK_Up: case XK_Down:
    case XK_Home: case XK_End: case XK_Page_Up: case XK_Page_Down:
      return true;
    default:
      return false;
  }
}

void ApplyPunctuation(char punctuation, SpacingState* state) {
  if (!state) return;
  switch (punctuation) {
    case ',': case ';': case ':': case '.': case '!': case '?':
    case ')': case ']': case '}':
      state->spaced = true;
      break;
    case '(': case '[': case '{':
      state->spaced = false;
      break;
    case '\'':
      state->spaced = state->single_quote_open;
      state->single_quote_open = !state->single_quote_open;
      break;
    case '"':
      state->spaced = state->double_quote_open;
      state->double_quote_open = !state->double_quote_open;
      break;
    default:
      state->spaced = false;
      state->single_quote_open = false;
      state->double_quote_open = false;
      break;
  }
}

bool IsForcedRawOnlySegment(Segment& segment) {
  const an<Menu> menu = segment.menu;
  return menu && menu->Prepare(2) == 1 &&
         IsForcedRawCandidate(menu->GetCandidateAt(0));
}

bool IsRawLikeSegment(Segment& segment) {
  return segment.HasTag("raw") || segment.HasTag("zz_code_token") ||
         segment.HasTag("text_expander") || segment.HasTag("punct_number") ||
         IsForcedRawOnlySegment(segment);
}

bool IsAsciiLetterKey(int keycode) {
  return (keycode >= 'a' && keycode <= 'z') ||
         (keycode >= 'A' && keycode <= 'Z');
}

bool ContinuesPredictionContext(int keycode) {
  return IsAsciiLetterKey(keycode) || keycode == XK_apostrophe ||
         keycode == XK_slash || keycode == XK_semicolon ||
         keycode == XK_asciitilde;
}

// Linnet owns selection validity, menu-bounded printable paging, Tab, raw-caret,
// and passive-prediction state before Rime Predictor/Selector/Navigator. Stock
// Selector/Navigator remain the sole owners of ordinary candidate and
// spelling-arrow movement.
class LinnetInteractionProcessor : public Processor {
 public:
  explicit LinnetInteractionProcessor(const Ticket& ticket)
      : Processor(ticket),
        prediction_selector_(ticket),
        schema_id_(ticket.schema ? ticket.schema->schema_id() : string()),
        options_(InteractionOptions::Load(ticket.schema)),
        predict_engine_(
            PredictEngineComponent::Shared()->GetInstance(ticket)) {
    if (engine_ && engine_->context()) {
      abort_connection_ = engine_->context()->abort_notifier().connect(
          [this](Context* context) { OnAbort(context); });
      unhandled_connection_ =
          engine_->context()->unhandled_key_notifier().connect(
              [this](Context* context, const KeyEvent& key) {
                OnUnhandledKey(context, key);
              });
    }
  }

  ~LinnetInteractionProcessor() override {
    abort_connection_.disconnect();
    unhandled_connection_.disconnect();
  }

  ProcessResult ProcessKeyEvent(const KeyEvent& key) override {
    if (!engine_ || key.release()) return kNoop;
    Context* context = engine_->context();
    if (!context) return kNoop;

    // These chords belong to the client application. Reject them before any
    // prediction, candidate, navigator or editor policy can consume the key
    // or mutate the composition on its way back to the host.
    if (HasHostShortcutModifier(key)) {
      HardStop(context);
      return kRejected;
    }
    // librime's Editor reports Delete as handled even when the spelling caret
    // is already at the trailing boundary and DeleteInput changes nothing.
    // Return that no-op to the client; an interior Delete still reaches the
    // sole editor owner below.
    if (key.keycode() == XK_Delete && IsPlainKey(key) &&
        !context->composition().empty() && !context->input().empty() &&
        context->caret_pos() >= context->input().size()) {
      return kRejected;
    }

    if (!context->composition().empty() &&
        context->composition().back().HasTag("prediction")) {
      return ProcessPrediction(context, key);
    }
    const ProcessResult printable_paging =
        ProcessPrintablePagingKey(context, key);
    if (printable_paging != kNoop) return printable_paging;
    if (key.keycode() == XK_Tab) return ProcessTab(context, key);

    if (!context->composition().empty()) {
      Segment& segment = context->composition().back();
      const bool forced_raw_only = IsForcedRawOnlySegment(segment);
      if (IsRawLikeSegment(segment)) {
        const ProcessResult raw_navigation =
            ProcessRawNavigation(context, key);
        if (raw_navigation != kNoop) return raw_navigation;
        if (forced_raw_only && SelectionIndex(key) >= 0) return kRejected;
      } else {
        const ProcessResult selection = ProcessSelectionKey(context, key);
        if (selection != kNoop) return selection;
        const int keycode = key.keycode();
        const bool unconfigured_digit =
            (keycode >= XK_0 && keycode <= XK_9) ||
            (keycode >= XK_KP_0 && keycode <= XK_KP_9);
        if (IsPlainKey(key) && unconfigured_digit) {
          CommitCurrentSelection(context, PostCommitPrediction::kDismiss,
                                 false);
          return kRejected;
        }
      }
    }

    if (schema_id_ == kSmartEnglishSchema &&
        key.keycode() == XK_space &&
        IsPlainKey(key)) {
      return CommitSpaceSelection(context, PostCommitPrediction::kPreserve);
    }
    if (schema_id_ == kSmartEnglishSchema &&
        key.keycode() == XK_Return && IsPlainKey(key)) {
      return CommitCurrentSelection(context, PostCommitPrediction::kDismiss,
                                    false)
                 ? kAccepted
                 : kRejected;
    }

    if (IsEditBoundary(key.keycode())) {
      SetSentenceBoundary(context, false);
    }
    return kNoop;
  }

 private:
  enum class PostCommitPrediction { kPreserve, kDismiss };

  ProcessResult CommitSpaceSelection(
      Context* context, PostCommitPrediction prediction) const {
    if (!CommitCurrentSelection(context, prediction,
                                options_.space_adds_trailing_space)) {
      return kRejected;
    }
    if (options_.space_adds_trailing_space) {
      // Session::OnCommit concatenates both sink writes from this key event,
      // so the client receives the selected candidate and its boundary now.
      engine_->CommitText(" ");
    }
    return kAccepted;
  }

  bool IsPlainKey(const KeyEvent& key) const {
    return (key.modifier() & ~kLockMask) == 0;
  }

  bool HasPredictionSegment(const Context* context) const {
    return context && !context->composition().empty() &&
           context->composition().back().HasTag("prediction");
  }

  ProcessResult ProcessPrintablePagingKey(Context* context,
                                          const KeyEvent& key) const {
    if (!IsPlainKey(key)) return kNoop;
    const bool previous =
        key.keycode() == XK_bracketleft || key.keycode() == XK_minus;
    const bool next =
        key.keycode() == XK_bracketright || key.keycode() == XK_equal;
    if (!previous && !next) return kNoop;
    // A paging symbol owns the key only when it can move to a real adjacent
    // page. Every boundary case stays on the normal punctuation/input path.
    if (!context || context->composition().empty()) return kNoop;

    Segment& segment = context->composition().back();
    if (!segment.menu || IsRawLikeSegment(segment) || !engine_->schema()) {
      return kNoop;
    }
    const int page_size = engine_->schema()->page_size();
    if (page_size <= 0) return kNoop;
    const size_t selected = segment.selected_index;
    size_t target = 0;
    if (previous) {
      if (selected < static_cast<size_t>(page_size)) return kNoop;
      target = selected - static_cast<size_t>(page_size);
    } else {
      const size_t page_start =
          (selected / static_cast<size_t>(page_size)) *
          static_cast<size_t>(page_size);
      const size_t next_page_start = page_start + page_size;
      const int candidate_count =
          segment.menu->Prepare(next_page_start + page_size);
      if (candidate_count <= static_cast<int>(next_page_start)) {
        return kNoop;
      }
      target = (std::min)(selected + static_cast<size_t>(page_size),
                          static_cast<size_t>(candidate_count - 1));
    }
    context->Highlight(target);
    segment.tags.insert("paging");
    context->set_property(kCandidateExpansionRequestProperty, "1");
    return kAccepted;
  }

  void HardStop(Context* context) const {
    ResetContinuationState(context, predict_engine_);
    if (HasPredictionSegment(context)) context->Clear();
  }

  void RemovePredictionProjection(Context* context) const {
    if (!context) return;
    context->set_property(kPredictionNavigationProperty, "");
    if (predict_engine_) predict_engine_->Clear(context);
    if (HasPredictionSegment(context)) context->Clear();
  }

  ProcessResult ProcessPrediction(Context* context, const KeyEvent& key) {
    const bool focused =
        context->get_property(kPredictionNavigationProperty) == "1";
    if (focused && IsPlainKey(key) && key.keycode() == XK_space) {
      context->set_property(kPredictionNavigationProperty, "");
      return CommitSpaceSelection(context, PostCommitPrediction::kPreserve);
    }
    if (focused && IsPlainKey(key) && key.keycode() == XK_Return) {
      context->set_property(kPredictionNavigationProperty, "");
      return CommitCurrentSelection(context, PostCommitPrediction::kDismiss,
                                    false)
                 ? kAccepted
                 : kRejected;
    }
    if (key.keycode() == XK_Tab) return ProcessTab(context, key);
    const int selection_index = SelectionIndex(key);
    if (selection_index >= 0) {
      const ProcessResult selection = ProcessSelectionKey(context, key);
      if (selection == kAccepted) return selection;
      HardStop(context);
      return kRejected;
    }
    if (IsPlainKey(key) &&
        (key.keycode() == XK_Left || key.keycode() == XK_Right ||
         key.keycode() == XK_Up || key.keycode() == XK_Down)) {
      return ProcessPredictionArrow(context, key);
    }
    // ascii_composer precedes this owner and, on an isolated Shift release,
    // confirms any remaining composition before the schema switch runs. Drop
    // the passive projection on Shift down so neither a tap nor an uppercase
    // chord can implicitly commit its first suggestion.
    if (key.keycode() == XK_Shift_L || key.keycode() == XK_Shift_R) {
      RemovePredictionProjection(context);
      return kNoop;
    }
    if (IsModifierKey(key.keycode())) return kNoop;
    if (ContinuesPredictionContext(key.keycode()) &&
        (key.modifier() & ~(kShiftMask | kLockMask)) == 0) {
      RemovePredictionProjection(context);
      return kNoop;
    }

    const bool is_space = key.keycode() == XK_space && IsPlainKey(key);
    const bool use_chinese_punctuator =
        schema_id_ != kSmartEnglishSchema && key.keycode() >= 0x21 &&
        key.keycode() <= 0x7e &&
        (key.modifier() & ~(kShiftMask | kLockMask)) == 0;
    if (is_space) {
      HardStop(context);
      engine_->CommitText(" ");
      return kAccepted;
    }
    if (key.keycode() == XK_Escape && IsPlainKey(key)) {
      HardStop(context);
      return kAccepted;
    }
    if (use_chinese_punctuator) {
      HardStop(context);
      return kNoop;
    }

    // This key will reach Context::unhandled_key_notifier().  Remove only the
    // zero-prefix projection here; its callback below owns whether the key is
    // punctuation (preserve quote/spacing state) or a hard boundary.
    RemovePredictionProjection(context);
    return kRejected;
  }

  ProcessResult ProcessRawNavigation(Context* context,
                                     const KeyEvent& key) const {
    if (!IsPlainKey(key)) return kNoop;
    const size_t caret = context->caret_pos();
    size_t target = caret;
    switch (key.keycode()) {
      case XK_Left:
        if (caret == 0) return kRejected;
        target = caret - 1;
        break;
      case XK_Right:
        if (caret >= context->input().size()) return kRejected;
        target = caret + 1;
        break;
      case XK_Home:
        if (caret == 0) return kRejected;
        target = 0;
        break;
      case XK_End:
        if (caret >= context->input().size()) return kRejected;
        target = context->input().size();
        break;
      case XK_Up:
      case XK_Down:
      case XK_Page_Up:
      case XK_Page_Down:
        return kRejected;
      default:
        return kNoop;
    }
    context->BeginEditing();
    context->set_caret_pos(target);
    return kAccepted;
  }

  ProcessResult ProcessPredictionArrow(Context* context,
                                       const KeyEvent& key) {
    if (!context || context->composition().empty()) return kRejected;
    const size_t selected = context->composition().back().selected_index;
    const ProcessResult result = prediction_selector_.ProcessKeyEvent(key);
    if (result != kAccepted || context->composition().empty() ||
        context->composition().back().selected_index == selected) {
      HardStop(context);
      return kRejected;
    }
    context->set_property(kPredictionNavigationProperty, "1");
    return kAccepted;
  }

  ProcessResult ProcessTab(Context* context, const KeyEvent& key) {
    const int modifiers = key.modifier() & ~kLockMask;
    const bool reverse = modifiers == kShiftMask;
    const bool prediction = HasPredictionSegment(context);
    if (modifiers != 0 && !reverse) {
      if (prediction) {
        HardStop(context);
      } else {
        ResetContinuationState(context, predict_engine_);
      }
      return kRejected;
    }
    if (context->composition().empty()) {
      ResetContinuationState(context, predict_engine_);
      return kRejected;
    }
    Segment& segment = context->composition().back();
    const an<Menu> menu = segment.menu;
    if (IsRawLikeSegment(segment) || !menu || !menu->GetCandidateAt(0) ||
        options_.tab_behavior == TabBehavior::kPass) {
      if (prediction) {
        HardStop(context);
      } else {
        ResetContinuationState(context, predict_engine_);
      }
      return kRejected;
    }

    if (options_.tab_behavior == TabBehavior::kNavigate ||
        schema_id_ != kSmartEnglishSchema) {
      if (!NavigateCandidate(context, reverse)) {
        if (prediction) HardStop(context);
        return kRejected;
      }
      if (prediction) {
        context->set_property(kPredictionNavigationProperty, "1");
      }
      return kAccepted;
    }
    if (reverse) {
      if (prediction) {
        HardStop(context);
      } else {
        ResetContinuationState(context, predict_engine_);
      }
      return kRejected;
    }
    return CommitSmartCandidate(context) ? kAccepted : kRejected;
  }

  bool NavigateCandidate(Context* context, bool reverse) const {
    if (!context || context->composition().empty()) return false;
    Segment& segment = context->composition().back();
    const an<Menu> menu = segment.menu;
    if (!menu || !menu->GetCandidateAt(segment.selected_index)) return false;
    const size_t selected = segment.selected_index;
    if (reverse) {
      if (selected == 0) return false;
      context->Highlight(selected - 1);
      return true;
    }
    if (selected >= static_cast<size_t>(std::numeric_limits<int>::max() - 1)) {
      return false;
    }
    const size_t target = selected + 1;
    if (!menu->GetCandidateAt(target)) return false;
    context->Highlight(target);
    return true;
  }

  bool CommitSmartCandidate(Context* context) const {
    if (!context || context->composition().empty()) return false;
    Segment& segment = context->composition().back();
    if (!segment.menu) return false;
    size_t target = segment.selected_index;
    if (!IsSmartEnglishCandidate(segment, segment.menu->GetCandidateAt(target))) {
      const size_t count = segment.menu->Prepare(kCandidateLimit);
      target = count;
      for (size_t index = 0; index < count; ++index) {
        if (IsSmartEnglishCandidate(segment,
                                    segment.menu->GetCandidateAt(index))) {
          target = index;
          break;
        }
      }
      if (target == count) return false;
    }
    context->Highlight(target);
    return CommitCurrentSelection(context, PostCommitPrediction::kPreserve,
                                  false);
  }

  bool CommitCurrentSelection(Context* context,
                              PostCommitPrediction prediction,
                              bool trailing_space) const {
    if (!context || context->composition().empty()) return false;
    Segment& segment = context->composition().back();
    const an<Menu> menu = segment.menu;
    if (!menu || !menu->GetCandidateAt(segment.selected_index)) return false;
    context->set_property(kSuppressFollowingSpaceProperty,
                          trailing_space ? "1" : "");
    if (!context->ConfirmCurrentSelection()) {
      context->set_property(kSuppressFollowingSpaceProperty, "");
      return false;
    }
    // ExpressEditor auto-commits synchronously from the select notifier. The
    // commit-armed Predictor may already have projected the next suggestion.
    if (prediction == PostCommitPrediction::kDismiss) HardStop(context);
    return true;
  }

  int SelectionIndex(const KeyEvent& key) const {
    if (!engine_ || !engine_->schema() ||
        (key.modifier() & ~kLockMask) != 0) {
      return -1;
    }
    int keycode = key.keycode();
    if (keycode >= XK_KP_0 && keycode <= XK_KP_9) {
      keycode = '0' + keycode - XK_KP_0;
    }
    if (keycode < 0x20 || keycode >= 0x7f) return -1;
    const string& select_keys = engine_->schema()->select_keys();
    const size_t index = select_keys.find(static_cast<char>(keycode));
    return index == string::npos ? -1 : static_cast<int>(index);
  }

  ProcessResult ProcessSelectionKey(Context* context,
                                    const KeyEvent& key) const {
    const int local_index = SelectionIndex(key);
    if (local_index < 0 || !context || context->composition().empty()) {
      return kNoop;
    }
    Segment& segment = context->composition().back();
    const an<Menu> menu = segment.menu;
    if (!menu) return kRejected;
    const int page_size = engine_->schema()->page_size();
    if (page_size <= 0 || local_index >= page_size) return kRejected;
    const size_t page_start =
        (segment.selected_index / static_cast<size_t>(page_size)) *
        static_cast<size_t>(page_size);
    const size_t target = page_start + static_cast<size_t>(local_index);
    if (!menu->GetCandidateAt(target)) return kRejected;
    return context->Select(target) ? kAccepted : kRejected;
  }

  void OnAbort(Context* context) const {
    ResetContinuationState(context, predict_engine_);
  }

  void RetirePredictionBoundary(Context* context) const {
    ClearPredictionContext(context, predict_engine_);
    if (HasPredictionSegment(context)) context->Clear();
  }

  void OnUnhandledKey(Context* context, const KeyEvent& key) const {
    if (!context || key.release() || IsModifierKey(key.keycode())) return;
    // ProcessKeyEvent already rejected host shortcuts before touching IME
    // state. The unhandled notification must preserve that same boundary.
    if (HasHostShortcutModifier(key)) return;
    if (IsEditBoundary(key.keycode())) {
      HardStop(context);
      return;
    }
    if ((key.modifier() & ~(kShiftMask | kLockMask)) != 0 ||
        key.keycode() < 0x20 || key.keycode() > 0x7e) {
      HardStop(context);
      return;
    }
    char punctuation = static_cast<char>(key.keycode());
    if (key.shift()) punctuation = ShiftedAscii(punctuation);
    if (string(",;:.!?()[]{}\"'").find(punctuation) == string::npos) {
      HardStop(context);
      return;
    }

    RetirePredictionBoundary(context);
    auto spacing =
        SpacingState::Load(context->get_property(kSpacingProperty));
    ApplyPunctuation(punctuation, &spacing);
    context->set_property(kSpacingProperty, spacing.Serialize());
    SetSentenceBoundary(
        context,
        options_.sentence_capitalization &&
            IsSentenceEndingPunctuation(punctuation));
  }

  Selector prediction_selector_;
  const string schema_id_;
  const InteractionOptions options_;
  const an<PredictEngine> predict_engine_;
  rime::connection abort_connection_;
  rime::connection unhandled_connection_;
};

class SmartEnglishTranslator : public Translator {
 public:
  explicit SmartEnglishTranslator(const Ticket& ticket)
      : Translator(ticket), schema_id_(ticket.schema ? ticket.schema->schema_id() : string()), options_(InteractionOptions::Load(ticket.schema)),
        predict_engine_(PredictEngineComponent::Shared()->GetInstance(ticket)), index_(predict_engine_) {
    if (!engine_) return;
    Context* context = engine_->context();
    commit_connection_ = context->commit_notifier().connect([this](Context* ctx) { OnCommit(ctx); });
  }

  ~SmartEnglishTranslator() override { commit_connection_.disconnect(); }

  an<Translation> Query(const string& input, const Segment& segment) override {
    auto result = New<FifoTranslation>();
    if (!predict_engine_) return result;
    const string normalized = LowerAsciiWord(input);
    // Uppercase letters are explicit English intent even while a Chinese
    // schema owns the session. Give that literal input the same typed identity
    // as Smart English's raw spelling so a completion cannot replace it. The
    // filter still retires this echo when an exact dictionary row exists.
    const bool explicit_chinese_mode_english =
        schema_id_ != kSmartEnglishSchema && segment.HasTag("abc") &&
        !normalized.empty() && input != normalized;
    if (segment.HasTag("zz_code_token") || segment.HasTag("zz_english") ||
        explicit_chinese_mode_english) {
      const char* candidate_type = segment.HasTag("zz_code_token")
                                       ? "raw"
                                       : kForcedRawCandidateType;
      auto raw =
          New<SimpleCandidate>(candidate_type, segment.start, segment.end, input);
      raw->set_quality(kRawTransportPriority);
      result->Append(raw);
      if (segment.HasTag("zz_code_token")) return result;
    }
    if (segment.HasTag("prediction")) {
      if (!input.empty() || !engine_ || engine_->context()->get_property(rime::predict::kStaticKeyProperty).empty()) {
        return result;
      }
      const auto context = ParseContext(engine_->context()->get_property(rime::predict::kContextProperty));
      if (context.empty()) return result;
      const auto bigrams = options_.learning_enabled
                               ? SessionBigrams::Load(engine_->context()->get_property(kBigramProperty))
                               : SessionBigrams{};
      std::size_t emitted = 0;
      for (const auto& edge : bigrams.NextWords(context.back())) {
        if (IsSuffix(edge.next) && !IsLowerWord(context.back())) continue;
        auto candidate = New<SimpleCandidate>("prediction", segment.start, segment.end, edge.next);
        candidate->set_quality(static_cast<double>(edge.count));
        result->Append(candidate);
        if (++emitted == 3) break;
      }
      return result;
    }
    if (segment.HasTag("linnet_pinyin")) {
      for (const auto& item : PinyinWords(input)) {
        auto candidate = New<SimpleCandidate>("linnet_pinyin", segment.start,
                                              segment.end, item.text);
        candidate->set_quality(kPinyinTransportPriority);
        result->Append(candidate);
      }
      return result;
    }
    if (!segment.HasTag("zz_english")) return result;
    for (const auto& word : index_.LookupCorrections(normalized)) {
      if (word.text == normalized) continue;
      auto candidate = New<SimpleCandidate>(kCorrectionCandidateType, segment.start, segment.end, word.text);
      candidate->set_quality(word.weight);
      result->Append(candidate);
    }
    for (const auto& word : PinyinWords(normalized)) {
      auto candidate = New<SimpleCandidate>("linnet_pinyin", segment.start,
                                            segment.end, word.text);
      candidate->set_quality(kPinyinTransportPriority);
      result->Append(candidate);
    }
    return result;
  }

 private:
  void InitializePinyinDecoder() {
    if (pinyin_decoder_initialized_) return;
    pinyin_decoder_initialized_ = true;
    if (!engine_) return;
    auto component = Dictionary::Require("dictionary");
    if (!component) return;
    const Ticket translator_ticket =
        schema_id_ == "linnet_en" ? Ticket(engine_, "linnet_pinyin")
                                  : Ticket(engine_, "translator");
    pinyin_delimiters_ =
        TranslatorOptions(translator_ticket).delimiters();
    pinyin_dictionary_.reset(component->Create(translator_ticket));
    if (!pinyin_dictionary_ || !pinyin_dictionary_->Load()) {
      pinyin_dictionary_.reset();
      return;
    }
    Config* config = engine_->schema()->config();
    pinyin_formatter_loaded_ =
        config && pinyin_key_formatter_.Load(
                      config->GetList("linnet_pinyin/key_format"));
  }

  std::vector<SmartEnglishWord> PinyinWords(const string& input) {
    auto keys = PinyinKeys(input);
    std::sort(keys.begin(), keys.end());
    std::vector<SmartEnglishWord> ranked;
    ranked.reserve(keys.size() * kCandidateLimit);
    for (const auto& key : keys) {
      for (const auto& word : index_.LookupPinyin(key)) {
        ranked.push_back(word);
      }
    }
    std::stable_sort(ranked.begin(), ranked.end(),
                     [](const auto& left, const auto& right) {
                       return left.weight > right.weight;
                     });
    std::vector<SmartEnglishWord> result;
    result.reserve((std::min)(ranked.size(), kCandidateLimit));
    std::unordered_set<string> emitted;
    for (const auto& word : ranked) {
      const string identity = NormalizeDisabledValue(word.text, false);
      if (!emitted.insert(identity).second) continue;
      result.push_back(word);
      if (result.size() == kCandidateLimit) break;
    }
    return result;
  }

  std::vector<string> PinyinKeys(const string& input) {
    if (input.empty() || input.size() > kPinyinInputByteLimit) return {};
    InitializePinyinDecoder();
    if (!pinyin_dictionary_ || !pinyin_formatter_loaded_) {
      return {};
    }
    SyllableGraph graph;
    Syllabifier syllabifier(pinyin_delimiters_, false, false);
    if (static_cast<size_t>(syllabifier.BuildSyllableGraph(
            input, *pinyin_dictionary_->prism(), &graph)) != input.size()) {
      return {};
    }

    std::vector<bool> normal_reachable(input.size() + 1, false);
    normal_reachable.front() = true;
    bool canonical_only = true;
    for (const auto& start : graph.edges) {
      if (start.first >= normal_reachable.size() ||
          !normal_reachable[start.first]) {
        continue;
      }
      for (const auto& end : start.second) {
        if (end.first > input.size()) return {};
        bool has_normal_spelling = false;
        for (const auto& spelling : end.second) {
          const auto& properties = spelling.second;
          if (properties.is_correction ||
              properties.type != kNormalSpelling) {
            continue;
          }
          string syllable = pinyin_dictionary_->primary_table()
                                ->GetSyllableById(spelling.first);
          if (syllable.empty()) continue;
          pinyin_key_formatter_.Apply(&syllable);
          if (!IsLowerWord(syllable)) continue;
          has_normal_spelling = true;
          canonical_only =
              canonical_only &&
              syllable.size() == end.first - start.first &&
              input.compare(start.first, syllable.size(), syllable) == 0;
        }
        if (has_normal_spelling) normal_reachable[end.first] = true;
      }
    }
    if (canonical_only && normal_reachable.back()) return {input};

    std::vector<string> result;
    std::unordered_set<string> seen;
    bool overflow = false;
    size_t traversed = 0;
    std::function<void(size_t, const string&)> visit =
        [&](size_t position, const string& prefix) {
          if (overflow) return;
          if (traversed == kPinyinTraversalLimit) {
            overflow = true;
            return;
          }
          ++traversed;
          if (position == input.size()) {
            if (!IsLowerWord(prefix) || !seen.insert(prefix).second) return;
            if (result.size() == kPinyinKeyLimit) {
              overflow = true;
              return;
            }
            result.push_back(prefix);
            return;
          }
          const auto start = graph.edges.find(position);
          if (start == graph.edges.end()) return;
          for (const auto& end : start->second) {
            std::set<string> syllables;
            for (const auto& spelling : end.second) {
              const auto& properties = spelling.second;
              if (properties.is_correction ||
                  properties.type != kNormalSpelling) {
                continue;
              }
              string syllable = pinyin_dictionary_->primary_table()
                                    ->GetSyllableById(spelling.first);
              if (syllable.empty()) continue;
              pinyin_key_formatter_.Apply(&syllable);
              if (IsLowerWord(syllable)) syllables.insert(syllable);
            }
            for (const auto& syllable : syllables) {
              visit(end.first, prefix + syllable);
              if (overflow) return;
            }
          }
        };
    visit(0, "");
    return overflow ? std::vector<string>() : result;
  }

  enum class CommitClass { kEnglishWord, kSuffix, kSpacedBoundary, kPunctuation, kHardBoundary };

  struct ClassifiedCommit { CommitClass type = CommitClass::kHardBoundary; string token; char punctuation = '\0'; };

  ClassifiedCommit Classify(const Segment& segment, const an<Candidate>& selected) const {
    if (!selected || segment.HasTag("zz_code_token") || segment.HasTag("text_expander") || segment.HasTag("linnet_pinyin")) {
      return {};
    }
    const auto genuine = Candidate::GetGenuineCandidate(selected);
    if (!genuine) return {};
    const string value = NormalizeCandidate(genuine->text());
    if (genuine->type() == "prediction" && IsSuffix(value)) return {CommitClass::kSuffix, value, '\0'};
    const bool smart_candidate =
        genuine->type() == kCorrectionCandidateType ||
        genuine->type() == "prediction" ||
        genuine->type() == "linnet_pinyin";
    if ((IsLinnetEnglishPhrase(genuine) || smart_candidate) && (IsOrdinarySegment(segment) || segment.HasTag("zz_english") || segment.HasTag("prediction")) && IsLowerWord(value)) {
      return {CommitClass::kEnglishWord, value, '\0'};
    }
    if (genuine->type() != "sentence" &&
        (genuine->type() == "linnet_pinyin" ||
         IsLinnetEnglishPhrase(genuine)) &&
        (IsOrdinarySegment(segment) || segment.HasTag("zz_english") ||
         segment.HasTag("prediction")) &&
        !genuine->text().empty()) {
      return {CommitClass::kSpacedBoundary, {}, '\0'};
    }
    if (schema_id_ == "linnet_en" && IsCustomPhrase(genuine) && IsOrdinarySegment(segment)) {
      if (IsLowerWord(value)) return {CommitClass::kEnglishWord, value, '\0'};
      if (!value.empty()) return {CommitClass::kSpacedBoundary, value, '\0'};
    }
    if (genuine->text().size() == 1) {
      const char value_byte = genuine->text().front();
      if (string(",;:.!?()[]{}\"'").find(value_byte) != string::npos) return {CommitClass::kPunctuation, {}, value_byte};
    }
    return {};
  }

  void ClearContext(Context* context) const {
    ClearPredictionContext(context, predict_engine_);
  }

  void StoreSpacing(Context* context, const SpacingState& spacing) const { context->set_property(kSpacingProperty, spacing.Serialize()); }

  void HardBoundary(Context* context) const {
    ResetContinuationState(context, predict_engine_);
  }

  void CommitEnglish(Context* context, const string& token) const {
    auto tokens = ParseContext(context->get_property(rime::predict::kContextProperty));
    if (IsSuffix(token) && (tokens.empty() || !IsLowerWord(tokens.back()))) {
      HardBoundary(context);
      return;
    }
    SetSentenceBoundary(context, false);
    const string previous = tokens.empty() ? string() : tokens.back();
    if (options_.learning_enabled && !previous.empty()) {
      auto bigrams = SessionBigrams::Load(context->get_property(kBigramProperty));
      bigrams.Learn(previous, token);
      context->set_property(kBigramProperty, bigrams.Serialize());
    }
    tokens.push_back(token);
    if (tokens.size() > kContextLimit) tokens.erase(tokens.begin());
    context->set_property(rime::predict::kContextProperty, SerializeContext(tokens));
    if (predict_engine_) predict_engine_->Resolve(context);
    auto spacing = SpacingState::Load(context->get_property(kSpacingProperty));
    spacing.spaced = true;
    StoreSpacing(context, spacing);
  }

  void OnCommit(Context* context) {
    if (!context) return;
    context->set_property(kPredictionNavigationProperty, "");
    const bool suppress_following_space =
        context->get_property(kSuppressFollowingSpaceProperty) == "1";
    context->set_property(kSuppressFollowingSpaceProperty, "");
    if (context->composition().empty() || context->composition().back().end != context->input().size()) {
      HardBoundary(context);
      return;
    }
    for (const auto& segment : context->composition()) {
      const auto classified = Classify(segment, segment.GetSelectedCandidate());
      switch (classified.type) {
        case CommitClass::kEnglishWord:
        case CommitClass::kSuffix:
          CommitEnglish(context, classified.token);
          break;
        case CommitClass::kSpacedBoundary: {
          ClearContext(context);
          SetSentenceBoundary(context, false);
          auto spacing = SpacingState::Load(context->get_property(kSpacingProperty));
          spacing.spaced = true;
          StoreSpacing(context, spacing);
          break;
        }
        case CommitClass::kPunctuation: {
          ClearContext(context);
          auto spacing = SpacingState::Load(context->get_property(kSpacingProperty));
          ApplyPunctuation(classified.punctuation, &spacing);
          StoreSpacing(context, spacing);
          SetSentenceBoundary(context, options_.sentence_capitalization && IsSentenceEndingPunctuation(classified.punctuation));
          break;
        }
        case CommitClass::kHardBoundary:
          HardBoundary(context);
          break;
      }
    }
    if (suppress_following_space) {
      auto spacing = SpacingState::Load(context->get_property(kSpacingProperty));
      spacing.spaced = false;
      StoreSpacing(context, spacing);
    }
  }

  const string schema_id_;
  const InteractionOptions options_;
  const an<PredictEngine> predict_engine_;
  const SmartEnglishIndex index_;
  bool pinyin_decoder_initialized_ = false;
  bool pinyin_formatter_loaded_ = false;
  the<Dictionary> pinyin_dictionary_;
  Projection pinyin_key_formatter_;
  string pinyin_delimiters_;
  rime::connection commit_connection_;
};

using DisabledWordSet = std::unordered_set<string>;

class DisabledWordsTranslation : public Translation {
 public:
  DisabledWordsTranslation(an<Translation> translation, std::shared_ptr<const DisabledWordSet> words) : translation_(std::move(translation)), words_(std::move(words)) { Locate(); }

  bool Next() override {
    if (exhausted()) return false;
    translation_->Next();
    return Locate();
  }

  an<Candidate> Peek() override { return exhausted() ? nullptr : translation_->Peek(); }

 private:
  bool Locate() {
    while (translation_ && !translation_->exhausted()) {
      const auto candidate = translation_->Peek();
      if (!candidate) break;
      const string word = NormalizeDisabledValue(candidate->text(), true);
      if (IsRawCandidate(candidate) || word.empty() ||
          words_->find(word) == words_->end()) {
        set_exhausted(false);
        return true;
      }
      translation_->Next();
    }
    set_exhausted(true);
    return false;
  }

  an<Translation> translation_;
  std::shared_ptr<const DisabledWordSet> words_;
};

class DisabledWordsFilter : public Filter {
 public:
  explicit DisabledWordsFilter(const Ticket& ticket) : Filter(ticket) {
    auto words = std::make_shared<DisabledWordSet>();
    if (ticket.schema) {
      if (auto list = ticket.schema->config()->GetList(ticket.name_space + "/words")) {
        for (const auto& item : *list) {
          if (auto value = rime::As<ConfigValue>(item)) {
            const string word = NormalizeDisabledValue(value->str(), false);
            if (!word.empty()) words->insert(word);
          }
        }
      }
    }
    words_ = std::move(words);
  }

  an<Translation> Apply(an<Translation> translation, CandidateList*) override { return words_->empty() ? translation : New<DisabledWordsTranslation>(translation, words_); }

  bool AppliesToSegment(Segment* segment) override { return IsDisabledSegment(segment); }

 private:
  std::shared_ptr<const DisabledWordSet> words_;
};

}  // namespace
}  // namespace linnet

static void rime_smart_english_initialize() {
  rime::Registry::instance().Register("linnet_mode_switch_processor", new rime::Component<linnet::ModeSwitchProcessor>);
  rime::Registry::instance().Register("linnet_interaction_processor", new rime::Component<linnet::LinnetInteractionProcessor>);
  rime::Registry::instance().Register("linnet_english_translator", new rime::Component<linnet::SmartEnglishTranslator>);
  rime::Registry::instance().Register("linnet_english_filter", new rime::Component<linnet::SmartEnglishFilter>);
  rime::Registry::instance().Register("linnet_disabled_filter", new rime::Component<linnet::DisabledWordsFilter>);
}

static void rime_smart_english_finalize() {}

RIME_REGISTER_MODULE(smart_english)
