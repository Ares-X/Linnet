#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <thread>
#include <tuple>
#include <utility>
#include <vector>

#include "rime_api_stdbool.h"
#include "rime_api.h"
#include <rime/candidate.h>
#include <rime/context.h>
#include <rime/gear/translator_commons.h>
#include <rime/key_table.h>
#include <rime/language.h>
#include <rime/menu.h>
#include <rime/predict/predict_engine.h>
#include <rime/schema.h>
#include <rime/segmentation.h>
#include <rime/service.h>
#include <rime/ticket.h>

#include "../plugins/smart_english/smart_english_index.h"

namespace {

using Nanoseconds = std::chrono::nanoseconds;
using LatencySample = Nanoseconds::rep;

constexpr size_t kLatencyWarmupSamples = 4096;
constexpr size_t kLatencySamples = 32768;
constexpr int kBackSpace = 0xff08;
constexpr int kTab = 0xff09;
constexpr int kReturn = 0xff0d;
constexpr int kEscape = 0xff1b;
constexpr int kControlMask = 1 << 2;
constexpr char kPredictContextProperty[] = "linnet/predict_context_v1";
constexpr char kBigramProperty[] = "linnet/session_bigrams_v1";
constexpr char kSpacingProperty[] = "linnet/spacing_v1";
constexpr char kSuppressFollowingSpaceProperty[] =
    "linnet/suppress_following_space_v1";
constexpr char kPredictStaticKeyProperty[] =
    "linnet/predict_static_key_v1";
constexpr char kPredictionNavigationProperty[] =
    "linnet/prediction_navigation_v1";
constexpr char kSentenceBoundaryProperty[] =
    "linnet/sentence_boundary_v1";
constexpr char kModeReturnSchemaProperty[] =
    "linnet/mode_return_schema_v1";
constexpr char kForcedRawCandidateType[] = "linnet_forced_raw";
constexpr std::array<const char*, 9> kProductSchemaIDs = {
    "linnet_zh_pinyin",  "linnet_zh",         "linnet_zh_flypy",
    "linnet_zh_mspy",    "linnet_zh_sogou",   "linnet_zh_abc",
    "linnet_zh_ziguang", "linnet_zh_jiajia",  "linnet_en",
};
constexpr std::array<const char*, 7> kDoublePinyinSchemaIDs = {
    "linnet_zh",       "linnet_zh_flypy",  "linnet_zh_mspy",
    "linnet_zh_sogou", "linnet_zh_abc",    "linnet_zh_ziguang",
    "linnet_zh_jiajia",
};

struct CandidateView {
  std::string text;
  std::string comment;
};

struct CandidateOriginView {
  std::string text;
  std::string type;
  std::string genuine_type;
  std::string genuine_language;
  size_t start;
  size_t end;
  double quality;
  bool phrase_exact;
  size_t phrase_code_size;
  std::string preedit;
};

struct AcceptanceCase {
  std::string query;
  std::string expected;
};

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "rime_smoke_test: " << message << '\n';
  // A failed assertion can leave live librime sessions whose filters belong
  // to dynamically loaded modules.  Running process-static destructors from
  // std::exit() then tears down those objects after module lifetime has ended
  // and can turn an ordinary test failure into SIGSEGV.  _Exit preserves the
  // intended nonzero process result without executing that unsafe teardown.
  std::cerr.flush();
  std::_Exit(1);
}

std::vector<CandidateView> Candidates(RimeApi_stdbool* api,
                                      RimeSessionId session) {
  std::vector<CandidateView> values;
  RimeCandidateListIterator iterator = {};
  if (!api->candidate_list_begin(session, &iterator)) {
    return values;
  }
  while (api->candidate_list_next(&iterator)) {
    values.push_back({iterator.candidate.text ? iterator.candidate.text : "",
                      iterator.candidate.comment
                          ? iterator.candidate.comment
                          : ""});
  }
  api->candidate_list_end(&iterator);
  return values;
}

std::vector<CandidateOriginView> CandidateOrigins(RimeSessionId session_id,
                                                  size_t limit = 64) {
  std::vector<CandidateOriginView> values;
  const auto session = rime::Service::instance().GetSession(session_id);
  if (!session || !session->context() ||
      session->context()->composition().empty()) {
    return values;
  }
  auto& segment = session->context()->composition().back();
  if (!segment.menu) return values;
  const size_t count = segment.menu->Prepare(limit);
  for (size_t index = 0; index < count; ++index) {
    const auto candidate = segment.menu->GetCandidateAt(index);
    const auto genuine = rime::Candidate::GetGenuineCandidate(candidate);
    const auto phrase = rime::As<rime::Phrase>(genuine);
    values.push_back({candidate ? candidate->text() : "",
                      candidate ? candidate->type() : "",
                      genuine ? genuine->type() : "",
                      phrase && phrase->language()
                          ? phrase->language()->name()
                          : "",
                      candidate ? candidate->start() : 0,
                      candidate ? candidate->end() : 0,
                      candidate ? candidate->quality() : 0.0,
                      phrase && phrase->is_exact_match(),
                      phrase ? phrase->code().size() : 0,
                      candidate ? candidate->preedit() : ""});
  }
  return values;
}

std::string BaseText(const std::string& value) {
  return !value.empty() && value.front() == ' ' ? value.substr(1) : value;
}

void ExpectCurrentSchema(RimeApi_stdbool* api,
                         RimeSessionId session,
                         const std::string& expected,
                         const std::string& boundary) {
  std::array<char, 128> active = {};
  if (!api->get_current_schema(session, active.data(), active.size()) ||
      active.data() != expected) {
    Fail("active schema changed at " + boundary + ": expected " + expected +
         ", got " + active.data());
  }
}

std::map<std::string, AcceptanceCase> LoadAcceptanceCases() {
  constexpr char kFixturePath[] =
      "tests/fixtures/m2_smart_english_cases.tsv";
  std::ifstream input(kFixturePath);
  if (!input) {
    Fail("M2 acceptance case fixture is missing");
  }
  std::map<std::string, AcceptanceCase> result;
  std::string line;
  bool saw_header = false;
  while (std::getline(input, line)) {
    if (line.empty() || line.front() == '#') {
      continue;
    }
    if (!saw_header) {
      if (line != "kind\tquery\texpected") {
        Fail("M2 acceptance case fixture has an unexpected header");
      }
      saw_header = true;
      continue;
    }
    const size_t first = line.find('\t');
    const size_t second =
        first == std::string::npos ? first : line.find('\t', first + 1);
    if (first == std::string::npos || second == std::string::npos ||
        line.find('\t', second + 1) != std::string::npos) {
      Fail("M2 acceptance case fixture is not strict three-column TSV");
    }
    const std::string kind = line.substr(0, first);
    if (kind.empty() || !result.emplace(
                             kind,
                             AcceptanceCase{
                                 line.substr(first + 1, second - first - 1),
                                 line.substr(second + 1)})
                             .second) {
      Fail("M2 acceptance case fixture has an invalid identity");
    }
  }
  if (!saw_header || result.size() != 10) {
    Fail("M2 acceptance case fixture is incomplete");
  }
  return result;
}

size_t CandidateIndex(RimeApi_stdbool* api,
                      RimeSessionId session,
                      const std::string& expected) {
  const auto candidates = Candidates(api, session);
  for (size_t i = 0; i < candidates.size(); ++i) {
    if (candidates[i].text == expected) {
      return i;
    }
  }

  std::cerr << "Candidates for expected text '" << expected << "':";
  for (const auto& candidate : candidates) {
    std::cerr << " [" << candidate.text << " :: " << candidate.comment
              << "]";
  }
  std::cerr << " origins:";
  for (const auto& candidate : CandidateOrigins(session)) {
    std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
              << candidate.genuine_type << ":" << candidate.start << "-"
              << candidate.end << "]";
  }
  std::cerr << '\n';
  Fail("missing expected candidate");
}

size_t NormalizedCandidateIndex(RimeApi_stdbool* api,
                                RimeSessionId session,
                                const std::string& expected) {
  const auto candidates = Candidates(api, session);
  for (size_t i = 0; i < candidates.size(); ++i) {
    if (BaseText(candidates[i].text) == expected) {
      return i;
    }
  }
  std::cerr << "Candidates for expected normalized text '" << expected
            << "':";
  for (const auto& candidate : candidates) {
    std::cerr << " [" << candidate.text << " :: " << candidate.comment
              << "]";
  }
  std::cerr << " origins:";
  for (const auto& candidate : CandidateOrigins(session)) {
    std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
              << candidate.genuine_type << ":" << candidate.start << "-"
              << candidate.end << "]";
  }
  std::cerr << '\n';
  Fail("missing expected normalized candidate");
}

void ExpectStandardTableOrigin(RimeSessionId session,
                               const std::string& expected) {
  const auto candidates = CandidateOrigins(session);
  if (std::none_of(candidates.begin(), candidates.end(),
                   [&](const auto& candidate) {
                     const auto& type = candidate.genuine_type;
                     return BaseText(candidate.text) == expected &&
                            (type == "table" || type == "user_table" ||
                             type == "completion");
                   })) {
    std::cerr << "Origins for expected standard Rime candidate '" << expected
              << "':";
    for (const auto& candidate : candidates) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << "]";
    }
    std::cerr << '\n';
    Fail("standard Rime table origin is missing for " + expected);
  }
}

size_t OptionalNormalizedCandidateIndex(
    const std::vector<CandidateView>& candidates,
    const std::string& expected) {
  for (size_t i = 0; i < candidates.size(); ++i) {
    if (BaseText(candidates[i].text) == expected) {
      return i;
    }
  }
  return candidates.size();
}

void Enter(RimeApi_stdbool* api,
           RimeSessionId session,
           const std::string& input) {
  // Replace an active spelling, but do not synthesize an abort at an idle or
  // zero-prefix prediction boundary.  Physical continuation after a commit
  // must preserve quote/spacing/context state until the next key classifies it.
  const char* active_input = api->get_input(session);
  if (active_input && *active_input != '\0') {
    api->clear_composition(session);
  }
  if (!api->simulate_key_sequence(session, input.c_str())) {
    Fail("could not simulate input: " + input);
  }
}

void ExpectCandidate(RimeApi_stdbool* api,
                     RimeSessionId session,
                     const std::string& input,
                     const std::string& expected) {
  Enter(api, session, input);
  CandidateIndex(api, session, expected);
}

void ExpectFirstCandidate(RimeApi_stdbool* api,
                          RimeSessionId session,
                          const std::string& input,
                          const std::string& expected) {
  Enter(api, session, input);
  const auto candidates = Candidates(api, session);
  if (candidates.empty() || candidates.front().text != expected) {
    const std::string actual =
        candidates.empty() ? "<none>" : candidates.front().text;
    Fail("expected first candidate '" + expected + "' for input '" + input +
         "', got '" + actual + "'");
  }
}

void ExpectFirstNormalizedCandidate(RimeApi_stdbool* api,
                                    RimeSessionId session,
                                    const std::string& input,
                                    const std::string& expected) {
  Enter(api, session, input);
  const auto candidates = Candidates(api, session);
  const std::string actual =
      candidates.empty() ? "<none>" : BaseText(candidates.front().text);
  if (actual != expected) {
    Fail("expected first normalized candidate '" + expected +
         "' for input '" + input + "', got '" + actual + "'");
  }
}

void ExpectEnglishTableReachable(RimeApi_stdbool* api,
                                 RimeSessionId session,
                                 const std::string& input) {
  Enter(api, session, input);
  const auto candidates = CandidateOrigins(session);
  if (std::none_of(candidates.begin(), candidates.end(),
                   [&](const auto& candidate) {
                     return BaseText(candidate.text) == input &&
                            candidate.genuine_type == "table";
                   })) {
    Fail("standard English table candidate was not reachable for input '" +
         input + "'");
  }
}

void ExpectExactEnglishFirst(RimeApi_stdbool* api,
                             RimeSessionId session,
                             const std::string& schema_id,
                             const std::string& input) {
  Enter(api, session, input);
  const auto candidates = CandidateOrigins(session);
  if (!candidates.empty() && BaseText(candidates.front().text) == input &&
      candidates.front().genuine_type == "table") {
    return;
  }
  std::cerr << "Origins for exact English '" << input << "' in "
            << schema_id << ":";
  for (const auto& candidate : candidates) {
    std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
              << candidate.genuine_type << ":q=" << candidate.quality
              << ":exact=" << candidate.phrase_exact
              << ":code=" << candidate.phrase_code_size
              << ":preedit=" << candidate.preedit << "]";
  }
  std::cerr << '\n';
  Fail("exact English dictionary word was not the first Chinese-mode candidate for input '" +
       input + "'");
}

CandidateOriginView ExpectAmbiguousEnglishPreservesChinese(
    RimeApi_stdbool* api,
    RimeSessionId session,
    const std::string& input,
    const std::string& expected_chinese) {
  Enter(api, session, input);
  const auto candidates = CandidateOrigins(session);
  const auto english = std::find_if(
      candidates.begin(), candidates.end(), [&](const auto& candidate) {
        return candidate.genuine_type == "table" &&
               BaseText(candidate.text) == input;
      });
  if (english == candidates.end()) {
    std::cerr << "Origins for English overlap '" << input << "':";
    for (const auto& candidate : candidates) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << "]";
    }
    std::cerr << '\n';
    Fail("ambiguous English candidate is not reachable for input '" + input +
         "'");
  }
  const auto chinese = std::find_if(
      candidates.begin(), candidates.end(), [&](const auto& candidate) {
        return candidate.genuine_language == "linnet_zh" &&
               candidate.start == 0 && candidate.end == input.size() &&
               BaseText(candidate.text) == expected_chinese;
      });
  if (chinese == candidates.end()) {
    Fail("expected same-span Chinese candidate '" + expected_chinese +
         "' is absent for ambiguous English input '" + input + "'");
  }
  if (chinese != candidates.begin() || english == candidates.begin()) {
    Fail("ambiguous English displaced the same-span Chinese candidate for input '" +
         input + "'");
  }
  return *chinese;
}

void ExpectPartialSelectionRanksCurrentSegment(RimeApi_stdbool* api) {
  constexpr char kSchema[] = "linnet_zh";
  constexpr char kInputPrefix[] = "xwvb";
  constexpr char kConfirmedPrefix[] = "下周";
  constexpr size_t kPrefixEnd = sizeof(kInputPrefix) - 1;
  struct RemainderCase {
    const char* input;
    const char* expected_first;
    bool chinese_first;
  };
  constexpr std::array<RemainderCase, 4> kCases{{
      {"ii", "吃", true},
      {"l", "了", true},
      {"bung", "不能", true},
      {"banana", "banana", false},
  }};

  for (const auto& test : kCases) {
    const std::string input = std::string(kInputPrefix) + test.input;
    const RimeSessionId session = api->create_session();
    if (!session || !api->select_schema(session, kSchema)) {
      if (session) api->destroy_session(session);
      Fail("could not create the partial-selection schema session");
    }
    Enter(api, session, input);
    const auto initial = CandidateOrigins(session, 64);
    const auto prefix = std::find_if(
        initial.begin(), initial.end(), [&](const auto& candidate) {
          return BaseText(candidate.text) == kConfirmedPrefix &&
                 candidate.start == 0 && candidate.end == kPrefixEnd;
        });
    if (prefix == initial.end() ||
        !api->select_candidate(session,
                               static_cast<size_t>(prefix - initial.begin()))) {
      api->destroy_session(session);
      Fail("could not partially confirm the leading Chinese segment before '" +
           std::string(test.input) + "'");
    }
    const auto live_session = rime::Service::instance().GetSession(session);
    if (!live_session || !live_session->context() ||
        live_session->context()->composition().empty()) {
      api->destroy_session(session);
      Fail("partial Chinese selection lost its remainder segment");
    }
    const auto& remainder_segment =
        live_session->context()->composition().back();
    if (remainder_segment.start != kPrefixEnd ||
        remainder_segment.end != input.size()) {
      api->destroy_session(session);
      Fail("partial Chinese selection exposed the wrong remainder span");
    }

    const auto remainder = CandidateOrigins(session, 64);
    const auto english = std::find_if(
        remainder.begin(), remainder.end(), [&](const auto& candidate) {
          return candidate.genuine_language == "linnet_en" &&
                 candidate.genuine_type == "table" &&
                 candidate.phrase_exact &&
                 BaseText(candidate.text) == test.input &&
                 candidate.start == kPrefixEnd && candidate.end == input.size();
        });
    const bool expected_order =
        !remainder.empty() &&
        BaseText(remainder.front().text) == test.expected_first &&
        english != remainder.end() &&
        (test.chinese_first
             ? remainder.front().genuine_language == "linnet_zh" &&
                   english != remainder.begin()
             : english == remainder.begin());
    if (!expected_order) {
      std::cerr << "Partial-selection remainder origins for '" << test.input
                << "':";
      for (const auto& candidate : remainder) {
        std::cerr << " [" << candidate.text << ":" << candidate.genuine_type
                  << ":" << candidate.genuine_language << ":"
                  << candidate.start << "-" << candidate.end << "]";
      }
      std::cerr << '\n';
      api->destroy_session(session);
      Fail("partial selection did not apply the standalone remainder ranking contract");
    }
    api->destroy_session(session);
  }
}

bool ExpectSingleLetterChinesePriority(RimeApi_stdbool* api,
                                       RimeSessionId session,
                                       const std::string& schema_id,
                                       char letter) {
  const std::string input(1, letter);
  Enter(api, session, input);
  const auto candidates = CandidateOrigins(session);
  const auto chinese = std::find_if(
      candidates.begin(), candidates.end(), [&](const auto& candidate) {
        return candidate.genuine_language == "linnet_zh" &&
               candidate.start == 0 && candidate.end == input.size();
      });
  if (chinese == candidates.end()) {
    return false;
  }
  const auto english = std::find_if(
      candidates.begin(), candidates.end(), [&](const auto& candidate) {
        return candidate.genuine_language == "linnet_en" &&
               candidate.genuine_type == "table" && candidate.phrase_exact &&
               candidate.start == 0 && candidate.end == input.size();
      });
  if (english == candidates.end()) {
    Fail("single-letter English candidate became unreachable for input '" +
         input + "' in " + schema_id);
  }
  if (candidates.front().genuine_language == "linnet_zh" &&
      candidates.front().start == 0 &&
      candidates.front().end == input.size()) {
    return true;
  }
  std::cerr << "Origins for single-letter Chinese input '" << input
            << "' in " << schema_id << ":";
  for (const auto& candidate : candidates) {
    std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
              << candidate.genuine_type << ":" << candidate.genuine_language
              << ":" << candidate.start << "-" << candidate.end << "]";
  }
  std::cerr << '\n';
  Fail("single-letter English displaced an available Chinese candidate for input '" +
       input + "' in " + schema_id);
}

void ExpectGlobalAmbiguousEnglishFirstWithoutChinese(RimeApi_stdbool* api,
                                                      RimeSessionId session,
                                                      const std::string& input) {
  Enter(api, session, input);
  const auto candidates = CandidateOrigins(session);
  if (candidates.empty() || BaseText(candidates.front().text) != input ||
      candidates.front().genuine_type != "table") {
    Fail("English table candidate was not first without a same-span Chinese candidate for input '" +
         input + "'");
  }
  const auto chinese = std::find_if(
      candidates.begin(), candidates.end(), [&](const auto& candidate) {
        return candidate.genuine_type == "phrase" &&
               BaseText(candidate.text) != input && candidate.start == 0 &&
               candidate.end == input.size();
      });
  if (chinese != candidates.end()) {
    Fail("global ambiguous English test expected no same-span Chinese candidate for input '" +
         input + "'");
  }
}

void ExpectCandidateAbsent(RimeApi_stdbool* api,
                           RimeSessionId session,
                           const std::string& input,
                           const std::string& forbidden) {
  Enter(api, session, input);
  const auto candidates = Candidates(api, session);
  if (std::any_of(candidates.begin(), candidates.end(),
                  [&](const auto& candidate) {
                    return candidate.text == forbidden ||
                           BaseText(candidate.text) == forbidden;
                  })) {
    for (const auto& candidate : CandidateOrigins(session)) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << "]";
    }
    std::cerr << '\n';
    Fail("disabled candidate remained visible for input '" + input + "'");
  }
}

void ExpectPinyinEchoFallbackRemoved(RimeApi_stdbool* api,
                                     RimeSessionId session,
                                     const std::string& expected_first) {
  Enter(api, session, ";yun");
  const auto live_session = rime::Service::instance().GetSession(session);
  if (!live_session || !live_session->schema() || !live_session->context() ||
      live_session->context()->composition().empty()) {
    Fail("pinyin echo-fallback probe has no live composition");
  }
  const rime::Ticket ticket(live_session->schema(),
                            "linnet_english_translator");
  const auto engine =
      rime::PredictEngineComponent::Shared()->GetInstance(ticket);
  if (!engine) {
    Fail("production pinyin projection has no Smart English index");
  }
  const linnet::SmartEnglishIndex index(engine);
  const auto source_rows = index.LookupPinyin("yun");
  if (source_rows.size() != 64) {
    Fail("production pinyin projection no longer has its bounded 64 rows");
  }
  auto& segment = live_session->context()->composition().back();
  const size_t prepared = segment.menu ? segment.menu->Prepare(256) : 0;
  if (!segment.menu || prepared < source_rows.size() || prepared >= 256) {
    Fail("pinyin echo-fallback probe did not exhaust a bounded real menu: " +
         std::to_string(prepared) + " candidates for " +
         std::to_string(source_rows.size()) + " source rows");
  }
  std::vector<std::string> actual;
  actual.reserve(prepared);
  for (size_t index = 0; index < prepared; ++index) {
    const auto candidate = segment.menu->GetCandidateAt(index);
    const auto genuine = rime::Candidate::GetGenuineCandidate(candidate);
    if (!candidate || !genuine || genuine->type() != "linnet_pinyin" ||
        candidate->type() == "raw" || genuine->type() == "raw" ||
        candidate->type() == kForcedRawCandidateType ||
        genuine->type() == kForcedRawCandidateType) {
      Fail("pinyin echo-fallback probe retained a raw candidate or lost a real candidate");
    }
    if (index == 0 && BaseText(candidate->text()) != expected_first) {
      Fail("pinyin echo-fallback probe changed the first real candidate");
    }
    actual.push_back(BaseText(candidate->text()));
  }
  for (const auto& source : source_rows) {
    if (std::find(actual.begin(), actual.end(), source.text) == actual.end()) {
      Fail("pinyin echo-fallback probe lost source candidate: " + source.text);
    }
  }
}

void ExpectAutomaticPinyinOrder(
    RimeApi_stdbool* api,
    RimeSessionId session,
    const std::string& input,
    const std::vector<std::string>& expected_pinyin_order) {
  Enter(api, session, input);
  const auto origins = CandidateOrigins(session);
  std::vector<std::string> pinyin_candidates;
  size_t first_pinyin = origins.size();
  size_t last_ordinary = 0;
  bool has_ordinary = false;
  for (size_t index = 0; index < origins.size(); ++index) {
    const auto& candidate = origins[index];
    if (candidate.genuine_type == "linnet_pinyin") {
      if (first_pinyin == origins.size()) first_pinyin = index;
      pinyin_candidates.push_back(BaseText(candidate.text));
    } else if (candidate.genuine_type != "raw" &&
               candidate.genuine_type != kForcedRawCandidateType) {
      last_ordinary = index;
      has_ordinary = true;
    }
  }
  size_t previous = 0;
  bool first = true;
  bool order_matches = true;
  for (const auto& expected : expected_pinyin_order) {
    const auto found = std::find(pinyin_candidates.begin(),
                                 pinyin_candidates.end(), expected);
    if (found == pinyin_candidates.end()) {
      order_matches = false;
      break;
    }
    const size_t index =
        static_cast<size_t>(std::distance(pinyin_candidates.begin(), found));
    if (!first && index <= previous) {
      order_matches = false;
      break;
    }
    first = false;
    previous = index;
  }
  if (!order_matches) {
    std::cerr << "Automatic pinyin origins for input '" << input << "':";
    for (const auto& candidate : origins) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << "]";
    }
    std::cerr << '\n';
    Fail("English ordinary input lost the upstream pinyin-to-English order");
  }
  if (has_ordinary && first_pinyin <= last_ordinary) {
    Fail("automatic pinyin displaced an ordinary English candidate");
  }
}

void ExpectFullSpanCandidateAbsent(RimeApi_stdbool* api,
                                   RimeSessionId session,
                                   const std::string& input,
                                   const std::string& forbidden,
                                   const std::string& expected_schema) {
  ExpectCurrentSchema(api, session, expected_schema,
                      "disabled-correction input");
  Enter(api, session, input);
  ExpectCurrentSchema(api, session, expected_schema,
                      "disabled-correction composition");
  const auto origins = CandidateOrigins(session);
  ExpectCurrentSchema(api, session, expected_schema,
                      "disabled-correction candidate preparation");
  for (const auto& candidate : origins) {
    if (BaseText(candidate.text) == forbidden && candidate.start == 0 &&
        candidate.end == input.size()) {
      Fail("disabled full-span correction remained visible for input '" +
           input + "'");
    }
  }
}

void ExpectCurrentCandidateAbsent(RimeApi_stdbool* api,
                                  RimeSessionId session,
                                  const std::string& forbidden) {
  const auto candidates = Candidates(api, session);
  if (std::any_of(candidates.begin(), candidates.end(),
                  [&](const auto& candidate) {
                    return candidate.text == forbidden ||
                           BaseText(candidate.text) == forbidden;
                  })) {
    Fail("candidate remained visible in current menu: " + forbidden);
  }
}

void ExpectNormalizedCandidate(RimeApi_stdbool* api,
                               RimeSessionId session,
                               const std::string& input,
                               const std::string& expected) {
  Enter(api, session, input);
  NormalizedCandidateIndex(api, session, expected);
}

void ExpectNormalizedBefore(RimeApi_stdbool* api,
                            RimeSessionId session,
                            const std::string& input,
                            const std::string& earlier,
                            const std::string& later) {
  Enter(api, session, input);
  const size_t earlier_index =
      NormalizedCandidateIndex(api, session, earlier);
  const size_t later_index = NormalizedCandidateIndex(api, session, later);
  if (earlier_index >= later_index) {
    Fail("candidate order changed for " + input + ": " + earlier +
         " must precede " + later);
  }
}

void ExpectCommentContains(RimeApi_stdbool* api,
                           RimeSessionId session,
                           const std::string& input,
                           const std::string& candidate_text,
                           const std::string& first,
                           const std::string& second) {
  Enter(api, session, input);
  const auto candidates = Candidates(api, session);
  for (const auto& candidate : candidates) {
    if (BaseText(candidate.text) == candidate_text) {
      if (candidate.comment.find(first) == std::string::npos ||
          candidate.comment.find(second) == std::string::npos) {
        Fail("candidate metadata comment is incomplete for " + candidate_text +
             ": " + candidate.comment);
      }
      return;
    }
  }
  Fail("metadata candidate is missing for " + candidate_text);
}

void ExpectCommentEmpty(RimeApi_stdbool* api,
                        RimeSessionId session,
                        const std::string& input,
                        const std::string& candidate_text) {
  Enter(api, session, input);
  const auto candidates = Candidates(api, session);
  bool found = false;
  for (const auto& candidate : candidates) {
    if (BaseText(candidate.text) != candidate_text) continue;
    found = true;
    if (!candidate.comment.empty()) {
      std::array<char, 128> active_schema = {};
      api->get_current_schema(session, active_schema.data(),
                              active_schema.size());
      std::cerr << "Unexpected metadata for '" << candidate_text << "': '"
                << candidate.comment << "'; schema=" << active_schema.data()
                << "; origins:";
      for (const auto& origin : CandidateOrigins(session)) {
        std::cerr << " [" << origin.text << ":" << origin.type << ":"
                  << origin.genuine_type << "]";
      }
      std::cerr << '\n';
      Fail("skipped proper term received metadata: " + candidate_text);
    }
  }
  if (!found) Fail("proper-term candidate is missing for " + candidate_text);
}

void ExpectCommentIncludesExcludes(RimeApi_stdbool* api,
                                   RimeSessionId session,
                                   const std::string& input,
                                   const std::string& candidate_text,
                                   const std::string& included,
                                   const std::string& excluded) {
  Enter(api, session, input);
  for (const auto& candidate : Candidates(api, session)) {
    if (BaseText(candidate.text) != candidate_text) continue;
    if (candidate.comment.find(included) == std::string::npos ||
        candidate.comment.find(excluded) != std::string::npos) {
      Fail("candidate metadata visibility is wrong for " + candidate_text +
           ": " + candidate.comment);
    }
    return;
  }
  Fail("metadata candidate is missing for " + candidate_text);
}

