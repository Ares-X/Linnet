// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef LINNET_SMART_ENGLISH_INDEX_H_
#define LINNET_SMART_ENGLISH_INDEX_H_

#include <rime/common.h>

#include <cstddef>
#include <string>
#include <vector>

namespace rime {
class PredictEngine;
}

namespace linnet {

struct SmartEnglishMetadata {
  std::string ipa, chinese_definition;
};

struct SmartEnglishWord {
  std::string text;
  double weight = 0.0;
};

// The sole typed interpretation boundary over PredictEngine's immutable map.
class SmartEnglishIndex {
 public:
  explicit SmartEnglishIndex(rime::an<rime::PredictEngine> engine);

  std::vector<SmartEnglishWord> LookupCorrections(
      const std::string& input) const;
  std::vector<SmartEnglishWord> LookupPinyin(const std::string& pinyin) const;
  bool LookupMetadata(const std::string& displayed_word,
                      const std::string& source_word,
                      SmartEnglishMetadata* result) const;

 private:
  enum class WordShape { kLowerWord, kPrintableEnglish };
  bool LookupWords(const std::string& key, std::size_t limit, WordShape shape, std::vector<SmartEnglishWord>* result) const;
  bool LookupSingleton(const std::string& key, std::string* result) const;
  static std::string EncodePhonex(const std::string& input);

  const rime::an<rime::PredictEngine> engine_;
};

}  // namespace linnet

#endif  // LINNET_SMART_ENGLISH_INDEX_H_
