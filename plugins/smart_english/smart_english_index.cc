// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include "smart_english_index.h"

#include <rime/predict/predict_engine.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <set>
#include <string_view>
#include <utility>

namespace linnet {
namespace {

constexpr std::size_t kMaxLookupWords = 64;
constexpr std::size_t kPhonexDistanceThreshold = 6;
constexpr std::size_t kMaxCorrectionKeys = 64, kMaxCorrectionInput = 64;
constexpr std::size_t kMinCrossBucketCorrectionLength = 8;

std::size_t KeyboardSubstitutionCost(char left, char right) {
  if (left == right) return 0;
  for (const std::string_view row : {"qwertyuiop", "asdfghjkl", "zxcvbnm"}) {
    const auto left_position = row.find(left);
    const auto right_position = row.find(right);
    if (left_position != std::string_view::npos &&
        right_position != std::string_view::npos &&
        (left_position + 1 == right_position || right_position + 1 == left_position)) {
      return 1;
    }
  }
  return 4;
}

// Smart English owns typo ranking for its phonetic lookup results. Keeping the
// small distance policy here avoids patching librime's disabled edit-distance
// corrector or generating a second 34 MiB correction index.
std::size_t SmartEnglishDistance(const std::string& left,
                                 const std::string& right,
                                 std::size_t threshold) {
  const auto rows = left.size() + 1;
  const auto columns = right.size() + 1;
  std::vector<std::size_t> distance(rows * columns);
  const auto at = [columns](std::size_t row, std::size_t column) {
    return row * columns + column;
  };
  for (std::size_t row = 1; row < rows; ++row) distance[at(row, 0)] = row * 2;
  for (std::size_t column = 1; column < columns; ++column) {
    distance[at(0, column)] = column * 2;
  }
  for (std::size_t row = 1; row < rows; ++row) {
    auto row_minimum = distance[at(row, 0)];
    for (std::size_t column = 1; column < columns; ++column) {
      distance[at(row, column)] = std::min({
          distance[at(row - 1, column)] + 2,
          distance[at(row, column - 1)] + 2,
          distance[at(row - 1, column - 1)] +
              KeyboardSubstitutionCost(left[row - 1], right[column - 1]),
      });
      if (row > 1 && column > 1 && left[row - 2] == right[column - 1] &&
          left[row - 1] == right[column - 2]) {
        distance[at(row, column)] = std::min(
            distance[at(row, column)], distance[at(row - 2, column - 2)] + 2);
      }
      row_minimum = std::min(row_minimum, distance[at(row, column)]);
    }
    if (row_minimum > threshold) return row_minimum;
  }
  return distance[at(left.size(), right.size())];
}

bool IsLowerWord(const std::string& value) {
  return !value.empty() && std::all_of(value.begin(), value.end(), [](unsigned char byte) { return byte >= 'a' && byte <= 'z'; });
}

bool IsPinyinValue(const std::string& value) {
  bool has_letter = false;
  if (value.empty()) return false;
  for (const unsigned char byte : value) {
    if (byte < 0x20 || byte > 0x7e) return false;
    has_letter = has_letter || (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z');
  }
  return has_letter;
}

bool IsMetadataKey(const std::string& value) {
  if (value.empty() || value.size() > 512) return false;
  for (std::size_t index = 0; index < value.size();) {
    const auto lead = static_cast<unsigned char>(value[index]);
    std::uint32_t codepoint = 0;
    std::size_t length = 0;
    if (lead < 0x80) {
      codepoint = lead;
      length = 1;
    } else if (lead >= 0xc2 && lead <= 0xdf) {
      codepoint = lead & 0x1f;
      length = 2;
    } else if (lead >= 0xe0 && lead <= 0xef) {
      codepoint = lead & 0x0f;
      length = 3;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      codepoint = lead & 0x07;
      length = 4;
    } else {
      return false;
    }
    if (index + length > value.size()) return false;
    for (std::size_t offset = 1; offset < length; ++offset) {
      const auto continuation = static_cast<unsigned char>(value[index + offset]);
      if ((continuation & 0xc0) != 0x80) return false;
      codepoint = (codepoint << 6) | (continuation & 0x3f);
    }
    if ((length == 3 && codepoint < 0x800) ||
        (length == 4 && codepoint < 0x10000) ||
        codepoint > 0x10ffff ||
        (codepoint >= 0xd800 && codepoint <= 0xdfff) ||
        codepoint < 0x20 ||
        (codepoint >= 0x7f && codepoint <= 0x9f) ||
        codepoint == 0x2028 || codepoint == 0x2029) {
      return false;
    }
    index += length;
  }
  return true;
}

bool IsMetadataValue(const std::string& value) {
  if (value.empty() || value.size() > 4096) return false;
  return std::none_of(value.begin(), value.end(), [](unsigned char byte) { return byte == 0 || byte == '\r' || byte == '\n' || byte == '\t'; });
}

}  // namespace

SmartEnglishIndex::SmartEnglishIndex(rime::an<rime::PredictEngine> engine) : engine_(std::move(engine)) {}

bool SmartEnglishIndex::LookupWords(const std::string& key, std::size_t limit, WordShape shape, std::vector<SmartEnglishWord>* result) const {
  if (!result) return false;
  result->clear();
  if (!engine_ || key.empty()) return false;

  rime::vector<rime::predict::RawEntry> raw;
  if (!engine_->LookupCopy(key, &raw) || raw.empty() || raw.size() > limit) return false;

  std::set<std::string> seen;
  result->reserve(raw.size());
  for (std::size_t ordinal = 0; ordinal < raw.size(); ++ordinal) {
    const auto& entry = raw[ordinal];
    const bool valid_text = shape == WordShape::kLowerWord ? IsLowerWord(entry.text) : IsPinyinValue(entry.text);
    if (!valid_text || !std::isfinite(entry.weight) || entry.weight <= 0.0 || !seen.insert(entry.text).second) {
      result->clear();
      return false;
    }
    result->push_back({entry.text, entry.weight});
  }
  return true;
}

bool SmartEnglishIndex::LookupSingleton(const std::string& key, std::string* result) const {
  if (!result) return false;
  result->clear();
  if (!engine_) return false;
  rime::vector<rime::predict::RawEntry> raw;
  if (!engine_->LookupCopy(key, &raw) || raw.size() != 1 || !std::isfinite(raw.front().weight) || raw.front().weight <= 0.0 || !IsMetadataValue(raw.front().text)) {
    return false;
  }
  *result = raw.front().text;
  return true;
}

std::string SmartEnglishIndex::EncodePhonex(const std::string& input) {
  if (!IsLowerWord(input)) return {};
  std::string name(input);
  std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return static_cast<char>(c - 'a' + 'A'); });
  while (!name.empty() && name.back() == 'S') name.pop_back();
  if (name.empty()) return {};

