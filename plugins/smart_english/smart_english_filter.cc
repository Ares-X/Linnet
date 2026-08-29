// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include "smart_english_filter.h"

#include <rime/candidate.h>
#include <rime/context.h>
#include <rime/engine.h>
#include <rime/gear/translator_commons.h>
#include <rime/language.h>
#include <rime/predict/predict_engine.h>
#include <rime/schema.h>
#include <rime/segmentation.h>
#include <rime/translation.h>

#include <algorithm>
#include <functional>
#include <limits>
#include <utility>
#include <vector>

namespace linnet {
using namespace rime;
using namespace smart_english_domain;
namespace {

// Rime dictionary weights are log(raw / 1e8). Preserve the established
// raw-weight floor without reopening the Chinese dictionary after grammar has
// adjusted the candidate's presentation weight.
constexpr double kEstablishedChinesePhraseMinimumLexicalWeight =
    -13.815510557964274;

struct MixedTextShape {
  std::size_t entity_start = std::string::npos;
  std::size_t entity_length = 0;

  explicit operator bool() const {
    return entity_start != std::string::npos;
  }
};

MixedTextShape InspectMixedText(const string& text) {
  MixedTextShape result;
  bool has_non_ascii = false;
  for (std::size_t index = 0; index < text.size();) {
    const auto byte = static_cast<unsigned char>(text[index]);
    if (byte >= 'A' && byte <= 'Z') {
      const std::size_t start = index;
      while (index < text.size() && text[index] >= 'A' &&
             text[index] <= 'Z') {
        ++index;
      }
      const std::size_t length = index - start;
      if (result || length < 2 || length > 6) return {};
      result.entity_start = start;
      result.entity_length = length;
      continue;
    }
    if (byte < 0x80) return {};
    has_non_ascii = true;
    ++index;
  }
  return result && has_non_ascii ? result : MixedTextShape{};
}

bool IsMixedChineseCandidate(const an<Candidate>& candidate) {
  const auto phrase = As<Phrase>(candidate);
  if (!phrase || !phrase->language() ||
      phrase->language()->name() != "linnet_zh" ||
      !phrase->is_exact_match()) {
    return false;
  }
  const MixedTextShape shape = InspectMixedText(phrase->text());
  return static_cast<bool>(shape);
}

an<Candidate> ProjectSmartEnglishCandidate(
    const an<Candidate>& candidate,
    const SmartEnglishIndex& index,
    const InteractionOptions& options,
    const SpacingState& spacing,
    CaseStyle requested_case,
    bool sentence_boundary) {
  if (!candidate || candidate->type() == kMixedCandidateType) return candidate;
  const auto genuine = Candidate::GetGenuineCandidate(candidate);
  if (!genuine) return nullptr;
  if (IsMixedChineseCandidate(genuine)) {
    return New<ShadowCandidate>(genuine, kMixedCandidateType, genuine->text(),
                                genuine->comment(), false);
  }
  string text = genuine->text();
  string comment = genuine->comment();
  const bool raw = IsRawCandidate(candidate);
  if (!raw) {
    const CaseStyle case_style =
        requested_case == CaseStyle::kUnchanged &&
                options.sentence_capitalization && sentence_boundary &&
                IsSmartEnglishCandidateOrigin(candidate)
            ? CaseStyle::kCapitalized
            : requested_case;
    const bool typed_pinyin_projection =
        genuine->type() == "linnet_pinyin";
    text = ApplyCase(text, case_style, typed_pinyin_projection);
    const bool printable_english_projection =
        (typed_pinyin_projection || IsLinnetEnglishPhrase(genuine)) &&
        !text.empty();
    if (spacing.spaced &&
        !IsSuffix(NormalizeCandidate(genuine->text())) &&
        (!NormalizeCandidate(text).empty() ||
         printable_english_projection)) {
      text.insert(text.begin(), ' ');
    }
  }
  if (!raw && !IsCustomPhrase(genuine)) {
    SmartEnglishMetadata metadata;
    if (index.LookupMetadata(MetadataKey(text), MetadataKey(genuine->text()),
                             &metadata)) {
      const string ipa = options.show_ipa ? metadata.ipa : string();
      const string translation =
          options.show_translation ? metadata.chinese_definition : string();
      comment = ipa.empty()
                    ? translation
                    : translation.empty() ? ipa : ipa + " · " + translation;
    }
  }
  if (candidate == genuine && text == genuine->text() &&
      comment == genuine->comment()) {
    return genuine;
  }
  return New<ShadowCandidate>(genuine, genuine->type(), text, comment, false);
}

using CandidateProjector =
    std::function<an<Candidate>(const an<Candidate>&)>;

class SmartEnglishTailTranslation : public Translation {
 public:
  SmartEnglishTailTranslation(an<Translation> translation,
                              bool drop_raw,
                              bool promote_exact,
                              CandidateProjector projector)
      : translation_(std::move(translation)),
        drop_raw_(drop_raw),
        promote_exact_(promote_exact),
        projector_(std::move(projector)) {
    Locate();
  }