void ExpectNormalizedOrder(RimeApi_stdbool* api,
                           RimeSessionId session,
                           const std::string& input,
                           const std::vector<std::string>& expected) {
  Enter(api, session, input);
  const auto candidates = Candidates(api, session);
  size_t previous = 0;
  bool first = true;
  for (const auto& value : expected) {
    size_t position = candidates.size();
    for (size_t index = 0; index < candidates.size(); ++index) {
      if (BaseText(candidates[index].text) == value) {
        position = index;
        break;
      }
    }
    if (position == candidates.size() || (!first && position <= previous)) {
      std::cerr << "Candidate order for input '" << input << "':";
      for (size_t index = 0; index < candidates.size(); ++index) {
        std::cerr << " [" << index << ":" << candidates[index].text << "]";
      }
      std::cerr << '\n';
      Fail("candidate order changed for input " + input);
    }
    first = false;
    previous = position;
  }
}

RimeSessionId CreateSchemaSession(RimeApi_stdbool* api,
                                  const char* schema_id) {
  const RimeSessionId session = api->create_session();
  if (!session) {
    Fail("could not create schema session");
  }
  if (!api->select_schema(session, schema_id)) {
    api->destroy_session(session);
    Fail("could not select schema");
  }
  return session;
}

std::string AbbreviatedModeLabel(RimeApi_stdbool* api,
                                 RimeSessionId session,
                                 bool ascii_mode) {
  const RimeStringSlice label = api->get_state_label_abbreviated(
      session, "ascii_mode", ascii_mode, true);
  if (!label.str || label.length == 0) {
    Fail("ascii_mode has no abbreviated status label");
  }
  return std::string(label.str, label.length);
}

void ExpectModeStatusLabels(RimeApi_stdbool* api) {
  for (const char* schema_id : kProductSchemaIDs) {
    const RimeSessionId session = CreateSchemaSession(api, schema_id);
    const std::string expected_input =
        std::strcmp(schema_id, "linnet_en") == 0
            ? "En"
            : (std::strcmp(schema_id, "linnet_zh_pinyin") == 0 ? "中"
                                                                 : "双");
    const std::string input = AbbreviatedModeLabel(api, session, false);
    const std::string ascii = AbbreviatedModeLabel(api, session, true);
    api->destroy_session(session);
    if (input != expected_input || ascii != "A") {
      Fail(std::string(schema_id) + " status labels were '" + input +
           "'/'" + ascii + "', expected '" + expected_input + "'/'A'");
    }
  }
}

void SetSchemaString(RimeApi_stdbool* api,
                     const char* schema_id,
                     const char* key,
                     const char* value) {
  RimeConfig config = {};
  if (!api->schema_open(schema_id, &config)) {
    Fail("could not open schema config");
  }
  const bool updated = api->config_set_string(&config, key, value);
  const bool closed = api->config_close(&config);
  if (!updated || !closed) {
    Fail("could not update schema config fixture");
  }
}

void SetSchemaBool(RimeApi_stdbool* api,
                   const char* schema_id,
                   const char* key,
                   bool value) {
  RimeConfig config = {};
  if (!api->schema_open(schema_id, &config)) {
    Fail("could not open schema config");
  }
  const bool updated = api->config_set_bool(&config, key, value);
  const bool closed = api->config_close(&config);
  if (!updated || !closed) {
    Fail("could not update schema boolean fixture");
  }
}

void ExpectDeployedMenuPageSize(RimeApi_stdbool* api,
                                const char* schema_id,
                                int expected) {
  const RimeSessionId session = CreateSchemaSession(api, schema_id);
  Enter(api, session, "a");
  RimeContext_stdbool context = {};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  if (!api->get_context(session, &context)) {
    Fail("could not inspect configured menu page size");
  }
  const int actual = context.menu.page_size;
  api->free_context(&context);
  api->destroy_session(session);
  if (actual != expected) {
    Fail("deployed menu/page_size produced runtime page size " +
         std::to_string(actual) +
         ", expected " + std::to_string(expected));
  }
}

void ExpectNineCandidateSelectKeys(RimeApi_stdbool* api,
                                   const char* schema_id,
                                   const std::string& input) {
  const RimeSessionId session = CreateSchemaSession(api, schema_id);
  Enter(api, session, input);
  RimeContext_stdbool context = {};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  if (!api->get_context(session, &context)) {
    Fail(std::string(schema_id) + " did not publish candidate selection keys");
  }
  const std::string select_keys =
      context.menu.select_keys ? context.menu.select_keys : "";
  api->free_context(&context);
  if (select_keys != "123456789") {
    Fail(std::string(schema_id) + " exposed candidate selection keys '" +
         select_keys + "' instead of 1-9");
  }
  if (api->process_key(session, XK_0, 0)) {
    Fail(std::string(schema_id) +
         " swallowed zero despite a nine-candidate page");
  }
  api->destroy_session(session);
}

LatencySample MeasureKey(RimeApi_stdbool* api,
                         RimeSessionId session,
                         int keycode) {
  RimeContext_stdbool context = {};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  const auto start = std::chrono::steady_clock::now();
  const bool processed = api->process_key(session, keycode, 0);
  const bool read = api->get_context(session, &context);
  const bool freed = read && api->free_context(&context);
  const auto end = std::chrono::steady_clock::now();
  if (!processed || !read || !freed) {
    Fail("latency sample could not process and read context");
  }
  return std::chrono::duration_cast<Nanoseconds>(end - start).count();
}

void RunLatencySteps(RimeApi_stdbool* api,
                     RimeSessionId session,
                     const std::string& sequence,
                     size_t count,
                     std::vector<LatencySample>* samples) {
  if (sequence.empty()) {
    Fail("latency sequence is empty");
  }
  for (size_t index = 0; index < count; ++index) {
    if (index % sequence.size() == 0) {
      api->clear_composition(session);
    }
    const auto keycode = static_cast<unsigned char>(
        sequence[index % sequence.size()]);
    const LatencySample elapsed = MeasureKey(api, session, keycode);
    if (samples) {
      samples->push_back(elapsed);
    }
  }
}

LatencySample NearestRank(std::vector<LatencySample>* samples,
                          size_t percentile) {
  if (!samples || samples->empty() || percentile == 0 || percentile > 100) {
    Fail("invalid latency percentile request");
  }
  std::sort(samples->begin(), samples->end());
  const size_t rank =
      (samples->size() * percentile + 99) / 100;
  return samples->at(rank - 1);
}

void BenchmarkSchema(RimeApi_stdbool* api,
                     const char* schema_id,
                     const std::string& sequence) {
  const RimeSessionId session = CreateSchemaSession(api, schema_id);
  RunLatencySteps(api, session, sequence, kLatencyWarmupSamples, nullptr);

  std::vector<LatencySample> samples;
  samples.reserve(kLatencySamples);
  RunLatencySteps(api, session, sequence, kLatencySamples, &samples);
  api->destroy_session(session);

  const LatencySample p95 = NearestRank(&samples, 95);
  const LatencySample p99 = NearestRank(&samples, 99);
  const LatencySample p95_limit =
      std::chrono::duration_cast<Nanoseconds>(std::chrono::milliseconds(5))
          .count();
  const LatencySample p99_limit =
      std::chrono::duration_cast<Nanoseconds>(std::chrono::milliseconds(15))
          .count();
  std::cout << "rime_smoke_test: latency schema=" << schema_id
            << " samples=" << kLatencySamples << " p95_ns=" << p95
            << " p99_ns=" << p99 << '\n';
  if (p95 > p95_limit || p99 > p99_limit) {
    Fail("per-key latency exceeded the product contract");
  }
}

void ExpectSchemaList(RimeApi_stdbool* api) {
  RimeSchemaList list = {};
  if (!api->get_schema_list(&list)) {
    Fail("could not read schema list");
  }

  std::vector<std::string> actual;
  bool valid = list.size == kProductSchemaIDs.size();
  for (size_t index = 0; valid && index < list.size; ++index) {
    valid = list.list[index].schema_id != nullptr;
    if (valid) actual.emplace_back(list.list[index].schema_id);
  }
  api->free_schema_list(&list);
  std::vector<std::string> expected(kProductSchemaIDs.begin(),
                                    kProductSchemaIDs.end());
  std::sort(actual.begin(), actual.end());
  std::sort(expected.begin(), expected.end());
  valid = valid && actual == expected;
  if (!valid) {
    Fail("product schema list is not the exact Linnet profile set");
  }
}

void ExpectFreshDefaultSchema(RimeApi_stdbool* api,
                              const std::string& expected_schema) {
  const RimeSessionId session = api->create_session();
  if (!session) Fail("could not create a fresh default-schema session");
  ExpectCurrentSchema(api, session, expected_schema,
                      "document-selected fresh session");
  api->destroy_session(session);
}

void ExpectSharedPredictIdentity(RimeSessionId session_id) {
  const auto session = rime::Service::instance().GetSession(session_id);
  if (!session || !session->schema()) {
    Fail("could not inspect the active schema for prediction identity");
  }
  const auto first_factory = rime::PredictEngineComponent::Shared();
  const auto second_factory = rime::PredictEngineComponent::Shared();
  if (!first_factory || first_factory.get() != second_factory.get()) {
    Fail("PredictEngine factory identity diverged in one process");
  }

  const rime::Ticket predictor_ticket(session->schema(), "predictor");
  const rime::Ticket translator_ticket(session->schema(),
                                       "predict_translator");
  const rime::Ticket product_ticket(session->schema(),
                                    "linnet_english_translator");
  const auto predictor_engine = first_factory->GetInstance(predictor_ticket);
  const auto translator_engine = first_factory->GetInstance(translator_ticket);
  const auto product_engine = second_factory->GetInstance(product_ticket);
  if (!predictor_engine || predictor_engine.get() != translator_engine.get() ||
      predictor_engine.get() != product_engine.get()) {
    Fail("PredictEngine identity diverged across same-schema consumers");
  }
  std::cout << "rime_smoke_test: shared PredictEngine factory/engine identity: "
               "PASS\n";
}

std::vector<std::string> LoadReviewedLowercaseNewWords() {
  constexpr char kPath[] =
      "data/linnet/linnet_en_zh_new_words.tsv";
  std::ifstream input(kPath);
  if (!input) {
    Fail("reviewed English new-word ledger is missing");
  }
  std::string line;
  if (!std::getline(input, line) || line != "text\tfrequency") {
    Fail("reviewed English new-word ledger header changed");
  }
  std::vector<std::string> words;
  while (std::getline(input, line)) {
    const size_t tab = line.find('\t');
    if (tab == std::string::npos ||
        line.find('\t', tab + 1) != std::string::npos || tab == 0 ||
        tab + 1 == line.size()) {
      Fail("reviewed English new-word ledger row is invalid");
    }
    const std::string word = line.substr(0, tab);
    if (std::all_of(word.begin(), word.end(), [](unsigned char byte) {
          return byte >= 'a' && byte <= 'z';
        })) {
      words.push_back(word);
    }
  }
  if (words.empty()) {
    Fail("reviewed English new-word ledger has no lowercase Phonex rows");
  }
  return words;
}

void ExpectCuratedPhonexRuntimeProjection(RimeSessionId session_id) {
  const auto session = rime::Service::instance().GetSession(session_id);
  if (!session || !session->schema()) {
    Fail("could not inspect the active schema for Phonex projection");
  }
  const rime::Ticket ticket(session->schema(),
                            "linnet_english_translator");
  const auto engine =
      rime::PredictEngineComponent::Shared()->GetInstance(ticket);
  if (!engine) {
    Fail("could not open the production Smart English index");
  }
  const linnet::SmartEnglishIndex index(engine);
  const auto words = LoadReviewedLowercaseNewWords();
  size_t verified = 0;
  for (const auto& word : words) {
    std::string query = word;
    while (query.size() <= 3) query.push_back('s');
    const auto corrections = index.LookupCorrections(query);
    const size_t matches = static_cast<size_t>(std::count_if(
        corrections.begin(), corrections.end(),
        [&](const auto& row) { return row.text == word; }));
    if (matches != 1) {
      Fail("production C++ Phonex could not recover reviewed word exactly "
           "once: " +
           word);
    }
    ++verified;
  }
  if (verified != words.size()) {
    Fail("production C++ Phonex did not cover every eligible reviewed word");
  }
  std::cout << "rime_smoke_test: reviewed Swift projection reachable through "
               "production C++ Phonex: "
            << verified << " rows PASS\n";
}

void ExpectCommit(RimeApi_stdbool* api,
                  RimeSessionId session,
                  const std::string& expected) {
  RimeCommit commit = {};
  RIME_STRUCT_INIT(RimeCommit, commit);
  if (!api->get_commit(session, &commit)) {
    Fail("candidate selection did not produce a commit");
  }
  const std::string actual = commit.text ? commit.text : "";
  api->free_commit(&commit);
  if (actual != expected) {
    Fail("expected commit '" + expected + "', got '" + actual + "'");
  }
}

std::string TakeCommit(RimeApi_stdbool* api, RimeSessionId session) {
  RimeCommit commit = {};
  RIME_STRUCT_INIT(RimeCommit, commit);
  if (!api->get_commit(session, &commit)) {
    Fail("expected a Rime commit");
  }
  const std::string text = commit.text ? commit.text : "";
  api->free_commit(&commit);
  return text;
}

std::string TakeCommit(RimeApi_stdbool* api,
                       RimeSessionId session,
                       const std::string& reason) {
  RimeCommit commit = {};
  RIME_STRUCT_INIT(RimeCommit, commit);
  if (!api->get_commit(session, &commit)) {
    Fail("expected a Rime commit after " + reason);
  }
  const std::string text = commit.text ? commit.text : "";
  api->free_commit(&commit);
  return text;
}

std::string TakeOptionalCommit(RimeApi_stdbool* api,
                               RimeSessionId session) {
  RimeCommit commit = {};
  RIME_STRUCT_INIT(RimeCommit, commit);
  if (!api->get_commit(session, &commit)) return {};
  const std::string text = commit.text ? commit.text : "";
  api->free_commit(&commit);
  return text;
}

void ExpectExpandedCandidateAbsoluteSelection(RimeApi_stdbool* api) {
  constexpr size_t kMaximumExpandedCandidates = 27;
  const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
  Enter(api, session, "a");

  RimeContext_stdbool context = {};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  if (!api->get_context(session, &context)) {
    api->destroy_session(session);
    Fail("could not inspect the expanded candidate fixture");
  }
  const int page_size = context.menu.page_size;
  const int page_no = context.menu.page_no;
  const bool has_following_page = !context.menu.is_last_page;
  api->free_context(&context);
  if (page_size <= 0 || page_no != 0 || !has_following_page) {
    api->destroy_session(session);
    Fail("expanded candidate fixture no longer starts with multiple pages");
  }

  RimeCandidateListIterator iterator = {};
  if (!api->candidate_list_from_index(session, &iterator, 0)) {
    api->destroy_session(session);
    Fail("could not begin the bounded expanded candidate iterator");
  }
  std::vector<std::pair<size_t, std::string>> candidates;
  bool indices_are_absolute_and_contiguous = true;
  while (candidates.size() < kMaximumExpandedCandidates &&
         api->candidate_list_next(&iterator)) {
    const size_t expected_index = candidates.size();
    if (iterator.index < 0 ||
        static_cast<size_t>(iterator.index) != expected_index) {
      indices_are_absolute_and_contiguous = false;
    }
    candidates.emplace_back(
        iterator.index < 0 ? 0 : static_cast<size_t>(iterator.index),
        iterator.candidate.text ? iterator.candidate.text : "");
  }
  api->candidate_list_end(&iterator);

  const size_t second_page_index = static_cast<size_t>(page_size);
  if (!indices_are_absolute_and_contiguous ||
      candidates.size() <= second_page_index ||
      candidates[second_page_index].second.empty()) {
    api->destroy_session(session);
    Fail("bounded expanded iterator did not expose a real second Rime page");
  }
  const size_t absolute_index = candidates[second_page_index].first;
  const std::string expected_commit = candidates[second_page_index].second;
  if (!api->select_candidate(session, absolute_index)) {
    api->destroy_session(session);
    Fail("absolute selection could not select an expanded-page candidate");
  }
  const std::string actual_commit = TakeCommit(api, session);
  api->destroy_session(session);
  if (actual_commit != expected_commit) {
    Fail("expanded-page absolute selection committed the wrong candidate");
  }
}

void ExpectForcedRawOverflowSafety(RimeApi_stdbool* api) {
  constexpr char kInput[] = "inte";
  const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
  Enter(api, session, kInput);
  const auto live_session = rime::Service::instance().GetSession(session);
  if (!live_session || !live_session->context() ||
      live_session->context()->composition().empty()) {
    Fail("forced-raw overflow probe has no live composition");
  }
  auto& segment = live_session->context()->composition().back();
  if (!segment.menu || segment.menu->Prepare(66) < 66) {
    Fail("production English prefix no longer crosses the 64-candidate boundary");
  }
  for (size_t index = 0; index < 66; ++index) {
    const auto candidate = segment.menu->GetCandidateAt(index);
    const auto genuine = rime::Candidate::GetGenuineCandidate(candidate);
    if (!candidate || !genuine) {
      Fail("forced-raw overflow probe found an invalid candidate");
    }
    const bool raw = candidate->type() == "raw" ||
                     genuine->type() == "raw" ||
                     candidate->type() == kForcedRawCandidateType ||
                     genuine->type() == kForcedRawCandidateType;
    if (index == 0) {
      if (!raw || candidate->type() != kForcedRawCandidateType ||
          genuine->type() != kForcedRawCandidateType ||
          BaseText(candidate->text()) != kInput) {
        Fail("typed forced raw was not first beyond the bounded prefix");
      }
    } else if (raw) {
      Fail("forced-raw overflow probe retained a duplicate raw candidate");
    }
  }
  if (!api->process_key(session, XK_space, 0) ||
      TakeCommit(api, session) != std::string(kInput) + " ") {
    Fail("Space did not safely commit the typed raw beyond 64 competitors");
  }
  api->destroy_session(session);
}

void ExpectNoCommit(RimeApi_stdbool* api,
                    RimeSessionId session,
                    const std::string& reason) {
  RimeCommit commit = {};
  RIME_STRUCT_INIT(RimeCommit, commit);
  if (api->get_commit(session, &commit)) {
    const std::string text = commit.text ? commit.text : "";
    api->free_commit(&commit);
    Fail("unexpected commit '" + text + "' after " + reason);
  }
}

void ExpectCapsLockPreservesComposition(RimeApi_stdbool* api,
                                        const char* schema_id,
                                        const char* input) {
  const RimeSessionId session = CreateSchemaSession(api, schema_id);
  Enter(api, session, input);
  const auto candidates = Candidates(api, session);
  const std::string expected =
      candidates.empty() ? std::string(input) : candidates.front().text;
  if (api->process_key(session, XK_Caps_Lock, 0) ||
      !api->get_option(session, "ascii_mode")) {
    Fail(std::string(schema_id) +
         " did not enter raw ASCII while preserving composition '" + input +
         "'");
  }
  const std::string actual = TakeCommit(
      api, session, std::string(schema_id) + " Caps Lock composition");
  if (actual != expected) {
    Fail(std::string(schema_id) + " Caps Lock changed or discarded '" +
         input + "': expected '" + expected + "', got '" + actual + "'");
  }
  const char* remaining = api->get_input(session);
  if (remaining && *remaining) {
    Fail(std::string(schema_id) +
         " retained a hidden composition after Caps Lock commit");
  }
  api->destroy_session(session);
}

void ExpectCapsLockPreservesPartialComposition(RimeApi_stdbool* api,
                                               const char* schema_id) {
  constexpr char kInput[] = "thisisenglish";
  const RimeSessionId session = CreateSchemaSession(api, schema_id);
  Enter(api, session, kInput);
  const auto live = rime::Service::instance().GetSession(session);
  const auto origins = CandidateOrigins(session);
  if (!live || !live->context() || origins.empty() ||
      origins.front().start != 0 ||
      origins.front().end >= std::strlen(kInput)) {
    Fail(std::string(schema_id) +
         " Caps Lock partial-match fixture lost its untranslated suffix");
  }
  const std::string preview = live->context()->GetCommitText();
  if (api->process_key(session, XK_Caps_Lock, 0) ||
      !api->get_option(session, "ascii_mode")) {
    Fail(std::string(schema_id) +
         " did not enter raw ASCII from a partial composition");
  }
  ExpectNoCommit(api, session, "Caps Lock partial composition");
  const char* remaining = api->get_input(session);
  const auto after = rime::Service::instance().GetSession(session);
  if (!remaining || remaining != std::string(kInput) || !after ||
      !after->context() || after->context()->GetCommitText() != preview) {
    Fail(std::string(schema_id) +
         " Caps Lock discarded a partial match or its raw suffix");
  }
  api->destroy_session(session);
}

void ExpectCapsLockRawPath(RimeApi_stdbool* api, const char* schema_id) {
  for (const char* input : {"shi", "qxhr", "bdbdbdbd", "uuuuuuuu"}) {
    ExpectCapsLockPreservesComposition(api, schema_id, input);
  }
  if (std::strcmp(schema_id, "linnet_zh") == 0) {
    ExpectCapsLockPreservesPartialComposition(api, "linnet_zh_pinyin");
  }
  const RimeSessionId session = CreateSchemaSession(api, schema_id);
  if (api->get_option(session, "ascii_mode")) {
    Fail(std::string(schema_id) + " unexpectedly started in ASCII mode");
  }
  if (api->process_key(session, XK_Caps_Lock, 0) ||
      !api->get_option(session, "ascii_mode")) {
    Fail(std::string(schema_id) + " did not enter the Caps Lock raw path");
  }
  if (api->process_key(session, 'A', kLockMask)) {
    Fail(std::string(schema_id) + " swallowed Caps Lock raw text");
  }
  ExpectNoCommit(api, session, "Caps Lock raw text");

  // Caps Lock owns this raw-ASCII session. Shift events carry LockMask and
  // must remain ordinary host events rather than being mistaken for a fresh
  // isolated-Shift classification by Linnet's schema switch processor.
  if (api->process_key(session, XK_Shift_L, kShiftMask | kLockMask) ||
      api->process_key(session, XK_Shift_L, kReleaseMask | kLockMask)) {
    Fail(std::string(schema_id) + " swallowed Shift while Caps Lock was active");
  }
  ExpectCurrentSchema(api, session, schema_id,
                      std::string(schema_id) + " Caps Lock plus Shift tap");
  if (!api->get_option(session, "ascii_mode")) {
    Fail(std::string(schema_id) + " left the Caps Lock raw path after Shift");
  }
  if (api->process_key(session, XK_Shift_R, kShiftMask | kLockMask) ||
      api->process_key(session, '!', kShiftMask | kLockMask) ||
      api->process_key(session, XK_Shift_R, kReleaseMask | kLockMask)) {
    Fail(std::string(schema_id) + " swallowed a Caps Lock Shift chord");
  }
  ExpectCurrentSchema(api, session, schema_id,
                      std::string(schema_id) + " Caps Lock Shift chord");
  if (!api->get_option(session, "ascii_mode")) {
    Fail(std::string(schema_id) + " left raw ASCII after a Caps Lock Shift chord");
  }
  if (api->process_key(session, XK_Caps_Lock, kLockMask) ||
      api->get_option(session, "ascii_mode")) {
    Fail(std::string(schema_id) + " did not leave the Caps Lock raw path");
  }
  api->destroy_session(session);
}

void TapShift(RimeApi_stdbool* api, RimeSessionId session, int shift_key) {
  api->process_key(session, shift_key, kShiftMask);
  api->process_key(session, shift_key, kReleaseMask);
}

void ExpectSwitcherHotkeysPassThrough(RimeApi_stdbool* api) {
  struct KeyCase {
    int keycode;
    int modifiers;
    const char* name;
  };
  for (const auto& key : std::vector<KeyCase>{
           {XK_F4, 0, "F4"},
           {XK_grave, kControlMask, "Control+grave"},
           {XK_grave, kControlMask | kShiftMask,
            "Control+Shift+grave"},
       }) {
    const RimeSessionId idle = CreateSchemaSession(api, "linnet_zh");
    if (api->process_key(idle, key.keycode, key.modifiers)) {
      Fail(std::string(key.name) + " was swallowed while idle");
    }
    ExpectCurrentSchema(api, idle, "linnet_zh",
                        std::string(key.name) + " idle pass-through");
    api->destroy_session(idle);

    const RimeSessionId composing =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    Enter(api, composing, "shi");
    const char* before = api->get_input(composing);
    const std::string input_before = before ? before : "";
    if (api->process_key(composing, key.keycode, key.modifiers)) {
      Fail(std::string(key.name) + " was swallowed during composition");
    }
    const char* after = api->get_input(composing);
    if (!after || input_before != after) {
      Fail(std::string(key.name) + " changed the active composition");
    }
    ExpectCurrentSchema(api, composing, "linnet_zh_pinyin",
                        std::string(key.name) + " composing pass-through");
    api->destroy_session(composing);
  }
}

void ExpectSessionPropertyAbsent(RimeApi_stdbool* api,
                                 RimeSessionId session_id,
                                 const std::string& key,
                                 const std::string& reason);

