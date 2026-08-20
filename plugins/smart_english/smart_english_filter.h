// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef LINNET_SMART_ENGLISH_FILTER_H_
#define LINNET_SMART_ENGLISH_FILTER_H_

#include <rime/dict/dictionary.h>
#include <rime/filter.h>

#include <optional>
#include <string>
#include <unordered_set>

#include "smart_english_domain.h"
#include "smart_english_index.h"

#pragma GCC visibility push(hidden)

namespace linnet {

class SmartEnglishFilter : public rime::Filter {
 public:
  explicit SmartEnglishFilter(const rime::Ticket& ticket);

  rime::an<rime::Translation> Apply(
      rime::an<rime::Translation> translation,
      rime::CandidateList*) override;
  bool AppliesToSegment(rime::Segment* segment) override;

 private:
  enum class ChineseSpellingPath { kUnavailable, kNotDirect, kDirect };
  struct ChineseSpellingEvidence {
    ChineseSpellingPath path = ChineseSpellingPath::kNotDirect;
    std::unordered_set<std::string> established_exact_phrases;
  };

  ChineseSpellingEvidence InspectChineseSpelling(const std::string& input);
  void InitializeChineseSpellingDecoder();

  const std::string schema_id_;
  const smart_english_domain::InteractionOptions options_;
  const SmartEnglishIndex index_;
  std::optional<std::string> pending_segment_input_;
  bool chinese_decoder_initialized_ = false;
  rime::the<rime::Dictionary> chinese_dictionary_;
  std::string chinese_delimiters_;
  rime::hash_set<std::string> chinese_blacklist_;
};

}  // namespace linnet

#pragma GCC visibility pop

#endif  // LINNET_SMART_ENGLISH_FILTER_H_
