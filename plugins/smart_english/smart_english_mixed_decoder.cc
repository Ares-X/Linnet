// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include "smart_english_mixed_decoder.h"

#include <rime/algo/syllabifier.h>
#include <rime/config.h>
#include <rime/engine.h>
#include <rime/gear/translator_commons.h>
#include <rime/schema.h>
#include <rime/segmentation.h>

#include <algorithm>
#include <limits>
#include <map>
#include <set>
#include <utility>

#include "smart_english_domain.h"

namespace linnet {
namespace {

using namespace rime;
using smart_english_domain::kMixedCandidateType;

constexpr std::size_t kMinimumEntityLength = 2;
constexpr std::size_t kMaximumEntityLength = 6;
constexpr std::size_t kMaximumInputLength = 48;
constexpr std::size_t kMaximumMixedCandidates = 3;
constexpr std::size_t kMaximumSentences = 8;
constexpr std::size_t kUserPhraseDepth = 5;
constexpr char kMixedEntityMarker[] = "linnet:modeless-english-entity";

struct EntityEdge {
  std::size_t start = 0;
  std::size_t end = 0;
  an<DictEntry> entry;
};

bool IsLowerAscii(const string& input) {
  return !input.empty() &&
         std::all_of(input.begin(), input.end(), [](unsigned char byte) {
           return byte >= 'a' && byte <= 'z';
         });
}

string UpperAscii(string input) {
  for (char& byte : input) {
    byte = static_cast<char>(byte - 'a' + 'A');
  }
  return input;
}

an<DictEntry> ExactEntity(Dictionary* dictionary, const string& raw) {
  if (!dictionary || raw.size() < kMinimumEntityLength ||
      raw.size() > kMaximumEntityLength) {
    return nullptr;
  }
  const string uppercase = UpperAscii(raw);
  DictEntryIterator entries;
  dictionary->LookupWords(&entries, uppercase, false);
  while (!entries.exhausted()) {
    const auto entry = entries.Peek();
    if (entry && entry->IsExactMatch() && entry->text == uppercase) {
      auto entity = New<DictEntry>(*entry);
      // The two dictionaries use independent corpus scales. Keep a neutral
      // entity prior and let the shared Chinese grammar rank its context.
      entity->weight = 0.0;
      entity->custom_code = kMixedEntityMarker;
      entity->code.clear();
      return entity;
    }
    if (!entries.Next()) break;
  }
  return nullptr;
}

std::vector<EntityEdge> FindEntities(Dictionary* dictionary,
                                     const string& input) {
  std::vector<EntityEdge> result;
  for (std::size_t start = 0; start < input.size(); ++start) {
    const std::size_t maximum =
        (std::min)(kMaximumEntityLength, input.size() - start);
    for (std::size_t length = kMinimumEntityLength; length <= maximum;
         ++length) {
      if (start == 0 && length == input.size()) continue;
      auto entry = ExactEntity(dictionary, input.substr(start, length));
      if (entry) result.push_back({start, start + length, std::move(entry)});
    }
  }
  return result;
}

template <class Collector, class Destination>
void EnrollEntries(const an<Collector>& source,
                   const std::set<std::size_t>& target_ends,
                   std::size_t maximum_homophones,
                   Destination* destination) {
  if (!source || !destination) return;
  for (auto& end : *source) {
    if (!target_ends.count(end.first)) continue;
    auto& homophones = (*destination)[static_cast<int>(end.first)];
    auto& entries = end.second;
    while (homophones.size() < maximum_homophones &&
           !entries.exhausted()) {
      if (const auto entry = entries.Peek()) homophones.push_back(entry);
      if (!entries.Next()) break;
    }
  }
}

std::map<std::size_t, std::set<std::size_t>> ChineseRanges(
    const std::vector<EntityEdge>& entities,
    std::size_t input_length) {
  std::map<std::size_t, std::set<std::size_t>> ranges;
  for (const auto& entity : entities) {
    if (entity.start > 0) ranges[0].insert(entity.start);
    if (entity.end < input_length) ranges[entity.end].insert(input_length);
    for (const auto& next : entities) {
      if (entity.end < next.start) ranges[entity.end].insert(next.start);
    }
  }
  return ranges;
}

bool BuildChineseWordGraph(const string& input,
                           const std::vector<EntityEdge>& entities,
                           Dictionary* dictionary,
                           UserDictionary* user_dictionary,
                           const string& delimiters,
                           const hash_set<string>& blacklist,
                           std::size_t maximum_homophones,
                           WordGraph* graph) {
  if (!dictionary || !graph) return false;
  SyllableGraph syllable_graph;
  Syllabifier syllabifier(delimiters, false, false);
  if (static_cast<std::size_t>(syllabifier.BuildSyllableGraph(
          input, *dictionary->prism(), &syllable_graph)) != input.size()) {
    return false;
  }
  for (const auto& range : ChineseRanges(entities, input.size())) {
    auto& same_start = (*graph)[static_cast<int>(range.first)];
    if (user_dictionary) {
      EnrollEntries(user_dictionary->Lookup(syllable_graph, range.first,
                                            kUserPhraseDepth),
                    range.second, maximum_homophones, &same_start);
    }
    EnrollEntries(dictionary->Lookup(syllable_graph, range.first, &blacklist),
                  range.second, maximum_homophones, &same_start);
  }
  return true;
}

bool UsesEnglishEntity(const Sentence& sentence) {
  return std::any_of(sentence.components().begin(),
                     sentence.components().end(), [](const auto& component) {
                       return component.custom_code == kMixedEntityMarker;
                     });
}

}  // namespace

ModelessMixedCandidate::ModelessMixedCandidate(std::size_t start,
                                               std::size_t end,
                                               std::string text,
                                               double model_weight)
    : SimpleCandidate(kMixedCandidateType, start, end, std::move(text)),
      model_weight_(model_weight) {}

ModelessMixedDecoder::ModelessMixedDecoder(const Ticket& ticket)
    : engine_(ticket.engine) {}

bool ModelessMixedDecoder::InitializeEnglish() {
  if (english_initialized_) return english_available_;
  english_initialized_ = true;
  if (!engine_) return false;
  auto component = Dictionary::Require("dictionary");
  if (!component) return false;
  english_dictionary_.reset(
      component->Create(Ticket(engine_, "linnet_english_words")));
  english_available_ = english_dictionary_ && english_dictionary_->Load();
  if (!english_available_) english_dictionary_.reset();
  return english_available_;
}

bool ModelessMixedDecoder::InitializeChinese() {
  if (chinese_initialized_) return chinese_available_;
  chinese_initialized_ = true;
  if (!engine_) return false;
  auto dictionary_component = Dictionary::Require("dictionary");
  if (!dictionary_component) return false;
  const Ticket translator_ticket(engine_, "translator");
  chinese_dictionary_.reset(dictionary_component->Create(translator_ticket));
  if (!chinese_dictionary_ || !chinese_dictionary_->Load()) {
    chinese_dictionary_.reset();
    return false;
  }

  TranslatorOptions options(translator_ticket);
  chinese_delimiters_ = options.delimiters();
  chinese_blacklist_ = options.blacklist();
  int configured_homophones = static_cast<int>(max_homophones_);
  if (engine_->schema() && engine_->schema()->config()) {
    engine_->schema()->config()->GetInt("translator/max_homophones",
                                       &configured_homophones);
  }
  max_homophones_ = static_cast<std::size_t>(
      std::clamp(configured_homophones, 1, 16));

  if (auto user_component = UserDictionary::Require("user_dictionary")) {
    chinese_user_dictionary_.reset(user_component->Create(translator_ticket));
    if (chinese_user_dictionary_ && chinese_user_dictionary_->Load()) {
      chinese_user_dictionary_->Attach(chinese_dictionary_->primary_table(),
                                       chinese_dictionary_->prism());
    } else {
      chinese_user_dictionary_.reset();
    }
  }
  chinese_language_.reset(new Language(
      Language::get_language_component(chinese_dictionary_->name())));
  poet_.reset(new Poet(chinese_language_.get(),
                       engine_->schema() ? engine_->schema()->config()
                                         : nullptr));
  chinese_available_ = poet_ != nullptr;
  return chinese_available_;
}

std::vector<an<ModelessMixedCandidate>> ModelessMixedDecoder::Query(
    const string& input,
    const Segment& segment) {
  if (input.size() < kMinimumEntityLength + 2 ||
      input.size() > kMaximumInputLength || !IsLowerAscii(input) ||
      !InitializeEnglish()) {
    return {};
  }
  const auto entities = FindEntities(english_dictionary_.get(), input);
  if (entities.empty() || !InitializeChinese()) return {};

  WordGraph graph;
  if (!BuildChineseWordGraph(input, entities, chinese_dictionary_.get(),
                             chinese_user_dictionary_.get(),
                             chinese_delimiters_, chinese_blacklist_,
                             max_homophones_, &graph)) {
    return {};
  }
  for (const auto& entity : entities) {
    graph[static_cast<int>(entity.start)][static_cast<int>(entity.end)]
        .push_back(entity.entry);
  }

  const auto sentences = poet_->MakeSentences(
      graph, input.size(), "", kMaximumSentences,
      std::numeric_limits<double>::infinity());
  std::vector<an<ModelessMixedCandidate>> result;
  std::set<string> emitted;
  for (const auto& sentence : sentences) {
    if (!sentence || !UsesEnglishEntity(*sentence) ||
        !emitted.insert(sentence->text()).second) {
      continue;
    }
    auto candidate = New<ModelessMixedCandidate>(
        segment.start, segment.end, sentence->text(), sentence->weight());
    result.push_back(std::move(candidate));
    if (result.size() == kMaximumMixedCandidates) break;
  }
  return result;
}

}  // namespace linnet