void ExpectDirectShiftSmartEnglish(RimeApi_stdbool* api) {
  for (size_t index = 0; index + 1 < kProductSchemaIDs.size(); ++index) {
    const char* chinese_schema = kProductSchemaIDs[index];
    const RimeSessionId session = CreateSchemaSession(api, chinese_schema);
    TapShift(api, session, XK_Shift_L);
    ExpectCurrentSchema(api, session, "linnet_en",
                        std::string(chinese_schema) +
                            " direct Shift to Smart English");
    if (api->get_option(session, "ascii_mode")) {
      Fail("direct Shift entered raw ASCII instead of Smart English");
    }

    TapShift(api, session, XK_Shift_R);
    ExpectCurrentSchema(api, session, chinese_schema,
                        std::string(chinese_schema) +
                            " direct Shift back to the same Chinese profile");
    if (api->get_option(session, "ascii_mode")) {
      Fail("direct Shift back to Chinese retained raw ASCII mode");
    }
    ExpectSessionPropertyAbsent(
        api, session, kModeReturnSchemaProperty,
        std::string(chinese_schema) + " direct Shift return identity");
    api->destroy_session(session);
  }

  // Global switcher history has second-level timestamps and is shared across
  // sessions. Interleave two profile pairs in one process to prove each
  // session returns through its own transition owner instead.
  const RimeSessionId first_pair =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  const RimeSessionId second_pair =
      CreateSchemaSession(api, "linnet_zh_jiajia");
  TapShift(api, first_pair, XK_Shift_L);
  TapShift(api, second_pair, XK_Shift_L);
  ExpectCurrentSchema(api, first_pair, "linnet_en",
                      "interleaved full-pinyin entry");
  ExpectCurrentSchema(api, second_pair, "linnet_en",
                      "interleaved Jiajia entry");
  TapShift(api, first_pair, XK_Shift_R);
  TapShift(api, second_pair, XK_Shift_R);
  ExpectCurrentSchema(api, first_pair, "linnet_zh_pinyin",
                      "interleaved full-pinyin return");
  ExpectCurrentSchema(api, second_pair, "linnet_zh_jiajia",
                      "interleaved Jiajia return");
  ExpectSessionPropertyAbsent(api, first_pair, kModeReturnSchemaProperty,
                              "interleaved full-pinyin return identity");
  ExpectSessionPropertyAbsent(api, second_pair, kModeReturnSchemaProperty,
                              "interleaved Jiajia return identity");
  api->destroy_session(second_pair);
  api->destroy_session(first_pair);

  const RimeSessionId direct_english =
      CreateSchemaSession(api, "linnet_en");
  TapShift(api, direct_english, XK_Shift_L);
  ExpectCurrentSchema(api, direct_english, "linnet_zh_pinyin",
                      "direct Smart English fallback to bundled Chinese");
  api->destroy_session(direct_english);

  const RimeSessionId composing =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, composing, "shuru");
  const auto composing_candidates = Candidates(api, composing);
  if (composing_candidates.empty()) {
    Fail("direct Shift composition fixture produced no Chinese candidate");
  }
  TapShift(api, composing, XK_Shift_L);
  ExpectCurrentSchema(api, composing, "linnet_en",
                      "direct Shift with a Chinese composition");
  if (TakeCommit(api, composing) != composing_candidates.front().text) {
    Fail("direct Shift did not commit the selected Chinese candidate");
  }
  api->destroy_session(composing);

  const RimeSessionId raw_composing =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, raw_composing, "uuuuuuuu");
  const auto raw_origins = CandidateOrigins(raw_composing);
  if (raw_origins.size() != 1 || raw_origins.front().type != "raw" ||
      raw_origins.front().genuine_type != "raw" ||
      raw_origins.front().start != 0 || raw_origins.front().end != 8) {
    Fail("direct Shift raw fixture gained a translated candidate");
  }
  TapShift(api, raw_composing, XK_Shift_L);
  ExpectCurrentSchema(api, raw_composing, "linnet_en",
                      "direct Shift with raw letters");
  const std::string raw_shift_commit = TakeCommit(api, raw_composing);
  if (raw_shift_commit != "uuuuuuuu") {
    Fail("direct Shift changed or discarded raw letters without a Chinese "
         "candidate: expected 'uuuuuuuu', got '" +
         raw_shift_commit + "'");
  }
  api->destroy_session(raw_composing);

  // A partial Chinese match plus an untranslated suffix is the destructive
  // schema-boundary case: ascii_composer confirms the prefix but cannot
  // auto-commit until the canonical raw tail is preserved as well.
  const RimeSessionId partial_composing =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  constexpr char kPartialInput[] = "thisisenglish";
  Enter(api, partial_composing, kPartialInput);
  const auto partial_origins = CandidateOrigins(partial_composing);
  const auto partial_session =
      rime::Service::instance().GetSession(partial_composing);
  if (partial_origins.empty() || partial_origins.front().start != 0 ||
      partial_origins.front().end >= std::strlen(kPartialInput) ||
      !partial_session || !partial_session->context()) {
    Fail("direct Shift partial-match fixture lost its untranslated suffix");
  }
  const std::string partial_preview =
      partial_session->context()->GetCommitText();
  if (partial_preview.empty() || partial_preview == kPartialInput) {
    Fail("direct Shift partial-match fixture has no canonical mixed preview");
  }
  TapShift(api, partial_composing, XK_Shift_L);
  ExpectCurrentSchema(api, partial_composing, "linnet_en",
                      "direct Shift with a partial Chinese match");
  if (TakeCommit(api, partial_composing) != partial_preview) {
    Fail("direct Shift discarded the untranslated suffix after a partial "
         "Chinese match");
  }
  api->destroy_session(partial_composing);

  const RimeSessionId chord = CreateSchemaSession(api, "linnet_zh");
  api->process_key(chord, XK_Shift_L, kShiftMask);
  api->process_key(chord, 'H', kShiftMask);
  api->process_key(chord, XK_Shift_L, kReleaseMask);
  ExpectCurrentSchema(api, chord, "linnet_zh", "Shift+letter chord");
  if (api->get_option(chord, "ascii_mode")) {
    Fail("Shift+letter chord entered raw ASCII mode");
  }
  api->destroy_session(chord);

  const RimeSessionId held = CreateSchemaSession(api, "linnet_zh");
  api->process_key(held, XK_Shift_L, kShiftMask);
  std::this_thread::sleep_for(std::chrono::milliseconds(550));
  api->process_key(held, XK_Shift_L, kReleaseMask);
  ExpectCurrentSchema(api, held, "linnet_zh", "held Shift");
  if (api->get_option(held, "ascii_mode")) {
    Fail("held Shift entered raw ASCII mode");
  }
  api->destroy_session(held);

  // InputMethodKit can deactivate while a modifier is held and deliver its
  // release to another input source. Composition abort is the active-epoch
  // boundary that must cancel ascii_composer's private tap gesture state.
  const RimeSessionId aborted_gesture =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  api->process_key(aborted_gesture, XK_Shift_L, kShiftMask);
  std::this_thread::sleep_for(std::chrono::milliseconds(550));
  api->clear_composition(aborted_gesture);
  TapShift(api, aborted_gesture, XK_Shift_L);
  ExpectCurrentSchema(api, aborted_gesture, "linnet_en",
                      "Shift tap after an inactive composition epoch");
  api->destroy_session(aborted_gesture);
}

int HighlightedCandidateIndex(RimeApi_stdbool* api,
                              RimeSessionId session) {
  RimeContext_stdbool context = {};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  if (!api->get_context(session, &context)) {
    Fail("could not inspect highlighted candidate");
  }
  const int index = context.menu.highlighted_candidate_index;
  api->free_context(&context);
  return index;
}

struct CandidateNavigationState {
  size_t selected_index;
  size_t caret_position;
};

struct CompositionEditingState {
  std::string input;
  size_t caret_position;
};

CandidateNavigationState ReadCandidateNavigationState(
    RimeSessionId session,
    const std::string& reason) {
  const auto live_session = rime::Service::instance().GetSession(session);
  if (!live_session || !live_session->context() ||
      live_session->context()->composition().empty()) {
    Fail("candidate navigation fixture has no composition: " + reason);
  }
  auto* context = live_session->context();
  const auto& segment = context->composition().back();
  if (!segment.menu) {
    Fail("candidate navigation fixture has no menu: " + reason);
  }
  return {segment.selected_index, context->caret_pos()};
}

CompositionEditingState ReadCompositionEditingState(
    RimeSessionId session,
    const std::string& reason) {
  const auto live_session = rime::Service::instance().GetSession(session);
  if (!live_session || !live_session->context() ||
      live_session->context()->composition().empty()) {
    Fail("editing fixture has no composition: " + reason);
  }
  const auto* context = live_session->context();
  return {context->input(), context->caret_pos()};
}

void ExpectCompositionTag(RimeSessionId session,
                          const std::string& expected,
                          const std::string& reason) {
  const auto live_session = rime::Service::instance().GetSession(session);
  if (!live_session || !live_session->context() ||
      live_session->context()->composition().empty() ||
      !live_session->context()->composition().back().HasTag(expected)) {
    Fail("editing fixture is missing tag " + expected + ": " + reason);
  }
}

std::string SelectNormalizedCandidate(RimeApi_stdbool* api,
                                      RimeSessionId session,
                                      const std::string& input,
                                      const std::string& expected);

void ExpectCandidateArrowNavigation(RimeApi_stdbool* api) {
  struct Fixture {
    const char* schema;
    const char* input;
  };
  struct Layout {
    const char* name;
    bool linear;
    bool vertical;
  };
  constexpr std::array<Fixture, 2> fixtures = {{
      {"linnet_zh_pinyin", "shi"},
      {"linnet_en", "a"},
  }};
  constexpr std::array<Layout, 2> layouts = {{
      {"horizontal-linear", true, false},
      {"vertical-stacked", false, true},
  }};
  constexpr std::array<int, 2> previous_keys = {XK_Left, XK_Up};
  constexpr std::array<int, 2> next_keys = {XK_Right, XK_Down};

  for (const auto& fixture : fixtures) {
    for (const auto& layout : layouts) {
      for (const int key : previous_keys) {
        const RimeSessionId session =
            CreateSchemaSession(api, fixture.schema);
        api->set_option(session, "_linear", layout.linear);
        api->set_option(session, "_vertical", layout.vertical);
        Enter(api, session, fixture.input);
        const auto before = ReadCandidateNavigationState(
            session, std::string(fixture.schema) + " " + layout.name +
                         " previous boundary");
        if (before.selected_index != 0 ||
            !api->process_key(session, key, 0)) {
          Fail("plain previous arrow was not consumed at the first candidate");
        }
        const auto after = ReadCandidateNavigationState(
            session, std::string(fixture.schema) + " " + layout.name +
                         " previous boundary");
        if (after.selected_index != 0 ||
            after.caret_position != before.caret_position) {
          Fail("plain previous arrow escaped candidate navigation at the first candidate");
        }
        api->destroy_session(session);
      }

      for (const int key : next_keys) {
        const RimeSessionId session =
            CreateSchemaSession(api, fixture.schema);
        api->set_option(session, "_linear", layout.linear);
        api->set_option(session, "_vertical", layout.vertical);
        Enter(api, session, fixture.input);
        const auto before = ReadCandidateNavigationState(
            session, std::string(fixture.schema) + " " + layout.name +
                         " next candidate");
        if (before.selected_index != 0 ||
            !api->process_key(session, key, 0)) {
          Fail("plain next arrow was not consumed over a candidate menu");
        }
        const auto after = ReadCandidateNavigationState(
            session, std::string(fixture.schema) + " " + layout.name +
                         " next candidate");
        if (after.selected_index != 1 ||
            after.caret_position != before.caret_position) {
          Fail("plain next arrow did not move exactly one candidate");
        }
        api->destroy_session(session);
      }
    }
  }

  const RimeSessionId crossing = CreateSchemaSession(api, "linnet_en");
  api->set_option(crossing, "_linear", true);
  Enter(api, crossing, "a");
  for (int index = 0; index < 9; ++index) {
    if (!api->process_key(crossing, XK_Right, 0)) {
      Fail("candidate arrow stopped before crossing the page boundary");
    }
  }
  if (ReadCandidateNavigationState(crossing, "cross-page navigation")
          .selected_index != 9) {
    Fail("candidate arrow did not cross from absolute candidate 8 to 9");
  }
  api->destroy_session(crossing);

  const RimeSessionId modified = CreateSchemaSession(api, "linnet_en");
  Enter(api, modified, "interface");
  const auto modified_before =
      ReadCandidateNavigationState(modified, "modified arrow");
  api->process_key(modified, XK_Right, kShiftMask);
  const auto modified_after =
      ReadCandidateNavigationState(modified, "modified arrow");
  if (modified_after.selected_index != modified_before.selected_index) {
    Fail("candidate navigation intercepted a modified arrow");
  }
  if (api->process_key(modified, XK_Down, kReleaseMask)) {
    Fail("candidate navigation intercepted an arrow release");
  }
  api->destroy_session(modified);
}

void ExpectRawLikeArrowEditing(RimeApi_stdbool* api) {
  struct Fixture {
    const char* input;
    const char* tag;
    bool forced_raw_only;
    bool english_only;
  };
  struct Layout {
    const char* name;
    bool linear;
    bool vertical;
  };
  constexpr std::array<Fixture, 3> fixtures = {{
      {"URLSession", "zz_code_token", false, false},
      {"x;br", "text_expander", false, false},
      {"bdbdbdbd", "", true, true},
  }};
  constexpr std::array<Layout, 2> layouts = {{
      {"horizontal-linear", true, false},
      {"vertical-stacked", false, true},
  }};

  for (const char* schema : {"linnet_en", "linnet_zh"}) {
    for (const auto& layout : layouts) {
      for (const auto& fixture : fixtures) {
        if (fixture.english_only && std::strcmp(schema, "linnet_en") != 0) {
          continue;
        }
        const std::string reason = std::string(schema) + " " + layout.name +
                                   " " + fixture.input;
        const RimeSessionId session = CreateSchemaSession(api, schema);
        api->set_option(session, "_linear", layout.linear);
        api->set_option(session, "_vertical", layout.vertical);
        Enter(api, session, fixture.input);
        if (fixture.forced_raw_only) {
          const auto origins = CandidateOrigins(session);
          if (origins.size() != 1 ||
              (origins.front().type != kForcedRawCandidateType &&
               origins.front().genuine_type != kForcedRawCandidateType)) {
            Fail("forced-raw editing fixture is not one non-navigable echo: " +
                 reason);
          }
        } else {
          ExpectCompositionTag(session, fixture.tag, reason);
        }

        const auto initial = ReadCompositionEditingState(session, reason);
        if (initial.input != fixture.input ||
            initial.caret_position != initial.input.size()) {
          Fail("raw-like editing fixture did not start at the trailing boundary: " +
               reason);
        }

        if (api->process_key(session, XK_Right, 0)) {
          Fail("raw-like Right was consumed at the trailing host boundary: " +
               reason);
        }
        const auto trailing = ReadCompositionEditingState(
            session, reason + " trailing Right");
        if (trailing.input != initial.input ||
            trailing.caret_position != initial.caret_position) {
          Fail("raw-like trailing Right changed the composition: " + reason);
        }
        ExpectNoCommit(api, session, reason + " trailing Right");

        if (!api->process_key(session, XK_Left, 0)) {
          Fail("raw-like Left did not edit the original spelling: " + reason);
        }
        const auto moved_left = ReadCompositionEditingState(
            session, reason + " interior Left");
        if (moved_left.input != initial.input ||
            moved_left.caret_position + 1 != initial.caret_position) {
          Fail("raw-like Left was handled without moving its spelling caret: " +
               reason);
        }
        if (!api->process_key(session, XK_Right, 0)) {
          Fail("raw-like Right did not edit the original spelling: " + reason);
        }
        const auto moved_right = ReadCompositionEditingState(
            session, reason + " interior Right");
        if (moved_right.input != initial.input ||
            moved_right.caret_position != initial.caret_position) {
          Fail("raw-like Right was handled without restoring its spelling caret: " +
               reason);
        }
        ExpectNoCommit(api, session, reason + " interior arrows");

        api->set_caret_pos(session, 0);
        if (api->process_key(session, XK_Left, 0)) {
          Fail("raw-like Left was consumed at the leading host boundary: " +
               reason);
        }
        const auto leading = ReadCompositionEditingState(
            session, reason + " leading Left");
        if (leading.input != initial.input || leading.caret_position != 0) {
          Fail("raw-like leading Left changed the composition: " + reason);
        }

        api->set_caret_pos(session, initial.input.size());
        if (!api->process_key(session, XK_Home, 0)) {
          Fail("raw-like Home did not move to the leading boundary: " +
               reason);
        }
        const auto home = ReadCompositionEditingState(
            session, reason + " interior Home");
        if (home.input != initial.input || home.caret_position != 0) {
          Fail("raw-like Home was handled without moving its spelling caret: " +
               reason);
        }
        if (api->process_key(session, XK_Home, 0)) {
          Fail("raw-like Home was consumed at the leading host boundary: " +
               reason);
        }
        if (!api->process_key(session, XK_End, 0)) {
          Fail("raw-like End did not move to the trailing boundary: " +
               reason);
        }
        const auto end = ReadCompositionEditingState(
            session, reason + " interior End");
        if (end.input != initial.input ||
            end.caret_position != initial.input.size()) {
          Fail("raw-like End was handled without moving its spelling caret: " +
               reason);
        }
        if (api->process_key(session, XK_End, 0)) {
          Fail("raw-like End was consumed at the trailing host boundary: " +
               reason);
        }

        for (const auto& host_key :
             std::array<std::tuple<int, int, const char*>, 6>{{
                 {XK_Up, 0, "Up"},
                 {XK_Down, 0, "Down"},
                 {XK_Page_Up, 0, "PageUp"},
                 {XK_Page_Down, 0, "PageDown"},
                 {kTab, 0, "Tab"},
                 {kTab, kShiftMask, "Shift+Tab"},
             }}) {
          if (api->process_key(session, std::get<0>(host_key),
                               std::get<1>(host_key))) {
            Fail("raw-like " + std::string(std::get<2>(host_key)) +
                 " did not pass through to the host: " + reason);
          }
          const auto after = ReadCompositionEditingState(
              session, reason + " " + std::get<2>(host_key));
          if (after.input != initial.input ||
              after.caret_position != initial.caret_position) {
            Fail("raw-like " + std::string(std::get<2>(host_key)) +
                 " changed the composition: " + reason);
          }
          ExpectNoCommit(api, session,
                         reason + " " + std::get<2>(host_key));
        }
        api->destroy_session(session);
      }
    }
  }
}

void ExpectInvalidActiveSelectionKeysPassThrough(RimeApi_stdbool* api) {
  for (int keycode = XK_2; keycode <= XK_9; ++keycode) {
    const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
    Enter(api, session, "bdbdbdbd");
    const auto candidates = CandidateOrigins(session);
    if (candidates.size() != 1 ||
        (candidates.front().type != kForcedRawCandidateType &&
         candidates.front().genuine_type != kForcedRawCandidateType)) {
      Fail("invalid selection fixture is not one forced-raw candidate");
    }
    const auto before = ReadCompositionEditingState(
        session, "invalid active selection key");
    if (api->process_key(session, keycode, 0)) {
      Fail("invalid active selection key " +
           std::string(1, static_cast<char>(keycode)) +
           " was consumed without a target candidate");
    }
    const auto after = ReadCompositionEditingState(
        session, "invalid active selection key");
    if (after.input != before.input ||
        after.caret_position != before.caret_position ||
        CandidateOrigins(session).size() != candidates.size()) {
      Fail("invalid active selection key changed the active composition");
    }
    ExpectNoCommit(api, session, "invalid active selection key");
    api->destroy_session(session);
  }
}

void ExpectActivePunctuationBoundaries(RimeApi_stdbool* api) {
  struct PunctuationCase {
    int keycode;
    int modifiers;
    const char* name;
    const char* chinese_commit;
    bool english_case;
  };
  constexpr std::array<PunctuationCase, 18> punctuation_cases = {{
      {'.', 0, ".", "。", true},
      {':', kShiftMask, ":", "：", true},
      {'-', 0, "-", "-", true},
      {'/', 0, "/", "/", true},
      {'+', kShiftMask, "+", "+", true},
      {'@', kShiftMask, "@", "@", true},
      {'=', 0, "=", "=", true},
      {'#', kShiftMask, "#", "#", true},
      {'%', kShiftMask, "%", "%", true},
      {'&', kShiftMask, "&", "&", true},
      {'*', kShiftMask, "*", "*", true},
      {'|', kShiftMask, "|", "|", true},
      {'~', kShiftMask, "~", "~", true},
      {'_', kShiftMask, "_", "——", true},
      {',', 0, ",", "，", true},
      {';', 0, ";", "；", true},
      {'[', 0, "[", "【", true},
      {']', 0, "]", "】", true},
  }};

  for (const auto& punctuation : punctuation_cases) {
    if (punctuation.english_case) {
      const std::string reason =
          std::string("English active hello+") + punctuation.name;
      const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
      Enter(api, session, "hello");
      const auto candidates = Candidates(api, session);
      const int selected = HighlightedCandidateIndex(api, session);
      if (selected < 0 || static_cast<size_t>(selected) >= candidates.size()) {
        Fail(reason + " has no selected candidate");
      }
      const std::string expected_word = candidates[selected].text;
      if (api->process_key(session, punctuation.keycode,
                           punctuation.modifiers)) {
        Fail(reason + " was captured instead of returning punctuation to the host");
      }
      const std::string actual_word = TakeCommit(api, session, reason);
      if (actual_word != expected_word) {
        Fail(reason + " committed '" + actual_word + "' instead of '" +
             expected_word + "'");
      }
      const char* input = api->get_input(session);
      if ((input && *input != '\0') || !Candidates(api, session).empty()) {
        Fail(reason + " did not clear input and menu on the same key event");
      }
      api->destroy_session(session);
    }

    const std::string reason =
        std::string("Chinese active shi+") + punctuation.name;
    const RimeSessionId session =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    Enter(api, session, "shi");
    const auto candidates = Candidates(api, session);
    const int selected = HighlightedCandidateIndex(api, session);
    if (selected < 0 || static_cast<size_t>(selected) >= candidates.size()) {
      Fail(reason + " has no selected candidate");
    }
    const std::string expected =
        candidates[selected].text + punctuation.chinese_commit;
    if (!api->process_key(session, punctuation.keycode,
                          punctuation.modifiers)) {
      Fail(reason + " did not commit through the Chinese punctuator");
    }
    const std::string actual = TakeCommit(api, session, reason);
    if (actual != expected) {
      Fail(reason + " committed '" + actual + "' instead of '" + expected +
           "'");
    }
    const char* input = api->get_input(session);
    if ((input && *input != '\0') || !Candidates(api, session).empty()) {
      Fail(reason + " did not clear input and menu on the same key event");
    }
    api->destroy_session(session);
  }

  // Identity mappings used to be wrapped together with the echo candidate by
  // `uniquifier`. Punctuator must inspect their genuine origin and commit the
  // literal on the same key event even when there is no active spelling.
  constexpr std::array<PunctuationCase, 11> idle_identity_cases = {{
      {'#', kShiftMask, "#", "#", false},
      {'%', kShiftMask, "%", "%", false},
      {'&', kShiftMask, "&", "&", false},
      {'*', kShiftMask, "*", "*", false},
      {'+', kShiftMask, "+", "+", false},
      {'-', 0, "-", "-", false},
      {'/', 0, "/", "/", false},
      {'=', 0, "=", "=", false},
      {'@', kShiftMask, "@", "@", false},
      {'|', kShiftMask, "|", "|", false},
      {'~', kShiftMask, "~", "~", false},
  }};
  for (const auto& punctuation : idle_identity_cases) {
    const std::string reason =
        std::string("idle Chinese identity punctuation ") + punctuation.name;
    const RimeSessionId session =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    if (!api->process_key(session, punctuation.keycode,
                          punctuation.modifiers)) {
      Fail(reason + " was not accepted by the Chinese punctuator");
    }
    const std::string actual = TakeCommit(api, session, reason);
    if (actual != punctuation.chinese_commit) {
      Fail(reason + " committed '" + actual + "' instead of '" +
           punctuation.chinese_commit + "'");
    }
    const char* input = api->get_input(session);
    if ((input && *input != '\0') || !Candidates(api, session).empty()) {
      Fail(reason + " remained in composition after the same key event");
    }
    api->destroy_session(session);
  }

  const RimeSessionId full_shape =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  api->set_option(full_shape, "full_shape", true);
  Enter(api, full_shape, "shi");
  const auto full_shape_candidates = Candidates(api, full_shape);
  const int full_shape_selected = HighlightedCandidateIndex(api, full_shape);
  if (full_shape_selected < 0 ||
      static_cast<size_t>(full_shape_selected) >=
          full_shape_candidates.size()) {
    Fail("full-shape punctuation fixture has no selected candidate");
  }
  if (!api->process_key(full_shape, '-', 0)) {
    Fail("full-shape punctuation was not accepted");
  }
  const std::string expected_full_shape =
      full_shape_candidates[full_shape_selected].text + "－";
  if (TakeCommit(api, full_shape, "full-shape punctuation") !=
      expected_full_shape) {
    Fail("full-shape punctuation did not use the canonical mapping");
  }
  api->destroy_session(full_shape);
}

std::string SelectNormalizedCandidate(RimeApi_stdbool* api,
                                      RimeSessionId session,
                                      const std::string& input,
                                      const std::string& expected) {
  Enter(api, session, input);
  const size_t index = NormalizedCandidateIndex(api, session, expected);
  if (!api->select_candidate(session, index)) {
    Fail("could not select normalized candidate " + expected);
  }
  return TakeCommit(api, session);
}

void ContinueInput(RimeApi_stdbool* api,
                   RimeSessionId session,
                   const std::string& input) {
  if (!api->simulate_key_sequence(session, input.c_str())) {
    Fail("could not continue input: " + input);
  }
}

std::string ContinueAndSelectNormalizedCandidate(
    RimeApi_stdbool* api,
    RimeSessionId session,
    const std::string& input,
    const std::string& expected) {
  ContinueInput(api, session, input);
  const size_t index = NormalizedCandidateIndex(api, session, expected);
  if (!api->select_candidate(session, index)) {
    Fail("could not select continuing normalized candidate " + expected);
  }
  return TakeCommit(api, session);
}

std::string SelectCurrentNormalizedCandidate(RimeApi_stdbool* api,
                                             RimeSessionId session,
                                             const std::string& expected) {
  const size_t index = NormalizedCandidateIndex(api, session, expected);
  if (!api->select_candidate(session, index)) {
    Fail("could not select current prediction " + expected);
  }
  return TakeCommit(api, session);
}

void ExpectMenuEmpty(RimeApi_stdbool* api,
                     RimeSessionId session,
                     const std::string& reason) {
  if (!Candidates(api, session).empty()) {
    Fail("candidate menu remained after " + reason);
  }
}

void ExpectPredictionMenu(RimeApi_stdbool* api,
                          RimeSessionId session,
                          const std::string& reason) {
  if (Candidates(api, session).empty()) {
    Fail("prediction menu is missing after " + reason);
  }
}

void ExpectSessionProperty(RimeApi_stdbool* api,
                           RimeSessionId session_id,
                           const std::string& key,
                           const std::string& expected,
                           const std::string& reason);

RimeSessionId CreatePassivePrediction(RimeApi_stdbool* api,
                                      const std::string& reason) {
  const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, session, "i", "I");
  ContinueAndSelectNormalizedCandidate(api, session, "do", "do");
  ContinueAndSelectNormalizedCandidate(api, session, "not", "not");
  ExpectPredictionMenu(api, session, reason);
  const char* input = api->get_input(session);
  if (input && *input != '\0') {
    Fail("passive prediction retained an active spelling after " + reason);
  }
  ExpectCompositionTag(session, "prediction", reason);
  ExpectSessionProperty(api, session, kPredictContextProperty, "i do not",
                        reason);
  std::array<char, 256> static_key = {};
  if (!api->get_property(session, kPredictStaticKeyProperty,
                         static_key.data(), static_key.size()) ||
      static_key.front() == '\0') {
    Fail("passive prediction has no static prediction owner after " + reason);
  }
  return session;
}

void ExpectPassivePredictionExit(RimeApi_stdbool* api,
                                 RimeSessionId session,
                                 const std::string& reason) {
  ExpectNoCommit(api, session, reason);
  ExpectMenuEmpty(api, session, reason);
  const char* input = api->get_input(session);
  if (input && *input != '\0') {
    Fail("passive prediction exit retained active input after " + reason);
  }
  for (const char* property :
       {kPredictContextProperty, kPredictStaticKeyProperty,
        kPredictionNavigationProperty, kSpacingProperty,
        kSentenceBoundaryProperty, kSuppressFollowingSpaceProperty}) {
    ExpectSessionPropertyAbsent(api, session, property, reason);
  }
}

void ExpectPassivePredictionExitContract(RimeApi_stdbool* api) {
  struct KeyCase {
    int keycode;
    int modifiers;
    bool consumed;
    const char* name;
  };
  const std::array<KeyCase, 8> key_cases = {{
      {XK_Home, 0, false, "Home"},
      {XK_End, 0, false, "End"},
      {XK_Page_Up, 0, false, "PageUp"},
      {XK_Page_Down, 0, false, "PageDown"},
      {XK_0, 0, false, "0"},
      {kEscape, 0, true, "Escape"},
      {'c', kControlMask, false, "Control+C"},
      {'v', kControlMask | kShiftMask, false, "Control+Shift+V"},
  }};

  for (const auto& key_case : key_cases) {
    const std::string reason =
        std::string("passive prediction ") + key_case.name;
    const RimeSessionId session = CreatePassivePrediction(api, reason);
    const bool consumed =
        api->process_key(session, key_case.keycode, key_case.modifiers);
    if (consumed != key_case.consumed) {
      Fail(reason + (key_case.consumed
                         ? " was not consumed as an explicit cancellation"
                         : " was consumed instead of reaching the host"));
    }
    ExpectPassivePredictionExit(api, session, reason);
    api->destroy_session(session);
  }

  const RimeSessionId cleared =
      CreatePassivePrediction(api, "clear_composition setup");
  api->clear_composition(cleared);
  ExpectPassivePredictionExit(api, cleared, "clear_composition");
  api->destroy_session(cleared);
}

void ExpectCapsLockDismissesPassivePrediction(RimeApi_stdbool* api) {
  const RimeSessionId session =
      CreatePassivePrediction(api, "Caps Lock passive prediction");
  if (api->process_key(session, XK_Caps_Lock, 0) ||
      !api->get_option(session, "ascii_mode")) {
    Fail("Caps Lock did not enter raw ASCII from a passive prediction");
  }
  ExpectPassivePredictionExit(api, session, "Caps Lock passive prediction");
  ExpectCurrentSchema(api, session, "linnet_en",
                      "Caps Lock passive prediction");
  api->destroy_session(session);
}

void ExpectPassivePredictionKeyboardSelection(RimeApi_stdbool* api) {
  const RimeSessionId arrows =
      CreatePassivePrediction(api, "passive prediction arrow navigation");
  if (CandidateOrigins(arrows).size() < 2) {
    Fail("passive prediction arrow fixture has fewer than two candidates");
  }
  for (const auto& arrow :
       std::array<std::tuple<int, size_t, const char*>, 4>{{
           {XK_Right, 1, "Right"},
           {XK_Left, 0, "Left"},
           {XK_Down, 1, "Down"},
           {XK_Up, 0, "Up"},
       }}) {
    if (!api->process_key(arrows, std::get<0>(arrow), 0)) {
      Fail(std::string("passive prediction ") + std::get<2>(arrow) +
           " did not enter candidate navigation");
    }
    const auto after = ReadCandidateNavigationState(
        arrows, std::string("passive prediction ") + std::get<2>(arrow));
    if (after.selected_index != std::get<1>(arrow)) {
      Fail(std::string("passive prediction ") + std::get<2>(arrow) +
           " did not move exactly one candidate");
    }
    ExpectSessionProperty(api, arrows, kPredictionNavigationProperty, "1",
                          std::string("passive prediction ") +
                              std::get<2>(arrow));
  }
  ExpectNoCommit(api, arrows, "passive prediction arrow navigation");
  api->destroy_session(arrows);

  for (int keycode = XK_1; keycode <= XK_9; ++keycode) {
    const std::string reason =
        "passive prediction direct selection " +
        std::string(1, static_cast<char>(keycode));
    const RimeSessionId session = CreatePassivePrediction(api, reason);
    const auto candidates = CandidateOrigins(session);
    const size_t target = static_cast<size_t>(keycode - XK_1);
    if (target >= candidates.size()) {
      Fail(reason + " fixture has no target candidate");
    }
    if (!api->process_key(session, keycode, 0)) {
      Fail(reason + " was returned to the host instead of selecting");
    }
    const std::string actual = TakeCommit(api, session);
    if (actual != candidates[target].text) {
      Fail(reason + " committed '" + actual + "' instead of '" +
           candidates[target].text + "'");
    }
    api->destroy_session(session);
  }
}

