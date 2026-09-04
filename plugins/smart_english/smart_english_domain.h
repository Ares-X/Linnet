// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef LINNET_SMART_ENGLISH_DOMAIN_H_
#define LINNET_SMART_ENGLISH_DOMAIN_H_

#include <rime/candidate.h>
#include <rime/config.h>
#include <rime/context.h>
#include <rime/gear/translator_commons.h>
#include <rime/language.h>
#include <rime/schema.h>

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#pragma GCC visibility push(hidden)

namespace linnet::smart_english_domain {

inline constexpr char kBigramProperty[] = "linnet/session_bigrams_v1";
inline constexpr char kSpacingProperty[] = "linnet/spacing_v1";
inline constexpr char kSentenceBoundaryProperty[] =
    "linnet/sentence_boundary_v1";
inline constexpr char kSmartEnglishSchema[] = "linnet_en";
inline constexpr char kDefinitionCommentPrefix = '\x1d';
inline constexpr std::size_t kContextLimit = 4;
inline constexpr std::size_t kBigramLimit = 128;
inline constexpr std::size_t kCandidateLimit = 64;
inline constexpr char kCorrectionCandidateType[] = "linnet_correction";
inline constexpr char kForcedRawCandidateType[] = "linnet_forced_raw";
inline constexpr char kMixedCandidateType[] = "linnet_mixed";
inline constexpr std::uint16_t kCountLimit = 255;

enum class CaseStyle { kUnchanged, kCapitalized, kUppercase };
enum class TabBehavior { kPass, kNavigate, kSmartComplete };

struct InteractionOptions {
  bool sentence_capitalization = false;
  bool show_ipa = true;
  bool show_translation = true;
  bool learning_enabled = true;
  bool space_adds_trailing_space = true;
  TabBehavior tab_behavior = TabBehavior::kSmartComplete;