  bool Next() override {
    if (exhausted()) return false;
    translation_->Next();
    return Locate();
  }

  an<Candidate> Peek() override {
    return exhausted() ? nullptr : projected_;
  }

 private:
  bool Locate() {
    projected_.reset();
    while (translation_ && !translation_->exhausted()) {
      const auto candidate = translation_->Peek();
      if (!candidate) break;
      if (!drop_raw_ ||
          !ShouldDropRawCandidate(candidate, promote_exact_)) {
        projected_ = projector_(candidate);
      }
      if (projected_) {
        set_exhausted(false);
        return true;
      }
      translation_->Next();
    }
    set_exhausted(true);
    return false;
  }

  an<Translation> translation_;
  const bool drop_raw_;
  const bool promote_exact_;
  const CandidateProjector projector_;
  an<Candidate> projected_;
};

}  // namespace

SmartEnglishFilter::SmartEnglishFilter(const Ticket& ticket)
    : Filter(ticket),
      schema_id_(ticket.schema ? ticket.schema->schema_id() : string()),
      options_(InteractionOptions::Load(ticket.schema)),
      index_(PredictEngineComponent::Shared()->GetInstance(ticket)) {}

an<Translation> SmartEnglishFilter::Apply(an<Translation> translation,
                                           CandidateList*) {
  auto result = New<FifoTranslation>();
  if (!translation || !engine_) return result;

  Context* context = engine_->context();
  const auto pending_segment =
      std::exchange(pending_segment_, std::nullopt);
  const string ranking_input =
      pending_segment ? pending_segment->input : string();
  const bool is_pinyin_flow =
      pending_segment && pending_segment->pinyin_flow;
  string input_word = LowerAsciiWord(ranking_input);
  struct RankedCandidate {
    an<Candidate> candidate, genuine;
    string word;
    std::size_t original = 0;
    std::size_t static_rank = std::numeric_limits<std::size_t>::max();
    std::uint16_t session_count = 0;
    bool raw = false, exact = false, chinese = false, mixed = false,
         strong_chinese_collision = false;
  };
  std::vector<RankedCandidate> candidates;
  candidates.reserve(kCandidateLimit);
  for (std::size_t index = 0;
       index < kCandidateLimit && !translation->exhausted(); ++index) {
    auto candidate = translation->Peek();
    if (!candidate) break;
    auto genuine = Candidate::GetGenuineCandidate(candidate);
    const string candidate_text = genuine ? genuine->text() : string();
    candidates.push_back(
        {candidate, genuine, NormalizeCandidate(candidate_text), index});
    translation->Next();
  }

  const auto context_tokens =
      ParseContext(context->get_property(rime::predict::kContextProperty));
  const string previous =
      context_tokens.empty() ? string() : context_tokens.back();
  const auto bigrams = options_.learning_enabled
                           ? SessionBigrams::Load(
                                 context->get_property(kBigramProperty))
                           : SessionBigrams{};
  const auto static_ranks = index_.LookupStaticOrdinals(
      context->get_property(rime::predict::kStaticKeyProperty));
  bool has_exact = false, has_pinyin = false, has_mixed = false;
  for (auto& item : candidates) {
    if (!item.genuine) continue;
    item.raw = IsRawCandidate(item.candidate);
    has_pinyin = has_pinyin || item.genuine->type() == "linnet_pinyin";
    const auto phrase = rime::As<Phrase>(item.genuine);
    item.mixed = IsMixedChineseCandidate(item.genuine);
    item.chinese = !item.mixed && phrase && phrase->language() &&
                   phrase->language()->name() == "linnet_zh";
    item.exact = !input_word.empty() && item.word == input_word &&
                 IsLinnetEnglishPhrase(item.genuine) &&
                 (!phrase || phrase->is_exact_match()) &&
                 item.candidate->type() != "linnet_correction";
    has_exact = has_exact || item.exact;
    has_mixed = has_mixed || item.mixed;
    item.session_count = previous.empty() || item.word.empty()
                             ? 0
                             : bigrams.Count(previous, item.word);
    const auto static_rank = static_ranks.find(item.word);
    if (static_rank != static_ranks.end()) {
      item.static_rank = static_rank->second;
    }
  }
  // Exact dictionary identity is the default bilingual intent signal for a
  // complete word. A lowercase single letter remains incomplete Chinese input
  // whenever the active profile has a same-span Chinese candidate. Longer
  // lowercase input preserves an established exact Chinese phrase reached
  // through the active Prism without abbreviation; generated sentences and
  // long-tail transliterations stay below an independently meaningful English
  // word.
  const bool explicit_english_case = !input_word.empty() && ranking_input != input_word;
  const bool lowercase_chinese_input =
      (has_exact || has_mixed) && schema_id_ != kSmartEnglishSchema &&
      !explicit_english_case;
  const bool lowercase_chinese_exact = has_exact && lowercase_chinese_input;
  auto bilingual_candidate = std::find_if(candidates.begin(), candidates.end(),
      [](const auto& item) { return item.exact; });
  if (bilingual_candidate == candidates.end()) {
    bilingual_candidate = std::find_if(candidates.begin(), candidates.end(),
        [](const auto& item) { return item.mixed; });
  }
  bool has_same_span_chinese = false;
  bool has_strong_same_span_chinese = false;
  if (lowercase_chinese_input && bilingual_candidate != candidates.end()) {
    for (auto& item : candidates) {
      if (!item.chinese ||
          item.genuine->start() != bilingual_candidate->genuine->start() ||
          item.genuine->end() != bilingual_candidate->genuine->end()) {
        continue;
      }
      has_same_span_chinese = true;
      const auto phrase = rime::As<Phrase>(item.genuine);
      const auto system_weight =
          phrase ? phrase->system_lexical_weight() : std::nullopt;
      item.strong_chinese_collision = phrase && phrase->is_exact_match() &&
          phrase->spelling_type() < kAbbreviation && system_weight &&
          *system_weight >= kEstablishedChinesePhraseMinimumLexicalWeight;
      has_strong_same_span_chinese = has_strong_same_span_chinese ||
          item.strong_chinese_collision;
    }
  }
  const bool single_letter_chinese_input =
      lowercase_chinese_exact && input_word.size() == 1 &&
      has_same_span_chinese;
  const bool preserve_chinese_exact =
      lowercase_chinese_exact &&
      (single_letter_chinese_input || has_strong_same_span_chinese);
  const bool promote_exact = has_exact && !preserve_chinese_exact;
  const bool promote_mixed =
      !has_exact && has_mixed && !has_same_span_chinese;
  const bool has_non_raw = std::any_of(
      candidates.begin(), candidates.end(),
      [](const auto& item) { return item.genuine && !item.raw; });
  // Prefetching the bounded prefix must not turn Rime's lowest-priority echo
  // fallback into an ordinary candidate. The native translator gives its
  // explicit zz_english typo candidate one typed origin; transport priority is
  // not candidate identity. An exact English dictionary row retires even that
  // typed fallback because the input is no longer a typo.
  if (has_non_raw) {
    candidates.erase(
        std::remove_if(candidates.begin(), candidates.end(),
                       [promote_exact](const auto& item) {
                         return ShouldDropRawCandidate(item.candidate,
                                                       promote_exact);
                       }),
        candidates.end());
  }
  if (!is_pinyin_flow && has_mixed && has_same_span_chinese) {
    const auto mixed = std::find_if(candidates.begin(), candidates.end(),
                                    [](const auto& item) {
                                      return item.mixed;
                                    });
    if (mixed != candidates.end()) {
      const auto chinese = std::find_if(
          mixed, candidates.end(), [&](const auto& item) {
            return item.chinese && item.genuine->start() == mixed->genuine->start() &&
                   item.genuine->end() == mixed->genuine->end();
          });
      if (chinese != candidates.end()) {
        std::rotate(mixed, chinese, std::next(chinese));
      }
    }
  }
  if (!is_pinyin_flow && (has_exact || promote_mixed)) {
    std::stable_partition(candidates.begin(), candidates.end(), [has_exact](const auto& item) {
      return has_exact ? !item.mixed : item.mixed;
    });
  }
  if (!is_pinyin_flow && has_exact) {
    if (promote_exact && schema_id_ == kSmartEnglishSchema) {
      std::stable_sort(candidates.begin(), candidates.end(),
                       [](const auto& left, const auto& right) {
        const auto left_group = left.raw ? 0 : left.exact ? 1 : 2;
        const auto right_group = right.raw ? 0 : right.exact ? 1 : 2;
        if (left_group != right_group) return left_group < right_group;
        if (left_group != 2) return left.original < right.original;
        const bool left_session = left.session_count > 0;
        const bool right_session = right.session_count > 0;
        if (left_session != right_session) return left_session;
        if (left.session_count != right.session_count) {
          return left.session_count > right.session_count;
        }
        const bool left_static =
            left.static_rank != std::numeric_limits<std::size_t>::max();
        const bool right_static =
            right.static_rank != std::numeric_limits<std::size_t>::max();
        if (left_static != right_static) return left_static;
        if (left.static_rank != right.static_rank) {
          return left.static_rank < right.static_rank;
        }
        return left.original < right.original;
      });
    } else if (promote_exact) {
      const auto exact = std::find_if(
          candidates.begin(), candidates.end(),
          [](const auto& item) { return item.exact; });
      if (exact != candidates.end()) {
        auto insertion = exact;
        while (insertion != candidates.begin()) {
          const auto previous_candidate = std::prev(insertion);
          if (!previous_candidate->chinese ||
              previous_candidate->genuine->start() !=
                  exact->genuine->start() ||
              previous_candidate->genuine->end() != exact->genuine->end()) {
            break;
          }
          insertion = previous_candidate;
        }
        std::rotate(insertion, exact, std::next(exact));
      }
    } else if (preserve_chinese_exact) {
      const auto exact = std::find_if(
          candidates.begin(), candidates.end(),
          [](const auto& item) { return item.exact; });
      if (exact != candidates.end()) {
        const auto chinese = std::find_if(
            exact, candidates.end(), [&](const auto& item) {
              return item.chinese &&
                     (single_letter_chinese_input ||
                      item.strong_chinese_collision) &&
                     item.genuine->start() == exact->genuine->start() &&
                     item.genuine->end() == exact->genuine->end();
            });
        if (chinese != candidates.end() && exact < chinese) {
          std::rotate(exact, chinese, std::next(chinese));
        }
      }
    }
  }

  // Hallelujah appends pinyin-to-English results after ordinary English
  // completion/correction. Keep that order even when Rime merges translator
  // streams by quality. The explicit Chinese lookup remains an already
  // ordered, tagged flow and never enters this branch.
  if (schema_id_ == "linnet_en" && has_pinyin) {
    std::stable_partition(candidates.begin(), candidates.end(),
                          [](const auto& item) {
                            return !item.genuine ||
                                   item.genuine->type() != "linnet_pinyin";
                          });
  }

  const auto spacing =
      SpacingState::Load(context->get_property(kSpacingProperty));
  const CaseStyle requested_case = RequestedCase(ranking_input);
  const bool sentence_boundary = SentenceBoundaryObserved(context);
  const CandidateProjector projector =
      [index = index_, options = options_, spacing, requested_case,
       sentence_boundary](const an<Candidate>& candidate) {
        return ProjectSmartEnglishCandidate(candidate, index, options, spacing,
                                            requested_case,
                                            sentence_boundary);
      };
  for (auto& item : candidates) {
    if (const auto projected = projector(item.candidate)) {
      result->Append(projected);
    }
  }
  // Only the bounded prefix is re-ranked. The same lazy projection remains
  // authoritative for the unbounded tail, so Chinese candidate 65+ stays
  // reachable without bypassing spacing, case or metadata.
  an<Translation> ranked_prefix = result;
  an<Translation> tail = New<SmartEnglishTailTranslation>(
      translation, has_non_raw, promote_exact, projector);
  return ranked_prefix + tail;
}

bool SmartEnglishFilter::AppliesToSegment(Segment* segment) {
  pending_segment_.reset();
  if (!segment || segment->HasTag("zz_code_token") ||
      segment->HasTag("text_expander")) {
    return false;
  }
  const bool applies =
      segment->HasTag("linnet_pinyin") || segment->HasTag("abc") ||
      (schema_id_ == "linnet_en" &&
       (segment->HasTag("zz_english") || segment->HasTag("prediction")));
  if (!applies || !engine_ || !engine_->context()) return false;

  // ConcreteEngine translates this exact Segment and immediately invokes
  // Apply after this predicate. Capture the same range once; composition.back
  // may name a later segment, while Context::input still includes confirmed
  // prefixes and therefore is not a ranking input.
  const string& composition_input = engine_->context()->composition().input();
  if (segment->start > segment->end ||
      segment->end > composition_input.size()) {
    return false;
  }
  pending_segment_ = PendingSegment{
      composition_input.substr(segment->start,
                               segment->end - segment->start),
      segment->HasTag("linnet_pinyin")};
  return true;
}

}  // namespace linnet