void ExpectPassivePredictionTabContracts(RimeApi_stdbool* api) {
  constexpr char kPolicyKey[] =
      "linnet_english_interaction/tab_behavior";

  SetSchemaString(api, "linnet_en", kPolicyKey, "pass");
  for (const auto& tab :
       std::array<std::pair<int, const char*>, 2>{{
           {0, "Tab"},
           {kShiftMask, "Shift+Tab"},
       }}) {
    const std::string reason =
        std::string("passive prediction pass ") + tab.second;
    const RimeSessionId session = CreatePassivePrediction(api, reason);
    if (api->process_key(session, kTab, tab.first)) {
      Fail(reason + " was consumed instead of reaching the host");
    }
    ExpectPassivePredictionExit(api, session, reason);
    api->destroy_session(session);
  }

  SetSchemaString(api, "linnet_en", kPolicyKey, "navigate");
  const RimeSessionId navigation =
      CreatePassivePrediction(api, "focused prediction arrows");
  if (CandidateOrigins(navigation).size() < 2) {
    Fail("focused prediction arrow fixture has fewer than two candidates");
  }
  if (!api->process_key(navigation, kTab, 0)) {
    Fail("navigate Tab did not focus the passive prediction menu");
  }
  ExpectSessionProperty(api, navigation, kPredictionNavigationProperty, "1",
                        "navigate Tab focus");
  if (ReadCandidateNavigationState(navigation, "navigate Tab focus")
          .selected_index != 1) {
    Fail("navigate Tab did not visibly move to the next passive prediction");
  }
  for (const auto& arrow :
       std::array<std::pair<int, const char*>, 4>{{
           {XK_Left, "Left"},
           {XK_Right, "Right"},
           {XK_Up, "Up"},
           {XK_Down, "Down"},
       }}) {
    const auto before = ReadCandidateNavigationState(
        navigation, std::string("focused prediction ") + arrow.second);
    const size_t expected =
        (arrow.first == XK_Left || arrow.first == XK_Up)
            ? before.selected_index - 1
            : before.selected_index + 1;
    if (!api->process_key(navigation, arrow.first, 0)) {
      Fail(std::string("focused prediction ") + arrow.second +
           " was not consumed as candidate navigation");
    }
    const auto after = ReadCandidateNavigationState(
        navigation, std::string("focused prediction ") + arrow.second);
    if (after.selected_index != expected ||
        after.caret_position != before.caret_position) {
      Fail(std::string("focused prediction ") + arrow.second +
           " did not move exactly one candidate");
    }
    ExpectSessionProperty(api, navigation, kPredictionNavigationProperty, "1",
                          std::string("focused prediction ") + arrow.second);
  }
  ExpectNoCommit(api, navigation, "focused prediction arrows");
  api->destroy_session(navigation);

  for (const auto& acceptance :
       std::array<std::pair<int, const char*>, 2>{{
           {XK_space, "Space"},
           {kReturn, "Return"},
       }}) {
    const std::string reason =
        std::string("focused prediction ") + acceptance.second;
    const RimeSessionId session = CreatePassivePrediction(api, reason);
    if (CandidateOrigins(session).size() < 2 ||
        !api->process_key(session, kTab, 0)) {
      Fail(reason + " fixture could not focus its second candidate");
    }
    const auto focused = ReadCandidateNavigationState(session, reason);
    const auto candidates = CandidateOrigins(session);
    if (focused.selected_index >= candidates.size()) {
      Fail(reason + " selected an unavailable candidate");
    }
    const std::string expected = candidates[focused.selected_index].text;
    if (!api->process_key(session, acceptance.first, 0)) {
      Fail(reason + " did not accept the focused prediction");
    }
    const std::string actual = TakeCommit(api, session);
    const std::string expected_commit =
        expected + (acceptance.first == XK_space ? " " : "");
    if (actual != expected_commit) {
      Fail(reason + " committed '" + actual + "' instead of '" +
           expected_commit + "'");
    }
    const char* input = api->get_input(session);
    if (input && *input != '\0') {
      Fail(reason + " retained active input after acceptance");
    }
    ExpectSessionPropertyAbsent(api, session, kPredictionNavigationProperty,
                                reason);
    if (acceptance.first == kReturn) {
      ExpectPassivePredictionExit(api, session, reason);
    }
    api->destroy_session(session);
  }
  SetSchemaString(api, "linnet_en", kPolicyKey, "smart_complete");
}

void ExpectPredictionPunctuationExitContract(RimeApi_stdbool* api) {
  // A punctuation key that confirms an active English word may arm a
  // zero-prefix prediction from the synchronous commit notifier.  The same
  // unhandled key must retire that projection before it reaches the host.
  const RimeSessionId active = CreateSchemaSession(api, "linnet_en");
  Enter(api, active, "hello");
  const auto active_candidates = Candidates(api, active);
  const int active_index = HighlightedCandidateIndex(api, active);
  if (active_index < 0 ||
      static_cast<size_t>(active_index) >= active_candidates.size() ||
      api->process_key(active, ',', 0)) {
    Fail("active English comma did not return to the host");
  }
  if (TakeCommit(api, active) != active_candidates[active_index].text) {
    Fail("active English comma changed the confirmed word");
  }
  ExpectMenuEmpty(api, active, "active English comma");
  for (const char* property :
       {kPredictContextProperty, kPredictStaticKeyProperty,
        kPredictionNavigationProperty}) {
    ExpectSessionPropertyAbsent(api, active, property,
                                "active English comma");
  }
  ExpectSessionProperty(api, active, kSpacingProperty, "1",
                        "active English comma");
  api->destroy_session(active);

  // Passive and explicitly focused predictions share one punctuation exit:
  // no suggestion is accepted, the key reaches the host, and punctuation
  // spacing survives removal of the zero-prefix projection.
  for (const bool focused : {false, true}) {
    const std::string reason =
        focused ? "focused prediction comma" : "passive prediction comma";
    const RimeSessionId session = CreatePassivePrediction(api, reason);
    if (focused) {
      if (!api->highlight_candidate(session, 1)) {
        Fail("could not establish focused prediction before comma");
      }
      api->set_property(session, kPredictionNavigationProperty, "1");
    }
    if (api->process_key(session, ',', 0)) {
      Fail(reason + " was swallowed");
    }
    ExpectNoCommit(api, session, reason);
    ExpectMenuEmpty(api, session, reason);
    for (const char* property :
         {kPredictContextProperty, kPredictStaticKeyProperty,
          kPredictionNavigationProperty}) {
      ExpectSessionPropertyAbsent(api, session, property, reason);
    }
    ExpectSessionProperty(api, session, kSpacingProperty, "1", reason);
    api->destroy_session(session);
  }

  // The closing quote arrives while the committed word owns a passive
  // prediction.  Removing that projection must not erase the remembered open
  // quote before the unhandled-key boundary classifies this as the close.
  const RimeSessionId quotes = CreateSchemaSession(api, "linnet_en");
  if (api->process_key(quotes, '"', 0)) {
    Fail("opening quote was swallowed in prediction punctuation contract");
  }
  ExpectSessionProperty(api, quotes, kSpacingProperty, "4",
                        "opening quote");
  const std::string quoted =
      SelectNormalizedCandidate(api, quotes, "i", "I");
  if (!quoted.empty() && quoted.front() == ' ') {
    Fail("opening quote inserted a leading space");
  }
  ContinueAndSelectNormalizedCandidate(api, quotes, "do", "do");
  ContinueAndSelectNormalizedCandidate(api, quotes, "not", "not");
  ExpectPredictionMenu(api, quotes, "quoted word");
  ExpectSessionProperty(api, quotes, kSpacingProperty, "5",
                        "quoted word before closing quote");
  const auto quote_session = rime::Service::instance().GetSession(quotes);
  if (!quote_session || !quote_session->context()) {
    Fail("closing quote fixture lost its native context");
  }
  int quote_unhandled_count = 0;
  auto quote_unhandled =
      quote_session->context()->unhandled_key_notifier().connect(
          [&](rime::Context*, const rime::KeyEvent&) {
            ++quote_unhandled_count;
          });
  if (api->process_key(quotes, '"', 0)) {
    Fail("closing quote was swallowed in prediction punctuation contract");
  }
  quote_unhandled.disconnect();
  if (quote_unhandled_count != 1) {
    Fail("closing quote crossed the unhandled boundary " +
         std::to_string(quote_unhandled_count) + " times");
  }
  ExpectNoCommit(api, quotes, "closing quote");
  ExpectMenuEmpty(api, quotes, "closing quote");
  for (const char* property :
       {kPredictContextProperty, kPredictStaticKeyProperty,
        kPredictionNavigationProperty}) {
    ExpectSessionPropertyAbsent(api, quotes, property, "closing quote");
  }
  ExpectSessionProperty(api, quotes, kSpacingProperty, "1",
                        "closing quote");
  const std::string after_quote =
      ContinueAndSelectNormalizedCandidate(api, quotes, "world", "world");
  if (after_quote.empty() || after_quote.front() != ' ') {
    Fail("closing quote did not space the next word");
  }
  api->destroy_session(quotes);
}

void ExpectChineseTabPolicy(RimeApi_stdbool* api) {
  // Mutate the canonical base schema directly. Wrapper schemas resolve their
  // inherited config during deployment, while this in-process config fixture
  // intentionally exercises the native policy without a second deploy.
  constexpr char kSchema[] = "linnet_zh";
  constexpr char kPolicyKey[] =
      "linnet_english_interaction/tab_behavior";
  struct PolicyCase {
    const char* value;
    bool navigates;
  };
  constexpr std::array<PolicyCase, 3> policies = {{
      {"pass", false},
      {"navigate", true},
      {"smart_complete", true},
  }};

  for (const auto& policy : policies) {
    SetSchemaString(api, kSchema, kPolicyKey, policy.value);
    const RimeSessionId session = CreateSchemaSession(api, kSchema);
    const auto runtime_session = rime::Service::instance().GetSession(session);
    std::string runtime_policy;
    if (!runtime_session || !runtime_session->schema() ||
        !runtime_session->schema()->config() ||
        !runtime_session->schema()->config()->GetString(
            kPolicyKey, &runtime_policy)) {
      Fail(std::string("Chinese ") + policy.value +
           " Tab fixture could not inspect its runtime policy");
    }
    if (runtime_policy != policy.value) {
      Fail(std::string("Chinese ") + policy.value +
           " Tab fixture loaded stale policy " + runtime_policy);
    }
    api->set_option(session, "_linear", true);
    api->set_option(session, "_vertical", false);
    Enter(api, session, "xxxx");
    if (Candidates(api, session).size() < 2 ||
        HighlightedCandidateIndex(api, session) != 0) {
      Fail(std::string("Chinese ") + policy.value +
           " Tab fixture has fewer than two candidates");
    }
    const auto before = ReadCandidateNavigationState(
        session, std::string("Chinese ") + policy.value + " Tab");
    const bool tab_handled = api->process_key(session, kTab, 0);
    const auto after_tab = ReadCandidateNavigationState(
        session, std::string("Chinese ") + policy.value + " Tab");

    if (!policy.navigates) {
      if (tab_handled || after_tab.selected_index != before.selected_index ||
          after_tab.caret_position != before.caret_position) {
        std::cerr << "Chinese pass Tab handled=" << tab_handled
                  << " selected=" << before.selected_index << "->"
                  << after_tab.selected_index << " caret="
                  << before.caret_position << "->"
                  << after_tab.caret_position << '\n';
        Fail("Chinese pass policy did not return Tab unchanged to the host");
      }
      const bool backtab_handled =
          api->process_key(session, kTab, kShiftMask);
      const auto after_backtab = ReadCandidateNavigationState(
          session, "Chinese pass Shift+Tab");
      if (backtab_handled ||
          after_backtab.selected_index != before.selected_index ||
          after_backtab.caret_position != before.caret_position) {
        Fail("Chinese pass policy did not return Shift+Tab unchanged to the host");
      }
    } else {
      if (!tab_handled || after_tab.selected_index != 1 ||
          after_tab.caret_position != before.caret_position) {
        Fail(std::string("Chinese ") + policy.value +
             " policy did not navigate forward with Tab");
      }
      if (!api->process_key(session, kTab, kShiftMask)) {
        Fail(std::string("Chinese ") + policy.value +
             " policy did not consume Shift+Tab navigation");
      }
      const auto after_backtab = ReadCandidateNavigationState(
          session, std::string("Chinese ") + policy.value + " Shift+Tab");
      if (after_backtab.selected_index != 0 ||
          after_backtab.caret_position != before.caret_position) {
        Fail(std::string("Chinese ") + policy.value +
             " policy did not navigate back with Shift+Tab");
      }
    }
    ExpectNoCommit(api, session,
                   std::string("Chinese ") + policy.value + " Tab policy");
    api->destroy_session(session);
  }
  SetSchemaString(api, kSchema, kPolicyKey, "smart_complete");
}

void ExpectImmediateEnglishSpaceCommit(RimeApi_stdbool* api) {
  for (const char uppercase : {'F', 'I'}) {
    const RimeSessionId shifted = CreateSchemaSession(api, "linnet_en");
    api->process_key(shifted, XK_Shift_L, kShiftMask);
    api->process_key(shifted, uppercase, kShiftMask);
    api->process_key(shifted, XK_Shift_L, kReleaseMask);
    const auto shifted_candidates = Candidates(api, shifted);
    const std::string expected(1, uppercase);
    if (shifted_candidates.empty() ||
        BaseText(shifted_candidates.front().text) != expected) {
      Fail("physical Shift input lost explicit uppercase candidate '" +
           expected + "'");
    }
    if (!api->process_key(shifted, XK_space, 0) ||
        TakeCommit(api, shifted) != expected + " ") {
      Fail("physical Shift input lost uppercase on Space commit '" +
           expected + "'");
    }
    api->destroy_session(shifted);
  }

  const RimeSessionId words = CreateSchemaSession(api, "linnet_en");
  Enter(api, words, "f");
  if (!api->process_key(words, XK_space, 0)) {
    Fail("Smart English did not accept Space over a word composition");
  }
  std::string host_text = TakeCommit(api, words);
  if (host_text != "f ") {
    Fail("Smart English delayed the first physical Space: '" + host_text +
         "'");
  }
  ExpectSessionProperty(api, words, kPredictContextProperty, "f",
                        "immediate Space word commit");

  ContinueInput(api, words, "a");
  const auto next_candidates = Candidates(api, words);
  if (next_candidates.empty() ||
      std::any_of(next_candidates.begin(), next_candidates.end(),
                  [](const auto& candidate) {
                    return !candidate.text.empty() &&
                           candidate.text.front() == ' ';
                  })) {
    Fail("Smart English kept a deferred leading Space after committing one");
  }
  if (!api->process_key(words, XK_space, 0)) {
    Fail("Smart English did not accept the second word boundary");
  }
  host_text += TakeCommit(api, words);
  if (host_text != "f a ") {
    Fail("Smart English word boundaries were not committed immediately: '" +
         host_text + "'");
  }
  ExpectSessionProperty(api, words, kPredictContextProperty, "f a",
                        "second immediate Space word commit");
  api->destroy_session(words);

  const RimeSessionId correction = CreateSchemaSession(api, "linnet_en");
  Enter(api, correction, "cluod");
  const size_t corrected = NormalizedCandidateIndex(api, correction, "cloud");
  if (!api->highlight_candidate(correction, corrected) ||
      !api->process_key(correction, XK_space, 0) ||
      TakeCommit(api, correction) != "cloud ") {
    Fail("Space did not immediately commit the selected correction and boundary");
  }
  api->destroy_session(correction);

  const RimeSessionId phrase = CreateSchemaSession(api, "linnet_en");
  Enter(api, phrase, "earlyaccess");
  const size_t phrase_index =
      NormalizedCandidateIndex(api, phrase, "early access");
  if (!api->highlight_candidate(phrase, phrase_index) ||
      !api->process_key(phrase, XK_space, 0) ||
      TakeCommit(api, phrase) != "early access ") {
    Fail("Space did not immediately commit a multi-word English candidate");
  }
  api->destroy_session(phrase);

  const RimeSessionId prediction = CreateSchemaSession(api, "linnet_en");
  Enter(api, prediction, "he");
  if (!api->process_key(prediction, XK_space, 0) ||
      TakeCommit(api, prediction) != "he ") {
    Fail("physical Space did not preserve a predictive English context");
  }
  ExpectSessionProperty(api, prediction, kPredictContextProperty, "he",
                        "predictive immediate Space commit");
  ExpectSessionProperty(api, prediction, kPredictStaticKeyProperty, "n/he",
                        "predictive immediate Space commit");
  const auto predicted = Candidates(api, prediction);
  if (predicted.empty()) {
    Fail("physical Space lost the prediction menu for a retained context");
  }
  if (!api->process_key(prediction, XK_space, 0)) {
    Fail("Space did not accept a literal boundary over English predictions");
  }
  const std::string prediction_commit = TakeCommit(api, prediction);
  if (prediction_commit != " ") {
    Fail("Space selected a zero-prefix prediction instead of inserting a literal boundary");
  }
  ExpectMenuEmpty(api, prediction, "literal Space over prediction");
  api->destroy_session(prediction);

  const RimeSessionId raw = CreateSchemaSession(api, "linnet_en");
  Enter(api, raw, "URLSession");
  if (!api->process_key(raw, XK_space, 0) ||
      TakeCommit(api, raw) != "URLSession ") {
    Fail("Space did not immediately commit a raw English token boundary");
  }
  api->destroy_session(raw);

  const RimeSessionId idle = CreateSchemaSession(api, "linnet_en");
  if (api->process_key(idle, XK_space, 0)) {
    Fail("Smart English consumed idle Space instead of passing it to the app");
  }
  ExpectNoCommit(api, idle, "idle Smart English Space");
  api->destroy_session(idle);
}

void ExpectFullShapeOff(RimeApi_stdbool* api,
                        RimeSessionId session,
                        const std::string& schema_id) {
  RimeStatus_stdbool status = {};
  RIME_STRUCT_INIT(RimeStatus_stdbool, status);
  if (!api->get_status(session, &status)) {
    Fail("could not read schema status");
  }
  const bool full_shape = status.is_full_shape;
  api->free_status(&status);
  if (full_shape) {
    Fail("full_shape reset is active in " + schema_id);
  }
}

void ExpectDefaultChinesePunctuation(RimeApi_stdbool* api,
                                     const char* schema_id) {
  const RimeSessionId session = CreateSchemaSession(api, schema_id);
  if (api->get_option(session, "ascii_punct")) {
    Fail(std::string(schema_id) +
         " unexpectedly started with English punctuation");
  }
  for (const auto& punctuation :
       std::array<std::pair<char, const char*>, 4>{{
           {',', "，"}, {'.', "。"}, {'?', "？"}, {'!', "！"},
       }}) {
    if (!api->process_key(session, punctuation.first, 0)) {
      Fail(std::string(schema_id) +
           " did not consume default Chinese punctuation");
    }
    RimeCommit commit = {};
    RIME_STRUCT_INIT(RimeCommit, commit);
    if (!api->get_commit(session, &commit)) {
      Fail(std::string(schema_id) + " did not commit punctuation '" +
           punctuation.first + "'");
    }
    const std::string actual = commit.text ? commit.text : "";
    api->free_commit(&commit);
    if (actual != punctuation.second) {
      Fail(std::string(schema_id) + " mapped punctuation to '" + actual +
           "', expected '" + punctuation.second + "'");
    }
  }
  api->destroy_session(session);
}

void SetPersistedUserOption(RimeApi_stdbool* api,
                            const char* option,
                            bool value) {
  RimeConfig config = {};
  if (!api->user_config_open("user", &config)) {
    Fail("could not open persisted user option fixture");
  }
  const std::string key = std::string("var/option/") + option;
  const bool updated = api->config_set_bool(&config, key.c_str(), value);
  const bool closed = api->config_close(&config);
  if (!updated || !closed) {
    Fail("could not update persisted user option fixture");
  }
}

void ExpectPersistedSwitchDefaults(RimeApi_stdbool* api) {
  const std::array<std::pair<const char*, bool>, 4> defaults = {{
      {"ascii_punct", false},
      {"traditionalization", false},
      {"emoji", true},
      {"search_single_char", false},
  }};
  for (const auto& item : defaults) {
    for (const bool persisted : {false, true}) {
      SetPersistedUserOption(api, item.first, persisted);
      const RimeSessionId session = CreateSchemaSession(api, "linnet_zh");
      const bool actual = api->get_option(session, item.first);
      api->destroy_session(session);
      if (actual != item.second) {
        Fail(std::string(item.first) + " restored persisted " +
             (persisted ? "true" : "false") +
             " instead of its Settings-owned new-session default");
      }
    }
    SetPersistedUserOption(api, item.first, item.second);
  }
  ExpectDefaultChinesePunctuation(api, "linnet_zh");
}

std::string SimulateHostText(RimeApi_stdbool* api,
                             RimeSessionId session,
                             const std::string& input);

void ExpectDeployedInputSwitches(RimeApi_stdbool* api) {
  const RimeSessionId punctuation =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  if (!api->get_option(punctuation, "ascii_punct") ||
      api->get_option(punctuation, "traditionalization") ||
      api->get_option(punctuation, "emoji") ||
      !api->get_option(punctuation, "search_single_char")) {
    Fail("the deployed graphical Chinese switch defaults were not loaded");
  }
  const std::string comma = SimulateHostText(api, punctuation, ",");
  if (comma != ",") {
    Fail("the deployed English-punctuation default produced '" + comma + "'");
  }
  api->destroy_session(punctuation);

  const RimeSessionId emoji =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, emoji, "nihao");
  const auto emoji_candidates = Candidates(api, emoji);
  if (std::none_of(emoji_candidates.begin(), emoji_candidates.end(),
                   [](const auto& candidate) {
                     return candidate.text == "你好";
                   })) {
    Fail("the Emoji-off probe lost the ordinary 你好 candidate");
  }
  if (std::any_of(emoji_candidates.begin(), emoji_candidates.end(),
                  [](const auto& candidate) {
                    return candidate.text.find("👋") != std::string::npos;
                  })) {
    Fail("the deployed Emoji-off default still expanded 你好");
  }
  api->destroy_session(emoji);

  const RimeSessionId single =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, single, "nihao`ren");
  const auto single_candidates = Candidates(api, single);
  if (single_candidates.empty() || single_candidates.front().text != "你") {
    Fail("the deployed auxiliary-code single-character preference did not "
         "put 你 first");
  }
  const auto phrase = std::find_if(
      single_candidates.begin(), single_candidates.end(),
      [](const auto& candidate) { return candidate.text == "你好"; });
  if (phrase == single_candidates.end() || phrase == single_candidates.begin()) {
    Fail("the auxiliary-code probe did not preserve 你好 after single characters");
  }
  api->destroy_session(single);
}

std::string SimulateHostText(RimeApi_stdbool* api,
                             RimeSessionId session,
                             const std::string& input) {
  std::string output;
  for (const unsigned char byte : input) {
    if (!api->process_key(session, byte, 0)) {
      output.push_back(static_cast<char>(byte));
    }
    RimeCommit commit = {};
    RIME_STRUCT_INIT(RimeCommit, commit);
    if (api->get_commit(session, &commit)) {
      output += commit.text ? commit.text : "";
      api->free_commit(&commit);
    }
  }
  return output;
}

void ExpectStandardChineseNumericPunctuation(RimeApi_stdbool* api) {
  for (const char separator : std::string(",.:")) {
    const RimeSessionId staged = CreateSchemaSession(api, "linnet_zh");
    if (api->process_key(staged, '3', 0)) {
      Fail("Chinese numeric prefix did not pass through to the host");
    }
    ExpectNoCommit(api, staged, "Chinese numeric prefix");
    if (!api->process_key(staged, separator, 0)) {
      Fail(std::string("Chinese numeric separator was not accepted: ") +
           separator);
    }
    const std::string actual = TakeOptionalCommit(api, staged);
    if (actual != std::string(1, separator)) {
      std::string action = "<missing>";
      const auto debug_session = rime::Service::instance().GetSession(staged);
      if (debug_session && debug_session->schema() &&
          debug_session->schema()->config()) {
        debug_session->schema()->config()->GetString(
            "punctuator/digit_separator_action", &action);
      }
      const auto origins = CandidateOrigins(staged);
      std::ostringstream evidence;
      for (const auto& origin : origins) {
        evidence << " [" << origin.type << "/" << origin.genuine_type << "]";
      }
      Fail(std::string("Chinese numeric separator committed '") + actual +
           "' instead of '" + separator + "'; action=" + action +
           " origins=" + evidence.str());
    }
    const auto live = rime::Service::instance().GetSession(staged);
    if (!live || !live->context() ||
        !live->context()->composition().empty() ||
        !live->context()->input().empty()) {
      Fail(std::string("Chinese numeric separator remained in composition: ") +
           separator);
    }
    api->destroy_session(staged);
  }

  for (const std::string& text : {"1,000", "3.14", "12:30"}) {
    const RimeSessionId session = CreateSchemaSession(api, "linnet_zh");
    const std::string actual = SimulateHostText(api, session, text);
    api->destroy_session(session);
    if (actual != text) {
      Fail("Chinese numeric punctuation changed '" + text + "' to '" +
           actual + "'");
    }
  }
}

struct KeyInteractionSnapshot {
  std::string input;
  std::string composition;
  size_t composition_size = 0;
  size_t caret = 0;
  size_t selected = 0;
  std::vector<std::string> candidates;

  bool operator==(const KeyInteractionSnapshot& other) const {
    return input == other.input && composition == other.composition &&
           composition_size == other.composition_size &&
           caret == other.caret &&
           selected == other.selected && candidates == other.candidates;
  }
};

KeyInteractionSnapshot ReadKeyInteractionSnapshot(RimeApi_stdbool* api,
                                                  RimeSessionId session) {
  KeyInteractionSnapshot result;
  const auto live = rime::Service::instance().GetSession(session);
  if (!live || !live->context()) {
    Fail("key-interaction snapshot has no live context");
  }
  result.input = live->context()->input();
  result.composition = live->context()->composition().GetDebugText();
  result.composition_size = live->context()->composition().size();
  result.caret = live->context()->caret_pos();
  if (!live->context()->composition().empty()) {
    result.selected = live->context()->composition().back().selected_index;
  }
  for (const auto& candidate : Candidates(api, session)) {
    result.candidates.push_back(candidate.text);
  }
  return result;
}