  static InteractionOptions Load(const rime::Schema* schema) {
    InteractionOptions result;
    if (!schema) return result;
    auto* config = schema->config();
    config->GetBool("linnet_english_interaction/sentence_capitalization",
                    &result.sentence_capitalization);
    config->GetBool("linnet_english_interaction/show_ipa", &result.show_ipa);
    config->GetBool("linnet_english_interaction/show_translation",
                    &result.show_translation);
    config->GetBool("linnet_english_interaction/learning_enabled",
                    &result.learning_enabled);
    config->GetBool("linnet_english_interaction/space_adds_trailing_space",
                    &result.space_adds_trailing_space);
    std::string tab_behavior;
    if (config->GetString("linnet_english_interaction/tab_behavior",
                          &tab_behavior)) {
      if (tab_behavior == "pass") {
        result.tab_behavior = TabBehavior::kPass;
      } else if (tab_behavior == "navigate") {
        result.tab_behavior = TabBehavior::kNavigate;
      } else if (tab_behavior != "smart_complete") {
        result.tab_behavior = TabBehavior::kPass;
      }
    }
    return result;
  }
};

inline bool IsLowerWord(const std::string& value) {
  return !value.empty() &&
         std::all_of(value.begin(), value.end(), [](unsigned char byte) {
           return byte >= 'a' && byte <= 'z';
         });
}

inline bool IsSuffix(const std::string& value) {
  static const std::set<std::string> kSuffixes = {
      "'d", "'ll", "'m", "'re", "'s", "'ve"};
  return kSuffixes.find(value) != kSuffixes.end();
}

inline bool IsContextToken(const std::string& value) {
  return IsLowerWord(value) || IsSuffix(value);
}

inline std::string LowerAsciiWord(const std::string& value,
                                  bool allow_apostrophe = false) {
  if (value.empty()) return {};
  std::string result;
  result.reserve(value.size());
  bool has_letter = false;
  for (const unsigned char byte : value) {
    if ((byte >= 'a' && byte <= 'z') ||
        (byte >= 'A' && byte <= 'Z')) {
      result.push_back(static_cast<char>(std::tolower(byte)));
      has_letter = true;
    } else if (allow_apostrophe && byte == '\'') {
      result.push_back('\'');
    } else {
      return {};
    }
  }
  return has_letter ? result : std::string();
}

inline std::string NormalizeCandidate(const std::string& value,
                                      bool allow_apostrophe = true) {
  const std::size_t offset =
      !value.empty() && value.front() == ' ' ? 1 : 0;
  const std::string candidate = value.substr(offset);
  if (candidate.empty()) return {};
  std::string normalized;
  std::size_t begin = 0;
  while (begin < candidate.size()) {
    const std::size_t end = candidate.find(' ', begin);
    const std::string token = LowerAsciiWord(
        candidate.substr(begin, end == std::string::npos
                                    ? std::string::npos
                                    : end - begin),
        allow_apostrophe);
    if (token.empty()) return {};
    if (!normalized.empty()) normalized.push_back(' ');
    normalized += token;
    if (end == std::string::npos) break;
    begin = end + 1;
    if (begin == candidate.size()) return {};
  }
  return normalized;
}

inline std::string MetadataKey(const std::string& value) {
  const std::size_t offset =
      !value.empty() && value.front() == ' ' ? 1 : 0;
  return value.substr(offset);
}

inline CaseStyle RequestedCase(const std::string& input) {
  // "i" (lowercase, single-character): always capitalize to "I" regardless
  // of input case. This is the most common single-letter word and writing it
  // lowercase is incorrect in standard English.
  if (input == "i" ||
      (input.size() == 1 && input.front() >= 'A' && input.front() <= 'Z')) {
    return CaseStyle::kCapitalized;
  }
  if (input.size() <= 1 || input.front() < 'A' || input.front() > 'Z') {
    return CaseStyle::kUnchanged;
  }
  return input[1] >= 'A' && input[1] <= 'Z' ? CaseStyle::kUppercase
                                             : CaseStyle::kCapitalized;
}

inline std::string ApplyCase(std::string value,
                             CaseStyle style,
                             bool typed_pinyin_projection = false) {
  const std::size_t offset =
      !value.empty() && value.front() == ' ' ? 1 : 0;
  if (style == CaseStyle::kUnchanged || offset == value.size() ||
      (NormalizeCandidate(value).empty() && !typed_pinyin_projection)) {
    return value;
  }
  if (style == CaseStyle::kUppercase) {
    for (std::size_t index = offset; index < value.size(); ++index) {
      if (value[index] >= 'a' && value[index] <= 'z') {
        value[index] = static_cast<char>(value[index] - 'a' + 'A');
      }
    }
  } else {
    const auto first = std::find_if(
        value.begin() + offset, value.end(), [](unsigned char byte) {
          return (byte >= 'a' && byte <= 'z') ||
                 (byte >= 'A' && byte <= 'Z');
        });
    if (first != value.end() && *first >= 'a' && *first <= 'z') {
      *first = static_cast<char>(*first - 'a' + 'A');
    }
  }
  return value;
}

inline bool IsLinnetEnglishPhrase(const rime::an<rime::Candidate>& candidate) {
  const auto phrase = rime::As<rime::Phrase>(candidate);
  return phrase && phrase->language() &&
         phrase->language()->name() == "linnet_en";
}

inline bool IsCustomPhrase(const rime::an<rime::Candidate>& candidate) {
  const auto phrase = rime::As<rime::Phrase>(candidate);
  return phrase && phrase->language() &&
         phrase->language()->name() == "linnet_custom_words";
}

inline bool HasCandidateType(const rime::an<rime::Candidate>& candidate,
                             const char* type) {
  if (!candidate) return false;
  const auto genuine = rime::Candidate::GetGenuineCandidate(candidate);
  return candidate->type() == type || (genuine && genuine->type() == type);
}

inline bool IsForcedRawCandidate(
    const rime::an<rime::Candidate>& candidate) {
  return HasCandidateType(candidate, kForcedRawCandidateType);
}

inline bool IsRawCandidate(const rime::an<rime::Candidate>& candidate) {
  return HasCandidateType(candidate, "raw") ||
         IsForcedRawCandidate(candidate);
}

inline bool ShouldDropRawCandidate(
    const rime::an<rime::Candidate>& candidate,
    bool promote_exact) {
  return IsRawCandidate(candidate) &&
         (!IsForcedRawCandidate(candidate) || promote_exact);
}

inline bool IsSmartEnglishCandidateOrigin(
    const rime::an<rime::Candidate>& candidate) {
  if (!candidate) return false;
  const auto genuine = rime::Candidate::GetGenuineCandidate(candidate);
  if (!genuine || IsRawCandidate(candidate)) return false;
  const bool typed_projection = genuine->type() == "linnet_pinyin" ||
                                IsLinnetEnglishPhrase(genuine);
  if (!typed_projection && NormalizeCandidate(genuine->text()).empty()) {
    return false;
  }
  return (genuine->type() != "sentence" &&
          (IsLinnetEnglishPhrase(genuine) || IsCustomPhrase(genuine))) ||
         genuine->type() == kCorrectionCandidateType ||
         genuine->type() == "prediction" ||
         genuine->type() == "linnet_pinyin";
}

inline bool SentenceBoundaryObserved(const rime::Context* context) {
  return context &&
         context->get_property(kSentenceBoundaryProperty) == "1";
}

inline std::string SerializeContext(
    const std::vector<std::string>& tokens);

inline std::vector<std::string> ParseContext(const std::string& value) {
  if (value.empty()) return {};
  std::vector<std::string> tokens;
  std::istringstream input(value);
  for (std::string token; input >> token;) tokens.push_back(token);
  if (tokens.empty() || tokens.size() > kContextLimit ||
      std::any_of(tokens.begin(), tokens.end(), [](const std::string& token) {
        return !IsContextToken(token);
      }) ||
      SerializeContext(tokens) != value) {
    return {};
  }
  return tokens;
}

inline std::string SerializeContext(
    const std::vector<std::string>& tokens) {
  std::string result;
  for (const auto& token : tokens) {
    result += (result.empty() ? "" : " ") + token;
  }
  return result;
}

struct BigramEdge {
  std::string previous, next;
  std::uint16_t count = 0;
  std::uint64_t last_used = 0;
};

class SessionBigrams {
 public:
  static SessionBigrams Load(const std::string& serialized) {
    SessionBigrams result;
    if (serialized.empty()) return result;
    std::istringstream input(serialized);
    std::string version;
    if (!(input >> version >> result.sequence_) || version != "v1") return {};
    std::set<std::pair<std::string, std::string>> seen;
    for (std::string previous; input >> previous;) {
      std::string next;
      std::uint64_t count = 0, last_used = 0;
      if (!(input >> next >> count >> last_used) ||
          !IsContextToken(previous) || !IsContextToken(next) || count == 0 ||
          count > kCountLimit || last_used == 0 ||
          last_used > result.sequence_ ||
          !seen.emplace(previous, next).second ||
          result.edges_.size() >= kBigramLimit) {
        return {};
      }
      result.edges_.push_back({previous, next,
                               static_cast<std::uint16_t>(count), last_used});
    }
    if (!input.eof()) return {};
    return result;
  }