  if (name.size() >= 2) {
    const std::string first_two = name.substr(0, 2);
    if (first_two == "KN")
      name = "N" + name.substr(2);
    else if (first_two == "PH")
      name = "F" + name.substr(2);
    else if (first_two == "WR")
      name = "R" + name.substr(2);
  }
  if (!name.empty() && name.front() == 'H') name.erase(name.begin());
  if (name.empty()) return {};

  const auto contains = [](const char* set, char value) { return std::string(set).find(value) != std::string::npos; };
  char first = name.front();
  if (contains("AEIOUY", first))
    first = 'A';
  else if (contains("BP", first))
    first = 'B';
  else if (contains("VF", first))
    first = 'F';
  else if (contains("KQC", first))
    first = 'C';
  else if (contains("JG", first))
    first = 'G';
  else if (contains("ZS", first))
    first = 'S';
  name.front() = first;

  std::string code(1, first);
  char last = first;
  for (std::size_t index = 1; index < name.size(); ++index) {
    const char letter = name[index];
    const char next = index + 1 < name.size() ? name[index + 1] : '\0';
    char encoding = '0';
    if (contains("BPFV", letter)) {
      encoding = '1';
    } else if (contains("CSKGJQXZ", letter)) {
      encoding = '2';
    } else if ((letter == 'D' || letter == 'T') && next != 'C') {
      encoding = '3';
    } else if (letter == 'L' && (contains("AEIOUY", next) || index + 1 == name.size())) {
      encoding = '4';
    } else if (letter == 'M' || letter == 'N') {
      if (next == 'D' || next == 'G') name[index + 1] = letter;
      encoding = '5';
    } else if (letter == 'R' && (contains("AEIOUY", next) || index + 1 == name.size())) {
      encoding = '6';
    }
    if (encoding != last && encoding != '0') code.push_back(encoding);
    last = code.back();
  }
  return code;
}