void ExpectHostModifierPassThrough(RimeApi_stdbool* api) {
  struct Fixture {
    const char* name;
    const char* schema;
    const char* input;
    bool prediction;
  };
  struct KeyCase {
    int keycode;
    const char* name;
  };
  constexpr std::array<Fixture, 4> fixtures = {{
      {"idle", "linnet_zh_pinyin", "", false},
      {"active", "linnet_zh_pinyin", "shi", false},
      {"raw", "linnet_en", "URLSession", false},
      {"prediction", "linnet_en", "", true},
  }};
  constexpr std::array<std::pair<int, const char*>, 6> modifiers = {{
      {kControlMask, "Control"},
      {kAltMask, "Option"},
      {kSuperMask, "Super"},
      {kMetaMask, "Meta"},
      {kHyperMask, "Hyper"},
      {kControlMask | kShiftMask, "Control+Shift"},
  }};
  constexpr std::array<KeyCase, 10> keys = {{
      {'c', "C"},
      {XK_Left, "Left"},
      {XK_Right, "Right"},
      {XK_Delete, "Delete"},
      {XK_BackSpace, "BackSpace"},
      {XK_Return, "Return"},
      {XK_Tab, "Tab"},
      {'1', "1"},
      {',', ","},
      {XK_space, "Space"},
  }};

  for (const auto& fixture : fixtures) {
    for (const auto& modifier : modifiers) {
      for (const auto& key : keys) {
        // macOS host shortcuts use Control/Alt/Super. Meta and Hyper remain
        // covered for raw navigation/editor keys, but printable raw spelling
        // is accepted by the upstream Recognizer before this product owner and
        // is not a macOS event shape.
        if ((std::strcmp(fixture.name, "raw") == 0 ||
             std::strcmp(fixture.name, "prediction") == 0) &&
            (modifier.first == kMetaMask || modifier.first == kHyperMask) &&
            key.keycode >= 0x20 && key.keycode < 0x7f) {
          continue;
        }
        const RimeSessionId session = fixture.prediction
            ? CreatePassivePrediction(api, "modifier prediction")
            : CreateSchemaSession(api, fixture.schema);
        if (*fixture.input) Enter(api, session, fixture.input);
        const auto before = ReadKeyInteractionSnapshot(api, session);
        if (api->process_key(session, key.keycode, modifier.first)) {
          Fail(std::string(fixture.name) + " " + modifier.second + "+" +
               key.name + " was swallowed instead of reaching the host");
        }
        if (!TakeOptionalCommit(api, session).empty()) {
          Fail(std::string(fixture.name) + " " + modifier.second + "+" +
               key.name + " committed text while passing to the host");
        }
        if (fixture.prediction) {
          ExpectPassivePredictionExit(
              api, session,
              std::string("modifier matrix ") + modifier.second + "+" +
                  key.name);
        } else if (!(ReadKeyInteractionSnapshot(api, session) == before)) {
          Fail(std::string(fixture.name) + " " + modifier.second + "+" +
               key.name + " changed active composition while passing");
        }
        api->destroy_session(session);
      }
    }
  }
}

void ExpectTrailingDeletePassThrough(RimeApi_stdbool* api) {
  for (const auto& fixture :
       std::array<std::pair<const char*, const char*>, 3>{{
           {"linnet_zh_pinyin", "shi"},
           {"linnet_en", "hello"},
           {"linnet_en", "URLSession"},
       }}) {
    const RimeSessionId trailing = CreateSchemaSession(api, fixture.first);
    Enter(api, trailing, fixture.second);
    const auto before = ReadKeyInteractionSnapshot(api, trailing);
    if (api->process_key(trailing, XK_Delete, 0)) {
      Fail(std::string(fixture.first) +
           " swallowed Delete at the trailing composition boundary");
    }
    if (!TakeOptionalCommit(api, trailing).empty() ||
        !(ReadKeyInteractionSnapshot(api, trailing) == before)) {
      Fail(std::string(fixture.first) +
           " changed composition on trailing Delete pass-through");
    }
    api->destroy_session(trailing);

    const RimeSessionId interior = CreateSchemaSession(api, fixture.first);
    Enter(api, interior, fixture.second);
    api->set_caret_pos(interior, std::strlen(fixture.second) - 1);
    const auto interior_before = ReadKeyInteractionSnapshot(api, interior);
    if (!api->process_key(interior, XK_Delete, 0)) {
      Fail(std::string(fixture.first) +
           " returned an actionable interior Delete to the host");
    }
    const auto interior_after = ReadKeyInteractionSnapshot(api, interior);
    if (interior_after.input == interior_before.input) {
      Fail(std::string(fixture.first) +
           " handled interior Delete without deleting input");
    }
    api->destroy_session(interior);
  }
}

int PrintableModifier(unsigned char ch) {
  constexpr char kShiftedPunctuation[] = "~!@#$%^&*()_+{}|:\"<>?";
  return (ch >= 'A' && ch <= 'Z') ||
                 std::strchr(kShiftedPunctuation, ch)
             ? kShiftMask
             : 0;
}

void ExpectPrintableAsciiMatrix(RimeApi_stdbool* api) {
  for (const char* schema : {"linnet_zh_pinyin", "linnet_en"}) {
    for (const char* initial : {"", std::strcmp(schema, "linnet_en") == 0
                                       ? "hello"
                                       : "shi"}) {
      for (int ch = 0x20; ch <= 0x7e; ++ch) {
        const RimeSessionId session = CreateSchemaSession(api, schema);
        if (*initial) Enter(api, session, initial);
        const auto before = ReadKeyInteractionSnapshot(api, session);
        const bool handled = api->process_key(
            session, ch, PrintableModifier(static_cast<unsigned char>(ch)));
        const std::string commit = TakeOptionalCommit(api, session);
        const auto after = ReadKeyInteractionSnapshot(api, session);
        if (handled && commit.empty() && after == before) {
          Fail(std::string(schema) + (*initial ? " active " : " idle ") +
               "printable ASCII key was handled without a visible effect: " +
               std::to_string(ch));
        }
        api->destroy_session(session);
      }
    }
  }
}

void ExpectRetiredHiddenRawPrefixes(RimeApi_stdbool* api) {
  for (const char symbol : std::string("/~")) {
    const RimeSessionId chinese =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    if (!api->process_key(chinese, symbol, 0) ||
        TakeCommit(api, chinese, "idle ordinary symbol") !=
            std::string(1, symbol)) {
      Fail(std::string("idle ordinary symbol remained a hidden raw prefix: ") +
           symbol);
    }
    const auto live = rime::Service::instance().GetSession(chinese);
    if (!live || !live->context() || !live->context()->input().empty() ||
        !live->context()->composition().empty()) {
      Fail(std::string("idle ordinary symbol retained a composition: ") +
           symbol);
    }
    api->destroy_session(chinese);

    const RimeSessionId english = CreateSchemaSession(api, "linnet_en");
    if (api->process_key(english, symbol, 0)) {
      Fail(std::string("Smart English intercepted idle ordinary symbol: ") +
           symbol);
    }
    if (!TakeOptionalCommit(api, english).empty()) {
      Fail(std::string("Smart English committed idle ordinary symbol: ") +
           symbol);
    }
    const auto english_live = rime::Service::instance().GetSession(english);
    if (!english_live || !english_live->context() ||
        !english_live->context()->input().empty() ||
        !english_live->context()->composition().empty() ||
        !Candidates(api, english).empty()) {
      Fail(std::string("Smart English retained idle ordinary symbol state: ") +
           symbol);
    }
    api->destroy_session(english);
  }
}

void ExpectIdleSpacePassThrough(RimeApi_stdbool* api) {
  const RimeSessionId session = CreateSchemaSession(api, "linnet_zh");
  if (api->process_key(session, XK_space, 0)) {
    Fail("Chinese half-shape punctuator consumed idle Space");
  }
  ExpectNoCommit(api, session, "idle Space pass-through");
  api->destroy_session(session);
}

bool IsWeekdayShortcutCandidate(const std::string& text) {
  static constexpr std::array<const char*, 36> kWeekdayCandidates = {
      "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六",
      "礼拜日", "礼拜一", "礼拜二", "礼拜三", "礼拜四", "礼拜五", "礼拜六",
      "周日",   "周一",   "周二",   "周三",   "周四",   "周五",   "周六",
      "Sun.",   "Sunday", "Mon.",   "Monday", "Tue.",   "Tuesday",
      "Wed.",   "Wednesday", "Thu.", "Thurs.", "Thursday", "Fri.",
      "Friday", "Sat.",   "Saturday",
  };
  return std::any_of(
      kWeekdayCandidates.begin(), kWeekdayCandidates.end(),
      [&](const char* candidate) { return text == candidate; });
}

bool IsUuidCandidate(const std::string& text) {
  if (text.size() != 36) return false;
  for (size_t index = 0; index < text.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) {
      if (text[index] != '-') return false;
    } else if (!((text[index] >= '0' && text[index] <= '9') ||
                 (text[index] >= 'a' && text[index] <= 'f'))) {
      return false;
    }
  }
  return true;
}

void ExpectDateShortcutProfileIsolation(RimeApi_stdbool* api) {
  for (size_t profile_index = 0;
       profile_index < kDoublePinyinSchemaIDs.size(); ++profile_index) {
    const char* schema_id = kDoublePinyinSchemaIDs[profile_index];
    const std::string schema = schema_id;
    const std::string prefix =
        schema == "linnet_zh_jiajia" || schema == "linnet_zh_mspy"
            ? "|"
            : ";";
    const RimeSessionId session = CreateSchemaSession(api, schema_id);
    Enter(api, session, "xq");
    const auto ordinary = Candidates(api, session);
    if (std::any_of(ordinary.begin(), ordinary.end(), [](const auto& item) {
          return IsWeekdayShortcutCandidate(BaseText(item.text));
        })) {
      Fail(std::string(schema_id) +
           " let the full-pinyin xq weekday shortcut shadow double pinyin");
    }
    const auto ordinary_origins = CandidateOrigins(session);
    const bool literal_profile =
        schema == "linnet_zh_abc" || schema == "linnet_zh_ziguang";
    const std::string expected_text =
        literal_profile ? "xq" : schema == "linnet_zh_jiajia" ? "行" : "修";
    const std::string expected_language =
        literal_profile ? "linnet_en" : "linnet_zh";
    const bool retained_ordinary = std::any_of(
        ordinary_origins.begin(), ordinary_origins.end(),
        [&](const auto& candidate) {
          return candidate.start == 0 && candidate.end == 2 &&
                 BaseText(candidate.text) == expected_text &&
                 candidate.genuine_language == expected_language;
        });
    if (!retained_ordinary) {
      Fail(std::string(schema_id) +
           " lost its ordinary non-date xq candidate");
    }
    Enter(api, session, "week");
    const auto explicit_command = Candidates(api, session);
    if (explicit_command.empty() ||
        !IsWeekdayShortcutCandidate(
            BaseText(explicit_command.front().text))) {
      Fail(std::string(schema_id) +
           " lost the explicit double-pinyin week command");
    }
    Enter(api, session, prefix + "week");
    const auto prefixed_date = Candidates(api, session);
    if (std::any_of(prefixed_date.begin(), prefixed_date.end(),
                    [](const auto& item) {
                      return IsWeekdayShortcutCandidate(BaseText(item.text));
                    })) {
      Fail(std::string(schema_id) +
           " let the date translator enter explicit pinyin reverse lookup");
    }
    Enter(api, session, "uuid");
    const auto uuid_command = Candidates(api, session);
    if (std::none_of(uuid_command.begin(), uuid_command.end(),
                     [](const auto& item) {
                       return IsUuidCandidate(BaseText(item.text));
                     })) {
      Fail(std::string(schema_id) + " lost the ordinary UUID command");
    }
    Enter(api, session, prefix + "uuid");
    const auto prefixed_uuid = Candidates(api, session);
    if (std::any_of(prefixed_uuid.begin(), prefixed_uuid.end(),
                    [](const auto& item) {
                      return IsUuidCandidate(BaseText(item.text));
                    })) {
      Fail(std::string(schema_id) +
           " let the UUID translator enter explicit pinyin reverse lookup");
    }
    api->destroy_session(session);
  }

  const RimeSessionId full_pinyin =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, full_pinyin, "xq");
  const auto full_pinyin_shortcut = Candidates(api, full_pinyin);
  if (full_pinyin_shortcut.empty() ||
      !IsWeekdayShortcutCandidate(
          BaseText(full_pinyin_shortcut.front().text))) {
    Fail("full pinyin lost its reviewed xq weekday shortcut");
  }
  Enter(api, full_pinyin, ";xq");
  const auto prefixed_shortcut = Candidates(api, full_pinyin);
  if (std::any_of(prefixed_shortcut.begin(), prefixed_shortcut.end(),
                  [](const auto& item) {
                    return IsWeekdayShortcutCandidate(BaseText(item.text));
                  })) {
    Fail("full pinyin let the xq date command enter reverse lookup");
  }
  Enter(api, full_pinyin, ";uuid");
  const auto prefixed_uuid = Candidates(api, full_pinyin);
  if (std::any_of(prefixed_uuid.begin(), prefixed_uuid.end(),
                  [](const auto& item) {
                    return IsUuidCandidate(BaseText(item.text));
                  })) {
    Fail("full pinyin let the UUID command enter reverse lookup");
  }
  api->destroy_session(full_pinyin);

  const RimeSessionId retained_double =
      CreateSchemaSession(api, "linnet_zh");
  const RimeSessionId retained_full =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  const auto expect_weekday = [&](RimeSessionId session,
                                  const std::string& input,
                                  const std::string& reason) {
    Enter(api, session, input);
    const auto candidates = Candidates(api, session);
    if (candidates.empty() ||
        !IsWeekdayShortcutCandidate(BaseText(candidates.front().text))) {
      Fail("date command lost its session-local configuration after " + reason);
    }
  };
  expect_weekday(retained_double, "week", "double-pinyin initialization");
  expect_weekday(retained_full, "xq", "full-pinyin initialization");
  const RimeSessionId later_double =
      CreateSchemaSession(api, "linnet_zh_flypy");
  expect_weekday(retained_double, "week", "full-pinyin initialization");
  expect_weekday(retained_full, "xq", "later double-pinyin initialization");
  api->destroy_session(later_double);
  api->destroy_session(retained_full);
  api->destroy_session(retained_double);
}

void ExpectPinyinReverseUsesActiveProfiles(RimeApi_stdbool* api) {
  struct ProfileCase {
    const char* schema;
    const char* code;
    const char* prefix;
  };
  for (const auto& profile :
       std::vector<ProfileCase>{
           {"linnet_zh_pinyin", "suanfa", ";"},
           {"linnet_zh", "srfa", ";"},
           {"linnet_zh_flypy", "srfa", ";"},
           {"linnet_zh_mspy", "srfa", "|"},
           {"linnet_zh_sogou", "srfa", ";"},
           {"linnet_zh_abc", "spfa", ";"},
           {"linnet_zh_ziguang", "slfa", ";"},
           {"linnet_zh_jiajia", "scfa", "|"},
       }) {
    const RimeSessionId session = CreateSchemaSession(api, profile.schema);
    Enter(api, session, std::string(profile.prefix) + profile.code);
    const auto origins = CandidateOrigins(session);
    const auto algorithm = std::find_if(
        origins.begin(), origins.end(), [](const auto& candidate) {
          return BaseText(candidate.text) == "algorithm" &&
                 candidate.genuine_type == "linnet_pinyin";
        });
    if (algorithm == origins.end()) {
      std::cerr << "Pinyin reverse origins for " << profile.schema << ":";
      for (const auto& candidate : origins) {
        std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                  << candidate.genuine_type << "]";
      }
      std::cerr << '\n';
      Fail(std::string(profile.schema) +
           " did not decode its active pinyin profile for English lookup");
    }
    if (std::string(profile.schema) == "linnet_zh_jiajia" &&
        std::any_of(origins.begin(), origins.end(), [](const auto& candidate) {
          return BaseText(candidate.text) == "color shading";
        })) {
      Fail("Jiajia reverse lookup used scfa as raw full pinyin");
    }
    Enter(api, session, profile.code);
    const auto unprefixed = CandidateOrigins(session);
    if (std::any_of(unprefixed.begin(), unprefixed.end(), [](const auto& candidate) {
                      return candidate.genuine_type == "linnet_pinyin";
                    })) {
      Fail(std::string(profile.schema) +
           " enabled pinyin-to-English lookup without the trigger");
    }
    if (std::string(profile.prefix) != ";") {
      Enter(api, session, std::string(";") + profile.code);
      const auto retired_trigger = CandidateOrigins(session);
      if (std::any_of(retired_trigger.begin(), retired_trigger.end(),
                      [](const auto& candidate) {
                        return candidate.genuine_type == "linnet_pinyin";
                      })) {
        Fail(std::string(profile.schema) +
             " kept the bundled semicolon after the Settings trigger changed");
      }
    }
    api->destroy_session(session);
  }

  for (const auto& profile :
       std::vector<ProfileCase>{
           {"linnet_zh_pinyin", "suan'fa", ";"},
           {"linnet_zh", "sr'fa", ";"},
           {"linnet_zh_jiajia", "sc'fa", "|"},
       }) {
    const RimeSessionId session = CreateSchemaSession(api, profile.schema);
    Enter(api, session, std::string(profile.prefix) + profile.code);
    const auto origins = CandidateOrigins(session);
    if (std::none_of(origins.begin(), origins.end(), [](const auto& candidate) {
          return BaseText(candidate.text) == "algorithm" &&
                 candidate.genuine_type == "linnet_pinyin";
        })) {
      std::cerr << "Delimited reverse origins for " << profile.schema << ":";
      for (const auto& candidate : origins) {
        std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                  << candidate.genuine_type << "]";
      }
      std::cerr << '\n';
      Fail(std::string(profile.schema) +
           " did not reuse the standard pinyin syllable delimiter");
    }
    api->destroy_session(session);
  }

  struct EmbeddedSeparatorCase {
    const char* schema;
    const char* code;
    const char* prefix;
  };
  for (const auto& profile :
       std::vector<EmbeddedSeparatorCase>{
           {"linnet_zh_mspy", "m;tm", "|"},
           {"linnet_zh_sogou", "m;tm", ";"},
           {"linnet_zh_ziguang", "m;tf", ";"},
       }) {
    const RimeSessionId session = CreateSchemaSession(api, profile.schema);
    Enter(api, session, std::string(profile.prefix) + profile.code);
    const auto origins = CandidateOrigins(session);
    if (std::none_of(origins.begin(), origins.end(), [](const auto& candidate) {
          return BaseText(candidate.text) == "tomorrow" &&
                 candidate.genuine_type == "linnet_pinyin";
        })) {
      Fail(std::string(profile.schema) +
           " lost the semicolon inside its active double-pinyin code");
    }
    if (std::string(profile.prefix) != ";") {
      Enter(api, session, std::string(";") + profile.code);
      const auto retired = CandidateOrigins(session);
      if (std::any_of(retired.begin(), retired.end(), [](const auto& candidate) {
            return candidate.genuine_type == "linnet_pinyin";
          })) {
        Fail(std::string(profile.schema) +
             " retained semicolon after the alternate trigger deployment");
      }
    }
    api->destroy_session(session);
  }

  const RimeSessionId decomposed_tone =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, decomposed_tone, ";me");
  const auto tone_origins = CandidateOrigins(decomposed_tone);
  if (std::none_of(tone_origins.begin(), tone_origins.end(),
                   [](const auto& candidate) {
                     return BaseText(candidate.text) == "astonished" &&
                            candidate.genuine_type == "linnet_pinyin";
                   }) ||
      std::any_of(tone_origins.begin(), tone_origins.end(),
                  [](const auto& candidate) {
                    return BaseText(candidate.text) == "mama" &&
                           candidate.genuine_type == "linnet_pinyin";
                  })) {
    Fail("decomposed m-grave syllable did not normalize to the p/m key");
  }
  api->destroy_session(decomposed_tone);
}

void ExpectEnglishPinyinProfile(RimeApi_stdbool* api,
                                const std::string& profile,
                                const std::string& expected_chinese_schema,
                                const std::string& code,
                                const std::string& prefix) {
  const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
  const auto expect_algorithm = [&](const std::string& input,
                                    const std::string& reason) {
    Enter(api, session, input);
    const auto origins = CandidateOrigins(session, 256);
    if (std::none_of(origins.begin(), origins.end(), [](const auto& item) {
          return BaseText(item.text) == "algorithm" &&
                 item.genuine_type == "linnet_pinyin";
        })) {
      Fail("Smart English did not decode " + profile + " for " + reason);
    }
  };
  expect_algorithm(code, "automatic reverse lookup");
  expect_algorithm(prefix + code, "explicit reverse lookup");

  if (profile == "jiajia") {
    Enter(api, session, code);
    const auto origins = CandidateOrigins(session, 256);
    if (std::any_of(origins.begin(), origins.end(), [](const auto& item) {
          return BaseText(item.text) == "color shading" &&
                 item.genuine_type == "linnet_pinyin";
        })) {
      Fail("Smart English retained raw-full-pinyin semantics for Jiajia");
    }
    Enter(api, session, "suanfa");
    const auto retired_full_pinyin = CandidateOrigins(session, 256);
    if (std::any_of(retired_full_pinyin.begin(), retired_full_pinyin.end(),
                    [](const auto& item) {
                      return BaseText(item.text) == "algorithm" &&
                             item.genuine_type == "linnet_pinyin";
                    })) {
      Fail("Smart English kept full pinyin after Jiajia was selected");
    }
  }

  if (profile == "microsoft") {
    Enter(api, session, prefix + "m;tm");
    const auto origins = CandidateOrigins(session, 256);
    if (std::none_of(origins.begin(), origins.end(), [](const auto& item) {
          return BaseText(item.text) == "tomorrow" &&
                 item.genuine_type == "linnet_pinyin";
        })) {
      Fail("Smart English lost the separator inside Microsoft double pinyin");
    }
    if (prefix != ";") {
      Enter(api, session, ";m;tm");
      const auto retired = CandidateOrigins(session, 256);
      if (std::any_of(retired.begin(), retired.end(), [](const auto& item) {
            return BaseText(item.text) == "tomorrow" &&
                   item.genuine_type == "linnet_pinyin";
          })) {
        Fail("Smart English retained semicolon for a punctuation-bearing Microsoft code");
      }
    }
  }
  api->destroy_session(session);

  const RimeSessionId direct = CreateSchemaSession(api, "linnet_en");
  TapShift(api, direct, XK_Shift_L);
  ExpectCurrentSchema(api, direct, expected_chinese_schema,
                      "direct Smart English return for " + profile);
  api->destroy_session(direct);
}

void ExpectPinyinReverseTraversalBounded(RimeApi_stdbool* api) {
  const RimeSessionId reviewed_session =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  constexpr char kReviewedLongKey[] =
      "zhongyangrenminzhengfuzhuxianggangtebiexingzhengqulianluobangongshi";
  constexpr char kReviewedLongResult[] =
      "Liaison Office of the Central People's Government in the Hong Kong "
      "Special Administrative Region";
  Enter(api, reviewed_session, std::string(";") + kReviewedLongKey);
  const auto reviewed = CandidateOrigins(reviewed_session);
  if (std::none_of(reviewed.begin(), reviewed.end(), [&](const auto& candidate) {
        return BaseText(candidate.text) == kReviewedLongResult &&
               candidate.genuine_type == "linnet_pinyin";
      })) {
    Fail("active-profile pinyin decoding truncated a reviewed long key");
  }
  api->destroy_session(reviewed_session);

  const RimeSessionId session =
      CreateSchemaSession(api, "linnet_zh_mspy");
  std::string adversarial = "|";
  for (int i = 0; i < 16; ++i) adversarial += "srfa";

  api->clear_composition(session);
  const auto started = std::chrono::steady_clock::now();
  if (!api->set_input(session, adversarial.c_str())) {
    Fail("could not set the ambiguous pinyin traversal probe");
  }
  const auto origins = CandidateOrigins(session);
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started);
  if (elapsed > std::chrono::milliseconds(250)) {
    Fail("ambiguous pinyin traversal exceeded the input-thread budget");
  }
  if (std::any_of(origins.begin(), origins.end(), [](const auto& candidate) {
        return candidate.genuine_type == "linnet_pinyin";
      })) {
    Fail("ambiguous pinyin traversal did not fail closed");
  }

  api->clear_composition(session);
  const std::string overlong = "|" + std::string(256, 'a');
  const auto overlong_started = std::chrono::steady_clock::now();
  if (!api->set_input(session, overlong.c_str())) {
    Fail("could not set the overlong pinyin graph probe");
  }
  const auto overlong_origins = CandidateOrigins(session);
  const auto overlong_elapsed =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - overlong_started);
  if (overlong_elapsed > std::chrono::milliseconds(250)) {
    Fail("overlong pinyin input reached graph construction");
  }
  if (std::any_of(overlong_origins.begin(), overlong_origins.end(),
                  [](const auto& candidate) {
                    return candidate.genuine_type == "linnet_pinyin";
                  })) {
    Fail("overlong pinyin input did not fail closed");
  }
  api->destroy_session(session);
}

void ExpectPinyinReverseKeyLimit(RimeApi_stdbool* api) {
  const RimeSessionId at_limit =
      CreateSchemaSession(api, "linnet_pinyin_limit_64");
  api->set_option(at_limit, "emoji", false);
  api->set_option(at_limit, "traditionalization", false);
  Enter(api, at_limit, ";probe");
  const auto allowed = CandidateOrigins(at_limit, 128);
  const size_t pinyin_count = static_cast<size_t>(std::count_if(
      allowed.begin(), allowed.end(), [](const auto& candidate) {
        return candidate.genuine_type == "linnet_pinyin";
      }));
  const bool has_last_key_rank_one =
      std::any_of(allowed.begin(), allowed.end(), [](const auto& candidate) {
        return BaseText(candidate.text) == "cloud" &&
               candidate.genuine_type == "linnet_pinyin";
      });
  const bool leaked_first_key_rank_two =
      std::any_of(allowed.begin(), allowed.end(), [](const auto& candidate) {
        return BaseText(candidate.text) == "cure" &&
               candidate.genuine_type == "linnet_pinyin";
      });
  if (pinyin_count != 64 || !has_last_key_rank_one ||
      leaked_first_key_rank_two) {
    std::cerr << "Pinyin 64-key merge origins (count=" << pinyin_count << "):";
    for (const auto& candidate : allowed) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << "]";
    }
    std::cerr << '\n';
    Fail("64 active-Prism keys did not merge by the stored source rank");
  }
  api->destroy_session(at_limit);

  const RimeSessionId over_limit =
      CreateSchemaSession(api, "linnet_pinyin_limit_65");
  api->set_option(over_limit, "emoji", false);
  api->set_option(over_limit, "traditionalization", false);
  Enter(api, over_limit, ";probe");
  const auto rejected = CandidateOrigins(over_limit);
  if (std::any_of(rejected.begin(), rejected.end(), [](const auto& candidate) {
        return candidate.genuine_type == "linnet_pinyin";
      })) {
    Fail("65 active-Prism pinyin keys returned a partial candidate set");
  }
  api->destroy_session(over_limit);
}

void ExpectSessionProperty(RimeApi_stdbool* api,
                           RimeSessionId session_id,
                           const std::string& key,
                           const std::string& expected,
                           const std::string& reason);

void ExpectModeSwitchClearsSmartEnglishState(RimeApi_stdbool* api) {
  const RimeSessionId session =
      CreateSchemaSession(api, "linnet_zh");
  TapShift(api, session, XK_Shift_L);
  ExpectCurrentSchema(api, session, "linnet_en",
                      "schema-boundary state probe entered Smart English");
  if (SelectNormalizedCandidate(api, session, "use", "use") != "use") {
    Fail("schema-boundary state probe could not commit English context");
  }
  ExpectSessionProperty(api, session, kPredictContextProperty, "use",
                        "English context before schema switch");

  TapShift(api, session, XK_Shift_R);
  ExpectCurrentSchema(api, session, "linnet_zh",
                      "schema-boundary state probe returned to Chinese");
  ExpectNoCommit(api, session,
                 "Shift dismissed an English prediction at schema boundary");
  for (const char* property :
       {kPredictContextProperty, kPredictStaticKeyProperty,
        kPredictionNavigationProperty, kSpacingProperty,
        kSentenceBoundaryProperty, kSuppressFollowingSpaceProperty}) {
    ExpectSessionPropertyAbsent(api, session, property,
                                "English-to-Chinese schema boundary");
  }
  Enter(api, session, ";ypjisr");
  const auto explicit_origins = CandidateOrigins(session);
  if (std::none_of(explicit_origins.begin(), explicit_origins.end(),
                   [](const auto& candidate) {
                     return candidate.text == "cloud computing" &&
                            candidate.genuine_type == "linnet_pinyin";
                   })) {
    Fail("Chinese reverse lookup inherited English leading-space state");
  }
  const std::string explicit_commit =
      SelectCurrentNormalizedCandidate(api, session, "cloud computing");
  if (explicit_commit != "cloud computing") {
    Fail("Chinese reverse lookup commit inherited English session state: '" +
         explicit_commit + "' (" + std::to_string(explicit_commit.size()) +
         " bytes)");
  }

  TapShift(api, session, XK_Shift_L);
  ExpectCurrentSchema(api, session, "linnet_en",
                      "schema-boundary state probe re-entered Smart English");
  ExpectSessionPropertyAbsent(api, session, kPredictContextProperty,
                              "Chinese-to-English schema boundary");
  ExpectSessionPropertyAbsent(api, session, kPredictStaticKeyProperty,
                              "Chinese-to-English schema boundary");
  ExpectCandidate(api, session, "platform", "platform");
  api->destroy_session(session);
}