  void Learn(const std::string& previous, const std::string& next) {
    if (!IsContextToken(previous) || !IsContextToken(next)) return;
    if (sequence_ != std::numeric_limits<std::uint64_t>::max()) ++sequence_;
    auto found = std::find_if(edges_.begin(), edges_.end(),
                              [&](const auto& edge) {
                                return edge.previous == previous &&
                                       edge.next == next;
                              });
    if (found == edges_.end()) {
      edges_.push_back({previous, next, 1, sequence_});
    } else {
      if (found->count < kCountLimit) ++found->count;
      found->last_used = sequence_;
    }
    if (edges_.size() > kBigramLimit) {
      const auto victim = std::min_element(
          edges_.begin(), edges_.end(), [](const auto& left, const auto& right) {
            return std::tie(left.last_used, left.count, left.previous,
                            left.next) <
                   std::tie(right.last_used, right.count, right.previous,
                            right.next);
          });
      edges_.erase(victim);
    }
  }

  std::uint16_t Count(const std::string& previous,
                      const std::string& next) const {
    const auto found = std::find_if(
        edges_.begin(), edges_.end(), [&](const auto& edge) {
          return edge.previous == previous && edge.next == next;
        });
    return found == edges_.end() ? 0 : found->count;
  }

  std::vector<BigramEdge> NextWords(const std::string& previous) const {
    std::vector<BigramEdge> result;
    for (const auto& edge : edges_) {
      if (edge.previous == previous) result.push_back(edge);
    }
    std::sort(result.begin(), result.end(),
              [](const auto& left, const auto& right) {
                if (left.count != right.count) return left.count > right.count;
                if (left.last_used != right.last_used) {
                  return left.last_used > right.last_used;
                }
                return left.next < right.next;
              });
    return result;
  }

  std::string Serialize() const {
    std::ostringstream output;
    output << "v1 " << sequence_;
    for (const auto& edge : edges_) {
      output << ' ' << edge.previous << ' ' << edge.next << ' ' << edge.count
             << ' ' << edge.last_used;
    }
    return output.str();
  }

 private:
  std::uint64_t sequence_ = 0;
  std::vector<BigramEdge> edges_;
};

struct SpacingState {
  bool spaced = false, single_quote_open = false, double_quote_open = false;

  static SpacingState Load(const std::string& value) {
    if (value.size() != 1 || value.front() < '0' || value.front() > '7') {
      return {};
    }
    const unsigned bits = static_cast<unsigned>(value.front() - '0');
    return {(bits & 1) != 0, (bits & 2) != 0, (bits & 4) != 0};
  }

  std::string Serialize() const {
    return std::string(
        1, static_cast<char>('0' + spaced + 2 * single_quote_open +
                             4 * double_quote_open));
  }
};

}  // namespace linnet::smart_english_domain

#pragma GCC visibility pop

#endif  // LINNET_SMART_ENGLISH_DOMAIN_H_
