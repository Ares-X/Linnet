// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include "smart_english_filter.h"

#include <rime/algo/syllabifier.h>
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
#include <cmath>
#include <functional>
#include <limits>
#include <utility>
#include <vector>
#include "smart_english_mixed_decoder.h"

namespace linnet {
using namespace rime;
using namespace smart_english_domain;
namespace {

// Rime projects a dictionary row with raw weight W as log(W / 1e8).
// Its grammar uses log(1e-6) as the unknown-token floor.  Reusing that floor
// gives Chinese lexical evidence one stable, corpus-local qualification rule:
// a row needs raw weight >= 100 before it may block an exact English word.
// This never compares weights from the independently scaled Chinese and
// English dictionaries.
constexpr double kEstablishedChinesePhraseMinimumLexicalWeight =
    -13.815510557964274;

an<Candidate> ProjectSmartEnglishCandidate(
    const an<Candidate>& candidate,
    const SmartEnglishIndex& index,
    const InteractionOptions& options,
    const SpacingState& spacing,
    CaseStyle requested_case,
    bool sentence_boundary) {
  if (As<ModelessMixedCandidate>(candidate)) return candidate;
  const auto genuine = Candidate::GetGenuineCandidate(candidate);
  if (!candidate || !genuine) return nullptr;
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
  const string ranking_input =
      std::exchange(pending_segment_input_, std::nullopt).value_or(string());
  string input_word = LowerAsciiWord(ranking_input);
  struct RankedCandidate {
    an<Candidate> candidate, genuine;
    string word;
    std::size_t original = 0;
    std::size_t static_rank = std::numeric_limits<std::size_t>::max();
    std::uint16_t session_count = 0;
    bool raw = false, exact = false, chinese = false, mixed = false,
         preferred_mixed = false,
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
  bool has_exact = false, has_pinyin = false, has_mixed = false,
       has_preferred_mixed = false;
  double best_chinese_sentence_weight = -std::numeric_limits<double>::infinity();
  for (auto& item : candidates) {
    if (!item.genuine) continue;
    item.raw = IsRawCandidate(item.candidate);
    has_pinyin = has_pinyin || item.genuine->type() == "linnet_pinyin";
    const auto phrase = rime::As<Phrase>(item.genuine);
    item.chinese = phrase && phrase->language() &&
                   phrase->language()->name() == "linnet_zh";
    if (item.chinese)
      if (const auto sentence = As<Sentence>(item.genuine))
        best_chinese_sentence_weight = (std::max)(
            best_chinese_sentence_weight, sentence->weight());
    item.exact = !input_word.empty() && item.word == input_word &&
                 IsLinnetEnglishPhrase(item.genuine) &&
                 (!phrase || phrase->is_exact_match()) &&
                 item.candidate->type() != "linnet_correction";
    has_exact = has_exact || item.exact;
    item.mixed = As<ModelessMixedCandidate>(item.candidate) != nullptr;
    has_mixed = has_mixed || item.mixed;
    item.session_count = previous.empty() || item.word.empty()
                             ? 0
                             : bigrams.Count(previous, item.word);
    const auto static_rank = static_ranks.find(item.word);
    if (static_rank != static_ranks.end()) {
      item.static_rank = static_rank->second;
    }
  }
  const bool is_pinyin_flow = schema_id_ != "linnet_en" && has_pinyin;
  // Exact dictionary identity is the default bilingual intent signal for a
  // complete word. A lowercase single letter remains incomplete Chinese input
  // whenever the active profile has a same-span Chinese candidate. Longer
  // lowercase input preserves an established exact Chinese phrase reached
  // through the active Prism without abbreviation; generated sentences and
  // long-tail transliterations stay below an independently meaningful English
  // word.
  const bool explicit_english_case = !input_word.empty() && ranking_input != input_word;
  const bool lowercase_chinese_input = (has_exact || has_mixed) &&
      schema_id_ != kSmartEnglishSchema && !explicit_english_case;
  const bool lowercase_chinese_exact = has_exact && lowercase_chinese_input;
  const ChineseSpellingEvidence chinese_spelling =
      lowercase_chinese_input ? InspectChineseSpelling(input_word)
                              : ChineseSpellingEvidence{};
  for (auto& item : candidates) {
    const auto phrase = rime::As<Phrase>(item.genuine);
    if (const auto mixed = As<ModelessMixedCandidate>(item.candidate)) {
      item.preferred_mixed = std::isfinite(best_chinese_sentence_weight) &&
          mixed->model_weight() - best_chinese_sentence_weight >=
              kMixedEntityAmbiguityLogMargin;
      has_preferred_mixed = has_preferred_mixed || item.preferred_mixed;
    }
    item.strong_chinese_collision =
        item.chinese && phrase && phrase->is_exact_match() &&
        chinese_spelling.established_exact_phrases.count(
            item.genuine->text());
  }
  auto bilingual_candidate = std::find_if(candidates.begin(), candidates.end(),
      [](const auto& item) { return item.exact; });
  if (bilingual_candidate == candidates.end()) {
    bilingual_candidate = std::find_if(candidates.begin(), candidates.end(),
        [](const auto& item) { return item.mixed; });
  }
  bool has_same_span_chinese = false;
  bool has_strong_same_span_chinese = false;
  if (bilingual_candidate != candidates.end()) {
    for (const auto& item : candidates) {
      if (!item.chinese ||
          item.genuine->start() != bilingual_candidate->genuine->start() ||
          item.genuine->end() != bilingual_candidate->genuine->end()) {
        continue;
      }
      has_same_span_chinese = true;
      has_strong_same_span_chinese =
          has_strong_same_span_chinese || item.strong_chinese_collision;
    }
  }
  const bool decoder_unavailable =
      chinese_spelling.path == ChineseSpellingPath::kUnavailable;
  const bool single_letter_chinese_input =
      lowercase_chinese_exact && input_word.size() == 1 &&
      has_same_span_chinese;
  const bool preserve_chinese_exact =
      lowercase_chinese_exact &&
      (single_letter_chinese_input || decoder_unavailable ||
       (chinese_spelling.path == ChineseSpellingPath::kDirect &&
        has_strong_same_span_chinese));
  const bool promote_exact = has_exact && !preserve_chinese_exact;
  const bool promote_mixed = !has_exact && has_preferred_mixed &&
      !decoder_unavailable && !has_strong_same_span_chinese;
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
  if (!is_pinyin_flow && (has_exact || promote_mixed)) {
    std::stable_partition(candidates.begin(), candidates.end(), [has_exact](const auto& item) {
      return has_exact ? !item.mixed : item.preferred_mixed;
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
                     (single_letter_chinese_input || decoder_unavailable ||
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
  pending_segment_input_.reset();
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
  pending_segment_input_ = composition_input.substr(
      segment->start, segment->end - segment->start);
  return true;
}

SmartEnglishFilter::ChineseSpellingEvidence
SmartEnglishFilter::InspectChineseSpelling(const string& input) {
  ChineseSpellingEvidence evidence;
  if (schema_id_ == kSmartEnglishSchema || input.empty()) {
    return evidence;
  }
  InitializeChineseSpellingDecoder();
  // Decoder availability is a product-data boundary. If it cannot be proven
  // healthy, fail closed and preserve Rime's Chinese-first order.
  if (!chinese_dictionary_) {
    evidence.path = ChineseSpellingPath::kUnavailable;
    return evidence;
  }

  SyllableGraph graph;
  Syllabifier syllabifier(chinese_delimiters_, false, false);
  if (static_cast<size_t>(syllabifier.BuildSyllableGraph(
          input, *chinese_dictionary_->prism(), &graph)) != input.size()) {
    return evidence;
  }
  // Syllabifier already records the best whole-path spelling type at every
  // vertex. Consume that owner instead of reconstructing a second path from
  // individual edges (which loses Rime's overlap and correction pruning).
  const auto end = graph.vertices.find(input.size());
  if (end == graph.vertices.end() || end->second >= kAbbreviation) {
    return evidence;
  }
  evidence.path = ChineseSpellingPath::kDirect;

  // Candidate type is session state after a system phrase is learned. Qualify
  // every form against the same static dictionary row, so learning cannot
  // change bilingual intent and an arbitrary learned long-tail phrase cannot
  // bypass the lexical floor.
  auto entries = chinese_dictionary_->Lookup(graph, 0, &chinese_blacklist_);
  if (!entries) return evidence;
  const auto full_span = entries->find(input.size());
  if (full_span == entries->end()) return evidence;
  auto& iterator = full_span->second;
  while (!iterator.exhausted()) {
    const auto entry = iterator.Peek();
    if (!entry ||
        entry->weight < kEstablishedChinesePhraseMinimumLexicalWeight) {
      break;
    }
    if (entry->IsExactMatch()) {
      evidence.established_exact_phrases.insert(entry->text);
    }
    if (!iterator.Next()) break;
  }
  return evidence;
}

void SmartEnglishFilter::InitializeChineseSpellingDecoder() {
  if (chinese_decoder_initialized_) return;
  chinese_decoder_initialized_ = true;
  if (!engine_) return;
  auto component = Dictionary::Require("dictionary");
  if (!component) return;
  const Ticket translator_ticket(engine_, "translator");
  TranslatorOptions translator_options(translator_ticket);
  chinese_delimiters_ = translator_options.delimiters();
  chinese_blacklist_ = translator_options.blacklist();
  chinese_dictionary_.reset(component->Create(translator_ticket));
  if (!chinese_dictionary_ || !chinese_dictionary_->Load()) {
    chinese_dictionary_.reset();
  }
}

}  // namespace linnet