void ExpectSessionProperty(RimeApi_stdbool* api,
                           RimeSessionId session_id,
                           const std::string& key,
                           const std::string& expected,
                           const std::string& reason) {
  char value[256] = {};
  if (!api->get_property(session_id, key.c_str(), value, sizeof(value))) {
    Fail("could not inspect Rime session property after " + reason);
  }
  const std::string actual = value;
  if (actual != expected) {
    Fail("session property " + key + " after " + reason +
         " expected '" + expected + "', got '" + actual + "'");
  }
}

void ExpectSessionPropertyAbsent(RimeApi_stdbool* api,
                                 RimeSessionId session_id,
                                 const std::string& key,
                                 const std::string& reason) {
  char value[256] = {};
  if (api->get_property(session_id, key.c_str(), value, sizeof(value))) {
    Fail("session property " + key + " remained '" + value + "' after " +
         reason);
  }
}

void ExpectEnglishLearningDisabled(RimeApi_stdbool* api,
                                   RimeSessionId session) {
  const auto live_session = rime::Service::instance().GetSession(session);
  if (!live_session || !live_session->schema() ||
      !live_session->schema()->config()) {
    Fail("could not inspect the disabled English learning schema");
  }
  bool user_dict_enabled = true;
  bool native_learning_enabled = true;
  if (!live_session->schema()->config()->GetBool(
          "translator/enable_user_dict", &user_dict_enabled) ||
      user_dict_enabled ||
      !live_session->schema()->config()->GetBool(
          "linnet_english_interaction/learning_enabled",
          &native_learning_enabled) ||
      native_learning_enabled) {
    Fail("the deployed English learning setting did not close both owners");
  }

  const std::string retained_bigram = "v1 7 hello zebra 7 7";
  api->set_property(session, kBigramProperty, retained_bigram.c_str());
  std::string spaced_text =
      SelectNormalizedCandidate(api, session, "hello", "hello");
  ExpectSessionProperty(api, session, kBigramProperty, retained_bigram,
                        "disabled learning read probe");
  const auto predictions = Candidates(api, session);
  if (OptionalNormalizedCandidateIndex(predictions, "zebra") !=
      predictions.size()) {
    Fail("disabled English learning still read a retained session bigram");
  }
  spaced_text += ContinueAndSelectNormalizedCandidate(
      api, session, "world", "world");
  ExpectSessionProperty(api, session, kBigramProperty, retained_bigram,
                        "disabled learning write probe");
  ExpectSessionProperty(api, session, kPredictContextProperty, "hello world",
                        "disabled learning context continuity");
  if (spaced_text != "hello world") {
    Fail("disabled English learning changed spacing: " + spaced_text);
  }

  const RimeSessionId static_context =
      CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, static_context, "i", "I");
  ContinueAndSelectNormalizedCandidate(api, static_context, "do", "do");
  ContinueAndSelectNormalizedCandidate(api, static_context, "not", "not");
  ExpectPredictionMenu(api, static_context,
                       "disabled learning static context");
  NormalizedCandidateIndex(api, static_context, "know");
  ExpectSessionPropertyAbsent(api, static_context, kBigramProperty,
                              "disabled learning static context");
  ExpectSessionProperty(api, static_context, kPredictContextProperty,
                        "i do not", "disabled learning static context");
  api->destroy_session(static_context);
}

void ExpectAutomaticPinyinTailProjection(RimeApi_stdbool* api) {
  const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
  if (SelectNormalizedCandidate(api, session, "use", "use") != "use") {
    Fail("automatic pinyin tail probe could not establish English spacing");
  }
  // Keep this as a real continuous typing transition. Enter() intentionally
  // calls clear_composition(), which is now a hard app/deactivation boundary
  // and must retire prediction context and spacing before the next word.
  if (!api->simulate_key_sequence(session, "QI")) {
    Fail("automatic pinyin tail probe could not continue English input");
  }
  const auto live_session = rime::Service::instance().GetSession(session);
  if (!live_session || !live_session->context() ||
      live_session->context()->composition().empty()) {
    Fail("automatic pinyin tail probe has no live composition");
  }
  auto& segment = live_session->context()->composition().back();
  const size_t prepared = segment.menu ? segment.menu->Prepare(128) : 0;
  size_t projected_index = prepared;
  for (size_t index = 0; index < prepared; ++index) {
    const auto candidate = segment.menu->GetCandidateAt(index);
    const auto genuine = rime::Candidate::GetGenuineCandidate(candidate);
    if (candidate && genuine && genuine->type() == "linnet_pinyin" &&
        genuine->text() == "large") {
      if (candidate->text() != " LARGE" ||
          candidate->comment().find("lɑrʤ") == std::string::npos ||
          candidate->comment().find("大的") == std::string::npos) {
        Fail("automatic pinyin tail bypassed spacing, case or metadata: text=" +
             candidate->text() + " comment=" + candidate->comment());
      }
      projected_index = index;
      break;
    }
  }
  if (projected_index < 64 || projected_index == prepared) {
    Fail("automatic pinyin tail fixture no longer exercises candidate 65+ " +
         std::to_string(projected_index) + "/" + std::to_string(prepared));
  }
  if (!api->select_candidate(session, projected_index) ||
      TakeCommit(api, session) != " LARGE") {
    Fail("automatic pinyin tail display and commit projections diverged");
  }
  ExpectSessionProperty(api, session, kPredictContextProperty,
                        "use large", "automatic pinyin tail commit");
  api->destroy_session(session);

  const RimeSessionId chinese =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, chinese, "shi");
  const auto chinese_session = rime::Service::instance().GetSession(chinese);
  if (!chinese_session || !chinese_session->context() ||
      chinese_session->context()->composition().empty()) {
    Fail("Chinese tail reachability probe has no live composition");
  }
  auto& chinese_segment = chinese_session->context()->composition().back();
  if (!chinese_segment.menu || chinese_segment.menu->Prepare(66) < 66 ||
      !chinese_segment.menu->GetCandidateAt(65)) {
    Fail("lazy Smart English projection truncated the Chinese candidate tail");
  }
  api->destroy_session(chinese);
}

struct FastReloadTarget {
  const char* file_name;
  const char* version_key;
};

constexpr std::array<FastReloadTarget, 11> kFastReloadTargets = {{
    {"default.yaml", "config_version"},
    {"linnet_en.schema.yaml", "schema/version"},
    {"linnet_zh.schema.yaml", "schema/version"},
    {"linnet_zh_pinyin.schema.yaml", "schema/version"},
    {"linnet_zh_flypy.schema.yaml", "schema/version"},
    {"linnet_zh_mspy.schema.yaml", "schema/version"},
    {"linnet_zh_sogou.schema.yaml", "schema/version"},
    {"linnet_zh_abc.schema.yaml", "schema/version"},
    {"linnet_zh_ziguang.schema.yaml", "schema/version"},
    {"linnet_zh_jiajia.schema.yaml", "schema/version"},
    {"squirrel.yaml", "config_version"},
}};

struct ArtifactIdentity {
  uintmax_t size;
  std::filesystem::file_time_type modified;

  bool operator==(const ArtifactIdentity& other) const {
    return size == other.size && modified == other.modified;
  }
};

bool HasSuffix(const std::string& value, const std::string& suffix) {
  return value.size() >= suffix.size() &&
         value.compare(value.size() - suffix.size(), suffix.size(), suffix) ==
             0;
}

std::map<std::string, ArtifactIdentity> DictionaryArtifactSnapshot(
    const std::filesystem::path& build_directory) {
  std::map<std::string, ArtifactIdentity> result;
  for (const auto& entry :
       std::filesystem::directory_iterator(build_directory)) {
    const std::string name = entry.path().filename().string();
    if (!entry.is_regular_file() ||
        (!HasSuffix(name, ".table.bin") &&
         !HasSuffix(name, ".prism.bin") &&
         !HasSuffix(name, ".reverse.bin"))) {
      continue;
    }
    result.emplace(name, ArtifactIdentity{entry.file_size(),
                                          entry.last_write_time()});
  }
  if (result.empty()) Fail("fast reload artifact baseline is empty");
  return result;
}

void WritePinnedFile(const std::filesystem::path& path,
                     const std::string& contents,
                     std::filesystem::file_time_type fixed_time) {
  std::ofstream output(path, std::ios::trunc);
  output << contents;
  output.close();
  if (!output) Fail("could not write fast reload projection " + path.string());
  std::error_code error;
  std::filesystem::last_write_time(path, fixed_time, error);
  if (error) Fail("could not pin projection timestamp " + path.string());
}

void WriteFastReloadProjection(const std::filesystem::path& user_directory,
                               const std::string& schema_id,
                               size_t original_index,
                               std::filesystem::file_time_type fixed_time) {
  std::ostringstream defaults;
  defaults << "patch:\n"
           << "  \"ascii_composer/switch_key/Caps_Lock\": commit_text\n"
           << "  \"linnet/recognizer_patterns/zz_code_token\": \"^(?:(?:www[.]|https?:|ftp[.:]|mailto:|file:).*|(?:[a-z]+[A-Z]|[A-Z][a-z]+[A-Z]|[A-Z]{2,}[a-z]|v[0-9]+|[A-Z][A-Za-z]*[0-9]|[A-Z]{2,}[._/@:+-])[0-9A-Za-z._/@:+?&=%#~-]*)$\"\n"
           << "  \"menu/page_size\": 5\n";
  if (schema_id != "linnet_zh_pinyin") {
    defaults << "  \"schema_list/@0/schema\": \"" << schema_id << "\"\n"
             << "  \"schema_list/@" << original_index
             << "/schema\": \"linnet_zh_pinyin\"\n";
  }
  WritePinnedFile(user_directory / "default.custom.yaml", defaults.str(),
                  fixed_time);

  const std::string chinese =
      "patch:\n"
      "  \"switches/@2/reset\": 1\n"
      "  \"recognizer/patterns/linnet_pinyin\": \"^[|][a-z;']*$\"\n"
      "  \"linnet_pinyin/prefix\": \"|\"\n"
      "  \"linnet_english_interaction/sentence_capitalization\": false\n"
      "  \"linnet_english_interaction/tab_behavior\": \"pass\"\n"
      "  \"linnet_english_interaction/show_ipa\": false\n"
      "  \"linnet_english_interaction/show_translation\": false\n"
      "  \"linnet_english_interaction/learning_enabled\": false\n";
  for (size_t index = 0; index + 1 < kProductSchemaIDs.size(); ++index) {
    WritePinnedFile(user_directory /
                        (std::string(kProductSchemaIDs[index]) +
                         ".custom.yaml"),
                    chinese, fixed_time);
  }

  std::ostringstream english;
  english
      << "patch:\n"
      << "  \"recognizer/patterns/linnet_pinyin\": \"^[|][a-z;']*$\"\n"
      << "  \"linnet_pinyin/prefix\": \"|\"\n"
      << "  \"linnet_pinyin/prism\": \"" << schema_id << "\"\n"
      << "  \"linnet_mode_switch/chinese_schema\": \"" << schema_id
      << "\"\n"
      << "  \"linnet_english_interaction/sentence_capitalization\": false\n"
      << "  \"linnet_english_interaction/tab_behavior\": \"pass\"\n"
      << "  \"linnet_english_interaction/show_ipa\": false\n"
      << "  \"linnet_english_interaction/show_translation\": false\n"
      << "  \"switches/@1/reset\": 0\n"
      << "  \"linnet_english_interaction/spelling_correction\": false\n"
      << "  \"translator/enable_user_dict\": false\n"
      << "  \"linnet_english_interaction/learning_enabled\": false\n";
  WritePinnedFile(user_directory / "linnet_en.custom.yaml", english.str(),
                  fixed_time);
  WritePinnedFile(user_directory / "linnet_user.custom.yaml",
                  "patch:\n"
                  "  disabled_words: []\n",
                  fixed_time);
}

double DeployFastReloadTargets(RimeApi_stdbool* api) {
  const auto started = std::chrono::steady_clock::now();
  for (const auto& target : kFastReloadTargets) {
    if (!api->deploy_config_file(target.file_name, target.version_key)) {
      Fail("targeted config deployment failed for " +
           std::string(target.file_name));
    }
  }
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now() - started)
      .count();
}

void ExpectFastConfigurationReload(RimeApi_stdbool* api,
                                   const std::filesystem::path& user_directory) {
  const auto artifact_baseline =
      DictionaryArtifactSnapshot(user_directory / "build");
  const auto fixed_time = std::filesystem::file_time_type::clock::now() -
                          std::chrono::hours(2);

  const RimeSessionId retained = CreateSchemaSession(api, "linnet_zh");
  Enter(api, retained, "ceshi");
  WriteFastReloadProjection(user_directory, "linnet_zh_jiajia", 7,
                            fixed_time);
  DeployFastReloadTargets(api);
  const char* retained_input = api->get_input(retained);
  if (!retained_input || std::string(retained_input) != "ceshi") {
    Fail("targeted deploy discarded the retained composition before cleanup");
  }
  ExpectCurrentSchema(api, retained, "linnet_zh",
                      "pre-cleanup targeted reload");
  api->cleanup_all_sessions();
  if (api->find_session(retained)) {
    Fail("session generation survived targeted-reload cleanup");
  }
  RimeSessionId fresh = api->create_session();
  if (!fresh) Fail("could not create a fresh targeted-reload session");
  ExpectCurrentSchema(api, fresh, "linnet_zh_jiajia",
                      "first targeted reload");
  api->destroy_session(fresh);

  constexpr size_t kSamples = 20;
  std::vector<double> latencies;
  latencies.reserve(kSamples);
  for (size_t index = 0; index < kSamples; ++index) {
    const bool final_profile = index % 2 == 1;
    const char* schema_id =
        final_profile ? "linnet_zh_pinyin" : "linnet_zh_jiajia";
    WriteFastReloadProjection(user_directory, schema_id,
                              final_profile ? 0 : 7, fixed_time);
    latencies.push_back(DeployFastReloadTargets(api));
    api->cleanup_all_sessions();
    fresh = api->create_session();
    if (!fresh) Fail("could not recreate a benchmark reload session");
    ExpectCurrentSchema(api, fresh, schema_id,
                        "same-second targeted reload");
    api->destroy_session(fresh);
  }

  if (DictionaryArtifactSnapshot(user_directory / "build") !=
      artifact_baseline) {
    Fail("targeted reload modified dictionary, prism, or table assets");
  }
  std::sort(latencies.begin(), latencies.end());
  const size_t p95_index = (latencies.size() * 95 + 99) / 100 - 1;
  const double p95 = latencies[p95_index];
  const double maximum = latencies.back();
  if (p95 >= 500.0 || maximum >= 1000.0) {
    Fail("targeted reload exceeded p95<500ms/max<1s: p95=" +
         std::to_string(p95) + "ms, max=" + std::to_string(maximum) + "ms");
  }

  fresh = api->create_session();
  if (!fresh) Fail("could not create the final targeted-reload session");
  ExpectCurrentSchema(api, fresh, "linnet_zh_pinyin",
                      "final targeted reload");
  api->destroy_session(fresh);
  ExpectDeployedMenuPageSize(api, "linnet_en", 5);

  const RimeSessionId chinese =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  const auto live_chinese = rime::Service::instance().GetSession(chinese);
  bool sentence_capitalization = true;
  std::string chinese_tab_behavior;
  if (!live_chinese || !live_chinese->schema() ||
      !live_chinese->schema()->config() ||
      !live_chinese->schema()->config()->GetBool(
          "linnet_english_interaction/sentence_capitalization",
          &sentence_capitalization) ||
      sentence_capitalization ||
      !live_chinese->schema()->config()->GetString(
          "linnet_english_interaction/tab_behavior", &chinese_tab_behavior) ||
      chinese_tab_behavior != "pass") {
    Fail("targeted reload lost a Chinese-schema document setting");
  }
  if (!api->get_option(chinese, "traditionalization")) {
    Fail("targeted reload lost the traditional-Chinese default");
  }
  ExpectFirstCandidate(api, chinese, "ceshi", "測試");
  ExpectCandidate(api, chinese, "|suanfa", "algorithm");
  ExpectCandidateAbsent(api, chinese, ";suanfa", "algorithm");
  api->destroy_session(chinese);

  const RimeSessionId english_session =
      CreateSchemaSession(api, "linnet_en");
  const auto live = rime::Service::instance().GetSession(english_session);
  if (!live || !live->schema() || !live->schema()->config()) {
    Fail("could not inspect targeted English settings");
  }
  auto* config = live->schema()->config();
  bool value = true;
  std::string tab_behavior;
  if (api->get_option(english_session, "prediction") ||
      !config->GetBool("linnet_english_interaction/spelling_correction",
                       &value) ||
      value ||
      !config->GetBool("linnet_english_interaction/show_ipa", &value) ||
      value ||
      !config->GetBool("linnet_english_interaction/show_translation", &value) ||
      value ||
      !config->GetBool("linnet_english_interaction/learning_enabled", &value) ||
      value ||
      !config->GetBool(
          "linnet_english_interaction/sentence_capitalization", &value) ||
      value ||
      !config->GetString("linnet_english_interaction/tab_behavior",
                         &tab_behavior) ||
      tab_behavior != "pass") {
    Fail("targeted reload lost an English document/runtime setting");
  }
  ExpectCandidate(api, english_session, "|suanfa", "algorithm");
  api->destroy_session(english_session);

  std::cout << "rime_smoke_test: exact-11 targeted config reload samples="
            << kSamples << " p95=" << p95 << "ms max=" << maximum
            << "ms: PASS\n";
}

}  // namespace