std::vector<SmartEnglishWord> SmartEnglishIndex::LookupCorrections(
    const std::string& input) const {
  std::vector<SmartEnglishWord> result;
  if (!engine_ || !IsLowerWord(input) || input.size() <= 3) return result;
  const std::string code = EncodePhonex(input);
  if (code.empty()) return result;

  // Phonex is lossy: a single neighboring-key typo can change its bucket.
  // Plan bounded lookups in the same immutable index, rather than scanning
  // the dictionary or allocating a second correction index. The caller only
  // enters this path for Smart English's zz_english segment.
  std::vector<std::string> keys{code};
  std::set<std::string> seen_keys{code};
  const auto add_variant = [&](const std::string& variant) {
    if (keys.size() >= kMaxCorrectionKeys) return;
    const std::string key = EncodePhonex(variant);
    if (!key.empty() && seen_keys.insert(key).second) keys.push_back(key);
  };
  if (input.size() >= kMinCrossBucketCorrectionLength &&
      input.size() <= kMaxCorrectionInput) {
    for (std::size_t position = 0;
         position < input.size() && keys.size() < kMaxCorrectionKeys;
         ++position) {
      std::string variant(input);
      for (char replacement = 'a'; replacement <= 'z'; ++replacement) {
        if (KeyboardSubstitutionCost(input[position], replacement) != 1) continue;
        variant[position] = replacement;
        add_variant(variant);
      }
      if (position + 1 < input.size()) {
        variant = input;
        std::swap(variant[position], variant[position + 1]);
        add_variant(variant);
      }
    }
  }

  struct RankedWord {
    SmartEnglishWord word;
    std::size_t distance;
  };
  std::vector<RankedWord> ranked;
  std::set<std::string> seen_words;
  for (const auto& key : keys) {
    std::vector<SmartEnglishWord> words;
    if (!LookupWords("f/" + key, kMaxLookupWords, WordShape::kLowerWord, &words)) continue;
    for (auto& word : words) {
      if (!seen_words.insert(word.text).second) continue;
      const auto length_difference = std::max(input.size(), word.text.size()) -
                                     std::min(input.size(), word.text.size());
      if (length_difference > kPhonexDistanceThreshold / 2) continue;
      const auto distance = SmartEnglishDistance(input, word.text, kPhonexDistanceThreshold);
      if (distance <= kPhonexDistanceThreshold) ranked.push_back({std::move(word), distance});
    }
  }
  // Each candidate's distance is computed once, not on every sort comparison.
  std::stable_sort(ranked.begin(), ranked.end(), [](const auto& left, const auto& right) {
    if (left.distance != right.distance) return left.distance < right.distance;
    if (left.word.weight != right.word.weight) return left.word.weight > right.word.weight;
    return left.word.text < right.word.text;
  });
  result.reserve(std::min(ranked.size(), kMaxLookupWords));
  for (auto& item : ranked) {
    if (result.size() == kMaxLookupWords) break;
    result.push_back(std::move(item.word));
  }
  return result;
}

std::vector<SmartEnglishWord> SmartEnglishIndex::LookupPinyin(const std::string& pinyin) const {
  std::vector<SmartEnglishWord> result;
  return IsLowerWord(pinyin) && LookupWords("p/" + pinyin, kMaxLookupWords, WordShape::kPrintableEnglish, &result) ? result : std::vector<SmartEnglishWord>();
}

bool SmartEnglishIndex::LookupMetadata(const std::string& displayed_word,
                                       const std::string& source_word,
                                       SmartEnglishMetadata* result) const {
  if (!result || !IsMetadataKey(displayed_word) || !IsMetadataKey(source_word)) return false;
  std::string skip_marker;
  if (LookupSingleton("m/skip/" + displayed_word, &skip_marker)) return false;
  SmartEnglishMetadata metadata;
  if (!LookupSingleton("m/zh/" + source_word, &metadata.chinese_definition)) return false;
  LookupSingleton("m/ipa/" + source_word, &metadata.ipa);
  *result = std::move(metadata);
  return true;
}

}  // namespace linnet
