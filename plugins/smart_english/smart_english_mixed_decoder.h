// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef LINNET_SMART_ENGLISH_MIXED_DECODER_H_
#define LINNET_SMART_ENGLISH_MIXED_DECODER_H_

#include <rime/candidate.h>
#include <rime/common.h>
#include <rime/dict/dictionary.h>
#include <rime/dict/user_dictionary.h>
#include <rime/gear/poet.h>
#include <rime/language.h>
#include <rime/ticket.h>

#include <cstddef>
#include <string>
#include <vector>

#pragma GCC visibility push(hidden)

namespace rime {
struct Segment;
}

namespace linnet {

class ModelessMixedCandidate final : public rime::SimpleCandidate {
 public:
  ModelessMixedCandidate(std::size_t start,
                         std::size_t end,
                         std::string text,
                         double model_weight);

  double model_weight() const { return model_weight_; }

 private:
  const double model_weight_;
};

// Adds exact all-caps English dictionary entities to the active Chinese word
// graph. The Chinese SyllableGraph is built once, then queried at each of its
// existing vertices exactly as librime ScriptTranslation does.
class ModelessMixedDecoder {
 public:
  explicit ModelessMixedDecoder(const rime::Ticket& ticket);

  std::vector<rime::an<ModelessMixedCandidate>> Query(
      const std::string& input,
      const rime::Segment& segment);

 private:
  bool InitializeEnglish();
  bool InitializeChinese();

  rime::Engine* const engine_;
  bool english_initialized_ = false;
  bool chinese_initialized_ = false;
  bool english_available_ = false;
  bool chinese_available_ = false;
  std::size_t max_homophones_ = 8;
  std::string chinese_delimiters_;
  rime::hash_set<std::string> chinese_blacklist_;
  rime::the<rime::Dictionary> english_dictionary_;
  rime::the<rime::Dictionary> chinese_dictionary_;
  rime::the<rime::UserDictionary> chinese_user_dictionary_;
  rime::the<rime::Language> chinese_language_;
  rime::the<rime::Poet> poet_;
};

}  // namespace linnet

#pragma GCC visibility pop

#endif  // LINNET_SMART_ENGLISH_MIXED_DECODER_H_