int main(int argc, char** argv) {
  const bool input_options_probe =
      argc == 4 && std::strcmp(argv[3], "--input-options-probe") == 0;
  const bool input_switches_probe =
      argc == 4 && std::strcmp(argv[3], "--input-switches-probe") == 0;
  const bool settings_off_probe =
      argc == 4 && std::strcmp(argv[3], "--settings-off-probe") == 0;
  const bool learning_off_probe =
      argc == 4 && std::strcmp(argv[3], "--learning-off-probe") == 0;
  const bool shift_probe =
      argc == 4 && std::strcmp(argv[3], "--shift-probe") == 0;
  const bool page_size_probe =
      argc == 5 && std::strcmp(argv[3], "--page-size-probe") == 0;
  const bool english_profile_probe =
      argc == 8 && std::strcmp(argv[3], "--english-profile-probe") == 0;
  const bool fast_config_reload_probe =
      argc == 4 && std::strcmp(argv[3], "--fast-config-reload-probe") == 0;
  const bool prediction_punctuation_probe =
      argc == 4 &&
      std::strcmp(argv[3], "--prediction-punctuation-probe") == 0;
  if (argc != 3 && !input_options_probe && !input_switches_probe &&
      !settings_off_probe && !learning_off_probe &&
      !shift_probe && !page_size_probe && !english_profile_probe &&
      !fast_config_reload_probe && !prediction_punctuation_probe) {
    Fail("usage: rime_smoke_test SHARED_DATA_DIR USER_DATA_DIR "
         "[--input-options-probe|--input-switches-probe|--settings-off-probe|--learning-off-probe|--shift-probe|"
         "--page-size-probe EXPECTED|"
         "--english-profile-probe PROFILE CHINESE_SCHEMA CODE PREFIX|"
         "--fast-config-reload-probe|--prediction-punctuation-probe]");
  }
  int expected_page_size = 0;
  if (page_size_probe) {
    char* end = nullptr;
    const long parsed = std::strtol(argv[4], &end, 10);
    if (!end || *end != '\0' || parsed < 1 || parsed > 100) {
      Fail("page-size probe expected value must be between 1 and 100");
    }
    expected_page_size = static_cast<int>(parsed);
  }

  auto* api = rime_get_api_stdbool();
  if (!api) {
    Fail("librime API unavailable");
  }
  const auto acceptance_cases = LoadAcceptanceCases();

  const std::string staging_dir = std::string(argv[2]) + "/build";
  RimeTraits traits = {};
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.staging_dir = staging_dir.c_str();
  traits.distribution_name = "Linnet Tests";
  traits.distribution_code_name = "linnet-tests";
  traits.distribution_version = "0.1.0";
  traits.app_name = "rime.linnet-tests";
  traits.min_log_level = 2;
  traits.log_dir = "";

  api->setup(&traits);
  api->initialize(nullptr);
  if (!api->find_module("smart_english")) {
    api->finalize();
    Fail("smart_english module was not loaded");
  }
  if (!api->find_module("octagram")) {
    api->finalize();
    Fail("octagram module was not loaded");
  }
  ExpectSchemaList(api);
  std::string expected_fresh_schema = "linnet_zh_pinyin";
  if (english_profile_probe) {
    expected_fresh_schema = argv[5];
  } else if (input_options_probe || input_switches_probe) {
    expected_fresh_schema = "linnet_zh_pinyin";
  } else if (settings_off_probe || learning_off_probe) {
    expected_fresh_schema = "linnet_zh_jiajia";
  }
  ExpectFreshDefaultSchema(api, expected_fresh_schema);

  if (fast_config_reload_probe) {
    // Production startup has already loaded the deployer module through its
    // one maintenance pass. Reproduce that precondition outside the timed
    // in-process reload boundary.
    if (api->start_maintenance(false)) {
      api->join_maintenance_thread();
    }
    ExpectFastConfigurationReload(api, argv[2]);
    api->finalize();
    return 0;
  }

  if (prediction_punctuation_probe) {
    ExpectPredictionPunctuationExitContract(api);
    api->finalize();
    std::cout << "rime_smoke_test: prediction punctuation exits: PASS\n";
    return 0;
  }

  if (input_options_probe) {
    const RimeSessionId chinese =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    if (!api->get_option(chinese, "traditionalization")) {
      Fail("the deployed graphical traditional-Chinese default remained disabled");
    }
    ExpectFirstCandidate(api, chinese, "ceshi", "測試");
    // Letter-only codes remain eligible for automatic Smart English lookup;
    // the punctuation-bearing Microsoft profile matrix above is the
    // authoritative retired-trigger negative.
    ExpectCandidate(api, chinese, "|suanfa", "algorithm");
    api->destroy_session(chinese);

    const RimeSessionId english = CreateSchemaSession(api, "linnet_en");
    ExpectCandidate(api, english, "|suanfa", "algorithm");
    const auto live_english = rime::Service::instance().GetSession(english);
    bool capitalization = true;
    std::string tab_behavior;
    if (!live_english || !live_english->schema() ||
        !live_english->schema()->config() ||
        !live_english->schema()->config()->GetBool(
            "linnet_english_interaction/sentence_capitalization",
            &capitalization) ||
        capitalization ||
        !live_english->schema()->config()->GetString(
            "linnet_english_interaction/tab_behavior", &tab_behavior) ||
        tab_behavior != "pass") {
      Fail("the production runtime-settings projection was not loaded");
    }
    api->destroy_session(english);

    for (const char* schema_id : {"linnet_en", "linnet_zh_pinyin"}) {
      const RimeSessionId disabled = CreateSchemaSession(api, schema_id);
      ExpectCandidateAbsent(api, disabled, "hell", "hello");
      api->destroy_session(disabled);
    }
    const RimeSessionId tab_pass = CreateSchemaSession(api, "linnet_en");
    Enter(api, tab_pass, "cluod");
    if (api->process_key(tab_pass, kTab, 0)) {
      Fail("the production pass-through Tab setting was ignored");
    }
    ExpectNoCommit(api, tab_pass, "production pass-through Tab");
    api->destroy_session(tab_pass);
    api->finalize();
    std::cout << "rime_smoke_test: graphical input and runtime settings: PASS\n";
    return 0;
  }

  if (input_switches_probe) {
    ExpectDeployedInputSwitches(api);
    api->finalize();
    std::cout << "rime_smoke_test: graphical Chinese switch behavior: PASS\n";
    return 0;
  }

  if (english_profile_probe) {
    ExpectEnglishPinyinProfile(api, argv[4], argv[5], argv[6], argv[7]);
    api->finalize();
    std::cout << "rime_smoke_test: Smart English " << argv[4]
              << " pinyin profile: PASS\n";
    return 0;
  }

  if (shift_probe) {
    ExpectCapsLockRawPath(api, "linnet_en");
    ExpectCapsLockRawPath(api, "linnet_zh");
    ExpectDirectShiftSmartEnglish(api);
    api->finalize();
    std::cout << "rime_smoke_test: direct Shift Chinese/Smart English and "
                 "Caps Lock raw ASCII: PASS\n";
    return 0;
  }

  if (page_size_probe) {
    // This must exercise a deployed schema in a fresh process. Rime's schema
    // component keeps only weak references to mutable ConfigData, so closing a
    // schema_open fixture before session creation reloads the on-disk value and
    // does not test the native Schema boundary.
    ExpectDeployedMenuPageSize(api, "linnet_en", expected_page_size);
    api->finalize();
    std::cout << "rime_smoke_test: deployed native menu page-size "
              << expected_page_size << ": PASS\n";
    return 0;
  }

  if (learning_off_probe) {
    const RimeSessionId learning_disabled =
        CreateSchemaSession(api, "linnet_en");
    ExpectEnglishLearningDisabled(api, learning_disabled);
    api->destroy_session(learning_disabled);
    api->finalize();
    std::cout << "rime_smoke_test: graphical English learning off: PASS\n";
    return 0;
  }

  if (settings_off_probe) {
    const RimeSessionId settings_off = CreateSchemaSession(api, "linnet_en");
    if (api->get_option(settings_off, "prediction")) {
      Fail("the deployed graphical prediction setting remained enabled");
    }
    ExpectFullSpanCandidateAbsent(api, settings_off, "cloudd", "cloud",
                                  "linnet_en");
    ExpectCommentEmpty(api, settings_off, "cloud", "cloud");
    SelectNormalizedCandidate(api, settings_off, "i", "I");
    ContinueAndSelectNormalizedCandidate(api, settings_off, "do", "do");
    ContinueAndSelectNormalizedCandidate(api, settings_off, "not", "not");
    ExpectMenuEmpty(api, settings_off, "deployed prediction setting");
    api->destroy_session(settings_off);

    const RimeSessionId short_spelling =
        CreateSchemaSession(api, "linnet_en");
    Enter(api, short_spelling, "teh");
    const auto short_candidates = Candidates(api, short_spelling);
    if (short_candidates.empty() || short_candidates.front().text != "teh") {
      Fail("standard short spelling did not preserve raw input first");
    }
    NormalizedCandidateIndex(api, short_spelling, "the");
    ExpectStandardTableOrigin(short_spelling, "the");
    api->destroy_session(short_spelling);

    const RimeSessionId uppercase_completion =
        CreateSchemaSession(api, "linnet_en");
    Enter(api, uppercase_completion, "CLOU");
    const auto uppercase_candidates = Candidates(api, uppercase_completion);
    if (uppercase_candidates.empty() ||
        uppercase_candidates.front().text != "CLOU") {
      Fail("standard uppercase completion did not preserve raw input first");
    }
    NormalizedCandidateIndex(api, uppercase_completion, "CLOUD");
    ExpectStandardTableOrigin(uppercase_completion, "CLOUD");
    api->destroy_session(uppercase_completion);

    for (const char* schema_id : {"linnet_zh", "linnet_zh_pinyin",
                                  "linnet_zh_flypy", "linnet_zh_mspy",
                                  "linnet_zh_sogou", "linnet_zh_abc",
                                  "linnet_zh_ziguang", "linnet_zh_jiajia"}) {
      const RimeSessionId chinese_settings_off =
          CreateSchemaSession(api, schema_id);
      ExpectEnglishTableReachable(api, chinese_settings_off, "cloud");
      ExpectCommentEmpty(api, chinese_settings_off, "cloud", "cloud");
      api->destroy_session(chinese_settings_off);
    }
    api->finalize();
    std::cout << "rime_smoke_test: graphical English settings off across English and Chinese: PASS\n";
    return 0;
  }

  ExpectPersistedSwitchDefaults(api);
  ExpectModeStatusLabels(api);
  const RimeSessionId english =
      CreateSchemaSession(api, "linnet_en");
  const RimeSessionId chinese =
      CreateSchemaSession(api, "linnet_zh");
  ExpectSharedPredictIdentity(english);
  ExpectCuratedPhonexRuntimeProjection(english);
  ExpectFullShapeOff(api, english, "linnet_en");
  ExpectFullShapeOff(api, chinese, "linnet_zh");
  ExpectDefaultChinesePunctuation(api, "linnet_zh");
  ExpectStandardChineseNumericPunctuation(api);
  ExpectIdleSpacePassThrough(api);
  ExpectDateShortcutProfileIsolation(api);
  ExpectPinyinReverseUsesActiveProfiles(api);
  ExpectPinyinReverseTraversalBounded(api);
  ExpectPinyinReverseKeyLimit(api);
  ExpectAutomaticPinyinTailProjection(api);
  ExpectDeployedMenuPageSize(api, "linnet_zh", 9);
  ExpectDeployedMenuPageSize(api, "linnet_en", 9);
  ExpectCapsLockRawPath(api, "linnet_en");
  ExpectCapsLockRawPath(api, "linnet_zh");
  ExpectDirectShiftSmartEnglish(api);
  ExpectSwitcherHotkeysPassThrough(api);
  ExpectModeSwitchClearsSmartEnglishState(api);
  ExpectNineCandidateSelectKeys(api, "linnet_zh_pinyin", "shi");
  ExpectNineCandidateSelectKeys(api, "linnet_en", "a");
  ExpectCandidateArrowNavigation(api);
  ExpectPassivePredictionExitContract(api);
  ExpectCapsLockDismissesPassivePrediction(api);
  ExpectPassivePredictionKeyboardSelection(api);
  ExpectPassivePredictionTabContracts(api);
  ExpectPredictionPunctuationExitContract(api);
  ExpectRawLikeArrowEditing(api);
  ExpectInvalidActiveSelectionKeysPassThrough(api);
  ExpectActivePunctuationBoundaries(api);
  ExpectHostModifierPassThrough(api);
  ExpectTrailingDeletePassThrough(api);
  ExpectPrintableAsciiMatrix(api);
  ExpectRetiredHiddenRawPrefixes(api);
  ExpectChineseTabPolicy(api);
  ExpectExpandedCandidateAbsoluteSelection(api);

  const RimeSessionId raw_punctuation =
      CreateSchemaSession(api, "linnet_en");
  api->clear_composition(raw_punctuation);
  if (api->process_key(raw_punctuation, '.', 0)) {
    Fail("linnet_en intercepted raw ASCII punctuation");
  }
  api->destroy_session(raw_punctuation);
  ExpectCandidate(api, english, "hello", "hello");
  ExpectCandidate(api, english, "Hello", "Hello");
  ExpectCandidate(api, english, "HE", "HE");
  // These candidates exist only in the pinned rime-ice complement. They use
  // the same compiled linnet_en dictionary and translator as Hallelujah.
  ExpectCandidate(api, english, "acknowledgments", "acknowledgments");
  ExpectCandidate(api, english, "dotnet", ".NET");
  ExpectCommentContains(api, english, "cloud", "cloud", "klaʊd", "云");
  ExpectCommentContains(api, english, "webhooks", "webhooks", "网络", "钩子");
  ExpectCommentContains(api, english, "API", "API", "应用", "接口");
  ExpectCommentContains(api, english, "April", "April", "四", "月");
  ExpectImmediateEnglishSpaceCommit(api);
  ExpectCommentContains(api, english, "Dejavu", "Déjà vu", "似曾", "相识");
  ExpectCommentContains(api, english, "jwt", "jwt", "JSON Web Token", "令牌");
  ExpectCommentIncludesExcludes(
      api, english, "serialization", "serialization", "序列化", "连载");
  ExpectCommentIncludesExcludes(
      api, english, "deserialization", "deserialization", "反序列化",
      "串并");
  ExpectCommentIncludesExcludes(api, english, "agent", "agent", "智能体",
                                "代理");
  ExpectCommentIncludesExcludes(api, english, "websocket", "websocket",
                                "WebSocket 协议", "网页套接字");
  ExpectCommentEmpty(api, english, "Kubernetes", "Kubernetes");
  ExpectAutomaticPinyinOrder(
      api, english, "yun", {"cloud", "confused", "dizzy", "giddy"});
  const RimeSessionId pinyin_reverse =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  ExpectPinyinEchoFallbackRemoved(api, pinyin_reverse, "cloud");
  ExpectForcedRawOverflowSafety(api);
  Enter(api, english, "deserilazation");
  const auto deserialization_correction = Candidates(api, english);
  if (deserialization_correction.size() < 2 ||
      deserialization_correction.front().text != "deserilazation" ||
      BaseText(deserialization_correction[1].text) != "deserialization" ||
      deserialization_correction[1].comment.find("反序列化") ==
          std::string::npos) {
    Fail("deserialization typo correction or translation is missing");
  }
  ExpectCandidateAbsent(api, english, "deser", "degree");
  ExpectCommentEmpty(api, english, "Surface", "Surface");
  ExpectCommentEmpty(api, english, "MicrosoftDefender", "Microsoft Defender");
  ExpectCommentEmpty(api, english, "FIFA", "Fédération Internationale de Football Association");

  SetSchemaBool(api, "linnet_en", "linnet_english_interaction/show_ipa", false);
  const RimeSessionId translation_only = CreateSchemaSession(api, "linnet_en");
  ExpectCommentIncludesExcludes(api, translation_only, "cloud", "cloud", "云", "klaʊd");
  api->destroy_session(translation_only);
  SetSchemaBool(api, "linnet_en", "linnet_english_interaction/show_ipa", true);
  SetSchemaBool(api, "linnet_en", "linnet_english_interaction/show_translation", false);
  const RimeSessionId ipa_only = CreateSchemaSession(api, "linnet_en");
  ExpectCommentIncludesExcludes(api, ipa_only, "cloud", "cloud", "klaʊd", "云");
  api->destroy_session(ipa_only);
  SetSchemaBool(api, "linnet_en", "linnet_english_interaction/show_ipa", false);
  const RimeSessionId metadata_hidden = CreateSchemaSession(api, "linnet_en");
  ExpectCommentEmpty(api, metadata_hidden, "cloud", "cloud");
  api->destroy_session(metadata_hidden);
  SetSchemaBool(api, "linnet_en", "linnet_english_interaction/show_ipa", true);
  SetSchemaBool(api, "linnet_en", "linnet_english_interaction/show_translation", true);

  SetSchemaBool(api, "linnet_en", "translator/enable_user_dict", false);
  SetSchemaBool(api, "linnet_en",
                "linnet_english_interaction/learning_enabled", false);
  const RimeSessionId learning_disabled =
      CreateSchemaSession(api, "linnet_en");
  ExpectEnglishLearningDisabled(api, learning_disabled);
  api->destroy_session(learning_disabled);
  SetSchemaBool(api, "linnet_en", "translator/enable_user_dict", true);
  SetSchemaBool(api, "linnet_en",
                "linnet_english_interaction/learning_enabled", true);

  // Sentence capitalization is disabled by default and only follows a
  // sentence terminator observed by this Rime session when explicitly on.
  const RimeSessionId capitalization_disabled =
      CreateSchemaSession(api, "linnet_en");
  if (api->process_key(capitalization_disabled, '.', 0)) {
    Fail("disabled capitalization swallowed period");
  }
  if (!api->simulate_key_sequence(capitalization_disabled, "cloud")) {
    Fail("could not type disabled capitalization probe");
  }
  NormalizedCandidateIndex(api, capitalization_disabled, "cloud");
  ExpectSessionPropertyAbsent(api, capitalization_disabled,
                              kSentenceBoundaryProperty,
                              "disabled sentence capitalization");
  api->destroy_session(capitalization_disabled);

  SetSchemaBool(api, "linnet_en",
                "linnet_english_interaction/sentence_capitalization", true);
  for (const auto& test_case :
       std::vector<std::pair<std::string, std::string>>{
           {"cloud", "Cloud"}, {"Cloud", "Cloud"}, {"CLOUD", "CLOUD"}}) {
    const RimeSessionId sentence_case =
        CreateSchemaSession(api, "linnet_en");
    if (api->process_key(sentence_case, '.', 0)) {
      Fail("sentence capitalization swallowed period");
    }
    ExpectSessionProperty(api, sentence_case, kSentenceBoundaryProperty, "1",
                          "observed sentence terminator");
    if (!api->simulate_key_sequence(sentence_case, test_case.first.c_str())) {
      Fail("could not type sentence capitalization case");
    }
    NormalizedCandidateIndex(api, sentence_case, test_case.second);
    api->destroy_session(sentence_case);
  }
  for (const char punctuation_value : {',', ':'}) {
    const RimeSessionId non_sentence =
        CreateSchemaSession(api, "linnet_en");
    if (api->process_key(non_sentence, '.', 0) ||
        api->process_key(non_sentence, punctuation_value, 0)) {
      Fail("non-sentence punctuation was swallowed");
    }
    ExpectSessionPropertyAbsent(api, non_sentence,
                                kSentenceBoundaryProperty,
                                "non-sentence punctuation");
    if (!api->simulate_key_sequence(non_sentence, "cloud")) {
      Fail("could not type punctuation boundary probe");
    }
    NormalizedCandidateIndex(api, non_sentence, "cloud");
    api->destroy_session(non_sentence);
  }
  for (const int edit_key : {kBackSpace, 0xff51, 0xff53}) {
    const RimeSessionId edit_boundary =
        CreateSchemaSession(api, "linnet_en");
    if (api->process_key(edit_boundary, '.', 0)) {
      Fail("edit boundary setup swallowed period");
    }
    api->process_key(edit_boundary, edit_key, 0);
    ExpectSessionPropertyAbsent(api, edit_boundary,
                                kSentenceBoundaryProperty,
                                "cursor/edit boundary");
    if (!api->simulate_key_sequence(edit_boundary, "cloud")) {
      Fail("could not type edit boundary probe");
    }
    NormalizedCandidateIndex(api, edit_boundary, "cloud");
    api->destroy_session(edit_boundary);
  }
  const RimeSessionId shortcut_boundary =
      CreateSchemaSession(api, "linnet_en");
  if (api->process_key(shortcut_boundary, '.', 0)) {
    Fail("shortcut boundary setup swallowed period");
  }
  api->process_key(shortcut_boundary, 'v', 1 << 2);
  ExpectSessionPropertyAbsent(api, shortcut_boundary,
                              kSentenceBoundaryProperty,
                              "host shortcut boundary");
  api->destroy_session(shortcut_boundary);
  for (const std::string& hard_input : {"URLSession", "x;br"}) {
    const RimeSessionId hard_boundary =
        CreateSchemaSession(api, "linnet_en");
    if (api->process_key(hard_boundary, '.', 0) ||
        !api->simulate_key_sequence(hard_boundary, hard_input.c_str())) {
      Fail("could not prepare code/Text Expander boundary");
    }
    if (hard_input == "x;br") {
      const size_t index = CandidateIndex(api, hard_boundary, "Best regards,");
      if (!api->select_candidate(hard_boundary, index)) {
        Fail("could not commit Text Expander boundary");
      }
    } else if (!api->process_key(hard_boundary, kReturn, 0)) {
      Fail("could not commit code-token boundary");
    }
    TakeCommit(api, hard_boundary);
    ExpectSessionPropertyAbsent(api, hard_boundary,
                                kSentenceBoundaryProperty,
                                "code/Text Expander boundary");
    if (!api->simulate_key_sequence(hard_boundary, "cloud")) {
      Fail("could not type after hard boundary");
    }
    NormalizedCandidateIndex(api, hard_boundary, "cloud");
    api->destroy_session(hard_boundary);
  }
  SetSchemaBool(api, "linnet_en",
                "linnet_english_interaction/sentence_capitalization", false);

  // The native processor owns Tab policy before the inherited key binder.
  SetSchemaString(api, "linnet_en",
                  "linnet_english_interaction/tab_behavior", "pass");
  const RimeSessionId tab_pass = CreateSchemaSession(api, "linnet_en");
  if (api->process_key(tab_pass, kTab, 0)) {
    Fail("pass-through Tab was consumed without composition");
  }
  Enter(api, tab_pass, "cluod");
  if (api->process_key(tab_pass, kTab, 0)) {
    Fail("pass-through Tab was consumed with composition");
  }
  if (api->process_key(tab_pass, kTab, kShiftMask)) {
    Fail("pass-through Shift+Tab was consumed with composition");
  }
  ExpectNoCommit(api, tab_pass, "pass-through Tab");
  api->destroy_session(tab_pass);

  SetSchemaString(api, "linnet_en",
                  "linnet_english_interaction/tab_behavior", "navigate");
  const RimeSessionId tab_navigate = CreateSchemaSession(api, "linnet_en");
  Enter(api, tab_navigate, "cluod");
  if (HighlightedCandidateIndex(api, tab_navigate) != 0 ||
      !api->process_key(tab_navigate, kTab, 0) ||
      HighlightedCandidateIndex(api, tab_navigate) != 1) {
    Fail("navigation Tab did not move to the next ranked candidate");
  }
  if (!api->process_key(tab_navigate, kTab, kShiftMask) ||
      HighlightedCandidateIndex(api, tab_navigate) != 0) {
    Fail("navigation Shift+Tab did not return to the previous ranked candidate");
  }
  ExpectNoCommit(api, tab_navigate, "navigation Tab");
  api->destroy_session(tab_navigate);

  SetSchemaString(api, "linnet_en",
                  "linnet_english_interaction/tab_behavior",
                  "smart_complete");
  for (const auto& test_case :
       std::vector<std::pair<std::string, std::string>>{
           {"cloud", "cloud"}, {"cluod", "cloud"}, {"nqdt", "nest"}}) {
    const RimeSessionId tab_complete =
        CreateSchemaSession(api, "linnet_en");
    Enter(api, tab_complete, test_case.first);
    const auto before_tab = CandidateOrigins(tab_complete);
    if (test_case.first == "nqdt" &&
        std::none_of(before_tab.begin(), before_tab.end(),
                     [](const auto& candidate) {
                       return candidate.text == "nest" &&
                              candidate.genuine_type == "linnet_correction";
                     })) {
      Fail("phonetic Tab fixture lost its typed correction candidate");
    }
    if (!api->process_key(tab_complete, kTab, 0)) {
      Fail("smart-complete Tab rejected " + test_case.first);
    }
    const std::string actual = BaseText(TakeCommit(api, tab_complete));
    if (actual != test_case.second) {
      std::cerr << "Candidates before smart-complete Tab:";
      for (const auto& candidate : before_tab) {
        std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                  << candidate.genuine_type << "]";
      }
      std::cerr << '\n';
      Fail("smart-complete Tab chose the wrong candidate for " +
           test_case.first + ": " + actual);
    }
    ExpectSessionProperty(api, tab_complete, kPredictContextProperty,
                          test_case.second, "smart-complete commit");
    api->destroy_session(tab_complete);
  }
  SetSchemaBool(api, "linnet_en",
                "linnet_english_interaction/spelling_correction", false);
  const RimeSessionId tab_pinyin_phrase =
      CreateSchemaSession(api, "linnet_en");
  Enter(api, tab_pinyin_phrase, "yunjisuan");
  const auto pinyin_before_tab = CandidateOrigins(tab_pinyin_phrase, 256);
  const auto pinyin_target = std::find_if(
      pinyin_before_tab.begin(), pinyin_before_tab.end(),
      [](const auto& candidate) {
        return BaseText(candidate.text) == "cloud computing" &&
               candidate.genuine_type == "linnet_pinyin";
      });
  if (pinyin_target == pinyin_before_tab.end() ||
      std::distance(pinyin_before_tab.begin(), pinyin_target) != 1) {
    Fail("isolated pinyin smart-complete fixture lost its first ranked smart candidate");
  }
  const bool pinyin_tab_handled =
      api->process_key(tab_pinyin_phrase, kTab, 0);
  const std::string pinyin_tab_commit =
      BaseText(TakeCommit(api, tab_pinyin_phrase));
  if (!pinyin_tab_handled || pinyin_tab_commit != "cloud computing") {
    const size_t target_index = static_cast<size_t>(
        std::distance(pinyin_before_tab.begin(), pinyin_target));
    std::cerr << "Candidates before pinyin smart-complete Tab:";
    for (const auto& candidate : pinyin_before_tab) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << "]";
    }
    std::cerr << "\nTab handled=" << pinyin_tab_handled << ", commit='"
              << pinyin_tab_commit << "'\n";
    Fail("smart-complete Tab skipped the automatic multi-word pinyin result " +
         std::to_string(target_index) + "/" +
         std::to_string(pinyin_before_tab.size()));
  }
  ExpectSessionPropertyAbsent(api, tab_pinyin_phrase,
                              kPredictContextProperty,
                              "multi-word pinyin smart-complete");
  api->destroy_session(tab_pinyin_phrase);
  SetSchemaBool(api, "linnet_en",
                "linnet_english_interaction/spelling_correction", true);
  const RimeSessionId tab_table_phrase =
      CreateSchemaSession(api, "linnet_en");
  Enter(api, tab_table_phrase, "earlyaccess");
  if (!api->process_key(tab_table_phrase, kTab, 0) ||
      BaseText(TakeCommit(api, tab_table_phrase)) != "early access") {
    Fail("smart-complete Tab skipped the standard multi-word table result");
  }
  ExpectSessionPropertyAbsent(api, tab_table_phrase,
                              kPredictContextProperty,
                              "multi-word table smart-complete");
  api->destroy_session(tab_table_phrase);
  const RimeSessionId tab_prediction =
      CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, tab_prediction, "i", "I");
  ContinueAndSelectNormalizedCandidate(api, tab_prediction, "do", "do");
  ContinueAndSelectNormalizedCandidate(api, tab_prediction, "not", "not");
  ExpectPredictionMenu(api, tab_prediction, "smart-complete prediction");
  if (!api->process_key(tab_prediction, kTab, 0) ||
      BaseText(TakeCommit(api, tab_prediction)) != "know") {
    Fail("smart-complete Tab did not commit the ranked prediction");
  }
  ExpectSessionProperty(api, tab_prediction, kPredictContextProperty,
                        "i do not know", "Tab prediction commit");
  api->destroy_session(tab_prediction);

  for (const std::string& rejected_input :
       {"URLSession", "x;br", "bdbdbdbd"}) {
    const RimeSessionId tab_rejected =
        CreateSchemaSession(api, "linnet_en");
    Enter(api, tab_rejected, rejected_input);
    const auto before_tab = CandidateOrigins(tab_rejected);
    if (api->process_key(tab_rejected, kTab, 0)) {
      for (const auto& candidate : before_tab) {
        std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                  << candidate.genuine_type << "]";
      }
      std::cerr << '\n';
      Fail("smart-complete Tab consumed non-Smart input " + rejected_input);
    }
    ExpectNoCommit(api, tab_rejected, "rejected smart-complete Tab");
    api->destroy_session(tab_rejected);
  }

  ExpectChineseTabPolicy(api);

  for (const auto& kind : {"correction_insertion", "correction_deletion",
                           "correction_substitution",
                           "correction_transposition"}) {
    const auto& test_case = acceptance_cases.at(kind);
    Enter(api, english, test_case.query);
    const auto candidates = Candidates(api, english);
    if (candidates.empty() || candidates.front().text != test_case.query) {
      Fail(std::string("correction did not preserve raw input first: ") + kind);
    }
    NormalizedCandidateIndex(api, english, test_case.expected);
  }
  Enter(api, english, "teh");
  const auto whole_word_correction = Candidates(api, english);
  if (whole_word_correction.empty() ||
      whole_word_correction.front().text != "teh") {
    Fail("whole-word correction did not preserve raw input first");
  }
  NormalizedCandidateIndex(api, english, "the");
  ExpectStandardTableOrigin(english, "the");
  if (SelectNormalizedCandidate(api, english, "hello", "hello") != "hello") {
    Fail("ordinary English candidate commit changed");
  }
  ContinueInput(api, english, "world");
  CandidateIndex(api, english, " world");

  const RimeSessionId pinyin_phrase_spacing =
      CreateSchemaSession(api, "linnet_en");
  std::string pinyin_phrase_text =
      SelectNormalizedCandidate(api, pinyin_phrase_spacing, "use", "use");
  pinyin_phrase_text += ContinueAndSelectNormalizedCandidate(
      api, pinyin_phrase_spacing, "yunjisuan", "cloud computing");
  ExpectSessionPropertyAbsent(api, pinyin_phrase_spacing,
                              kPredictContextProperty,
                              "multi-word pinyin phrase boundary");
  ExpectSessionPropertyAbsent(api, pinyin_phrase_spacing,
                              kPredictStaticKeyProperty,
                              "multi-word pinyin phrase boundary");
  ExpectSessionPropertyAbsent(api, pinyin_phrase_spacing, kBigramProperty,
                              "multi-word pinyin phrase boundary");
  pinyin_phrase_text += ContinueAndSelectNormalizedCandidate(
      api, pinyin_phrase_spacing, "platform", "platform");
  if (pinyin_phrase_text != "use cloud computing platform") {
    Fail("automatic multi-word pinyin result broke English spacing: " +
         pinyin_phrase_text);
  }
  ExpectSessionProperty(api, pinyin_phrase_spacing, kPredictContextProperty,
                        "platform", "post-pinyin phrase commit");
  api->destroy_session(pinyin_phrase_spacing);

  const RimeSessionId pinyin_phrase_case =
      CreateSchemaSession(api, "linnet_en");
  if (SelectNormalizedCandidate(api, pinyin_phrase_case, "Yunjisuan",
                                "Cloud computing") != "Cloud computing") {
    Fail("automatic multi-word pinyin result lost requested case");
  }
  api->destroy_session(pinyin_phrase_case);

  const RimeSessionId pinyin_phrase_uppercase =
      CreateSchemaSession(api, "linnet_en");
  if (SelectNormalizedCandidate(api, pinyin_phrase_uppercase, "YUNJISUAN",
                                "CLOUD COMPUTING") != "CLOUD COMPUTING") {
    Fail("automatic multi-word pinyin result lost uppercase projection");
  }
  api->destroy_session(pinyin_phrase_uppercase);

  const RimeSessionId table_phrase_spacing =
      CreateSchemaSession(api, "linnet_en");
  std::string table_phrase_text =
      SelectNormalizedCandidate(api, table_phrase_spacing, "use", "use");
  table_phrase_text += ContinueAndSelectNormalizedCandidate(
      api, table_phrase_spacing, "earlyaccess", "early access");
  ExpectSessionPropertyAbsent(api, table_phrase_spacing,
                              kPredictContextProperty,
                              "multi-word table phrase boundary");
  table_phrase_text += ContinueAndSelectNormalizedCandidate(
      api, table_phrase_spacing, "platform", "platform");
  if (table_phrase_text != "use early access platform") {
    Fail("standard multi-word table result broke English spacing: " +
         table_phrase_text);
  }
  api->destroy_session(table_phrase_spacing);

  const RimeSessionId explicit_pinyin_phrase =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  if (SelectNormalizedCandidate(api, explicit_pinyin_phrase, ";yunjisuan",
                                "cloud computing") != "cloud computing") {
    Fail("explicit Chinese pinyin reverse lookup changed its phrase commit");
  }
  ExpectSessionPropertyAbsent(api, explicit_pinyin_phrase,
                              kPredictContextProperty,
                              "explicit Chinese pinyin reverse lookup");
  api->destroy_session(explicit_pinyin_phrase);

  const RimeSessionId isolated_session =
      CreateSchemaSession(api, "linnet_en");
  ExpectCandidate(api, isolated_session, "world", "world");
  Enter(api, isolated_session, "CLOU");
  const auto corrected_upper = Candidates(api, isolated_session);
  if (corrected_upper.empty() || corrected_upper.front().text != "CLOU") {
    Fail("uppercase correction did not keep raw input first");
  }
  NormalizedCandidateIndex(api, isolated_session, "CLOUD");
  ExpectStandardTableOrigin(isolated_session, "CLOUD");

  Enter(api, chinese, "nihk");
  const size_t nihao_index = CandidateIndex(api, chinese, "你好");
  if (!api->select_candidate(chinese, nihao_index)) {
    Fail("could not select Chinese candidate");
  }
  ExpectCommit(api, chinese, "你好");
  ExpectFirstCandidate(api, chinese, "nihkaa", "你好啊");
  ExpectCandidateAbsent(api, chinese, "nihkaa", "nihkaa");
  ExpectCandidate(api, chinese, "hello", "hello");
  // 跨 (kuà, 自然码 double-pinyin code "kw") is in the locked Wanxiang
  // jichu table and proves the direct import reached the compiled dictionary.
  ExpectCandidate(api, chinese, "kw", "跨");
  // The radical dictionary's own prism removes dictionary delimiters, so both
  // a single component and a concatenated multi-component code must route
  // through the one uU command without borrowing the active pinyin profile.
  ExpectCandidate(api, chinese, "uUheng", "一");
  ExpectFirstCandidate(api, chinese, "uUrener", "你");
  ExpectCandidate(api, chinese, "U4e2d", "中");
  ExpectCandidate(api, chinese, "cC1+1", "2");
  ExpectCandidate(api, chinese, "V1", "一");
  ExpectCandidateAbsent(api, chinese, "v1", "一");
  // An exact, independently meaningful English word must win over a weak
  // accidental Chinese decoding.  Strong Chinese readings are exercised with
  // each profile's own code below; full-pinyin spellings are not valid oracles
  // for this default double-pinyin session.
  constexpr std::array<const char*, 9> kChineseModeExactEnglishWords = {
      "apple",     "banana", "computer", "hello", "interface",
      "cloud",     "algorithm", "email", "github",
  };
  for (const char* word : kChineseModeExactEnglishWords) {
    ExpectExactEnglishFirst(api, chinese, "linnet_zh", word);
  }
  ExpectEnglishTableReachable(api, chinese, "Cloud");
  ExpectEnglishTableReachable(api, chinese, "CLOUD");
  // Explicit case is direct English intent even when the lowercase spelling
  // is a reviewed pinyin ambiguity.
  ExpectEnglishTableReachable(api, chinese, "MAMA");
  ExpectCommentContains(api, chinese, "cloud", "cloud", "klaʊd", "云");
  ExpectCommentContains(api, chinese, "banana", "banana", "bəˈnænə",
                        "香蕉");
  ExpectCandidateAbsent(api, chinese, "clou", "cloud");
  ExpectCandidateAbsent(api, chinese, "cluod", "cloud");

  const std::array<std::pair<const char*, const char*>, 7> profiles = {{
      {"linnet_zh_pinyin", "nihao"},
      {"linnet_zh_flypy", "nihc"},
      {"linnet_zh_mspy", "nihk"},
      {"linnet_zh_sogou", "nihk"},
      {"linnet_zh_abc", "nihk"},
      {"linnet_zh_ziguang", "nihq"},
      {"linnet_zh_jiajia", "nihd"},
  }};
  for (const auto& profile : profiles) {
    const RimeSessionId profile_session =
        CreateSchemaSession(api, profile.first);
    ExpectCandidate(api, profile_session, profile.second, "你好");
    for (const char* word : kChineseModeExactEnglishWords) {
      ExpectExactEnglishFirst(api, profile_session, profile.first, word);
    }
    ExpectEnglishTableReachable(api, profile_session, "Cloud");
    ExpectEnglishTableReachable(api, profile_session, "CLOUD");
    ExpectEnglishTableReachable(api, profile_session, "MAMA");
    api->destroy_session(profile_session);
  }
  // Each row is anchored in chinese_profile_golden.tsv: when this profile
  // exposes its reviewed same-span Chinese reading, that reading must remain
  // first and the standard English table candidate must stay reachable.
  struct ProfileAmbiguityCase {
    const char* schema_id;
    const char* input;
    const char* expected_chinese;
  };
  constexpr std::array<ProfileAmbiguityCase, 15> kProfileAmbiguities{{
           {"linnet_zh", "bung", "不能"},
           {"linnet_zh", "xxxx", "谢谢"},
           {"linnet_zh_pinyin", "beijing", "北京"},
           {"linnet_zh_flypy", "tsui", "同事"},
           {"linnet_zh_flypy", "tcbc", "淘宝"},
           {"linnet_zh_mspy", "xxxx", "谢谢"},
           {"linnet_zh_mspy", "lily", "利率"},
           {"linnet_zh_sogou", "xxxx", "谢谢"},
           {"linnet_zh_sogou", "kyle", "快乐"},
           {"linnet_zh_abc", "gssi", "公司"},
           {"linnet_zh_abc", "tsai", "通知"},
           {"linnet_zh_ziguang", "fago", "发过"},
           {"linnet_zh_ziguang", "heyn", "合约"},
           {"linnet_zh_jiajia", "lodi", "落地"},
           {"linnet_zh_jiajia", "pugs", "铺盖"},
       }};
  for (const auto& profile : kProfileAmbiguities) {
    const RimeSessionId profile_session =
        CreateSchemaSession(api, profile.schema_id);
    ExpectAmbiguousEnglishPreservesChinese(
        api, profile_session, profile.input, profile.expected_chinese);
    api->destroy_session(profile_session);
  }
  // A partially confirmed composition has its own remaining Segment. Bilingual
  // intent must be classified from that segment, not from the full historical
  // input that still contains the confirmed prefix.
  ExpectPartialSelectionRanksCurrentSegment(api);
  // Learning changes an ordinary dictionary phrase into Rime's user_phrase
  // candidate type. That transition must not change bilingual intent: the
  // same static Chinese lexical evidence remains authoritative, while the
  // English candidate stays reachable.
  for (const auto& profile : kProfileAmbiguities) {
    const RimeSessionId learning_session =
        CreateSchemaSession(api, profile.schema_id);
    if (SelectNormalizedCandidate(api, learning_session, profile.input,
                                  profile.expected_chinese) !=
        profile.expected_chinese) {
      Fail("could not learn the Chinese collision candidate for input '" +
           std::string(profile.input) + "'");
    }
    api->destroy_session(learning_session);

    const RimeSessionId learned_session =
        CreateSchemaSession(api, profile.schema_id);
    const auto learned = ExpectAmbiguousEnglishPreservesChinese(
        api, learned_session, profile.input, profile.expected_chinese);
    if (learned.genuine_type != "user_phrase") {
      Fail("Chinese collision did not exercise the learned user_phrase state for input '" +
           std::string(profile.input) + "'");
    }
    api->destroy_session(learned_session);
  }
  // A learned low-frequency accidental Chinese decoding still must not block
  // an independently meaningful exact English word.
  const RimeSessionId weak_learning_session =
      CreateSchemaSession(api, "linnet_zh");
  if (SelectNormalizedCandidate(api, weak_learning_session, "banana",
                                "芭娜娜") != "芭娜娜") {
    Fail("could not learn the weak Chinese collision fixture");
  }
  api->destroy_session(weak_learning_session);
  const RimeSessionId learned_weak_session =
      CreateSchemaSession(api, "linnet_zh");
  ExpectExactEnglishFirst(api, learned_weak_session, "linnet_zh", "banana");
  const auto learned_weak_origins = CandidateOrigins(learned_weak_session);
  if (std::none_of(learned_weak_origins.begin(), learned_weak_origins.end(),
                   [](const auto& candidate) {
                     return candidate.genuine_type == "user_phrase" &&
                            BaseText(candidate.text) == "芭娜娜";
                   })) {
    Fail("weak Chinese collision did not exercise the learned user_phrase state");
  }
  api->destroy_session(learned_weak_session);
  // Lowercase single letters are incomplete Chinese input, not independently
  // meaningful English words. Whenever the active profile can produce a
  // same-span Chinese candidate, keep that candidate first without deleting
  // the English candidate from the menu.
  for (size_t schema_index = 0;
       schema_index + 1 < kProductSchemaIDs.size(); ++schema_index) {
    const char* schema_id = kProductSchemaIDs[schema_index];
    const RimeSessionId profile_session = CreateSchemaSession(api, schema_id);
    size_t covered_letters = 0;
    for (char letter = 'a'; letter <= 'z'; ++letter) {
      covered_letters += ExpectSingleLetterChinesePriority(
          api, profile_session, schema_id, letter);
    }
    if (covered_letters == 0) {
      Fail("single-letter priority matrix found no Chinese candidates in " +
           std::string(schema_id));
    }
    for (const char* explicit_english : {"A", "L", "I"}) {
      ExpectExactEnglishFirst(api, profile_session, schema_id,
                              explicit_english);
    }
    api->destroy_session(profile_session);
  }
  // The full-pinyin profile has no same-span Chinese candidate for inglis, so
  // its standard English table candidate must be first in this session.
  const RimeSessionId global_union_without_chinese =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  ExpectGlobalAmbiguousEnglishFirstWithoutChinese(
      api, global_union_without_chinese, "inglis");
  api->destroy_session(global_union_without_chinese);
  const RimeSessionId full_pinyin_rank =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  ExpectFirstCandidate(api, full_pinyin_rank, "a", "啊");
  ExpectFirstCandidate(api, full_pinyin_rank, "l", "了");
  ExpectFirstCandidate(api, full_pinyin_rank, "mama", "妈妈");
  ExpectFirstCandidate(api, full_pinyin_rank, "he", "和");
  ExpectFirstCandidate(api, full_pinyin_rank, "shi", "是");
  ExpectFirstCandidate(api, full_pinyin_rank, "you", "有");
  ExpectFirstCandidate(api, full_pinyin_rank, "women", "我们");
  ExpectFirstCandidate(api, full_pinyin_rank, "beijing", "北京");
  // Established three-syllable Chinese phrases must not be displaced merely
  // because their full spelling is also an exact English dictionary word.
  ExpectAmbiguousEnglishPreservesChinese(api, full_pinyin_rank, "renminbi",
                                         "人民币");
  ExpectAmbiguousEnglishPreservesChinese(api, full_pinyin_rank, "tiananmen",
                                         "天安门");
  api->destroy_session(full_pinyin_rank);
  const RimeSessionId chinese_exact_commit =
      CreateSchemaSession(api, "linnet_zh");
  if (SelectNormalizedCandidate(api, chinese_exact_commit, "cloud", "cloud") !=
      "cloud") {
    Fail("Chinese exact-English commit changed the selected word");
  }
  ExpectSessionProperty(api, chinese_exact_commit, kPredictContextProperty,
                        "cloud", "Chinese exact-English commit");
  ContinueInput(api, chinese_exact_commit, "banana");
  CandidateIndex(api, chinese_exact_commit, " banana");
  api->destroy_session(chinese_exact_commit);
  const RimeSessionId association =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  ExpectCandidate(api, association, "shijiemaoyi", "世界贸易组织");
  ExpectFirstCandidate(api, association, "shijiemaoyizuzhi", "世界贸易组织");
  api->destroy_session(association);

  for (const RimeSessionId schema_session : {english, chinese}) {
    ExpectNormalizedCandidate(api, schema_session, "customword",
                              "Linnet Custom");
    ExpectCandidateAbsent(api, schema_session, "blockedcustom",
                          "BlockedCustom");
    ExpectFirstCandidate(api, schema_session, "x;br", "Best regards,");
    ExpectFirstCandidate(api, schema_session, "x;unknown", "x;unknown");
  }

  const RimeSessionId custom_phrase_spacing =
      CreateSchemaSession(api, "linnet_en");
  std::string custom_phrase_text = SelectNormalizedCandidate(
      api, custom_phrase_spacing, "hello", "hello");
  custom_phrase_text += ContinueAndSelectNormalizedCandidate(
      api, custom_phrase_spacing, "customword", "Linnet Custom");
  custom_phrase_text += ContinueAndSelectNormalizedCandidate(
      api, custom_phrase_spacing, "world", "world");
  if (custom_phrase_text != "hello Linnet Custom world") {
    Fail("custom multi-word candidate broke English spacing: " +
         custom_phrase_text);
  }
  api->destroy_session(custom_phrase_spacing);

  const RimeSessionId apostrophe_custom =
      CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, apostrophe_custom, "hello", "hello");
  ContinueInput(api, apostrophe_custom, "don't");
  const auto apostrophe_origins = CandidateOrigins(apostrophe_custom);
  if (apostrophe_origins.empty() ||
      apostrophe_origins.front().text != " don't" ||
      apostrophe_origins.front().genuine_type != "user_table" ||
      std::any_of(apostrophe_origins.begin(), apostrophe_origins.end(),
                  [](const auto& candidate) {
                    return candidate.type == "raw" ||
                           candidate.genuine_type == "raw" ||
                           candidate.type == kForcedRawCandidateType ||
                           candidate.genuine_type == kForcedRawCandidateType;
                  })) {
    Fail("custom apostrophe word retained an echo raw candidate");
  }
  api->destroy_session(apostrophe_custom);

  for (const char* schema_id : {"linnet_en", "linnet_zh"}) {
    SetSchemaString(api, schema_id,
                    "linnet_disabled_filter/words/@0", "hello");
    const RimeSessionId static_disabled =
        CreateSchemaSession(api, schema_id);
    ExpectCandidateAbsent(api, static_disabled, "hell", "hello");
    api->destroy_session(static_disabled);
    SetSchemaString(api, schema_id,
                    "linnet_disabled_filter/words/@0", "forbiddenword");
  }

  // Printable multi-word pinyin results use the same canonical disabled-word
  // projection as ordinary English candidates.
  for (const char* schema_id : {"linnet_en", "linnet_zh"}) {
    SetSchemaString(api, schema_id,
                    "linnet_disabled_filter/words/@0", "surname Pa");
    const RimeSessionId pinyin_disabled =
        CreateSchemaSession(api, schema_id);
    ExpectCandidateAbsent(api, pinyin_disabled, ";pa", "surname Pa");
    api->destroy_session(pinyin_disabled);
    SetSchemaString(api, schema_id,
                    "linnet_disabled_filter/words/@0", "forbiddenword");
  }

  SetSchemaString(api, "linnet_en",
                  "linnet_disabled_filter/words/@0", "hello");
  const RimeSessionId learned_disabled =
      CreateSchemaSession(api, "linnet_en");
  ExpectCandidateAbsent(api, learned_disabled, "hell", "hello");
  api->destroy_session(learned_disabled);
  SetSchemaString(api, "linnet_en",
                  "linnet_disabled_filter/words/@0", "forbiddenword");

  // Static prediction uses the longest validated multi-word context.
  const RimeSessionId prediction = CreateSchemaSession(api, "linnet_en");
  std::string prediction_text;
  prediction_text += SelectNormalizedCandidate(api, prediction, "i", "I");
  prediction_text += ContinueAndSelectNormalizedCandidate(
      api, prediction, "do", "do");
  prediction_text += ContinueAndSelectNormalizedCandidate(
      api, prediction, "not", "not");
  ExpectPredictionMenu(api, prediction, "i do not");
  const auto& static_case = acceptance_cases.at("prediction_static");
  if (static_case.query != "i do not") {
    Fail("static prediction fixture no longer matches the exercised context");
  }
  const auto prediction_candidates = Candidates(api, prediction);
  if (prediction_candidates.empty() ||
      BaseText(prediction_candidates.front().text) != static_case.expected) {
    Fail("longest-context static prediction order changed");
  }
  prediction_text +=
      SelectCurrentNormalizedCandidate(api, prediction, static_case.expected);
  if (prediction_text != "I do not know") {
    Fail("static prediction spacing changed: " + prediction_text);
  }

  // A learned pair absent from static data still creates a prediction menu,
  // while the same context in another session remains empty.
  const RimeSessionId learned_only = CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, learned_only, "aachen", "aachen");
  ContinueAndSelectNormalizedCandidate(api, learned_only, "cloud", "cloud");
  api->process_key(learned_only, kReturn, 0);
  SelectNormalizedCandidate(api, learned_only, "aachen", "aachen");
  ExpectPredictionMenu(api, learned_only, "learned-only all-miss context");
  NormalizedCandidateIndex(api, learned_only, "cloud");

  const RimeSessionId learned_isolated =
      CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, learned_isolated, "aachen", "aachen");
  ExpectMenuEmpty(api, learned_isolated, "isolated all-miss context");

  // Contraction suffixes commit tight and remain separate context tokens.
  const RimeSessionId contraction = CreateSchemaSession(api, "linnet_en");
  std::string contraction_text =
      SelectNormalizedCandidate(api, contraction, "he", "he");
  ExpectPredictionMenu(api, contraction, "he");
  contraction_text +=
      SelectCurrentNormalizedCandidate(api, contraction, "'s");
  ExpectPredictionMenu(api, contraction, "he 's");
  const auto& contraction_case = acceptance_cases.at("contraction");
  if (contraction_case.query != "he 's") {
    Fail("contraction fixture no longer matches the exercised context");
  }
  contraction_text +=
      SelectCurrentNormalizedCandidate(api, contraction,
                                       contraction_case.expected);
  if (contraction_text != "he's not") {
    Fail("contraction spacing changed: " + contraction_text);
  }

  // Raw punctuation dismisses a highlighted prediction and updates the one
  // spacing state without committing the selected prediction.
  const RimeSessionId punctuation = CreateSchemaSession(api, "linnet_en");
  std::string sentence =
      SelectNormalizedCandidate(api, punctuation, "Hello", "Hello");
  if (api->process_key(punctuation, ',', 0)) {
    Fail("comma was swallowed while dismissing prediction");
  }
  ExpectMenuEmpty(api, punctuation, "comma dismissal");
  sentence += ',';
  sentence += ContinueAndSelectNormalizedCandidate(
      api, punctuation, "world", "world");
  if (api->process_key(punctuation, '.', 0)) {
    Fail("period was swallowed while dismissing prediction");
  }
  sentence += '.';
  if (sentence != "Hello, world.") {
    Fail("punctuation spacing changed: " + sentence);
  }

  const RimeSessionId comma_dismissal =
      CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, comma_dismissal, "he", "he");
  ExpectPredictionMenu(api, comma_dismissal, "comma setup");
  if (api->process_key(comma_dismissal, ',', 0)) {
    Fail("comma was swallowed while dismissing highlighted prediction");
  }
  ExpectMenuEmpty(api, comma_dismissal, "highlighted comma dismissal");

  const RimeSessionId brackets = CreateSchemaSession(api, "linnet_en");
  std::string bracket_text =
      SelectNormalizedCandidate(api, brackets, "foo", "foo");
  if (api->process_key(brackets, '(', 0)) {
    Fail("opening bracket was swallowed");
  }
  bracket_text += '(';
  const std::string bar_commit =
      ContinueAndSelectNormalizedCandidate(api, brackets, "bar", "bar");
  if (!bar_commit.empty() && bar_commit.front() == ' ') {
    Fail("opening bracket did not make the next word tight");
  }
  bracket_text += bar_commit;
  if (api->process_key(brackets, ')', 0)) {
    Fail("closing bracket was swallowed");
  }
  bracket_text += ')';
  const std::string after_bracket =
      ContinueAndSelectNormalizedCandidate(api, brackets, "cloud", "cloud");
  if (after_bracket.empty() || after_bracket.front() != ' ') {
    Fail("closing bracket did not space the next word");
  }
  bracket_text += after_bracket;
  if (bracket_text != "foo(bar) cloud") {
    Fail("bracket spacing changed: " + bracket_text);
  }

  const RimeSessionId quotes = CreateSchemaSession(api, "linnet_en");
  if (api->process_key(quotes, '"', 0)) {
    Fail("opening quote was swallowed");
  }
  std::string quote_text = "\"";
  const std::string quoted_word =
      ContinueAndSelectNormalizedCandidate(api, quotes, "hello", "hello");
  if (!quoted_word.empty() && quoted_word.front() == ' ') {
    Fail("opening quote did not make the quoted word tight");
  }
  quote_text += quoted_word;
  if (api->process_key(quotes, '"', 0)) {
    Fail("closing quote was swallowed");
  }
  quote_text += '"';
  const std::string after_quote =
      ContinueAndSelectNormalizedCandidate(api, quotes, "world", "world");
  if (after_quote.empty() || after_quote.front() != ' ') {
    Fail("closing quote did not space the next word");
  }
  quote_text += after_quote;
  if (quote_text != "\"hello\" world") {
    Fail("quote spacing changed: " + quote_text);
  }

  // Dismissal keys have intentionally different acceptance semantics.
  const RimeSessionId backspace = CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, backspace, "he", "he");
  ExpectPredictionMenu(api, backspace, "Backspace setup");
  if (api->process_key(backspace, kBackSpace, 0)) {
    Fail("Backspace did not reach the application from prediction");
  }
  ExpectMenuEmpty(api, backspace, "Backspace dismissal");

  const RimeSessionId return_dismissal =
      CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, return_dismissal, "he", "he");
  ExpectPredictionMenu(api, return_dismissal, "Return setup");
  if (api->process_key(return_dismissal, kReturn, 0)) {
    Fail("Return did not reach the application from prediction");
  }
  ExpectMenuEmpty(api, return_dismissal, "Return dismissal");

  const RimeSessionId escape = CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, escape, "he", "he");
  ExpectPredictionMenu(api, escape, "Escape setup");
  ExpectSessionProperty(api, escape, kPredictContextProperty, "he",
                        "Escape setup");
  ExpectSessionProperty(api, escape, kPredictStaticKeyProperty, "n/he",
                        "Escape setup");
  if (!api->process_key(escape, kEscape, 0)) {
    Fail("Escape did not consume prediction cancellation");
  }
  ExpectPassivePredictionExit(api, escape, "Escape dismissal");

  // Plain Return commits the current candidate without arming a leading space
  // for the next word. Modified Return belongs to the host application.
  {
    const RimeSessionId candidate_return =
        CreateSchemaSession(api, "linnet_en");
    Enter(api, candidate_return, "cluod");
    const size_t correction =
        NormalizedCandidateIndex(api, candidate_return, "cloud");
    if (!api->highlight_candidate(candidate_return, correction) ||
        !api->process_key(candidate_return, kReturn, 0) ||
        TakeCommit(api, candidate_return) != "cloud") {
      Fail("plain Return did not commit the selected candidate");
    }
    Enter(api, candidate_return, "world");
    const auto after_return = Candidates(api, candidate_return);
    const bool unspaced_world = std::any_of(
        after_return.begin(), after_return.end(), [](const auto& candidate) {
          return candidate.text == "world";
        });
    if (!unspaced_world) {
      Fail("plain Return armed an unwanted following space");
    }
    api->destroy_session(candidate_return);
  }
  for (const int modifiers :
       std::array<int, 2>{{1 << 2, (1 << 2) | (1 << 0)}}) {
    const RimeSessionId raw_return =
        CreateSchemaSession(api, "linnet_en");
    Enter(api, raw_return, "hellx");
    const auto before = ReadKeyInteractionSnapshot(api, raw_return);
    if (api->process_key(raw_return, kReturn, modifiers)) {
      Fail("modified Return was swallowed instead of reaching the host");
    }
    if (!TakeOptionalCommit(api, raw_return).empty() ||
        !(ReadKeyInteractionSnapshot(api, raw_return) == before)) {
      Fail("modified Return changed active composition while passing through");
    }
    api->destroy_session(raw_return);
  }

  // Return over a confirmed segment plus an unconfirmed raw tail commits the
  // literal composition and must not retain or learn the confirmed word as a
  // prediction context. This exercises the partial-confirmed replay path.
  const RimeSessionId partial_return =
      CreateSchemaSession(api, "linnet_zh");
  Enter(api, partial_return, "hello'");
  api->set_caret_pos(partial_return, 5);
  const size_t partial_hello =
      NormalizedCandidateIndex(api, partial_return, "hello");
  if (!api->select_candidate(partial_return, partial_hello)) {
    Fail("could not confirm the leading segment for raw Return");
  }
  api->set_caret_pos(partial_return, 6);
  if (!api->simulate_key_sequence(partial_return, "qzxqzxq")) {
    Fail("could not append the unconfirmed raw Return tail");
  }
  // Candidate visibility is owned by the active Chinese translator stack.
  // The editor contract is the literal Return commit and cleared English
  // context below, independent of which pinyin candidate is currently shown.
  if (!api->process_key(partial_return, kReturn, 0)) {
    Fail("partial-confirmed raw Return was not accepted");
  }
  if (TakeCommit(api, partial_return) != "hello'qzxqzxq") {
    Fail("partial-confirmed raw Return changed literal composition");
  }
  ExpectSessionPropertyAbsent(api, partial_return, kPredictContextProperty,
                              "partial-confirmed raw Return");
  ExpectSessionPropertyAbsent(api, partial_return, kPredictStaticKeyProperty,
                              "partial-confirmed raw Return");

  const RimeSessionId partial_return_audit =
      CreateSchemaSession(api, "linnet_en");
  SelectNormalizedCandidate(api, partial_return_audit, "hello", "hello");
  ExpectCurrentCandidateAbsent(api, partial_return_audit, "qzxqzxq");

  // The default Full Pinyin profile decodes its own spellings before the
  // canonical pinyin index. Chinese keeps an explicit prefix so this lookup
  // can never steal the ordinary Chinese composition.
  ExpectAutomaticPinyinOrder(
      api, english, "ceshi", {"test", "beta", "exam", "quiz"});
  ExpectAutomaticPinyinOrder(api, english, "zhinengti", {"agent"});
  ExpectAutomaticPinyinOrder(api, english, "xiecheng", {"coroutine"});
  ExpectNormalizedOrder(api, pinyin_reverse, ";yun",
                        {"cloud", "confused", "dizzy", "giddy"});
  for (const auto& product_case :
       std::vector<std::pair<std::string, std::string>>{
           {"zong", "total"}, {"cheng", "ride"},
           {"zu", "enough"},  {"su", "speed"},
           {"qin", "relative"}, {"sihou", "time"},
           {"zhinengti", "agent"}, {"xiecheng", "coroutine"},
           {"bingfa", "concurrency"}, {"xiaoxi", "message"},
           {"chengxu", "program"}, {"duotai", "polymorphism"},
           {"yunjisuan", "cloud computing"},
           {"kaiyuan", "open source"},
           {"damoxing", "large language model"},
           {"duilie", "queue"}, {"shuzihua", "digitalization"},
           {"daishu", "algebra"}, {"juzhen", "matrix"},
           {"tongji", "statistics"}, {"jisuanji", "computer"},
           {"jiemi", "decrypt"}, {"xunihua", "virtualization"},
           {"jiqiren", "robot"}, {"jihe", "set"},
           {"daoshu", "derivative"}, {"xiangliang", "vector"},
           {"wangluo", "network"}, {"xieyi", "protocol"},
           {"jiekou", "interface"}, {"duixiang", "object"},
           {"jicheng", "inherit"}, {"biancheng", "programming"},
           {"bu", "no"}, {"shuo", "say"}, {"he", "and"},
           {"ni", "you"}, {"de", "of"}, {"chu", "out"},
           {"fa", "send"}}) {
    ExpectFirstNormalizedCandidate(api, pinyin_reverse,
                                   ";" + product_case.first,
                                   product_case.second);
  }
  ExpectCandidateAbsent(api, pinyin_reverse, ";zhinengti", "a gent");
  for (const auto& retained_sense :
       std::vector<std::pair<std::string, std::string>>{
           {"bu", "not"}, {"shuo", "speak"}, {"he", "with"},
           {"chu", "exit"}, {"chu", "leave"}, {"fa", "fine"}}) {
    ExpectNormalizedCandidate(
        api, pinyin_reverse, ";" + retained_sense.first,
        retained_sense.second);
  }
  for (const auto& rejected_candidate :
       std::vector<std::pair<std::string, std::string>>{
           {"aisang", "gonest"}, {"aisang", "lovedest"},
           {"aisang", "lovingest"}}) {
    ExpectCandidateAbsent(api, english, rejected_candidate.first,
                          rejected_candidate.second);
    ExpectCandidateAbsent(api, pinyin_reverse,
                          ";" + rejected_candidate.first,
                          rejected_candidate.second);
  }
  api->destroy_session(pinyin_reverse);
  // Complete professional coverage has a dedicated lower weight band than
  // L3, including when tone-less input merges different tone-coded groups.
  // Exercise this through the product's full-pinyin profile; the base
  // ``linnet_zh`` profile has a different prism and is not an oracle for
  // concatenated full-pinyin segmentation.
  const RimeSessionId complete_pinyin =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  ExpectNormalizedBefore(api, complete_pinyin, "anqi", "暗棋", "安琦");
  ExpectNormalizedBefore(api, complete_pinyin, "baishan", "白山", "白珊");
  // Reviewed product policy: correctly spelled general words rank ahead of
  // typo hints and generic place/name projections for these audited inputs.
  ExpectNormalizedBefore(api, complete_pinyin, "chengzhi", "橙汁", "称职");
  ExpectNormalizedBefore(api, complete_pinyin, "chengzhi", "诚挚", "称职");
  ExpectNormalizedBefore(api, complete_pinyin, "huarong", "华融", "华荣");
  ExpectNormalizedBefore(api, complete_pinyin, "huarong", "华融", "华容");
  ExpectNormalizedBefore(api, complete_pinyin, "jiangyan", "讲演", "江堰");
  ExpectNormalizedBefore(api, complete_pinyin, "jiangyan", "讲演", "姜堰");
  ExpectNormalizedBefore(api, complete_pinyin, "lindong", "凛冬", "林东");
  ExpectNormalizedBefore(api, complete_pinyin, "linzhuang", "鳞状", "林庄");
  ExpectNormalizedCandidate(
      api, complete_pinyin, "lishuangdaishu", "李双代数");
  api->destroy_session(complete_pinyin);
  const std::vector<std::pair<std::string, std::string>> code_tokens = {
      {"https://api.example.com", "https://api.example.com"},
      {"www.example.com", "www.example.com"},
      {"mailto:hello@example.com", "mailto:hello@example.com"},
      {"file:/tmp/linnet", "file:/tmp/linnet"},
      {"camelCase", "camelCase"},
      {"iPhone", "iPhone"},
      {"PascalCase", "PascalCase"},
      {"URLSession", "URLSession"},
      {"CFNetwork", "CFNetwork"},
      {"OAuthToken", "OAuthToken"},
      {"EMA20", "EMA20"},
      {"v1.16.0", "v1.16.0"},
      {"CVE-2026-1234", "CVE-2026-1234"},
      {"README.md", "README.md"},
  };
  // Both language schemas share one explicit/unambiguous raw classifier.
  // Ordinary lowercase word+separator input remains a punctuation boundary so
  // Chinese pinyin and Smart English never have to wait for a future key.
  for (const auto& token : code_tokens) {
    ExpectFirstCandidate(api, english, token.first, token.second);
  }
  for (const char* schema : {"linnet_en", "linnet_zh"}) {
    for (const char* token : {"https://api.example.com",
                              "mailto:hello@example.com",
                              "file:/tmp/linnet", "README.md",
                              "URLSession"}) {
      const RimeSessionId raw_session = CreateSchemaSession(api, schema);
      Enter(api, raw_session, token);
      ExpectCompositionTag(raw_session, "zz_code_token",
                           std::string(schema) + " explicit raw " + token);
      ExpectNoCommit(api, raw_session,
                     std::string(schema) + " explicit raw " + token);
      api->destroy_session(raw_session);
    }
  }
  {
    const RimeSessionId zh_code_token =
        CreateSchemaSession(api, "linnet_zh");
    for (const auto& token : code_tokens) {
      ExpectFirstCandidate(api, zh_code_token, token.first, token.second);
    }
    Enter(api, zh_code_token, "huang");
    const auto pinyin_candidates = Candidates(api, zh_code_token);
    if (pinyin_candidates.empty() ||
        !api->process_key(zh_code_token, '1', 0) ||
        TakeCommit(api, zh_code_token) != pinyin_candidates.front().text) {
      Fail("the shared code classifier swallowed Chinese digit selection");
    }
    api->destroy_session(zh_code_token);
  }

  // These prefixes are commands only in the Chinese schema. The English
  // schema must not inherit duplicate exclusions from that sibling.
  for (const std::string& token : {"uUser", "U2", "cCalculator", "V2"}) {
    ExpectFirstCandidate(api, english, token, token);
  }
  api->destroy_session(isolated_session);
  api->destroy_session(prediction);
  api->destroy_session(learned_only);
  api->destroy_session(learned_isolated);
  api->destroy_session(contraction);
  api->destroy_session(punctuation);
  api->destroy_session(comma_dismissal);
  api->destroy_session(brackets);
  api->destroy_session(quotes);
  api->destroy_session(backspace);
  api->destroy_session(return_dismissal);
  api->destroy_session(partial_return);
  api->destroy_session(partial_return_audit);
  api->destroy_session(chinese);
  api->destroy_session(english);

  BenchmarkSchema(api, "linnet_en", "cloud");
  BenchmarkSchema(api, "linnet_zh", "nihk");

  const RimeSessionId fresh_wa = CreateSchemaSession(api, "linnet_en");
  Enter(api, fresh_wa, "wa");
  const auto fresh_wa_candidates = Candidates(api, fresh_wa);
  const size_t fresh_wa_was =
      OptionalNormalizedCandidateIndex(fresh_wa_candidates, "was");
  if (fresh_wa_was == fresh_wa_candidates.size()) {
    Fail("fresh wa candidates do not expose was within the bounded menu");
  }

  Enter(api, escape, "wa");
  ExpectSessionPropertyAbsent(api, escape, kPredictContextProperty,
                              "typed prefix after Escape");
  ExpectSessionPropertyAbsent(api, escape, kPredictStaticKeyProperty,
                              "typed prefix after Escape");
  const auto escaped_wa_candidates = Candidates(api, escape);
  const size_t escaped_wa_was =
      OptionalNormalizedCandidateIndex(escaped_wa_candidates, "was");
  if (escaped_wa_was == escaped_wa_candidates.size()) {
    Fail("wa candidates after Escape lost the ordinary candidate was");
  }
  if (escaped_wa_was != fresh_wa_was) {
    Fail("Escape retained prediction ranking instead of restoring a fresh word");
  }
  std::cout << "rime_smoke_test: Escape hard reset fresh_wa_was="
            << fresh_wa_was
            << " escaped_wa_was=" << escaped_wa_was << '\n';
  api->destroy_session(fresh_wa);
  api->destroy_session(escape);

  api->finalize();
  return 0;
}
