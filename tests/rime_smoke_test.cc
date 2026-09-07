#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <set>
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
#include <rime/dict/user_dictionary.h>
#include <rime/dict/level_db.h>
#include <rime/deployer.h>
#include <rime/gear/translator_commons.h>
#include <rime/key_table.h>
#include <rime/language.h>
#include <rime/menu.h>
#include <rime/predict/predict_engine.h>
#include <rime/registry.h>
#include <rime/schema.h>
#include <rime/segmentation.h>
#include <rime/service.h>
#include <rime/ticket.h>

#include "../plugins/smart_english/smart_english_index.h"

namespace {

using Nanoseconds = std::chrono::nanoseconds;
using LatencySample = Nanoseconds::rep;

// Keep enough observations for a stable p99 (about 82 tail samples) without
// making every CI run pay for benchmark-scale repetition. Correctness cases
// are exercised separately below; this loop owns only the latency contract.
constexpr size_t kLatencyWarmupSamples = 1024;
constexpr size_t kLatencySamples = 8192;
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
constexpr char kCandidateExpansionRequestProperty[] =
    "linnet/candidate_expansion_request_v1";
constexpr char kForcedRawCandidateType[] = "linnet_forced_raw";
constexpr char kDefaultPinyinReversePrefix[] = "|";
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
struct ShiftKeyCase {
  int keycode;
  const char* name;
};
constexpr std::array<ShiftKeyCase, 2> kShiftKeyCases = {{
    {XK_Shift_L, "Shift_L"},
    {XK_Shift_R, "Shift_R"},
}};

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
  double phrase_system_lexical_weight;
  int phrase_spelling_type;
  std::string preedit;
  std::string sentence_components;
  size_t sentence_uppercase_entity_count;
  bool sentence_components_follow_mixed_contract;
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

bool ContainsAscii(const std::string& text) {
  return std::any_of(text.begin(), text.end(),
                     [](unsigned char byte) { return byte < 0x80; });
}

bool IsUppercaseEntityText(const std::string& text) {
  return text.size() >= 2 && text.size() <= 6 &&
         std::all_of(text.begin(), text.end(), [](unsigned char byte) {
           return byte >= 'A' && byte <= 'Z';
         });
}

std::vector<std::string> RuntimeProductSchemaIDs(RimeApi_stdbool* api) {
  RimeSchemaList list = {};
  if (!api->get_schema_list(&list)) {
    Fail("could not read the deployed product schema list");
  }
  std::vector<std::string> result;
  result.reserve(list.size);
  for (size_t index = 0; index < list.size; ++index) {
    if (!list.list[index].schema_id) {
      api->free_schema_list(&list);
      Fail("the deployed product schema list contains an empty identity");
    }
    result.emplace_back(list.list[index].schema_id);
  }
  api->free_schema_list(&list);
  return result;
}

std::vector<std::string> RuntimeChineseSchemaIDs(RimeApi_stdbool* api) {
  std::vector<std::string> result;
  for (const auto& schema_id : RuntimeProductSchemaIDs(api)) {
    if (schema_id == "linnet_en") continue;
    if (schema_id.rfind("linnet_zh", 0) != 0) {
      Fail("the deployed Chinese profile set contains an undeclared identity: " +
           schema_id);
    }
    result.push_back(schema_id);
  }
  if (result.size() != 8) {
    Fail("the deployed product no longer exposes exactly eight Chinese profiles");
  }
  return result;
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
    std::ostringstream sentence_components;
    size_t sentence_uppercase_entity_count = 0;
    bool sentence_components_follow_mixed_contract = true;
    if (const auto sentence = rime::As<rime::Sentence>(genuine)) {
      for (const auto& component : sentence->components()) {
        if (sentence_components.tellp() > 0) sentence_components << '|';
        sentence_components << component.text;
        if (!ContainsAscii(component.text)) continue;
        if (IsUppercaseEntityText(component.text)) {
          ++sentence_uppercase_entity_count;
        } else {
          sentence_components_follow_mixed_contract = false;
        }
      }
    }
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
                      phrase && phrase->system_lexical_weight()
                          ? *phrase->system_lexical_weight()
                          : 0.0,
                      phrase ? static_cast<int>(phrase->spelling_type()) : -1,
                      candidate ? candidate->preedit() : "",
                      sentence_components.str(),
                      sentence_uppercase_entity_count,
                      sentence_components_follow_mixed_contract});
  }
  return values;
}

std::string BaseText(const std::string& value) {
  return !value.empty() && value.front() == ' ' ? value.substr(1) : value;
}

bool IsFullSpanUnprojectedMixed(const CandidateOriginView& candidate,
                                size_t input_size) {
  return candidate.genuine_language == "linnet_zh" &&
         candidate.type != "linnet_mixed" && candidate.start == 0 &&
         candidate.end == input_size && ContainsAscii(BaseText(candidate.text));
}

void ExpectNoFullSpanUnprojectedMixed(
    const std::vector<CandidateOriginView>& candidates,
    size_t input_size,
    const std::string& reason) {
  const auto invalid = std::find_if(
      candidates.begin(), candidates.end(), [&](const auto& candidate) {
        return IsFullSpanUnprojectedMixed(candidate, input_size);
      });
  if (invalid == candidates.end()) return;
  Fail(reason + "; full-span ASCII-bearing Chinese candidate '" +
       BaseText(invalid->text) + "' retained outer type " + invalid->type);
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

void AppendShiftedUppercase(RimeApi_stdbool* api,
                            RimeSessionId session,
                            const std::string& uppercase) {
  api->process_key(session, XK_Shift_L, kShiftMask);
  for (const unsigned char byte : uppercase) {
    if (byte < 'A' || byte > 'Z' ||
        !api->process_key(session, byte, kShiftMask)) {
      Fail("could not append physical Shift uppercase input: " + uppercase);
    }
  }
  api->process_key(session, XK_Shift_L, kReleaseMask);
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
    const auto live = rime::Service::instance().GetSession(session);
    if (live && live->context()) {
      std::cerr << "Composition for '" << input << "': "
                << live->context()->composition().GetDebugText() << '\n';
    }
    std::cerr << "Candidate origins for '" << input << "':";
    std::size_t shown = 0;
    for (const auto& candidate : CandidateOrigins(session)) {
      if (shown++ == 20) break;
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << ":q=" << candidate.quality
                << ":weight=" << candidate.phrase_system_lexical_weight << "]";
    }
    std::cerr << '\n';
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
    std::cerr << "Origins for displaced Chinese overlap '" << input << "':";
    for (const auto& candidate : candidates) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << ":q=" << candidate.quality
                << ":exact=" << candidate.phrase_exact
                << ":code=" << candidate.phrase_code_size
                << ":system_lexical="
                << candidate.phrase_system_lexical_weight
                << ":spelling=" << candidate.phrase_spelling_type
                << ":preedit=" << candidate.preedit << "]";
    }
    std::cerr << '\n';
    Fail("ambiguous English displaced the same-span Chinese candidate for input '" +
         input + "'");
  }
  return *chinese;
}

RimeSessionId CreateSchemaSession(RimeApi_stdbool* api,
                                  const char* schema_id);

void ExpectSpellingDerivedEnglishPreservesChinese(RimeApi_stdbool* api) {
  struct Case {
    const char* schema_id;
    const char* input;
    const char* english;
    bool chinese_collision;
  };
  // CandidateOrigins(64) confirmed these complete rows against the frozen
  // profile set. The three aer rows without a Chinese reading deliberately
  // assert only that the derived English table candidate stays reachable.
  constexpr std::array<Case, 24> kCases{{
      {"linnet_zh_pinyin", "teh", "the", true},
      {"linnet_zh_pinyin", "aer", "are", true},
      {"linnet_zh_pinyin", "oen", "one", true},
      {"linnet_zh", "teh", "the", true},
      {"linnet_zh", "aer", "are", true},
      {"linnet_zh", "oen", "one", true},
      {"linnet_zh_flypy", "teh", "the", true},
      {"linnet_zh_flypy", "aer", "are", true},
      {"linnet_zh_flypy", "oen", "one", true},
      {"linnet_zh_mspy", "teh", "the", true},
      {"linnet_zh_mspy", "aer", "are", false},
      {"linnet_zh_mspy", "oen", "one", true},
      {"linnet_zh_sogou", "teh", "the", true},
      {"linnet_zh_sogou", "aer", "are", false},
      {"linnet_zh_sogou", "oen", "one", true},
      {"linnet_zh_abc", "teh", "the", true},
      {"linnet_zh_abc", "aer", "are", true},
      {"linnet_zh_abc", "oen", "one", true},
      {"linnet_zh_ziguang", "teh", "the", true},
      {"linnet_zh_ziguang", "aer", "are", true},
      {"linnet_zh_ziguang", "oen", "one", true},
      {"linnet_zh_jiajia", "teh", "the", true},
      {"linnet_zh_jiajia", "aer", "are", false},
      {"linnet_zh_jiajia", "oen", "one", true},
  }};
  for (const auto& test : kCases) {
    const RimeSessionId session = CreateSchemaSession(api, test.schema_id);
    Enter(api, session, test.input);
    const auto candidates = CandidateOrigins(session);
    const auto english = std::find_if(
        candidates.begin(), candidates.end(), [&](const auto& candidate) {
          return candidate.genuine_type == "table" &&
                 candidate.genuine_language == "linnet_en" &&
                 BaseText(candidate.text) == test.english &&
                 candidate.start == 0 &&
                 candidate.end == std::strlen(test.input);
        });
    const auto chinese = std::find_if(
        candidates.begin(), candidates.end(), [&](const auto& candidate) {
          return candidate.genuine_language == "linnet_zh" &&
                 candidate.start == 0 &&
                 candidate.end == std::strlen(test.input);
        });
    if (english == candidates.end() ||
        (test.chinese_collision &&
         (chinese == candidates.end() || chinese != candidates.begin() ||
          english == candidates.begin()))) {
      std::cerr << "Origins for spelling-derived English '" << test.input
                << "' in " << test.schema_id << ":";
      for (const auto& candidate : candidates) {
        std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                  << candidate.genuine_type << ":" << candidate.genuine_language
                  << ":" << candidate.start << "-" << candidate.end << "]";
      }
      std::cerr << '\n';
      api->destroy_session(session);
      Fail("spelling-derived English regression changed table reachability or Chinese priority");
    }
    api->destroy_session(session);
  }
  for (const auto& schema_id : RuntimeChineseSchemaIDs(api)) {
    const RimeSessionId session = CreateSchemaSession(api, schema_id.c_str());
    for (const char* exact : {"the", "agent"}) {
      ExpectExactEnglishFirst(api, session, schema_id, exact);
    }
    api->destroy_session(session);
  }
}

void ExpectSmartEnglishSpellingDerivedCandidate(RimeApi_stdbool* api) {
  const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
  Enter(api, session, "teh");
  const auto candidates = CandidateOrigins(session);
  const auto english = std::find_if(
      candidates.begin(), candidates.end(), [](const auto& candidate) {
        return candidate.genuine_type == "table" &&
               candidate.genuine_language == "linnet_en" &&
               BaseText(candidate.text) == "the";
      });
  const bool raw_first = !candidates.empty() &&
      BaseText(candidates.front().text) == "teh" &&
      (candidates.front().type == kForcedRawCandidateType ||
       candidates.front().genuine_type == kForcedRawCandidateType);
  if (!raw_first || english == candidates.end()) {
    std::cerr << "Origins for Smart English spelling-derived input teh:";
    for (const auto& candidate : candidates) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << ":" << candidate.genuine_language
                << "]";
    }
    std::cerr << '\n';
    api->destroy_session(session);
    Fail("Smart English lost raw-first spelling-derived input or table reachability");
  }
  api->destroy_session(session);
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
  const auto english = std::find_if(
      candidates.begin(), candidates.end(), [&](const auto& candidate) {
        std::string text = BaseText(candidate.text);
        std::transform(text.begin(), text.end(), text.begin(),
                       [](unsigned char byte) {
                         return byte >= 'A' && byte <= 'Z' ? byte + 32 : byte;
                       });
        const bool english_origin =
            candidate.genuine_language == "linnet_en" ||
            candidate.type == "raw" || candidate.genuine_type == "raw" ||
            candidate.type == kForcedRawCandidateType ||
            candidate.genuine_type == kForcedRawCandidateType;
        return english_origin && text == input &&
               candidate.start == 0 && candidate.end == input.size();
      });
  if (english == candidates.end()) {
    Fail("single-letter English candidate became unreachable for input '" +
         input + "' in " + schema_id);
  }
  if (chinese == candidates.end()) {
    if (english == candidates.begin()) return false;
    Fail("single-letter English was not first when no same-span Chinese "
         "candidate exists for input '" + input + "' in " + schema_id);
  }
  if (chinese == candidates.begin()) {
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

RimeSessionId CreateSchemaSession(RimeApi_stdbool* api,
                                  const char* schema_id);
std::string TakeCommit(RimeApi_stdbool* api,
                       RimeSessionId session,
                       const std::string& reason = {},
                       unsigned source_line = __builtin_LINE());
void ExpectNoCommit(RimeApi_stdbool* api,
                    RimeSessionId session,
                    const std::string& reason);
std::map<std::string, std::string> LoadFormalProfileReviewedInputs();
std::string PagingInputForProfile(RimeApi_stdbool* api,
                                  const std::string& schema_id,
                                  const std::string& reviewed);
void ExpectNineCandidateSelectKeys(RimeApi_stdbool* api,
                                   const char* schema_id,
                                   const std::string& input);

void ExpectNaturalSingleKeyDefaultRanking(RimeApi_stdbool* api) {
  const RimeSessionId session = CreateSchemaSession(api, "linnet_zh");
  api->set_option(session, "emoji", false);
  Enter(api, session, "a");
  const auto candidates = CandidateOrigins(session);
  if (candidates.empty() || BaseText(candidates.front().text) != "啊" ||
      candidates.front().genuine_language != "linnet_zh") {
    std::cerr << "Natural-code candidates for single key 'a':";
    for (const auto& candidate : candidates) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << ":"
                << candidate.genuine_language << ":q="
                << candidate.quality << ":preedit=" << candidate.preedit
                << "]";
    }
    std::cerr << '\n';
    Fail("natural-code single key 'a' did not rank 啊 first");
  }
  const bool retained_english = std::any_of(
      candidates.begin(), candidates.end(), [](const auto& candidate) {
        return BaseText(candidate.text) == "a" &&
               candidate.genuine_language == "linnet_en";
      });
  if (!retained_english) {
    Fail("natural-code single key 'a' lost its explicit English candidate");
  }
  api->destroy_session(session);

  const RimeSessionId full_code = CreateSchemaSession(api, "linnet_zh");
  api->set_option(full_code, "emoji", false);
  Enter(api, full_code, "aa");
  const auto full_code_candidates = CandidateOrigins(full_code);
  if (full_code_candidates.empty() ||
      BaseText(full_code_candidates.front().text) != "啊") {
    Fail("natural-code full code 'aa' no longer ranks 啊 first");
  }
  api->destroy_session(full_code);
}

void ExpectSingleSyllablePreferenceLearning(RimeApi_stdbool* api) {
  constexpr char kSchema[] = "linnet_zh";
  constexpr char kInput[] = "a";
  const RimeSessionId learning = CreateSchemaSession(api, kSchema);
  api->set_option(learning, "emoji", false);
  Enter(api, learning, kInput);
  const auto before = CandidateOrigins(learning);
  if (before.empty()) {
    Fail("single-syllable learning fixture has no Chinese candidates");
  }
  const auto chosen = std::find_if(
      std::next(before.begin()), before.end(), [](const auto& candidate) {
        return candidate.genuine_language == "linnet_zh" &&
               candidate.start == 0 && candidate.end == 1 &&
               !BaseText(candidate.text).empty();
      });
  if (chosen == before.end()) {
    Fail("single-syllable learning fixture has no non-first Chinese choice");
  }
  const std::string expected = BaseText(chosen->text);
  if (!api->select_candidate(
          learning, static_cast<size_t>(std::distance(before.begin(), chosen))) ||
      BaseText(TakeCommit(api, learning)) != expected) {
    Fail("single-syllable learning fixture could not select " + expected);
  }
  api->destroy_session(learning);

  const RimeSessionId learned = CreateSchemaSession(api, kSchema);
  api->set_option(learned, "emoji", false);
  Enter(api, learned, kInput);
  const auto after = CandidateOrigins(learned);
  if (after.empty() || BaseText(after.front().text) != expected ||
      after.front().genuine_type != "user_phrase") {
    Fail("single-syllable Chinese preference was not first after learning " +
         expected);
  }
  api->destroy_session(learned);
}

void ExpectNativeMixedInput(RimeApi_stdbool* api) {
  struct MixedCase {
    const char* input;
    const char* expected;
  };
  constexpr std::array<MixedCase, 3> kCases{{
      {"xuexiCSjiting", "学习CS急停"},
      {"liaojieAIjishu", "了解AI技术"},
      {"shiyongCPUxingneng", "使用CPU性能"},
  }};

  bool verified_mixed_learning_round_trip = false;

  const auto expect_mixed = [&](const std::string& schema_id,
                                const std::string& input,
                                const std::string& expected,
                                const std::string& reason,
                                bool verify_digit_commit) {
    const RimeSessionId session = CreateSchemaSession(api, schema_id.c_str());
    Enter(api, session, input);
    const auto candidates = CandidateOrigins(session);
    ExpectNoFullSpanUnprojectedMixed(candidates, input.size(), reason);
    const auto mixed = std::find_if(
        candidates.begin(), candidates.end(), [&](const auto& candidate) {
          return BaseText(candidate.text) == expected &&
                 candidate.type == "linnet_mixed" &&
                 candidate.genuine_language == "linnet_zh" &&
                 candidate.start == 0 && candidate.end == input.size() &&
                 (candidate.genuine_type == "sentence" ||
                  candidate.genuine_type == "user_phrase");
        });
    const auto same_span_chinese = std::find_if(
        candidates.begin(), candidates.end(), [&](const auto& candidate) {
          return candidate.genuine_language == "linnet_zh" &&
                 candidate.type != "linnet_mixed" &&
                 !ContainsAscii(BaseText(candidate.text)) &&
                 candidate.start == 0 && candidate.end == input.size();
        });
    const bool valid_position =
        mixed != candidates.end() &&
        static_cast<size_t>(std::distance(candidates.begin(), mixed)) < 9;
    const bool valid_collision =
        same_span_chinese == candidates.end()
            ? mixed == candidates.begin()
            : same_span_chinese < mixed;
    if (!valid_position || !valid_collision) {
      const char* retained = api->get_input(session);
      std::ostringstream observed;
      observed << " input=" << (retained ? retained : "") << " candidates=";
      for (size_t index = 0; index < (std::min)(candidates.size(), size_t{8});
           ++index) {
        observed << " [" << BaseText(candidates[index].text) << ":"
                 << candidates[index].type << ":"
                 << candidates[index].genuine_type << ":components="
                 << candidates[index].sentence_components << "]";
      }
      api->destroy_session(session);
      Fail(reason + observed.str());
    }
    if (verify_digit_commit) {
      if (mixed->genuine_type == "sentence" &&
          (mixed->sentence_uppercase_entity_count != 1 ||
           !mixed->sentence_components_follow_mixed_contract)) {
        api->destroy_session(session);
        Fail(reason + "; system mixed sentence did not contain exactly one "
             "pure-uppercase 2-6 byte entity component: " +
             mixed->sentence_components);
      }
      const bool verify_learning = !verified_mixed_learning_round_trip;
      if (verify_learning && mixed->genuine_type != "sentence") {
        api->destroy_session(session);
        Fail(reason +
             "; initial mixed learning fixture was not a system sentence");
      }
      const size_t mixed_index =
          static_cast<size_t>(std::distance(candidates.begin(), mixed));
      if (!api->process_key(session, '1' + static_cast<int>(mixed_index), 0) ||
          BaseText(TakeCommit(api, session)) != expected) {
        api->destroy_session(session);
        Fail(reason + "; its 1-9 selection key did not commit the candidate");
      }
      api->destroy_session(session);
      if (verify_learning) {
        const RimeSessionId learned =
            CreateSchemaSession(api, schema_id.c_str());
        Enter(api, learned, input);
        const auto learned_candidates = CandidateOrigins(learned);
        ExpectNoFullSpanUnprojectedMixed(learned_candidates, input.size(),
                                         reason + " after learning");
        const auto learned_mixed = std::find_if(
            learned_candidates.begin(), learned_candidates.end(),
            [&](const auto& candidate) {
              return BaseText(candidate.text) == expected &&
                     candidate.type == "linnet_mixed" &&
                     candidate.genuine_language == "linnet_zh" &&
                     candidate.start == 0 && candidate.end == input.size() &&
                     (candidate.genuine_type == "sentence" ||
                      candidate.genuine_type == "user_phrase");
            });
        const bool learned_without_demotion =
            learned_mixed != learned_candidates.end() &&
            static_cast<size_t>(
                std::distance(learned_candidates.begin(), learned_mixed)) <=
                mixed_index;
        if (!learned_without_demotion) {
          std::cerr << "Learned mixed origins for " << schema_id << ":";
          for (const auto& candidate : learned_candidates) {
            std::cerr << " [" << BaseText(candidate.text) << ":"
                      << candidate.type << ":" << candidate.genuine_type
                      << ":" << candidate.genuine_language << ":"
                      << candidate.start << "-" << candidate.end << "]";
          }
          std::cerr << '\n';
          api->destroy_session(learned);
          Fail(reason + "; committed mixed sentence did not reopen as a "
               "full-span linnet_mixed candidate without ranking demotion");
        }
        api->destroy_session(learned);
        verified_mixed_learning_round_trip = true;
      }
      return;
    }
    api->destroy_session(session);
  };

  for (const auto& profile : LoadFormalProfileReviewedInputs()) {
    for (const auto& entity :
         std::array<std::pair<const char*, const char*>, 2>{{
             {"CS", "CS"},
             {"CPU", "CPU"},
         }}) {
      expect_mixed(
          profile.first, std::string(entity.first) + profile.second,
          std::string(entity.second) + "你好",
          profile.first + " did not preserve sentence-initial " +
              entity.first + " before its reviewed remaining syllables",
          std::strcmp(entity.first, "CS") == 0);
      expect_mixed(
          profile.first, profile.second + entity.first,
          "你好" + std::string(entity.second),
          profile.first + " did not preserve sentence-final " + entity.first,
          false);
      expect_mixed(
          profile.first, profile.second + entity.first + profile.second,
          "你好" + std::string(entity.second) + "你好",
          profile.first + " did not preserve sentence-middle " +
              entity.first,
          false);
    }
    for (const char* input : {"ai", "cpu"}) {
      const RimeSessionId standalone_entity =
          CreateSchemaSession(api, profile.first.c_str());
      Enter(api, standalone_entity, input);
      const auto candidates = CandidateOrigins(standalone_entity);
      if (std::any_of(candidates.begin(), candidates.end(),
                      [](const auto& candidate) {
                        return candidate.type == "linnet_mixed";
                      })) {
        api->destroy_session(standalone_entity);
        Fail(profile.first +
             " synthesized mixed text for standalone English entity " + input);
      }
      api->destroy_session(standalone_entity);
    }
    ExpectNineCandidateSelectKeys(
        api, profile.first.c_str(),
        PagingInputForProfile(api, profile.first, profile.second));

    for (const char* entity : {"WAF", "QZX"}) {
      const RimeSessionId explicit_mixed =
          CreateSchemaSession(api, profile.first.c_str());
      Enter(api, explicit_mixed, profile.second);
      AppendShiftedUppercase(api, explicit_mixed, entity);
      if (!api->simulate_key_sequence(explicit_mixed,
                                      profile.second.c_str())) {
        api->destroy_session(explicit_mixed);
        Fail(profile.first +
             " could not append Chinese input after an uppercase entity");
      }
      const std::string input =
          profile.second + std::string(entity) + profile.second;
      const std::string expected =
          "你好" + std::string(entity) + "你好";
      const auto candidates = CandidateOrigins(explicit_mixed);
      const auto exact = std::find_if(
          candidates.begin(), candidates.end(), [&](const auto& candidate) {
            return candidate.type == "linnet_mixed" &&
                   candidate.genuine_type == "sentence" &&
                   candidate.genuine_language == "linnet_zh" &&
                   candidate.start == 0 && candidate.end == input.size() &&
                   BaseText(candidate.text) == expected &&
                   candidate.sentence_uppercase_entity_count == 1 &&
                   candidate.sentence_components_follow_mixed_contract;
          });
      if (exact == candidates.end()) {
        const char* retained = api->get_input(explicit_mixed);
        std::cerr << "Explicit mixed origins for " << profile.first << " '"
                  << input << "' retained='" << (retained ? retained : "")
                  << "':";
        for (const auto& candidate : candidates) {
          std::cerr << " [" << BaseText(candidate.text) << ":"
                    << candidate.type << ":" << candidate.genuine_type << ":"
                    << candidate.genuine_language << ":" << candidate.start
                    << "-" << candidate.end << ":components="
                    << candidate.sentence_components << "]";
        }
        const auto live = rime::Service::instance().GetSession(explicit_mixed);
        if (live && live->context()) {
          std::cerr << " segments=";
          for (const auto& segment : live->context()->composition()) {
            std::cerr << "[" << segment.start << "-" << segment.end
                      << ":status=" << segment.status << ":tags=";
            for (const auto& tag : segment.tags) std::cerr << tag << ",";
            std::cerr << "]";
          }
        }
        std::cerr << '\n';
        api->destroy_session(explicit_mixed);
        Fail(profile.first + " did not preserve novel explicit uppercase " +
             entity + " while composing Chinese on both sides");
      }
      const size_t exact_index =
          static_cast<size_t>(std::distance(candidates.begin(), exact));
      if (exact_index >= 9 ||
          !api->select_candidate(explicit_mixed, exact_index) ||
          BaseText(TakeCommit(api, explicit_mixed)) != expected) {
        api->destroy_session(explicit_mixed);
        Fail(profile.first + " could not select and commit novel explicit " +
             entity + " with Chinese on both sides");
      }
      api->destroy_session(explicit_mixed);
    }
  }

  for (const auto& ordinary_case :
       std::array<std::pair<const char*, const char*>, 2>{{
           {"xuexihejishu", "学习和技术"},
           {"woaini", "我爱你"},
       }}) {
    const RimeSessionId ordinary =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    Enter(api, ordinary, ordinary_case.first);
    const auto ordinary_candidates = CandidateOrigins(ordinary);
    ExpectNoFullSpanUnprojectedMixed(
        ordinary_candidates, std::strlen(ordinary_case.first),
        std::string("ordinary Chinese input ") + ordinary_case.first);
    if (ordinary_candidates.empty() ||
        BaseText(ordinary_candidates.front().text) != ordinary_case.second ||
        ordinary_candidates.front().type == "linnet_mixed") {
      Fail("an acronym-shaped substring displaced ordinary Chinese context " +
           std::string(ordinary_case.first));
    }
    api->destroy_session(ordinary);
  }

  expect_mixed("linnet_zh_pinyin", "CSjiting", "CS急停",
               "a leading letter-only entity did not compose", false);
  expect_mixed("linnet_zh_pinyin", "xuexiHTTPSjishu",
               "学习HTTPS技术",
               "overlapping HTTP/HTTPS entities did not select HTTPS", false);

  for (const auto& test : kCases) {
    const RimeSessionId session =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    Enter(api, session, test.input);
    const auto candidates = CandidateOrigins(session);
    ExpectNoFullSpanUnprojectedMixed(
        candidates, std::strlen(test.input),
        std::string("mixed input ") + test.input);
    const auto mixed = std::find_if(
        candidates.begin(), candidates.end(), [&](const auto& candidate) {
          return candidate.type == "linnet_mixed" &&
                 BaseText(candidate.text) == test.expected &&
                 candidate.start == 0 && candidate.end == std::strlen(test.input);
        });
    const auto same_span_chinese = std::find_if(
        candidates.begin(), candidates.end(), [&](const auto& candidate) {
          return candidate.genuine_language == "linnet_zh" &&
                 candidate.type != "linnet_mixed" &&
                 !ContainsAscii(BaseText(candidate.text)) &&
                 candidate.start == 0 &&
                 candidate.end == std::strlen(test.input);
        });
    const bool valid_collision =
        same_span_chinese == candidates.end() ? mixed == candidates.begin()
                                              : same_span_chinese < mixed;
    if (mixed == candidates.end() || !valid_collision) {
      std::cerr << "Mixed origins for '" << test.input << "':";
      for (const auto& candidate : candidates) {
        std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                  << candidate.genuine_type << ":"
                  << candidate.genuine_language << ":q="
                  << candidate.quality << "]";
      }
      std::cerr << '\n';
      Fail("modeless mixed input did not rank '" +
           std::string(test.expected) + "' first");
    }
    const size_t mixed_index =
        static_cast<size_t>(std::distance(candidates.begin(), mixed));
    if (mixed_index >= 9 ||
        !api->process_key(session, '1' + static_cast<int>(mixed_index), 0) ||
        BaseText(TakeCommit(api, session)) != test.expected) {
      Fail("digit selection did not commit modeless mixed candidate " +
           std::string(test.expected));
    }
    api->destroy_session(session);
  }

  const RimeSessionId ambiguous =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, ambiguous, "cs");
  const auto standalone = CandidateOrigins(ambiguous);
  const bool has_english = std::any_of(
      standalone.begin(), standalone.end(), [](const auto& candidate) {
        const std::string text = BaseText(candidate.text);
        return candidate.genuine_language == "linnet_en" &&
               (text == "cs" || text == "CS");
      });
  const bool has_chinese = std::any_of(
      standalone.begin(), standalone.end(), [](const auto& candidate) {
        return candidate.genuine_language == "linnet_zh" &&
               candidate.start == 0 && candidate.end == 2;
      });
  const bool synthesized_standalone = std::any_of(
      standalone.begin(), standalone.end(), [](const auto& candidate) {
        return candidate.type == "linnet_mixed";
      });
  if (!has_english || !has_chinese || synthesized_standalone) {
    std::cerr << "Standalone origins for 'cs':";
    for (const auto& candidate : standalone) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << ":"
                << candidate.genuine_language << ":" << candidate.start
                << "-" << candidate.end << ":q=" << candidate.quality << "]";
    }
    std::cerr << '\n';
    Fail("standalone cs did not preserve Chinese/English ambiguity");
  }
  api->destroy_session(ambiguous);

  for (const char* input : {
           "jintiankaihuigaidaoxiawusandian", "mingtianzaoshangyaoqujichang",
           "qingbawenjianfadaowodeyouxiang", "woxiangzhidaojutiyuanyin"}) {
    const RimeSessionId lowercase =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    Enter(api, lowercase, input);
    const auto candidates = CandidateOrigins(lowercase);
    if (std::any_of(candidates.begin(), candidates.end(),
                    [](const auto& candidate) {
                      return candidate.type == "linnet_mixed";
                    })) {
      Fail(std::string("lowercase sentence inferred an uppercase entity: ") + input);
    }
    api->destroy_session(lowercase);
  }

  // Lowercase acronyms may compete on the native sentence score, without
  // borrowing the preserved candidate slot reserved for explicit uppercase.
  for (const auto& sample :
       std::array<std::pair<const char*, const char*>, 3>{{
           {"jianchacpuzhanyong", "检查CPU占用"},
           {"xiugaidnsshezhi", "修改DNS设置"},
           {"qingqiushiyonghttpsxieyi", "请求使用HTTPS协议"},
       }}) {
    const RimeSessionId inferred = CreateSchemaSession(api, "linnet_zh_pinyin");
    Enter(api, inferred, sample.first);
    const auto candidates = CandidateOrigins(inferred);
    if (candidates.empty() || candidates.front().type != "linnet_mixed" ||
        BaseText(candidates.front().text) != sample.second) {
      Fail(std::string("native scoring lost a contextual lowercase acronym: ") +
           sample.first);
    }
    if (!api->process_key(inferred, '1', 0) ||
        BaseText(TakeCommit(api, inferred)) != sample.second) {
      Fail("lowercase acronym sentence could not be selected and committed");
    }
    api->destroy_session(inferred);
  }

  for (const char* input : {"https://api.example.com", "v0.1.18", "URLSession",
                            "HTTPServer2", "WAF"}) {
    const RimeSessionId raw = CreateSchemaSession(api, "linnet_zh_pinyin");
    Enter(api, raw, input);
    api->process_key(raw, XK_Return, 0);
    if (TakeCommit(api, raw) != input) {
      Fail(std::string("mixed selection changed literal input: ") + input);
    }
    api->destroy_session(raw);
  }
}

void ExpectSupplementalExtendedChineseCoverage(RimeApi_stdbool* api) {
  constexpr char kExpected[] = "希尔瓦娜斯";
  constexpr std::array<std::pair<const char*, const char*>, 8> kProfiles = {{
      {"linnet_zh_pinyin", "xi'er'wa'na'si"},
      {"linnet_zh", "xierwanasi"},
      {"linnet_zh_flypy", "xierwanasi"},
      {"linnet_zh_mspy", "xiorwanasi"},
      {"linnet_zh_sogou", "xiorwanasi"},
      {"linnet_zh_abc", "xiorwanasi"},
      {"linnet_zh_ziguang", "xiojwanasi"},
      {"linnet_zh_jiajia", "xieqwanasi"},
  }};
  for (const auto& profile : kProfiles) {
    const RimeSessionId session = CreateSchemaSession(api, profile.first);
    ExpectFirstCandidate(api, session, profile.second, kExpected);
    api->destroy_session(session);
  }

  struct ReviewedLongTailCase {
    const char* input;
    const char* expected;
  };
  // Source projection separately proves these rows are verified-only,
  // absent from the product's Wanxiang core tables, and span the reviewed
  // length/domain/rank strata. This native row proves that the compiled
  // supplement contributes reachable product candidates rather than dead
  // package bytes.
  constexpr std::array<ReviewedLongTailCase, 5> kLongTailCases{{
      {"a'dai'er", "阿黛尔"},
      {"a'bei'er'jiang", "阿贝尔奖"},
      {"a'er'ci'hai'mo", "阿尔茨海默"},
      {"a'heng'ke'ji'da'xue", "阿亨科技大学"},
      {"sheng'cheng'shi'ren'gong'zhi'neng", "生成式人工智能"},
  }};
  const RimeSessionId long_tail =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  for (const auto& sample : kLongTailCases) {
    ExpectCandidate(api, long_tail, sample.input, sample.expected);
  }
  api->destroy_session(long_tail);
}

void ExpectNativeMixedLearningEnabled(RimeApi_stdbool* api) {
  constexpr char kInput[] = "shuanghezhanCSjiting";
  constexpr char kLearnedText[] = "霜河栈CS急停";
  const RimeSessionId session =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, session, kInput);
  const auto candidates = CandidateOrigins(session);
  if (candidates.empty() || candidates.front().type != "linnet_mixed" ||
      candidates.front().genuine_type != "sentence" ||
      candidates.front().genuine_language != "linnet_zh" ||
      BaseText(candidates.front().text) != kLearnedText) {
    std::cerr << "Mixed learning-on origins:";
    for (const auto& candidate : candidates) {
      std::cerr << " [" << BaseText(candidate.text) << ":"
                << candidate.type << ":" << candidate.genuine_type << ":"
                << candidate.genuine_language << ":" << candidate.start
                << "-" << candidate.end << "]";
    }
    std::cerr << '\n';
    Fail("enabled Chinese learning did not preserve the seeded phrase inside "
         "the preferred mixed sentence");
  }
  api->destroy_session(session);
}

void ExpectNativeMixedLearningDisabled(RimeApi_stdbool* api) {
  constexpr char kInput[] = "shuanghezhanCSjiting";
  constexpr char kLearnedText[] = "霜河栈CS急停";
  const RimeSessionId session =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, session, kInput);
  const auto candidates = CandidateOrigins(session);
  if (std::any_of(candidates.begin(), candidates.end(), [&](const auto& candidate) {
        return candidate.type == "linnet_mixed" &&
               BaseText(candidate.text) == kLearnedText;
      })) {
    Fail("disabled Chinese learning still exposed a user phrase through mixed input");
  }
  api->destroy_session(session);

  const RimeSessionId static_mixed =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, static_mixed, "xuexiCSjiting");
  const auto static_candidates = CandidateOrigins(static_mixed);
  if (std::none_of(
          static_candidates.begin(), static_candidates.end(), [](const auto& candidate) {
            return candidate.type == "linnet_mixed" &&
                   candidate.genuine_type == "sentence" &&
                   candidate.genuine_language == "linnet_zh" &&
                   BaseText(candidate.text) == "学习CS急停";
          })) {
    Fail("disabling Chinese learning also disabled static mixed input");
  }
  api->destroy_session(static_mixed);
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
  Enter(api, session, "|yun");
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
    if (!candidate.comment.empty() &&
        candidate.comment != std::string(1, '\x1d')) {
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
  for (const auto& schema_id : RuntimeProductSchemaIDs(api)) {
    const RimeSessionId session = CreateSchemaSession(api, schema_id.c_str());
    const std::string expected_input =
        schema_id == "linnet_en"
            ? "En"
            : (schema_id == "linnet_zh_pinyin" ? "中" : "双");
    const std::string input = AbbreviatedModeLabel(api, session, false);
    const std::string ascii = AbbreviatedModeLabel(api, session, true);
    api->destroy_session(session);
    if (input != expected_input || ascii != "A") {
      Fail(schema_id + " status labels were '" + input +
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
  for (int keycode = XK_0; keycode <= XK_9; ++keycode) {
    const std::string reason =
        std::string(schema_id) + " idle digit " +
        static_cast<char>(keycode);
    const RimeSessionId idle = CreateSchemaSession(api, schema_id);
    if (api->process_key(idle, keycode, 0)) {
      Fail(reason + " was captured instead of reaching the host");
    }
    ExpectNoCommit(api, idle, reason);
    const char* retained = api->get_input(idle);
    if ((retained && *retained != '\0') || !Candidates(api, idle).empty()) {
      Fail(reason + " retained hidden input-method state");
    }
    api->destroy_session(idle);
  }

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
  const auto before_zero = Candidates(api, session);
  if (before_zero.empty()) {
    api->destroy_session(session);
    Fail(std::string(schema_id) + " zero pass-through fixture has no candidate");
  }
  const std::string expected_before_zero = before_zero.front().text;
  if (api->process_key(session, XK_0, 0)) {
    Fail(std::string(schema_id) +
         " swallowed zero despite a nine-candidate page");
  }
  if (TakeCommit(api, session,
                 std::string(schema_id) + " active zero pass-through") !=
      expected_before_zero) {
    Fail(std::string(schema_id) +
         " did not commit the current candidate before zero reached the host");
  }
  const char* after_zero = api->get_input(session);
  if ((after_zero && *after_zero != '\0') || !Candidates(api, session).empty()) {
    Fail(std::string(schema_id) +
         " retained input-method state after zero reached the host");
  }
  api->destroy_session(session);

  for (int keycode = XK_1; keycode <= XK_9; ++keycode) {
    const std::string reason =
        std::string(schema_id) + " direct candidate selection " +
        static_cast<char>(keycode);
    const RimeSessionId selection = CreateSchemaSession(api, schema_id);
    Enter(api, selection, input);
    const auto candidates = Candidates(api, selection);
    const size_t target = static_cast<size_t>(keycode - XK_1);
    if (target >= candidates.size()) {
      Fail(reason + " fixture has no target candidate");
    }
    if (!api->process_key(selection, keycode, 0) ||
        TakeCommit(api, selection) != candidates[target].text) {
      Fail(reason + " did not commit its matching visible candidate");
    }
    api->destroy_session(selection);
  }
}

int CurrentCandidatePage(RimeApi_stdbool* api,
                         RimeSessionId session,
                         const std::string& reason) {
  RimeContext_stdbool context = {};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  if (!api->get_context(session, &context)) {
    Fail("could not inspect candidate page for " + reason);
  }
  const int page = context.menu.page_no;
  api->free_context(&context);
  return page;
}

void ExpectCandidatePagingShortcuts(RimeApi_stdbool* api,
                                    const char* schema_id,
                                    const std::string& input) {
  const auto expect_expansion_request = [&](RimeSessionId session,
                                             bool expected,
                                             const std::string& reason) {
    std::array<char, 8> value = {};
    const bool present = api->get_property(
        session, kCandidateExpansionRequestProperty,
        value.data(), value.size());
    if (present != expected || (expected && std::string(value.data()) != "1")) {
      Fail(std::string(schema_id) + " candidate expansion request " + reason);
    }
    if (present) {
      api->set_property(session, kCandidateExpansionRequestProperty, "");
    }
  };
  for (const auto& key_case :
       std::array<std::tuple<int, const char*, int, const char*>, 2>{{
           {XK_bracketright, "right bracket", XK_bracketleft, "left bracket"},
           {XK_equal, "equal", XK_minus, "minus"},
       }}) {
    const RimeSessionId session = CreateSchemaSession(api, schema_id);
    Enter(api, session, input);
    if (CurrentCandidatePage(api, session, "initial page") != 0) {
      Fail(std::string(schema_id) + " paging fixture did not start on page zero");
    }

    int final_page = 0;
    while (true) {
      RimeContext_stdbool context = {};
      RIME_STRUCT_INIT(RimeContext_stdbool, context);
      if (!api->get_context(session, &context)) {
        Fail(std::string(schema_id) + " could not inspect the paging boundary");
      }
      const bool is_last_page = context.menu.is_last_page;
      final_page = context.menu.page_no;
      api->free_context(&context);
      if (is_last_page) break;
      if (!api->process_key(session, std::get<0>(key_case), 0)) {
        Fail(std::string(schema_id) + " " + std::get<1>(key_case) +
             " did not move to the next candidate page");
      }
      expect_expansion_request(session, true, "missing after accepted next paging");
    }
    if (final_page == 0) {
      Fail(std::string(schema_id) + " paging fixture has no next candidate page");
    }
    if (!api->process_key(session, std::get<2>(key_case), 0) ||
        CurrentCandidatePage(api, session, std::get<3>(key_case)) !=
            final_page - 1) {
      Fail(std::string(schema_id) + " " + std::get<3>(key_case) +
           " did not return from the final candidate page");
    }
    expect_expansion_request(session, true, "missing after accepted previous paging");
    api->destroy_session(session);

    // The compact page has nine entries, but the host displays five columns.
    // First open without moving; then follow the visual row, not page_size.
    const RimeSessionId grid = CreateSchemaSession(api, schema_id);
    Enter(api, grid, input);
    const auto expect_selected = [&](int expected) {
      RimeContext_stdbool context = {};
      RIME_STRUCT_INIT(RimeContext_stdbool, context);
      if (!api->get_context(grid, &context)) Fail("could not inspect grid selection");
      const int selected = context.menu.page_no * context.menu.page_size +
                           context.menu.highlighted_candidate_index;
      api->free_context(&context);
      if (selected != expected) Fail("expanded paging did not follow the visual row");
    };
    api->set_property(grid, "linnet/candidate_next_row_v1", "expand");
    if (!api->process_key(grid, std::get<0>(key_case), 0)) {
      Fail("first paging key did not request expansion");
    }
    expect_expansion_request(grid, true, "missing on first expansion");
    expect_selected(0);
    api->set_property(grid, "linnet/candidate_next_row_v1", "5");
    if (!api->process_key(grid, std::get<0>(key_case), 0)) {
      Fail("expanded paging did not reach the next row");
    }
    expect_selected(5);
    api->set_property(grid, "linnet/candidate_previous_row_v1", "0");
    if (!api->process_key(grid, std::get<2>(key_case), 0)) {
      Fail("expanded paging did not return within the first compact page");
    }
    expect_selected(0);
    api->destroy_session(grid);
  }
}

void ExpectCandidatePagingBoundaryNormalInput(RimeApi_stdbool* api,
                                              const char* schema_id,
                                              const std::string& input) {
  struct BoundaryCase {
    int keycode;
    const char* expected_symbol;
    bool final_page;
  };
  for (const auto& boundary : std::array<BoundaryCase, 4>{{
           {XK_bracketleft, "【", false},
           {XK_minus, "-", false},
           {XK_bracketright, "】", true},
           {XK_equal, "=", true},
       }}) {
    const RimeSessionId session = CreateSchemaSession(api, schema_id);
    Enter(api, session, input);
    if (boundary.final_page) {
      while (true) {
        RimeContext_stdbool page_context = {};
        RIME_STRUCT_INIT(RimeContext_stdbool, page_context);
        if (!api->get_context(session, &page_context)) {
          api->destroy_session(session);
          Fail(std::string(schema_id) + " could not inspect final paging boundary");
        }
        const bool is_last_page = page_context.menu.is_last_page;
        api->free_context(&page_context);
        if (is_last_page) break;
        if (!api->process_key(session, XK_bracketright, 0)) {
          api->destroy_session(session);
          Fail(std::string(schema_id) + " could not reach final paging boundary");
        }
        api->set_property(session, kCandidateExpansionRequestProperty, "");
      }
    }

    const auto live = rime::Service::instance().GetSession(session);
    if (!live || !live->context() || live->context()->composition().empty()) {
      api->destroy_session(session);
      Fail(std::string(schema_id) + " could not inspect normal paging fallback");
    }
    const auto selected_candidate =
        live->context()->composition().back().GetSelectedCandidate();
    if (!selected_candidate) {
      api->destroy_session(session);
      Fail(std::string(schema_id) + " normal paging fallback has no selection");
    }
    const std::string selected_text = selected_candidate->text();
    const bool handled = api->process_key(session, boundary.keycode, 0);
    std::string actual = TakeCommit(api, session, "normal paging boundary");
    if (!handled) actual.push_back(static_cast<char>(boundary.keycode));
    const std::string expected = selected_text + boundary.expected_symbol;
    const char* remaining_input = api->get_input(session);
    const bool retained_input = remaining_input && *remaining_input != '\0';
    const bool retained_candidates = !Candidates(api, session).empty();
    api->destroy_session(session);
    if (actual != expected || retained_input || retained_candidates) {
      Fail(std::string(schema_id) + " paging boundary produced '" + actual +
           "' instead of normal input '" + expected + "'");
    }
  }
}

void ExpectSmartEnglishHyphenBoundary(RimeApi_stdbool* api) {
  const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
  Enter(api, session, "built");
  const auto candidates = Candidates(api, session);
  RimeContext_stdbool context = {};
  RIME_STRUCT_INIT(RimeContext_stdbool, context);
  if (!api->get_context(session, &context)) {
    api->destroy_session(session);
    Fail("could not inspect the Smart English built- fixture");
  }
  const int selected = context.menu.highlighted_candidate_index;
  api->free_context(&context);
  if (selected < 0 || static_cast<size_t>(selected) >= candidates.size()) {
    api->destroy_session(session);
    Fail("Smart English built- fixture has no selected candidate");
  }
  const std::string expected = candidates[selected].text;

  if (api->process_key(session, XK_minus, 0)) {
    api->destroy_session(session);
    Fail("Smart English built- captured the hyphen as candidate paging");
  }
  if (TakeCommit(api, session, "Smart English built- boundary") != expected) {
    api->destroy_session(session);
    Fail("Smart English built- did not confirm the selected word before the host hyphen");
  }
  const char* remaining_input = api->get_input(session);
  const bool retained_input = remaining_input && *remaining_input != '\0';
  const bool retained_candidates = !Candidates(api, session).empty();
  api->destroy_session(session);
  if (retained_input || retained_candidates) {
    Fail("Smart English built- left marked text for the host hyphen to replace");
  }
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
                     const std::string& sequence,
                     bool enforce_contract = true) {
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
            << " sequence=" << sequence
            << " samples=" << kLatencySamples << " p95_ns=" << p95
            << " p99_ns=" << p99 << '\n';
  if (enforce_contract && (p95 > p95_limit || p99 > p99_limit)) {
    Fail("per-key latency exceeded the product contract");
  }
}

void ExpectRetainedWarmSessionLatency(RimeApi_stdbool* api) {
  const RimeSessionId warm = CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, warm, "ceshi");
  if (CandidateOrigins(warm).empty()) {
    Fail("resource warm-up did not traverse the candidate path");
  }
  api->clear_composition(warm);

  const auto started = std::chrono::steady_clock::now();
  const RimeSessionId client = CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, client, "ceshi");
  if (CandidateOrigins(client).empty()) {
    Fail("a client session produced no candidate after resource warm-up");
  }
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started);
  std::cout << "rime_smoke_test: retained warm-session first-candidate_ms="
            << elapsed.count() << '\n';
  api->destroy_session(client);
  api->destroy_session(warm);
  if (elapsed >= std::chrono::milliseconds(100)) {
    Fail("a new client exceeded the 100ms first-candidate contract after "
         "resource warm-up");
  }
}

void ExpectColdClientFirstKeyLatency(RimeApi_stdbool* api) {
  const RimeSessionId warm = CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, warm, "ceshi");
  if (CandidateOrigins(warm).empty()) {
    Fail("cold-client probe could not warm the shared candidate path");
  }
  api->clear_composition(warm);

  for (const auto& probe :
       std::array<std::pair<const char*, char>, 2>{{
           {"linnet_zh_pinyin", 'a'},
           {"linnet_en", 'z'},
       }}) {
    const RimeSessionId client = CreateSchemaSession(api, probe.first);
    const auto started = std::chrono::steady_clock::now();
    if (!api->process_key(client, probe.second, 0) ||
        CandidateOrigins(client).empty()) {
      Fail(std::string(probe.first) +
           " did not publish candidates for its first client key");
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started);
    std::cout << "rime_smoke_test: cold-client first-key schema="
              << probe.first << " elapsed_ms=" << elapsed.count() << '\n';
    api->destroy_session(client);
    if (elapsed >= std::chrono::milliseconds(100)) {
      Fail(std::string(probe.first) +
           " exceeded the 100ms cold-client first-key contract");
    }
  }
  api->destroy_session(warm);
}

void ExpectSchemaList(RimeApi_stdbool* api) {
  std::vector<std::string> actual = RuntimeProductSchemaIDs(api);
  bool valid = actual.size() == kProductSchemaIDs.size();
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

std::string TakeCommit(RimeApi_stdbool* api,
                       RimeSessionId session,
                       const std::string& reason,
                       unsigned source_line) {
  RimeCommit commit = {};
  RIME_STRUCT_INIT(RimeCommit, commit);
  if (!api->get_commit(session, &commit)) {
    char schema[128] = {};
    api->get_current_schema(session, schema, sizeof(schema));
    const char* input = api->get_input(session);
    Fail("expected a Rime commit at line " + std::to_string(source_line) +
         ", schema=" + schema + ", input='" + (input ? input : "") +
         "'" + (reason.empty() ? "" : ", after " + reason));
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

void ExpectCapsLockCommitsRawCode(RimeApi_stdbool* api,
                                  const char* schema_id,
                                  const char* input) {
  const RimeSessionId session = CreateSchemaSession(api, schema_id);
  Enter(api, session, input);
  const auto before = rime::Service::instance().GetSession(session);
  if (!before || !before->context() || !before->context()->IsComposing()) {
    Fail(std::string(schema_id) +
         " Caps Lock raw-code fixture did not start composing '" + input +
         "'");
  }
  if (api->process_key(session, XK_Caps_Lock, 0) ||
      !api->get_option(session, "ascii_mode")) {
    Fail(std::string(schema_id) +
         " did not enter raw ASCII while preserving composition '" + input +
         "'");
  }
  const std::string actual = TakeCommit(
      api, session, std::string(schema_id) + " Caps Lock composition");
  if (actual != input) {
    Fail(std::string(schema_id) + " Caps Lock selected or changed pending '" +
         input + "': got '" + actual + "'");
  }
  ExpectNoCommit(api, session,
                 std::string(schema_id) + " duplicate Caps Lock commit");
  const char* remaining = api->get_input(session);
  if ((remaining && *remaining) || !Candidates(api, session).empty()) {
    Fail(std::string(schema_id) +
         " retained a hidden composition after Caps Lock raw commit");
  }
  api->destroy_session(session);
}

RimeSessionId CreateExplicitChinesePrefixFixture(RimeApi_stdbool* api,
                                                 const std::string& reason) {
  constexpr char kSchema[] = "linnet_zh";
  constexpr char kInput[] = "xwvbii";
  constexpr char kRawPrefix[] = "xwvb";
  constexpr char kSelectedPrefix[] = "下周";
  const RimeSessionId session = CreateSchemaSession(api, kSchema);
  Enter(api, session, kInput);
  const auto origins = CandidateOrigins(session);
  const auto prefix = std::find_if(
      origins.begin(), origins.end(), [&](const auto& candidate) {
        return BaseText(candidate.text) == kSelectedPrefix &&
               candidate.start == 0 &&
               candidate.end == std::strlen(kRawPrefix);
      });
  if (prefix == origins.end() ||
      !api->select_candidate(
          session, static_cast<size_t>(prefix - origins.begin()))) {
    Fail(reason + " could not explicitly confirm its Chinese prefix");
  }
  const auto live = rime::Service::instance().GetSession(session);
  if (!live || !live->context() || live->context()->composition().empty() ||
      live->context()->composition().back().start != std::strlen(kRawPrefix)) {
    Fail(reason + " lost its unconfirmed raw tail");
  }
  return session;
}

void ExpectCapsLockPreservesExplicitPrefix(RimeApi_stdbool* api) {
  constexpr char kExpected[] = "下周ii";
  const RimeSessionId session =
      CreateExplicitChinesePrefixFixture(api, "Caps Lock fixture");
  if (api->process_key(session, XK_Caps_Lock, 0) ||
      !api->get_option(session, "ascii_mode")) {
    Fail("Caps Lock did not enter raw ASCII from a partially confirmed composition");
  }
  if (TakeCommit(api, session, "Caps Lock partial composition") != kExpected) {
    Fail("Caps Lock did not preserve the explicit prefix and raw tail");
  }
  ExpectNoCommit(api, session, "duplicate partial Caps Lock commit");
  const char* remaining = api->get_input(session);
  if ((remaining && *remaining) || !Candidates(api, session).empty()) {
    Fail("Caps Lock retained a hidden partial composition after commit");
  }
  api->destroy_session(session);
}

void ExpectReturnPreservesExplicitPrefix(RimeApi_stdbool* api) {
  constexpr char kExpected[] = "下周ii";
  const RimeSessionId session =
      CreateExplicitChinesePrefixFixture(api, "raw Return fixture");
  if (!api->process_key(session, kReturn, 0)) {
    Fail("commit_raw_input Return did not accept a partially confirmed composition");
  }
  if (TakeCommit(api, session, "partial-confirmed raw Return") != kExpected) {
    Fail("commit_raw_input Return did not emit exactly '下周ii'");
  }
  ExpectNoCommit(api, session, "duplicate partial-confirmed raw Return commit");
  const char* remaining = api->get_input(session);
  const auto live = rime::Service::instance().GetSession(session);
  if ((remaining && *remaining) || !Candidates(api, session).empty() ||
      !live || !live->context() || !live->context()->composition().empty()) {
    Fail("commit_raw_input Return retained a hidden partial composition");
  }
  api->destroy_session(session);
}

void ExpectCapsLockRawPath(RimeApi_stdbool* api, const char* schema_id) {
  ExpectCapsLockCommitsRawCode(api, schema_id, "shi");
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

void ExpectShiftCommitsRawCode(RimeApi_stdbool* api,
                               const char* schema_id,
                               const ShiftKeyCase& shift,
                               const char* input) {
  const std::string reason = std::string(schema_id) + " " + shift.name +
                             " pending raw code";
  const RimeSessionId session = CreateSchemaSession(api, schema_id);
  Enter(api, session, input);
  const auto before = rime::Service::instance().GetSession(session);
  if (!before || !before->context() || !before->context()->IsComposing() ||
      Candidates(api, session).empty()) {
    Fail(reason + " fixture has no competing translated candidate");
  }

  TapShift(api, session, shift.keycode);
  ExpectCurrentSchema(api, session, "linnet_en", reason);
  if (api->get_option(session, "ascii_mode")) {
    Fail(reason + " entered raw ASCII instead of Smart English");
  }
  const std::string actual = TakeCommit(api, session, reason);
  if (actual != input) {
    Fail(reason + " selected or changed pending input: got '" + actual + "'");
  }
  ExpectNoCommit(api, session, "duplicate " + reason);
  const char* remaining = api->get_input(session);
  const auto after = rime::Service::instance().GetSession(session);
  if ((remaining && *remaining) || !Candidates(api, session).empty() ||
      !after || !after->context() || !after->context()->composition().empty()) {
    Fail(reason + " retained hidden input or candidates after the commit");
  }
  api->destroy_session(session);
}

void ExpectShiftPreservesExplicitPrefix(RimeApi_stdbool* api) {
  constexpr char kExpected[] = "下周ii";
  for (const auto& shift : kShiftKeyCases) {
    const std::string reason =
        std::string(shift.name) + " partial-confirmed Chinese composition";
    const RimeSessionId session =
        CreateExplicitChinesePrefixFixture(api, reason);
    TapShift(api, session, shift.keycode);
    ExpectCurrentSchema(api, session, "linnet_en", reason);
    if (api->get_option(session, "ascii_mode")) {
      Fail(reason + " entered raw ASCII instead of Smart English");
    }
    if (TakeCommit(api, session, reason) != kExpected) {
      Fail(reason + " did not preserve the selected prefix and raw tail");
    }
    ExpectNoCommit(api, session, "duplicate " + reason);
    const char* remaining = api->get_input(session);
    const auto after = rime::Service::instance().GetSession(session);
    if ((remaining && *remaining) || !Candidates(api, session).empty() ||
        !after || !after->context() ||
        !after->context()->composition().empty()) {
      Fail(reason + " retained hidden input or candidates after the commit");
    }
    api->destroy_session(session);
  }
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

void ExpectOverlappingShiftRepressDoesNotToggle(RimeApi_stdbool* api) {
  struct ShiftStep {
    int keycode;
    int modifiers;
    const char* name;
  };
  constexpr std::array<ShiftStep, 6> steps = {{
      {XK_Shift_L, kShiftMask, "left down"},
      {XK_Shift_R, kShiftMask, "right down"},
      {XK_Shift_L, kShiftMask | kReleaseMask, "left up; right held"},
      {XK_Shift_L, kShiftMask, "left down again; right held"},
      {XK_Shift_L, kShiftMask | kReleaseMask, "left up again; right held"},
      {XK_Shift_R, kReleaseMask, "right up"},
  }};

  const RimeSessionId session =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, session, "shuru");
  const std::string input_before = api->get_input(session);
  for (const auto& step : steps) {
    // InputMethodKit owns flagsChanged delivery and does not expose librime's
    // internal processor return to the host. Product behavior is the schema,
    // pending input, and commit state below—not which Core processor observed
    // the physical edge.
    api->process_key(session, step.keycode, step.modifiers);
    const std::string reason =
        std::string("overlapping Shift re-press at ") + step.name;
    ExpectCurrentSchema(api, session, "linnet_zh_pinyin", reason);
    const char* input_after = api->get_input(session);
    if (!input_after || input_before != input_after) {
      Fail(reason + " changed the pending composition");
    }
    ExpectNoCommit(api, session, reason);
  }
  api->destroy_session(session);
}

void ExpectDirectShiftSmartEnglish(RimeApi_stdbool* api) {
  ExpectOverlappingShiftRepressDoesNotToggle(api);
  ExpectShiftPreservesExplicitPrefix(api);
  for (const auto& chinese_schema : RuntimeChineseSchemaIDs(api)) {
    const RimeSessionId session =
        CreateSchemaSession(api, chinese_schema.c_str());
    TapShift(api, session, XK_Shift_L);
    ExpectCurrentSchema(api, session, "linnet_en",
                        std::string(chinese_schema) +
                            " direct Shift to Smart English");
    if (api->get_option(session, "ascii_mode")) {
      Fail("direct Shift entered raw ASCII instead of Smart English");
    }

    TapShift(api, session, XK_Shift_R);
    ExpectCurrentSchema(api, session, chinese_schema,
                        chinese_schema +
                            " direct Shift back to the same Chinese profile");
    if (api->get_option(session, "ascii_mode")) {
      Fail("direct Shift back to Chinese retained raw ASCII mode");
    }
    ExpectSessionPropertyAbsent(
        api, session, kModeReturnSchemaProperty,
        chinese_schema + " direct Shift return identity");
    api->destroy_session(session);

    for (const auto& shift : kShiftKeyCases) {
      ExpectShiftCommitsRawCode(api, chinese_schema.c_str(), shift, "a");
    }
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

  for (const auto& shift : kShiftKeyCases) {
    const RimeSessionId composing =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    Enter(api, composing, "shuru");
    const auto composing_candidates = Candidates(api, composing);
    if (composing_candidates.empty()) {
      Fail(std::string(shift.name) +
           " full-pinyin composition fixture produced no Chinese candidate");
    }
    TapShift(api, composing, shift.keycode);
    ExpectCurrentSchema(api, composing, "linnet_en",
                        std::string(shift.name) +
                            " with an active full-pinyin composition");
    if (TakeCommit(api, composing) != "shuru") {
      Fail(std::string(shift.name) +
           " did not preserve uncommitted full-pinyin letters");
    }
    const char* remaining_composition = api->get_input(composing);
    ExpectNoCommit(api, composing,
                   std::string(shift.name) +
                       " duplicate full-pinyin composition commit");
    if (remaining_composition && remaining_composition[0] != '\0') {
      Fail(std::string(shift.name) +
           " duplicated or retained the full-pinyin composition");
    }
    api->destroy_session(composing);
  }

  const RimeSessionId english_composing =
      CreateSchemaSession(api, "linnet_en");
  Enter(api, english_composing, "worl");
  if (Candidates(api, english_composing).empty()) {
    Fail("direct Shift Smart English fixture produced no completion");
  }
  TapShift(api, english_composing, XK_Shift_L);
  ExpectCurrentSchema(api, english_composing, "linnet_zh_pinyin",
                      "direct Shift with pending Smart English letters");
  if (TakeCommit(api, english_composing) != "worl") {
    Fail("direct Shift accepted or duplicated a Smart English completion");
  }
  ExpectNoCommit(api, english_composing,
                 "duplicate Smart English Shift commit");
  api->destroy_session(english_composing);

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

  // A partial Chinese match plus an untranslated suffix must stay literal too;
  // Shift changes modes and must not choose any translated prefix for the user.
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
  const std::string partial_preview = partial_session->context()->GetCommitText();
  if (partial_preview.empty() || partial_preview == kPartialInput) {
    Fail("direct Shift partial-match fixture has no canonical mixed preview");
  }
  TapShift(api, partial_composing, XK_Shift_L);
  ExpectCurrentSchema(api, partial_composing, "linnet_en",
                      "direct Shift with a partial Chinese match");
  if (TakeCommit(api, partial_composing) != kPartialInput) {
    Fail("direct Shift translated part of a pending letter composition");
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

  const auto expect_overlapping_shifts_do_not_toggle =
      [api](int first_release, int second_release,
            const std::string& release_order) {
        const RimeSessionId session =
            CreateSchemaSession(api, "linnet_zh_pinyin");
        Enter(api, session, "shuru");
        const std::string input_before = api->get_input(session);
        if (api->process_key(session, XK_Shift_L, kShiftMask) ||
            api->process_key(session, XK_Shift_R, kShiftMask) ||
            api->process_key(session, first_release,
                             kShiftMask | kReleaseMask) ||
            api->process_key(session, second_release, kReleaseMask)) {
          Fail("overlapping Shift was consumed: " + release_order);
        }
        ExpectCurrentSchema(api, session, "linnet_zh_pinyin",
                            "overlapping Shift " + release_order);
        const char* input_after = api->get_input(session);
        if (!input_after || input_before != input_after) {
          Fail("overlapping Shift changed the pending composition: " +
               release_order);
        }
        ExpectNoCommit(api, session,
                       "overlapping Shift " + release_order);
        api->destroy_session(session);
      };
  expect_overlapping_shifts_do_not_toggle(
      XK_Shift_L, XK_Shift_R, "left-then-right release");
  expect_overlapping_shifts_do_not_toggle(
      XK_Shift_R, XK_Shift_L, "right-then-left release");

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

  const RimeSessionId committed_gesture =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, committed_gesture, "shuru");
  api->process_key(committed_gesture, XK_Shift_L, kShiftMask);
  if (!api->commit_raw_input(committed_gesture) ||
      TakeCommit(api, committed_gesture,
                 "held-Shift lifecycle raw exit") != "shuru") {
    Fail("held-Shift lifecycle exit did not preserve pending raw letters");
  }
  std::this_thread::sleep_for(std::chrono::milliseconds(550));
  TapShift(api, committed_gesture, XK_Shift_L);
  ExpectCurrentSchema(api, committed_gesture, "linnet_en",
                      "Shift tap after lifecycle raw commit");
  api->destroy_session(committed_gesture);
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
std::map<std::string, std::string> LoadFormalProfileReviewedInputs();
std::string PagingInputForProfile(RimeApi_stdbool* api,
                                  const std::string& schema_id,
                                  const std::string& reviewed);

void ExpectCandidateArrowNavigation(RimeApi_stdbool* api) {
  const auto reviewed_inputs = LoadFormalProfileReviewedInputs();
  std::vector<std::pair<std::string, std::string>> fixtures;
  for (const auto& schema_id : RuntimeChineseSchemaIDs(api)) {
    const auto reviewed = reviewed_inputs.find(schema_id);
    if (reviewed == reviewed_inputs.end()) {
      Fail("candidate arrows have no reviewed input for " + schema_id);
    }
    fixtures.emplace_back(
        schema_id, PagingInputForProfile(api, schema_id, reviewed->second));
  }
  fixtures.emplace_back("linnet_en", "a");

  for (const auto& fixture : fixtures) {
    const std::string horizontal_reason =
        fixture.first + " horizontal linear";
    const RimeSessionId horizontal =
        CreateSchemaSession(api, fixture.first.c_str());
    api->set_option(horizontal, "_linear", true);
    api->set_option(horizontal, "_vertical", false);
    Enter(api, horizontal, fixture.second);
    if (CandidateOrigins(horizontal).size() < 10) {
      Fail(horizontal_reason + " fixture has fewer than ten candidates");
    }
    const auto horizontal_start =
        ReadCandidateNavigationState(horizontal, horizontal_reason);
    if (horizontal_start.selected_index != 0 ||
        !api->process_key(horizontal, XK_Left, 0)) {
      Fail(horizontal_reason + " did not restore the stock spelling caret");
    }
    const auto horizontal_left =
        ReadCandidateNavigationState(horizontal, horizontal_reason + " Left");
    if (horizontal_left.selected_index != 0 ||
        horizontal_left.caret_position >= horizontal_start.caret_position) {
      Fail(horizontal_reason +
           " captured first-candidate Left instead of moving the caret");
    }
    if (!api->process_key(horizontal, XK_Right, 0)) {
      Fail(horizontal_reason + " did not restore the trailing caret");
    }
    const auto horizontal_restored = ReadCandidateNavigationState(
        horizontal, horizontal_reason + " caret restore");
    if (horizontal_restored.selected_index != 0 ||
        horizontal_restored.caret_position != horizontal_start.caret_position) {
      Fail(horizontal_reason + " did not restore the original caret");
    }
    if (!api->process_key(horizontal, XK_Right, 0) ||
        ReadCandidateNavigationState(horizontal, horizontal_reason + " Right")
                .selected_index != 1 ||
        !api->process_key(horizontal, XK_Left, 0) ||
        ReadCandidateNavigationState(horizontal, horizontal_reason + " Left")
                .selected_index != 0) {
      Fail(horizontal_reason + " lost linear Left/Right candidate selection");
    }
    if (!api->process_key(horizontal, XK_Down, 0) ||
        ReadCandidateNavigationState(horizontal, horizontal_reason + " Down")
                .selected_index != 9 ||
        !api->process_key(horizontal, XK_Up, 0) ||
        ReadCandidateNavigationState(horizontal, horizontal_reason + " Up")
                .selected_index != 0) {
      Fail(horizontal_reason + " diverged from stock Up/Down page semantics");
    }
    api->destroy_session(horizontal);

    // The product's "vertical candidates" setting is a stacked list with
    // horizontal text. `_vertical` describes glyph orientation, not list flow.
    const std::string stacked_reason =
        fixture.first + " vertical stacked horizontal-text";
    const RimeSessionId stacked =
        CreateSchemaSession(api, fixture.first.c_str());
    api->set_option(stacked, "_linear", false);
    api->set_option(stacked, "_vertical", false);
    Enter(api, stacked, fixture.second);
    const auto stacked_start =
        ReadCandidateNavigationState(stacked, stacked_reason);
    if (stacked_start.selected_index != 0 ||
        !api->process_key(stacked, XK_Up, 0) ||
        ReadCandidateNavigationState(stacked, stacked_reason + " Up")
                .selected_index != 0 ||
        !api->process_key(stacked, XK_Down, 0) ||
        ReadCandidateNavigationState(stacked, stacked_reason + " Down")
                .selected_index != 1 ||
        !api->process_key(stacked, XK_Up, 0) ||
        ReadCandidateNavigationState(stacked, stacked_reason + " Up restore")
                .selected_index != 0) {
      Fail(stacked_reason + " lost stacked Up/Down candidate selection");
    }
    if (!api->process_key(stacked, XK_Left, 0)) {
      Fail(stacked_reason + " did not expose horizontal-text caret editing");
    }
    const auto stacked_left =
        ReadCandidateNavigationState(stacked, stacked_reason + " Left");
    if (stacked_left.selected_index != 0 ||
        stacked_left.caret_position >= stacked_start.caret_position ||
        !api->process_key(stacked, XK_Right, 0)) {
      Fail(stacked_reason + " captured Left instead of moving the caret");
    }
    const auto stacked_restored =
        ReadCandidateNavigationState(stacked, stacked_reason + " Right");
    if (stacked_restored.selected_index != 0 ||
        stacked_restored.caret_position != stacked_start.caret_position) {
      Fail(stacked_reason + " did not restore the original caret");
    }
    api->destroy_session(stacked);
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
  constexpr std::array<Fixture, 5> fixtures = {{
      {"URLSession", "zz_code_token", false, false},
      {"HTTPServer", "zz_code_token", false, false},
      {"JSONDecoder", "zz_code_token", false, false},
      {"x;br", "text_expander", false, false},
      {"bdbdbdbd", "", true, true},
  }};
  constexpr std::array<Layout, 2> layouts = {{
      {"horizontal-linear", true, false},
      {"vertical-stacked-horizontal-text", false, false},
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
  // The macOS transport owner normalizes composing keypad digits to their
  // number-row equivalents before Rime sees them. MacOSKeyCodesTests covers
  // that boundary; exercise the resulting Rime contract here only once.
  {
    constexpr const char* kReason = "number-row zero";
    const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
    Enter(api, session, "a");
    const auto candidates = CandidateOrigins(session);
    if (candidates.size() < 10) {
      Fail(std::string(kReason) + " fixture has fewer than ten candidates");
    }
    const auto expected = candidates.front().text;
    if (api->process_key(session, XK_0, 0)) {
      Fail(std::string(kReason) +
           " selected the hidden tenth candidate instead of reaching the host");
    }
    if (TakeCommit(api, session, kReason) != expected) {
      Fail(std::string(kReason) +
           " did not commit the current candidate before host insertion");
    }
    ExpectNoCommit(api, session,
                   std::string("duplicate ") + kReason + " commit");
    const char* input = api->get_input(session);
    if ((input && *input) || !Candidates(api, session).empty()) {
      Fail(std::string(kReason) +
           " retained composition after returning the digit to the host");
    }
    api->destroy_session(session);
  }

  for (int index = 2; index <= 9; ++index) {
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
    if (api->process_key(session, XK_0 + index, 0)) {
      Fail("invalid selection index " + std::to_string(index) +
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

void ExpectNonFormalPunctuationBoundaries(RimeApi_stdbool* api) {
  // The formal profile matrix owns / , . : ; ' [ ] - = and reverse lookup
  // owns |. This table covers only the remaining half-shape punctuation.
  struct PunctuationCase {
    int keycode;
    int modifiers;
    const char* name;
    const char* chinese_commit;
    bool identity_mapping;
  };
  constexpr std::array<PunctuationCase, 19> punctuation_cases = {{
      {'!', kShiftMask, "!", "！", false},
      {'#', kShiftMask, "#", "#", true},
      {'$', kShiftMask, "$", "¥", false},
      {'%', kShiftMask, "%", "%", true},
      {'&', kShiftMask, "&", "&", true},
      {'(', kShiftMask, "(", "（", false},
      {')', kShiftMask, ")", "）", false},
      {'*', kShiftMask, "*", "*", true},
      {'+', kShiftMask, "+", "+", true},
      {'<', kShiftMask, "<", "《", false},
      {'>', kShiftMask, ">", "》", false},
      {'?', kShiftMask, "?", "？", false},
      {'@', kShiftMask, "@", "@", true},
      {'\\', 0, "\\", "、", false},
      {'^', kShiftMask, "^", "……", false},
      {'_', kShiftMask, "_", "——", false},
      {'{', kShiftMask, "{", "「", false},
      {'}', kShiftMask, "}", "」", false},
      {'~', kShiftMask, "~", "~", true},
  }};

  for (const auto& punctuation : punctuation_cases) {
    {
      const std::string english_reason =
          std::string("English active hello+") + punctuation.name;
      const RimeSessionId english = CreateSchemaSession(api, "linnet_en");
      Enter(api, english, "hello");
      const auto english_candidates = Candidates(api, english);
      const int english_selected = HighlightedCandidateIndex(api, english);
      if (english_selected < 0 ||
          static_cast<size_t>(english_selected) >= english_candidates.size()) {
        Fail(english_reason + " has no selected candidate");
      }
      const std::string expected_word =
          english_candidates[english_selected].text;
      if (api->process_key(english, punctuation.keycode,
                           punctuation.modifiers)) {
        Fail(english_reason +
             " was captured instead of returning punctuation to the host");
      }
      const std::string actual_word = TakeCommit(api, english, english_reason);
      if (actual_word != expected_word) {
        Fail(english_reason + " committed '" + actual_word + "' instead of '" +
             expected_word + "'");
      }
      const char* english_input = api->get_input(english);
      if ((english_input && *english_input != '\0') ||
          !Candidates(api, english).empty()) {
        Fail(english_reason +
             " did not clear input and menu on the same key event");
      }
      api->destroy_session(english);

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
      const bool handled =
          api->process_key(session, punctuation.keycode, punctuation.modifiers);
      if (handled == punctuation.identity_mapping) {
        Fail(reason + (punctuation.identity_mapping
                           ? " captured an identity symbol instead of "
                             "returning it to the host"
                           : " did not commit through the Chinese punctuator"));
      }
      const std::string expected =
          candidates[selected].text +
          (punctuation.identity_mapping ? "" : punctuation.chinese_commit);
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

    {
      const std::string idle_reason =
          std::string("idle Chinese punctuation ") + punctuation.name;
      const RimeSessionId idle =
          CreateSchemaSession(api, "linnet_zh_pinyin");
      const bool idle_handled = api->process_key(
          idle, punctuation.keycode, punctuation.modifiers);
      if (idle_handled == punctuation.identity_mapping) {
        Fail(idle_reason +
             (punctuation.identity_mapping
                  ? " was captured instead of reaching the host"
                  : " did not commit through the Chinese punctuator"));
      }
      if (punctuation.identity_mapping) {
        ExpectNoCommit(api, idle, idle_reason);
      } else if (TakeCommit(api, idle, idle_reason) !=
                 punctuation.chinese_commit) {
        Fail(idle_reason + " did not use its exact half-shape mapping");
      }
      const char* idle_input = api->get_input(idle);
      if ((idle_input && *idle_input != '\0') ||
          !Candidates(api, idle).empty()) {
        Fail(idle_reason + " retained hidden input-method state");
      }
      api->destroy_session(idle);
    }

    {
      const std::string idle_english_reason =
          std::string("idle Smart English punctuation ") + punctuation.name;
      const RimeSessionId idle_english = CreateSchemaSession(api, "linnet_en");
      if (api->process_key(idle_english, punctuation.keycode,
                           punctuation.modifiers)) {
        Fail(idle_english_reason +
             " was captured instead of reaching the host");
      }
      ExpectNoCommit(api, idle_english, idle_english_reason);
      const auto english_live =
          rime::Service::instance().GetSession(idle_english);
      if (!english_live || !english_live->context() ||
          !english_live->context()->input().empty() ||
          !english_live->context()->composition().empty() ||
          !Candidates(api, idle_english).empty()) {
        Fail(idle_english_reason + " retained hidden input-method state");
      }
      api->destroy_session(idle_english);
    }
  }

  {
    const RimeSessionId idle_apostrophe =
        CreateSchemaSession(api, "linnet_en");
    if (api->process_key(idle_apostrophe, XK_apostrophe, 0)) {
      Fail("idle Smart English apostrophe started a hidden spelling");
    }
    ExpectNoCommit(api, idle_apostrophe, "idle Smart English apostrophe");
    const auto live = rime::Service::instance().GetSession(idle_apostrophe);
    if (!live || !live->context() || !live->context()->input().empty() ||
        !live->context()->composition().empty() ||
        !Candidates(api, idle_apostrophe).empty()) {
      Fail("idle Smart English apostrophe retained input-method state");
    }
    api->destroy_session(idle_apostrophe);
  }

  const RimeSessionId full_shape =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  api->set_option(full_shape, "full_shape", true);
  Enter(api, full_shape, "shi");
  if (!api->process_key(full_shape, '=', 0) ||
      CurrentCandidatePage(api, full_shape, "full-shape next page") != 1) {
    Fail("full-shape mode displaced candidate paging");
  }
  if (!api->process_key(full_shape, '-', 0)) {
    Fail("full-shape mode did not accept previous-page navigation");
  }
  if (CurrentCandidatePage(api, full_shape, "full-shape previous page") != 0) {
    Fail("full-shape mode did not return to the previous candidate page");
  }
  api->clear_composition(full_shape);
  if (!api->process_key(full_shape, '-', 0) ||
      TakeCommit(api, full_shape, "idle full-shape punctuation") != "－") {
    Fail("idle full-shape punctuation lost the canonical mapping");
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
                                      const std::string& reason,
                                      bool configure_layout = false,
                                      bool linear = false,
                                      bool vertical = false) {
  const RimeSessionId session = CreateSchemaSession(api, "linnet_en");
  if (configure_layout) {
    api->set_option(session, "_linear", linear);
    api->set_option(session, "_vertical", vertical);
  }
  SelectNormalizedCandidate(api, session, "i", "I");
  ExpectPredictionMenu(api, session, reason);
  const char* input = api->get_input(session);
  if (input && *input != '\0') {
    Fail("passive prediction retained an active spelling after " + reason);
  }
  ExpectCompositionTag(session, "prediction", reason);
  ExpectSessionProperty(api, session, kPredictContextProperty, "i",
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

  const RimeSessionId focused_clear = CreatePassivePrediction(
      api, "focused clear_composition setup", true, true, false);
  if (!api->process_key(focused_clear, XK_Right, 0)) {
    Fail("focused clear_composition fixture did not navigate prediction");
  }
  ExpectSessionProperty(api, focused_clear, kPredictionNavigationProperty, "1",
                        "focused clear_composition setup");
  api->clear_composition(focused_clear);
  ExpectPassivePredictionExit(api, focused_clear,
                              "focused clear_composition");
  api->destroy_session(focused_clear);
}

void ExpectLifecycleRawExitContract(RimeApi_stdbool* api,
                                    bool switcher_fixture = false) {
  if (!RIME_API_AVAILABLE(api, commit_raw_input)) {
    Fail("librime does not expose the lifecycle raw-input exit owner");
  }
  if (api->commit_raw_input(0)) {
    Fail("lifecycle raw-input exit accepted an invalid session");
  }

  const RimeSessionId idle = CreateSchemaSession(api, "linnet_zh_pinyin");
  if (api->commit_raw_input(idle)) {
    Fail("idle lifecycle exit reported unread commit text");
  }
  ExpectNoCommit(api, idle, "idle lifecycle exit");
  ExpectMenuEmpty(api, idle, "idle lifecycle exit");
  api->destroy_session(idle);

  const RimeSessionId pinyin =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, pinyin, "shuru");
  const auto pending_pinyin = rime::Service::instance().GetSession(pinyin);
  if (!pending_pinyin || !pending_pinyin->HasPendingClientState()) {
    Fail("stale cleanup did not recognize pending full-pinyin input");
  }
  if (!api->commit_raw_input(pinyin) ||
      TakeCommit(api, pinyin, "full-pinyin lifecycle exit") != "shuru") {
    Fail("lifecycle exit selected or changed pending full-pinyin letters");
  }
  if (pending_pinyin->HasPendingClientState()) {
    Fail("completed full-pinyin exit remained pending for stale cleanup");
  }
  ExpectNoCommit(api, pinyin, "duplicate full-pinyin lifecycle exit");
  ExpectMenuEmpty(api, pinyin, "full-pinyin lifecycle exit");
  api->destroy_session(pinyin);

  const RimeSessionId dumb = CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, dumb, "shuru");
  api->set_option(dumb, "dumb", true);
  const bool dumb_committed = api->commit_raw_input(dumb);
  const std::string dumb_text = TakeOptionalCommit(api, dumb);
  if (!dumb_committed || dumb_text != "shuru") {
    Fail("lifecycle raw-input exit obeyed dumb commit suppression: got '" +
         dumb_text + "'");
  }
  if (!api->get_option(dumb, "dumb")) {
    Fail("lifecycle raw-input exit changed the caller-owned dumb option");
  }
  ExpectNoCommit(api, dumb, "duplicate dumb lifecycle exit");
  ExpectMenuEmpty(api, dumb, "dumb lifecycle exit");
  api->destroy_session(dumb);

  const RimeSessionId english = CreateSchemaSession(api, "linnet_en");
  Enter(api, english, "worl");
  const size_t completion = NormalizedCandidateIndex(api, english, "world");
  if (!api->highlight_candidate(english, completion)) {
    Fail("Smart English lifecycle fixture could not focus its completion");
  }
  if (!api->commit_raw_input(english) ||
      TakeCommit(api, english, "Smart English lifecycle exit") != "worl") {
    Fail("lifecycle exit accepted a focused Smart English completion");
  }
  ExpectNoCommit(api, english, "duplicate Smart English lifecycle exit");
  ExpectMenuEmpty(api, english, "Smart English lifecycle exit");
  api->destroy_session(english);

  const RimeSessionId apostrophe = CreateSchemaSession(api, "linnet_en");
  Enter(api, apostrophe, "don't");
  if (!api->commit_raw_input(apostrophe) ||
      TakeCommit(api, apostrophe, "apostrophe lifecycle exit") != "don't") {
    Fail("lifecycle exit changed an apostrophe-bearing English word");
  }
  ExpectNoCommit(api, apostrophe, "duplicate apostrophe lifecycle exit");
  api->destroy_session(apostrophe);

  const RimeSessionId edited = CreateSchemaSession(api, "linnet_en");
  Enter(api, edited, "worl");
  api->set_caret_pos(edited, 2);
  const bool edited_committed = api->commit_raw_input(edited);
  const std::string edited_text =
      TakeCommit(api, edited, "edited-caret lifecycle exit");
  if (!edited_committed || edited_text != "worl") {
    Fail("lifecycle exit changed raw text after caret editing: got '" +
         edited_text + "'");
  }
  ExpectNoCommit(api, edited, "duplicate edited-caret lifecycle exit");
  api->destroy_session(edited);

  const RimeSessionId inserted = CreateSchemaSession(api, "linnet_en");
  Enter(api, inserted, "worl");
  api->set_caret_pos(inserted, 2);
  if (!api->process_key(inserted, 'x', 0)) {
    Fail("edited-caret lifecycle fixture could not insert raw text");
  }
  const char* inserted_input = api->get_input(inserted);
  if (!inserted_input || std::string(inserted_input) != "woxrl" ||
      !api->commit_raw_input(inserted) ||
      TakeCommit(api, inserted, "middle-insert lifecycle exit") != "woxrl") {
    Fail("lifecycle exit lost a middle raw insertion");
  }
  api->destroy_session(inserted);

  const RimeSessionId deleted = CreateSchemaSession(api, "linnet_en");
  Enter(api, deleted, "worl");
  api->set_caret_pos(deleted, 2);
  if (!api->process_key(deleted, XK_Delete, 0)) {
    Fail("edited-caret lifecycle fixture could not delete raw text");
  }
  const char* deleted_input = api->get_input(deleted);
  if (!deleted_input || std::string(deleted_input) != "wol" ||
      !api->commit_raw_input(deleted) ||
      TakeCommit(api, deleted, "middle-delete lifecycle exit") != "wol") {
    Fail("lifecycle exit lost a middle raw deletion");
  }
  api->destroy_session(deleted);

  const RimeSessionId partial =
      CreateExplicitChinesePrefixFixture(api, "lifecycle partial fixture");
  if (!api->commit_raw_input(partial) ||
      TakeCommit(api, partial, "partial-confirmed lifecycle exit") !=
          "下周ii") {
    Fail("lifecycle exit lost the selected Chinese prefix or raw tail");
  }
  ExpectNoCommit(api, partial,
                 "duplicate partial-confirmed lifecycle exit");
  ExpectMenuEmpty(api, partial, "partial-confirmed lifecycle exit");
  api->destroy_session(partial);

  const RimeSessionId edited_tail =
      CreateExplicitChinesePrefixFixture(api, "edited raw-tail fixture");
  api->set_caret_pos(edited_tail, 5);
  if (!api->process_key(edited_tail, 'x', 0)) {
    Fail("partial-confirmed lifecycle fixture could not edit its raw tail");
  }
  const char* edited_tail_input = api->get_input(edited_tail);
  if (!edited_tail_input || std::string(edited_tail_input) != "xwvbixi" ||
      !api->commit_raw_input(edited_tail) ||
      TakeCommit(api, edited_tail, "edited raw-tail lifecycle exit") !=
          "下周ixi") {
    Fail("lifecycle exit lost a valid Chinese prefix after raw-tail editing");
  }
  api->destroy_session(edited_tail);

  const RimeSessionId edited_prefix =
      CreateExplicitChinesePrefixFixture(api, "edited selected-prefix fixture");
  api->set_caret_pos(edited_prefix, 2);
  if (!api->process_key(edited_prefix, 'x', 0)) {
    Fail("partial-confirmed lifecycle fixture could not edit its selected prefix");
  }
  const char* edited_prefix_input = api->get_input(edited_prefix);
  if (!edited_prefix_input ||
      std::string(edited_prefix_input) != "xwxvbii" ||
      !api->commit_raw_input(edited_prefix) ||
      TakeCommit(api, edited_prefix, "edited selected-prefix lifecycle exit") !=
          "xwxvbii") {
    Fail("lifecycle exit retained an invalidated Chinese prefix after editing");
  }
  api->destroy_session(edited_prefix);

  if (switcher_fixture) {
    const RimeSessionId switcher =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    Enter(api, switcher, "shuru");
    if (!api->process_key(switcher, XK_F4, 0) ||
        Candidates(api, switcher).empty()) {
      Fail("lifecycle fixture could not activate the schema switcher");
    }
    if (!api->commit_raw_input(switcher) ||
        TakeCommit(api, switcher, "switcher lifecycle exit") != "shuru") {
      Fail("lifecycle exit lost root input behind the active switcher");
    }
    ExpectNoCommit(api, switcher, "duplicate switcher lifecycle exit");
    ExpectMenuEmpty(api, switcher, "switcher lifecycle exit");

    if (!api->process_key(switcher, XK_F4, 0) ||
        Candidates(api, switcher).empty()) {
      Fail("idle lifecycle fixture could not reactivate the schema switcher");
    }
    const auto idle_switcher = rime::Service::instance().GetSession(switcher);
    if (!idle_switcher || idle_switcher->HasPendingClientState()) {
      Fail("zero-input schema switcher blocked stale-session cleanup");
    }
    if (api->commit_raw_input(switcher)) {
      Fail("idle schema switcher produced lifecycle commit text");
    }
    ExpectNoCommit(api, switcher, "idle switcher lifecycle exit");
    ExpectMenuEmpty(api, switcher, "idle switcher lifecycle exit");

    Enter(api, switcher, "ceshi");
    if (!api->process_key(switcher, XK_F4, 0) ||
        Candidates(api, switcher).empty()) {
      Fail("clear-composition fixture could not reactivate the schema switcher");
    }
    api->clear_composition(switcher);
    ExpectNoCommit(api, switcher, "active-switcher clear_composition");
    ExpectMenuEmpty(api, switcher, "active-switcher clear_composition");
    const char* cleared_input = api->get_input(switcher);
    if (cleared_input && *cleared_input) {
      Fail("clear_composition retained root input behind the switcher");
    }
    if (!api->process_key(switcher, XK_F4, 0) ||
        Candidates(api, switcher).empty()) {
      Fail("clear_composition left the schema switcher active or stranded");
    }
    api->clear_composition(switcher);
    api->destroy_session(switcher);

    const RimeSessionId partial_switcher =
        CreateExplicitChinesePrefixFixture(api, "partial switcher fixture");
    if (!api->process_key(partial_switcher, XK_F4, 0) ||
        Candidates(api, partial_switcher).empty() ||
        !api->process_key(partial_switcher, XK_F4, 0)) {
      Fail("partial lifecycle fixture could not change switcher highlight");
    }
    const auto pending_switcher =
        rime::Service::instance().GetSession(partial_switcher);
    if (!pending_switcher || !pending_switcher->HasPendingClientState() ||
        !api->commit_raw_input(partial_switcher) ||
        TakeCommit(api, partial_switcher,
                   "highlighted partial-switcher lifecycle exit") !=
            "下周ii") {
      Fail("lifecycle exit lost partial root input behind a changed switcher");
    }
    api->destroy_session(partial_switcher);
  }

  const RimeSessionId prediction = CreatePassivePrediction(
      api, "focused lifecycle prediction", true, true, false);
  const auto passive_state =
      rime::Service::instance().GetSession(prediction);
  if (!passive_state || passive_state->HasPendingClientState()) {
    Fail("zero-input passive prediction blocked stale-session cleanup");
  }
  if (!api->process_key(prediction, XK_Right, 0)) {
    Fail("lifecycle prediction fixture could not focus a candidate");
  }
  if (api->commit_raw_input(prediction)) {
    Fail("lifecycle exit committed a zero-input prediction");
  }
  ExpectPassivePredictionExit(api, prediction,
                              "focused lifecycle prediction");
  api->destroy_session(prediction);

  const RimeSessionId unfocused_prediction =
      CreatePassivePrediction(api, "unfocused lifecycle prediction");
  if (api->commit_raw_input(unfocused_prediction)) {
    Fail("lifecycle exit committed an unfocused zero-input prediction");
  }
  ExpectPassivePredictionExit(api, unfocused_prediction,
                              "unfocused lifecycle prediction");
  api->destroy_session(unfocused_prediction);

  const RimeSessionId queued = CreateSchemaSession(api, "linnet_en");
  Enter(api, queued, "i");
  const size_t queued_index = NormalizedCandidateIndex(api, queued, "I");
  if (!api->select_candidate(queued, queued_index)) {
    Fail("queued lifecycle fixture could not select its committed word");
  }
  ExpectPredictionMenu(api, queued, "queued lifecycle commit");
  if (api->commit_raw_input(queued)) {
    Fail("queued commit was misclassified as a new raw lifecycle commit");
  }
  const auto unread_queue = rime::Service::instance().GetSession(queued);
  if (!unread_queue || !unread_queue->HasPendingClientState()) {
    Fail("stale cleanup did not recognize unread committed text");
  }
  if (TakeCommit(api, queued, "queued lifecycle commit") != "I") {
    Fail("lifecycle exit lost or changed previously unread commit text");
  }
  if (unread_queue->HasPendingClientState()) {
    Fail("consumed commit queue remained pending for stale cleanup");
  }
  ExpectPassivePredictionExit(api, queued, "queued lifecycle commit");
  api->destroy_session(queued);

  const RimeSessionId queued_with_raw = CreateSchemaSession(api, "linnet_en");
  Enter(api, queued_with_raw, "i");
  const size_t queued_with_raw_index =
      NormalizedCandidateIndex(api, queued_with_raw, "I");
  if (!api->select_candidate(queued_with_raw, queued_with_raw_index) ||
      !api->process_key(queued_with_raw, 'a', 0) ||
      !api->commit_raw_input(queued_with_raw)) {
    Fail("queued lifecycle fixture could not add new raw input");
  }
  if (TakeCommit(api, queued_with_raw,
                 "queued commit plus raw lifecycle exit") != "Ia") {
    Fail("lifecycle exit reordered or lost unread commit plus new raw input");
  }
  const auto completed_queue =
      rime::Service::instance().GetSession(queued_with_raw);
  if (!completed_queue || completed_queue->HasPendingClientState()) {
    Fail("completed queued-plus-raw exit remained pending for stale cleanup");
  }
  api->destroy_session(queued_with_raw);
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

void ExpectPassivePredictionLayoutMatrix(RimeApi_stdbool* api) {
  struct LayoutCase {
    const char* name;
    bool linear;
    bool vertical;
    int previous_key;
    int next_key;
    int previous_page_key;
    int next_page_key;
    std::array<int, 2> unbound_keys;
  };
  // Match librime Selector's four layout maps. Linear lists use their
  // orthogonal axis for page movement; stacked lists leave that axis to the
  // host, which also gives users a direct way to dismiss passive prediction.
  constexpr std::array<LayoutCase, 4> layouts = {{
      {"horizontal-linear", true, false, XK_Left, XK_Right,
       XK_Up, XK_Down, {0, 0}},
      {"vertical-linear", true, true, XK_Up, XK_Down,
       XK_Right, XK_Left, {0, 0}},
      {"horizontal-stacked", false, false, XK_Up, XK_Down,
       0, 0, {XK_Left, XK_Right}},
      {"vertical-stacked", false, true, XK_Right, XK_Left,
       0, 0, {XK_Up, XK_Down}},
  }};

  for (const auto& layout : layouts) {
    const std::string reason =
        std::string("passive prediction ") + layout.name;
    const RimeSessionId navigation = CreatePassivePrediction(
        api, reason + " navigation", true, layout.linear, layout.vertical);
    if (CandidateOrigins(navigation).size() < 2) {
      Fail(reason + " fixture has fewer than two candidates");
    }
    if (!api->process_key(navigation, layout.next_key, 0) ||
        ReadCandidateNavigationState(navigation, reason + " next")
                .selected_index != 1 ||
        !api->process_key(navigation, layout.previous_key, 0) ||
        ReadCandidateNavigationState(navigation, reason + " previous")
                .selected_index != 0) {
      Fail(reason + " did not navigate exactly one candidate on its axis");
    }
    ExpectSessionProperty(api, navigation, kPredictionNavigationProperty, "1",
                          reason + " navigation");
    ExpectNoCommit(api, navigation, reason + " navigation");
    api->destroy_session(navigation);

    const RimeSessionId boundary = CreatePassivePrediction(
        api, reason + " leading boundary", true, layout.linear,
        layout.vertical);
    if (api->process_key(boundary, layout.previous_key, 0)) {
      Fail(reason + " consumed a leading-boundary arrow instead of exiting");
    }
    ExpectPassivePredictionExit(api, boundary, reason + " leading boundary");
    api->destroy_session(boundary);

    if (layout.next_page_key != 0) {
      const RimeSessionId paging = CreatePassivePrediction(
          api, reason + " paging", true, layout.linear, layout.vertical);
      const auto page_candidates = CandidateOrigins(paging);
      if (page_candidates.size() < 10 ||
          !api->process_key(paging, layout.next_page_key, 0)) {
        Fail(reason + " did not expose stock next-page prediction navigation");
      }
      const auto next_page =
          ReadCandidateNavigationState(paging, reason + " next page");
      if (next_page.selected_index == 0 ||
          !api->process_key(paging, layout.previous_page_key, 0) ||
          ReadCandidateNavigationState(paging, reason + " previous page")
                  .selected_index != 0) {
        Fail(reason + " did not restore stock previous-page prediction navigation");
      }
      ExpectNoCommit(api, paging, reason + " paging");
      api->destroy_session(paging);
    }

    for (const int keycode : layout.unbound_keys) {
      if (keycode == 0) continue;
      const RimeSessionId exit = CreatePassivePrediction(
          api, reason + " unbound exit", true, layout.linear,
          layout.vertical);
      if (api->process_key(exit, keycode, 0)) {
        Fail(reason + " consumed an unbound arrow instead of exiting");
      }
      ExpectPassivePredictionExit(api, exit, reason + " unbound exit");
      api->destroy_session(exit);
    }
  }
}

void ExpectPassivePredictionKeyboardSelection(RimeApi_stdbool* api) {
  ExpectPassivePredictionLayoutMatrix(api);

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
      CreatePassivePrediction(api, "focused prediction arrows",
                              true, true, false);
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
       std::array<std::pair<int, const char*>, 2>{{
           {XK_Left, "Left"},
           {XK_Right, "Right"},
       }}) {
    const auto before = ReadCandidateNavigationState(
        navigation, std::string("focused prediction ") + arrow.second);
    const size_t expected =
        arrow.first == XK_Left
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

void ExpectFrequentEnglishCompletions(RimeApi_stdbool* api) {
  for (const auto& sample :
       std::array<std::pair<const char*, const char*>, 6>{{
           {"kn", "know"}, {"lib", "library"},
           {"con", "contact"}, {"LIB", "LIBRARY"},
           {"suppor", "support"}, {"mater", "matter"},
       }}) {
    const auto session = CreateSchemaSession(api, "linnet_en");
    Enter(api, session, sample.first);
    const auto candidates = Candidates(api, session);
    const auto found = std::find_if(
        candidates.begin(), candidates.end(), [&](const auto& candidate) {
          return BaseText(candidate.text) == sample.second;
        });
    if (candidates.empty() || BaseText(candidates.front().text) != sample.first ||
        found == candidates.end() || found - candidates.begin() >= 3) {
      Fail(std::string("English suggestion did not preserve raw input and ") +
           "reach the first three candidates: " + sample.first);
    }
    api->destroy_session(session);
  }
  // Compare the complete reachable menu, not just the newly ranked first page.
  // Later expansion must not skip words that outrank an already emitted batch.
  std::set<std::string> original_words;
  for (bool weighted : {false, true}) {
    SetSchemaBool(api, "linnet_en", "translator/completion_by_weight", weighted);
    const auto session = CreateSchemaSession(api, "linnet_en");
    Enter(api, session, "co");
    std::set<std::string> words;
    for (const auto& candidate : Candidates(api, session)) {
      words.insert(BaseText(candidate.text));
    }
    api->destroy_session(session);
    if (!weighted) {
      original_words = std::move(words);
    } else if (words != original_words) {
      Fail("frequency completion changed the complete reachable candidate set");
    }
  }
  std::cout << "rime_smoke_test: English completion tail preserved "
            << original_words.size() << " distinct candidates\n";
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

void ExpectDefaultChinesePunctuationMode(RimeApi_stdbool* api,
                                         const char* schema_id) {
  const RimeSessionId session = CreateSchemaSession(api, schema_id);
  if (api->get_option(session, "ascii_punct")) {
    Fail(std::string(schema_id) +
         " unexpectedly started with English punctuation");
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
  ExpectDefaultChinesePunctuationMode(api, "linnet_zh");
}

std::string SimulateHostText(RimeApi_stdbool* api,
                             RimeSessionId session,
                             const std::string& input);
int PrintableModifier(unsigned char ch);

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
    if (!api->process_key(session, byte, PrintableModifier(byte))) {
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

void ExpectStatefulChinesePunctuation(RimeApi_stdbool* api) {
  const auto expect_cleared = [&](RimeSessionId session,
                                  const std::string& reason) {
    const auto state = ReadKeyInteractionSnapshot(api, session);
    if (!state.input.empty() || state.composition_size != 0 ||
        !state.candidates.empty()) {
      Fail(reason + " retained hidden input-method state");
    }
  };

  const RimeSessionId quotes =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  for (const char* expected : {"“", "”"}) {
    if (!api->process_key(quotes, '"', kShiftMask) ||
        TakeCommit(api, quotes, "idle Chinese quote pair") != expected) {
      Fail("idle Chinese quote pair lost its opening/closing state");
    }
    ExpectNoCommit(api, quotes, "duplicate idle Chinese quote pair");
    expect_cleared(quotes, "idle Chinese quote pair");
  }
  api->destroy_session(quotes);

  const RimeSessionId backtick =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  if (!api->process_key(backtick, XK_grave, 0) ||
      TakeCommit(api, backtick, "idle Chinese backtick") != "·") {
    Fail("idle Chinese backtick did not use its half-shape mapping");
  }
  ExpectNoCommit(api, backtick, "duplicate idle Chinese backtick");
  expect_cleared(backtick, "idle Chinese backtick");
  api->destroy_session(backtick);
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
    Enter(api, session, std::string(kDefaultPinyinReversePrefix) + "week");
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
    Enter(api, session, std::string(kDefaultPinyinReversePrefix) + "uuid");
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
  Enter(api, full_pinyin, std::string(kDefaultPinyinReversePrefix) + "xq");
  const auto prefixed_shortcut = Candidates(api, full_pinyin);
  if (std::any_of(prefixed_shortcut.begin(), prefixed_shortcut.end(),
                  [](const auto& item) {
                    return IsWeekdayShortcutCandidate(BaseText(item.text));
                  })) {
    Fail("full pinyin let the xq date command enter reverse lookup");
  }
  Enter(api, full_pinyin, std::string(kDefaultPinyinReversePrefix) + "uuid");
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
  };
  for (const auto& profile :
       std::vector<ProfileCase>{
           {"linnet_zh_pinyin", "suanfa"},
           {"linnet_zh", "srfa"},
           {"linnet_zh_flypy", "srfa"},
           {"linnet_zh_mspy", "srfa"},
           {"linnet_zh_sogou", "srfa"},
           {"linnet_zh_abc", "spfa"},
           {"linnet_zh_ziguang", "slfa"},
           {"linnet_zh_jiajia", "scfa"},
       }) {
    const RimeSessionId session = CreateSchemaSession(api, profile.schema);
    Enter(api, session,
          std::string(kDefaultPinyinReversePrefix) + profile.code);
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
    Enter(api, session, std::string(";") + profile.code);
    const auto retired_trigger = CandidateOrigins(session);
    if (std::any_of(retired_trigger.begin(), retired_trigger.end(),
                    [](const auto& candidate) {
                      return candidate.genuine_type == "linnet_pinyin";
                    })) {
      Fail(std::string(profile.schema) +
           " retained semicolon after the product default moved to vertical bar");
    }
    api->destroy_session(session);
  }

  for (const auto& profile :
       std::vector<ProfileCase>{
           {"linnet_zh_pinyin", "suan'fa"},
           {"linnet_zh", "sr'fa"},
           {"linnet_zh_jiajia", "sc'fa"},
       }) {
    const RimeSessionId session = CreateSchemaSession(api, profile.schema);
    Enter(api, session,
          std::string(kDefaultPinyinReversePrefix) + profile.code);
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

  for (const auto& profile :
       std::vector<ProfileCase>{
           {"linnet_zh_mspy", "m;tm"},
           {"linnet_zh_sogou", "m;tm"},
           {"linnet_zh_ziguang", "m;tf"},
       }) {
    const RimeSessionId session = CreateSchemaSession(api, profile.schema);
    Enter(api, session,
          std::string(kDefaultPinyinReversePrefix) + profile.code);
    const auto origins = CandidateOrigins(session);
    if (std::none_of(origins.begin(), origins.end(), [](const auto& candidate) {
          return BaseText(candidate.text) == "tomorrow" &&
                 candidate.genuine_type == "linnet_pinyin";
        })) {
      Fail(std::string(profile.schema) +
           " lost the semicolon inside its active double-pinyin code");
    }
    Enter(api, session, std::string(";") + profile.code);
    const auto retired = CandidateOrigins(session);
    if (std::any_of(retired.begin(), retired.end(), [](const auto& candidate) {
          return candidate.genuine_type == "linnet_pinyin";
        })) {
      Fail(std::string(profile.schema) +
           " retained semicolon after the alternate trigger deployment");
    }
    api->destroy_session(session);
  }

  const RimeSessionId decomposed_tone =
      CreateSchemaSession(api, "linnet_zh_pinyin");
  Enter(api, decomposed_tone, "|me");
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
  Enter(api, session, code);
  const auto automatic = CandidateOrigins(session, 256);
  if (std::none_of(automatic.begin(), automatic.end(), [](const auto& item) {
        return BaseText(item.text) == "algorithm" &&
               item.genuine_type == "linnet_pinyin";
      })) {
    Fail("Smart English lost its automatic selected-profile lookup for " +
         profile);
  }
  api->destroy_session(session);

  if (profile == "jiajia") {
    const RimeSessionId full_pinyin = CreateSchemaSession(api, "linnet_en");
    Enter(api, full_pinyin, "suanfa");
    const auto candidates = CandidateOrigins(full_pinyin, 256);
    if (std::any_of(candidates.begin(), candidates.end(), [](const auto& item) {
          return BaseText(item.text) == "algorithm" &&
                 item.genuine_type == "linnet_pinyin";
        })) {
      Fail("Smart English ignored the selected Jiajia Prism");
    }
    api->destroy_session(full_pinyin);
  }

  const RimeSessionId idle_semicolon = CreateSchemaSession(api, "linnet_en");
  if (api->process_key(idle_semicolon, ';', 0)) {
    Fail("Smart English captured an idle semicolon for " + profile);
  }
  const auto idle_after = ReadKeyInteractionSnapshot(api, idle_semicolon);
  ExpectNoCommit(api, idle_semicolon, "idle English semicolon for " + profile);
  api->destroy_session(idle_semicolon);
  if (!idle_after.input.empty() || idle_after.composition_size != 0 ||
      !idle_after.candidates.empty()) {
    Fail("Smart English retained hidden state after an idle semicolon for " +
         profile);
  }

  const RimeSessionId active_semicolon = CreateSchemaSession(api, "linnet_en");
  Enter(api, active_semicolon, "hello");
  const auto english_candidates = Candidates(api, active_semicolon);
  const int selected = HighlightedCandidateIndex(api, active_semicolon);
  if (selected < 0 ||
      static_cast<size_t>(selected) >= english_candidates.size()) {
    Fail("Smart English semicolon fixture has no candidate for " + profile);
  }
  const std::string expected_word = english_candidates[selected].text;
  if (api->process_key(active_semicolon, ';', 0)) {
    Fail("Smart English captured an active semicolon for " + profile);
  }
  if (TakeCommit(api, active_semicolon,
                 "active English semicolon for " + profile) != expected_word) {
    Fail("Smart English semicolon did not commit the selected word for " +
         profile);
  }
  const auto active_after = ReadKeyInteractionSnapshot(api, active_semicolon);
  ExpectNoCommit(api, active_semicolon,
                 "duplicate active English semicolon for " + profile);
  api->destroy_session(active_semicolon);
  if (!active_after.input.empty() || active_after.composition_size != 0 ||
      !active_after.candidates.empty()) {
    Fail("Smart English retained hidden state after an active semicolon for " +
         profile);
  }

  const RimeSessionId chinese =
      CreateSchemaSession(api, expected_chinese_schema.c_str());
  Enter(api, chinese, prefix + code);
  const auto chinese_lookup = CandidateOrigins(chinese, 256);
  if (std::none_of(chinese_lookup.begin(), chinese_lookup.end(),
                   [](const auto& item) {
                     return BaseText(item.text) == "algorithm" &&
                            item.genuine_type == "linnet_pinyin";
                   })) {
    Fail("Chinese mode lost explicit pinyin reverse lookup for " + profile);
  }
  if (profile == "microsoft") {
    Enter(api, chinese, prefix + "m;tm");
    const auto punctuation_code = CandidateOrigins(chinese, 256);
    if (std::none_of(punctuation_code.begin(), punctuation_code.end(),
                     [](const auto& item) {
                       return BaseText(item.text) == "tomorrow" &&
                              item.genuine_type == "linnet_pinyin";
                     })) {
      Fail("Chinese Microsoft reverse lookup lost its internal semicolon");
    }
  }
  api->destroy_session(chinese);

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
  Enter(api, reviewed_session,
        std::string(kDefaultPinyinReversePrefix) + kReviewedLongKey);
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
  Enter(api, at_limit, std::string(kDefaultPinyinReversePrefix) + "probe");
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
  Enter(api, over_limit,
        std::string(kDefaultPinyinReversePrefix) + "probe");
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
  Enter(api, session,
        std::string(kDefaultPinyinReversePrefix) + "ypjisr");
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
          candidate->comment().empty() ||
          candidate->comment().front() != '\x1d' ||
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
           << "  \"ascii_composer/switch_key/Caps_Lock\": commit_code\n"
           << "  \"ascii_composer/switch_key/Shift_L\": commit_code\n"
           << "  \"ascii_composer/switch_key/Shift_R\": commit_code\n"
           << "  \"linnet/recognizer_patterns/zz_code_token\": \"^(?:(?:www[.]|https?:|ftp[.:]|mailto:|file:).*|(?:[a-z]+[A-Z]|[A-Z][a-z]+[A-Z]|[A-Z]{2,}[a-z]|v[0-9]+|[A-Z][A-Za-z]*[0-9]|[A-Z]{2,}[._/@:+-])[0-9A-Za-z._/@:+?&=%#~-]*)$\"\n"
           << "  \"menu/page_size\": 5\n";
  if (original_index + 1 >= kProductSchemaIDs.size() ||
      schema_id != std::string(kProductSchemaIDs[original_index])) {
    Fail("fast reload profile is outside the canonical schema order");
  }
  for (size_t index = 0; index < kProductSchemaIDs.size(); ++index) {
    size_t source_index = index;
    if (index == 0) {
      source_index = original_index;
    } else if (index == original_index) {
      source_index = 0;
    }
    defaults << "  \"schema_list/@" << index << "/schema\": \""
             << kProductSchemaIDs[source_index] << "\"\n";
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
      << "  \"linnet_pinyin/prism\": \"" << schema_id << "\"\n"
      << "  \"linnet_mode_switch/chinese_schema\": \"" << schema_id
      << "\"\n"
      << "  \"linnet_english_interaction/sentence_capitalization\": false\n"
      << "  \"linnet_english_interaction/tab_behavior\": \"pass\"\n"
      << "  \"linnet_english_interaction/show_ipa\": false\n"
      << "  \"linnet_english_interaction/show_translation\": false\n"
      << "  \"switches/@1/reset\": 0\n"
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
      config->GetBool("linnet_english_interaction/spelling_correction", &value) ||
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
  ExpectCandidate(api, english_session, "suanfa", "algorithm");
  api->destroy_session(english_session);

  std::cout << "rime_smoke_test: exact-11 targeted config reload samples="
            << kSamples << " p95=" << p95 << "ms max=" << maximum
            << "ms: PASS\n";
}

std::map<std::string, std::string> LoadFormalProfileReviewedInputs() {
  constexpr char kPath[] = "tests/fixtures/chinese_profile_golden.tsv";
  std::ifstream input(kPath);
  if (!input) {
    Fail("the fixed Chinese profile fixture is missing");
  }
  std::map<std::string, std::string> result;
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line.front() == '#' ||
        line.rfind("case_id\t", 0) == 0) {
      continue;
    }
    std::istringstream row(line);
    std::array<std::string, 6> fields;
    for (auto& field : fields) {
      if (!std::getline(row, field, '\t')) {
        Fail("the fixed Chinese profile fixture is not strict six-column TSV");
      }
    }
    std::string trailing;
    if (std::getline(row, trailing, '\t')) {
      Fail("the fixed Chinese profile fixture has an extra column");
    }
    if (fields[0] != "c001") continue;
    if (fields[1] != "canonical:daily" || fields[4] != "你好" ||
        fields[2].empty() || fields[3].empty() ||
        !result.emplace(fields[2], fields[3]).second) {
      Fail("the fixed Chinese profile fixture has an invalid c001 owner row");
    }
  }
  if (result.size() != 8) {
    Fail("the fixed Chinese profile fixture does not own all eight spellings");
  }
  return result;
}

std::string PagingInputForProfile(RimeApi_stdbool* api,
                                  const std::string& schema_id,
                                  const std::string& reviewed) {
  for (size_t length = 1; length <= reviewed.size(); ++length) {
    const std::string input = reviewed.substr(0, length);
    const RimeSessionId session =
        CreateSchemaSession(api, schema_id.c_str());
    Enter(api, session, input);
    const size_t candidates = CandidateOrigins(session).size();
    api->destroy_session(session);
    if (candidates >= 10) return input;
  }
  Fail(schema_id +
       " has no reviewed prefix with a second candidate page");
}

void ExpectFormalProfileCommitKeys(RimeApi_stdbool* api,
                                   const std::string& schema_id,
                                   const std::string& input) {
  for (const auto& idle_key :
       std::array<std::pair<int, const char*>, 4>{{
           {XK_space, "Space"},
           {kReturn, "Return"},
           {kTab, "Tab"},
           {kEscape, "Escape"},
       }}) {
    const std::string reason = schema_id + " idle " + idle_key.second;
    const RimeSessionId idle = CreateSchemaSession(api, schema_id.c_str());
    if (api->process_key(idle, idle_key.first, 0)) {
      Fail(reason + " was captured instead of reaching the host");
    }
    ExpectNoCommit(api, idle, reason);
    const auto after = ReadKeyInteractionSnapshot(api, idle);
    api->destroy_session(idle);
    if (!after.input.empty() || after.composition_size != 0 ||
        !after.candidates.empty()) {
      Fail(reason + " retained hidden input-method state");
    }
  }

  {
    const std::string reason = schema_id + " active Space";
    const RimeSessionId session = CreateSchemaSession(api, schema_id.c_str());
    Enter(api, session, input);
    const auto candidates = Candidates(api, session);
    const int selected = HighlightedCandidateIndex(api, session);
    if (selected < 0 || static_cast<size_t>(selected) >= candidates.size() ||
        !api->process_key(session, XK_space, 0) ||
        TakeCommit(api, session, reason) != candidates[selected].text) {
      Fail(reason + " did not commit the selected candidate exactly once");
    }
    ExpectNoCommit(api, session, "duplicate " + reason);
    api->destroy_session(session);
  }

  {
    const std::string reason = schema_id + " active Return";
    const RimeSessionId session = CreateSchemaSession(api, schema_id.c_str());
    Enter(api, session, input);
    if (!api->process_key(session, kReturn, 0) ||
        TakeCommit(api, session, reason) != input) {
      Fail(reason + " did not commit the unconfirmed spelling verbatim");
    }
    ExpectNoCommit(api, session, "duplicate " + reason);
    api->destroy_session(session);
  }

  {
    const std::string reason = schema_id + " active Tab";
    const RimeSessionId session = CreateSchemaSession(api, schema_id.c_str());
    api->set_option(session, "_linear", true);
    api->set_option(session, "_vertical", false);
    Enter(api, session, input);
    const auto before = ReadCandidateNavigationState(session, reason);
    if (CandidateOrigins(session).size() < 2 ||
        !api->process_key(session, kTab, 0)) {
      Fail(reason + " did not expose candidate navigation");
    }
    const auto after = ReadCandidateNavigationState(session, reason);
    if (before.selected_index != 0 || after.selected_index != 1 ||
        after.caret_position != before.caret_position) {
      Fail(reason + " did not move exactly one candidate");
    }
    ExpectNoCommit(api, session, reason);
    api->destroy_session(session);
  }

  {
    const std::string reason = schema_id + " active Escape";
    const RimeSessionId session = CreateSchemaSession(api, schema_id.c_str());
    Enter(api, session, input);
    if (!api->process_key(session, kEscape, 0)) {
      Fail(reason + " did not cancel the active composition");
    }
    ExpectNoCommit(api, session, reason);
    const auto after = ReadKeyInteractionSnapshot(api, session);
    api->destroy_session(session);
    if (!after.input.empty() || after.composition_size != 0 ||
        !after.candidates.empty()) {
      Fail(reason + " retained hidden input-method state");
    }
  }
}

void ExpectFormalProfileSymbolKeys(RimeApi_stdbool* api,
                                   const std::string& schema_id,
                                   const std::string& input,
                                   bool semicolon_is_spelling) {
  const std::array<std::pair<char, const char*>, 5> symbols = {{
      {'/', "/"}, {',', "，"}, {'.', "。"}, {':', "："}, {';', "；"},
  }};
  for (const auto& mapping : symbols) {
    const char symbol = mapping.first;
    if (symbol == ';' && semicolon_is_spelling) continue;
    const std::string reason =
        schema_id + " active host symbol " + std::string(1, symbol);
    const RimeSessionId session = CreateSchemaSession(api, schema_id.c_str());
    Enter(api, session, input);
    const auto candidates = Candidates(api, session);
    const int selected = HighlightedCandidateIndex(api, session);
    if (selected < 0 || static_cast<size_t>(selected) >= candidates.size()) {
      Fail(reason + " has no selected Chinese candidate");
    }
    const bool handled = api->process_key(
        session, symbol,
        PrintableModifier(static_cast<unsigned char>(symbol)));
    std::string actual = TakeCommit(api, session, reason);
    if (!handled) actual.push_back(symbol);
    const std::string expected = candidates[selected].text + mapping.second;
    if (actual != expected) {
      Fail(reason + " produced '" + actual + "' instead of '" + expected + "'");
    }
    ExpectNoCommit(api, session, "duplicate " + reason);
    const auto after = ReadKeyInteractionSnapshot(api, session);
    api->destroy_session(session);
    if (!after.input.empty() || after.composition_size != 0 ||
        !after.candidates.empty()) {
      Fail(reason + " retained hidden input-method state");
    }
  }

  for (const auto& spelling :
       std::array<std::pair<char, bool>, 3>{{
           {'\'', true},
           {';', semicolon_is_spelling},
           {'`', true},
       }}) {
    if (!spelling.second) continue;
    const std::string reason = schema_id + " active spelling separator " +
                               std::string(1, spelling.first);
    const RimeSessionId session = CreateSchemaSession(api, schema_id.c_str());
    Enter(api, session, input);
    if (!api->process_key(session, spelling.first, 0)) {
      Fail(reason + " did not remain in the schema spelling");
    }
    ExpectNoCommit(api, session, reason);
    const auto after = ReadCompositionEditingState(session, reason);
    api->destroy_session(session);
    if (after.input != input + spelling.first ||
        after.caret_position != after.input.size()) {
      Fail(reason + " did not preserve its exact active spelling");
    }
  }
}

void ExpectFormalSingleLetterMatrix(RimeApi_stdbool* api) {
  for (const auto& schema_id : RuntimeChineseSchemaIDs(api)) {
    const RimeSessionId session =
        CreateSchemaSession(api, schema_id.c_str());
    size_t covered_letters = 0;
    size_t english_fallback_letters = 0;
    for (char letter = 'a'; letter <= 'z'; ++letter) {
      if (ExpectSingleLetterChinesePriority(api, session, schema_id, letter)) {
        ++covered_letters;
      } else {
        ++english_fallback_letters;
      }
    }
    api->destroy_session(session);
    if (covered_letters + english_fallback_letters != 26 ||
        covered_letters == 0) {
      Fail("single-letter priority matrix found no Chinese candidates in " +
           schema_id);
    }
  }
}

void ExpectFormalProfileKeyMatrix(RimeApi_stdbool* api) {
  const auto schemas = RuntimeChineseSchemaIDs(api);
  const auto reviewed_inputs = LoadFormalProfileReviewedInputs();
  for (const auto& schema_id : schemas) {
    const auto reviewed = reviewed_inputs.find(schema_id);
    if (reviewed == reviewed_inputs.end()) {
      Fail("the fixed profile fixture has no reviewed input for " + schema_id);
    }
    const RimeSessionId schema_session =
        CreateSchemaSession(api, schema_id.c_str());
    const auto live = rime::Service::instance().GetSession(schema_session);
    std::string alphabet;
    if (!live || !live->schema() || !live->schema()->config() ||
        !live->schema()->config()->GetString("speller/alphabet", &alphabet)) {
      Fail(schema_id + " does not publish its formal speller alphabet");
    }
    for (char letter = 'a'; letter <= 'z'; ++letter) {
      if (alphabet.find(letter) == std::string::npos) {
        Fail(schema_id + " formal alphabet lost key " +
             std::string(1, letter));
      }
    }
    const bool semicolon_is_spelling = alphabet.find(';') != std::string::npos;
    api->destroy_session(schema_session);

    const std::string paging_input =
        PagingInputForProfile(api, schema_id, reviewed->second);
    ExpectCandidatePagingShortcuts(api, schema_id.c_str(), paging_input);
    ExpectCandidatePagingBoundaryNormalInput(
        api, schema_id.c_str(), paging_input);
    ExpectNineCandidateSelectKeys(api, schema_id.c_str(), paging_input);
    ExpectFormalProfileCommitKeys(api, schema_id, paging_input);
    ExpectFormalProfileSymbolKeys(
        api, schema_id, paging_input, semicolon_is_spelling);

    // With no adjacent candidate page, these keys use ordinary Chinese
    // punctuation or the host-owned ASCII path. Slash, '-' and '=' remain
    // ASCII by design.
    const std::array<std::pair<char, const char*>, 10> idle_symbols = {{
        {'/', "/"}, {',', "，"}, {'.', "。"}, {':', "："}, {';', "；"},
        {'\'', "‘"}, {'[', "【"}, {']', "】"}, {'-', "-"}, {'=', "="},
    }};
    for (const auto& mapping : idle_symbols) {
      const char symbol = mapping.first;
      const std::string reason = schema_id + " idle identity symbol " + symbol;
      const RimeSessionId idle = CreateSchemaSession(api, schema_id.c_str());
      const bool handled = api->process_key(
          idle, symbol, PrintableModifier(static_cast<unsigned char>(symbol)));
      std::string actual = TakeOptionalCommit(api, idle);
      if (!handled) actual.push_back(symbol);
      if (actual != mapping.second) {
        api->destroy_session(idle);
        Fail(reason + " produced '" + actual + "' instead of '" +
             mapping.second + "'");
      }
      const auto after = ReadKeyInteractionSnapshot(api, idle);
      api->destroy_session(idle);
      if (!after.input.empty() || after.composition_size != 0 ||
          !after.candidates.empty()) {
        Fail(reason + " retained hidden input-method state");
      }
    }

    for (const std::string& numeric : {"1,000", "3.14", "12:30"}) {
      const RimeSessionId numeric_session =
          CreateSchemaSession(api, schema_id.c_str());
      api->set_option(numeric_session, "ascii_punct", true);
      const std::string actual =
          SimulateHostText(api, numeric_session, numeric);
      api->destroy_session(numeric_session);
      if (actual != numeric) {
        Fail(schema_id + " English-punctuation mode changed numeric input '" +
             numeric + "' to '" + actual + "'");
      }
    }
  }
}

class SyncFaultDb : public rime::UserDbWrapper<rime::LevelDb> {
 public:
  SyncFaultDb(const rime::path& directory, const std::string& name)
      : UserDbWrapper(directory / (name + ".userdb"), name) {}
  int writes_until_throw = 0;
  bool Update(const std::string& key, const std::string& value) override {
    if (writes_until_throw > 0 && --writes_until_throw == 0)
      throw std::runtime_error("injected sync write exception");
    return rime::LevelDb::Update(key, value);
  }
};

class SyncFaultDbFactory : public rime::Db::Component {
 public:
  rime::Db* Create(const std::string& name) override {
    return new SyncFaultDb(rime::Service::instance().deployer().user_data_dir, name);
  }
};

void ExpectSessionIndependentLearningSync(RimeApi_stdbool* api) {
  api->cleanup_all_sessions();
  const auto directory = rime::Service::instance().deployer().user_data_dir /
                         "session-independent-sync";
  const auto peer = directory / "other-device";
  std::filesystem::create_directories(peer);
  const char* names[] = {"linnet_zh", "linnet_en", nullptr};
  for (const char* name : {names[0], names[1]}) {
    std::ofstream remote(peer / (std::string(name) + ".userdb.txt"));
    remote << "#@/db_name\t" << name << "\n#@/db_type\tuserdb\n#@/tick\t10\n"
              "syncprobe \tSyncProbe\tc=3 d=1 t=10\n";
  }
  auto* component = dynamic_cast<rime::UserDictionaryComponent*>(
      rime::UserDictionary::Require("user_dictionary"));
  if (!component) Fail("learning dictionary factory unavailable");
  const std::string sync_directory = directory.string();
  Nanoseconds::rep maximum_step = 0;
  int maximum_step_result = 0;
  for (bool change_client : {false, true}) {
    bool changed = false;
    int result = 1;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while ((result == 1 || result == 3) && std::chrono::steady_clock::now() < deadline) {
      const auto before = std::chrono::steady_clock::now();
      result = api->sync_user_data_step(sync_directory.c_str(), names);
      const auto elapsed = std::chrono::duration_cast<Nanoseconds>(
          std::chrono::steady_clock::now() - before).count();
      if (elapsed > maximum_step) { maximum_step = elapsed; maximum_step_result = result; }
      if (change_client && !changed && result == 1 &&
          component->GetDb("linnet_en", "userdb")->loaded()) {
        const auto session = CreateSchemaSession(api, "linnet_zh_pinyin");
        Enter(api, session, "niha");
        api->clear_composition(session);
        if (!api->select_schema(session, "linnet_en")) Fail("cannot switch test client");
        Enter(api, session, "test");
        NormalizedCandidateIndex(api, session, "test");
        api->clear_composition(session);
        api->destroy_session(session);
        changed = true;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    if (result != 0 || (change_client && !changed))
      Fail("learning synchronization still depends on input sessions");
    for (const char* name : {names[0], names[1]}) {
      const auto exported = directory / rime::Service::instance().deployer().user_id /
                            (std::string(name) + ".userdb.txt");
      auto database = component->GetDb(name, "userdb");
      std::string value;
      if (!std::filesystem::exists(exported) ||
          (!database->loaded() && !database->Open()) ||
          !database->Fetch("syncprobe \tSyncProbe", &value))
        Fail("session-independent sync did not import and export both learning databases");
      if (!database->Close()) Fail("cannot close isolated verification database");
    }
  }
  // A first English input arriving during a background open must share the
  // same connection, not fail on a competing LevelDB file lock.
  rime::an<rime::Db> prepared;
  component->PrepareDb("linnet_en", &prepared);
  const auto input_started = std::chrono::steady_clock::now();
  const auto first_english = CreateSchemaSession(api, "linnet_en");
  Enter(api, first_english, "test");
  NormalizedCandidateIndex(api, first_english, "test");
  const auto first_input_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - input_started).count();
  if (!component->PrepareDb("linnet_en", &prepared) || !prepared || !prepared->loaded() ||
      prepared != component->GetDb("linnet_en", "userdb") || first_input_ms > 100)
    Fail("first input did not share the background learning database open");
  api->clear_composition(first_english);
  api->destroy_session(first_english);
  prepared.reset();
  std::cout << "first English input during cold open ms=" << first_input_ms << '\n';
  std::cout << "cold-start maximum step ns=" << maximum_step
            << " result=" << maximum_step_result << std::endl;
  if (maximum_step > 15'000'000) Fail("cold-start sync step exceeded 15ms");
  std::cout << "session-independent sync: PASS; maximum step ns=" << maximum_step << '\n';
}

void ExpectLiveUserDataSync(RimeApi_stdbool* api) {
  static_assert(offsetof(RimeApi_stdbool, sync_user_data_step) >
                offsetof(RimeApi_stdbool, commit_raw_input), "Rime API additions must be append-only");
  if (api->start_maintenance(false)) api->join_maintenance_thread();
  ExpectSessionIndependentLearningSync(api);
  const auto chinese = CreateSchemaSession(api, "linnet_zh_pinyin");
  const auto english = CreateSchemaSession(api, "linnet_en");
  auto* component = dynamic_cast<rime::UserDictionaryComponent*>(
      rime::UserDictionary::Require("user_dictionary"));
  if (!component) Fail("user dictionary component unavailable");
  const auto database = component->GetDb("linnet_zh", "userdb");
  auto* transaction = dynamic_cast<rime::Transactional*>(database.get());
  if (!transaction) Fail("the live dictionary is not transactional");

  // Space commits a real word but keeps its learning reversible. Stopping here
  // must not require another key or a session restart before cloud sync works.
  {
    const auto directory = rime::Service::instance().deployer().user_data_dir / "idle-sync";
    std::filesystem::create_directories(directory);
    const auto sync_directory = directory.string();
    const char* names[] = {"linnet_zh", "linnet_en", nullptr};
    auto learning_rows = [&] {
      std::map<std::string, std::string> rows;
      auto query = database->QueryAll();
      std::string key, value;
      while (query && query->GetNextRecord(&key, &value)) rows.emplace(key, value);
      return rows;
    };
    const auto before = learning_rows();
    Enter(api, chinese, "nihao");
    api->process_key(chinese, ' ', 0);
    if (TakeCommit(api, chinese) != "你好" || !transaction->in_transaction())
      Fail("space commit did not create real reversible learning");
    for (int index = 0; index < 30; ++index) {
      const int result = api->sync_user_data_step(sync_directory.c_str(), names);
      if ((result != 1 && result != 3) || !transaction->in_transaction())
        Fail("sync ended learning before the undo window expired");
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    int result = 1;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    do {
      result = api->sync_user_data_step(sync_directory.c_str(), names);
      if (result != 1 && result != 3) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    } while (std::chrono::steady_clock::now() < deadline);
    if (result != 0 || transaction->in_transaction() || learning_rows() == before)
      Fail("idle committed learning did not synchronize without another key: result=" +
           std::to_string(result) + ", transaction=" +
           std::to_string(transaction->in_transaction()) + ", changed=" +
           std::to_string(learning_rows() != before));
    const auto learned = learning_rows();
    const auto exported = directory / rime::Service::instance().deployer().user_id /
                          "linnet_zh.userdb.txt";
    std::ifstream stream(exported);
    const std::string contents((std::istreambuf_iterator<char>(stream)), {});
    for (const auto& row : learned) {
      if (contents.find(row.first + '\t' + row.second + '\n') == std::string::npos)
        Fail("idle sync omitted committed learning from its export");
    }
    std::cout << "idle learning sync: PASS; undo window preserved and key-free export\n";
  }
  // A cooperative merge must agree with one uninterrupted upstream merger
  // even when pre-existing, equally weighted rows span several work slices.
  // The reference uses the real implementation, not a copied decay formula.
  constexpr size_t existing_rows = 129;
  const std::string local_value = "c=7 d=5 t=10";
  const std::string remote_value = "c=7 d=1 t=1000";
  std::vector<std::pair<std::string, std::string>> expected_existing;
  std::vector<std::string> recovery_failures;
  using SyncRows = std::map<std::string, std::string>;
  auto read_rows = [](rime::Db* db) {
    SyncRows rows;
    for (const char* prefix : {"tong bu bi dui \t", "yun tong bu ce shi \t"}) {
      const auto query = db->Query(prefix);
      if (!query) Fail("cannot query the isolated learning rows");
      std::string key, value;
      while (query->GetNextRecord(&key, &value)) rows.emplace(key, value);
    }
    return rows;
  };
  auto record_failure = [&](const std::string& message) {
    recovery_failures.push_back(message);
    std::cerr << "live-sync regression: " << message << '\n';
  };
  auto expect_view = [&](const std::string& label, rime::Db* db,
                         const SyncRows& expected, const std::string& expected_tick) {
    size_t mismatches = 0;
    std::string value, clock;
    for (const auto& [key, wanted] : expected)
      if (!db->Fetch(key, &value) || value != wanted) ++mismatches;
    const auto queried = read_rows(db);
    db->MetaFetch("/tick", &clock);
    if (mismatches || queried != expected || clock != expected_tick)
      record_failure(label + ": Fetch mismatches=" + std::to_string(mismatches) +
          "/" + std::to_string(expected.size()) + ", Query rows=" +
          std::to_string(queried.size()) + ", Query equals oracle=" +
          (queried == expected ? "true" : "false") + ", tick=" + clock +
          ", expected tick=" + expected_tick);
  };
  auto existing_key = [](size_t index) {
    return "tong bu bi dui \t同步对照" + std::to_string(1000 + index) + "\"\\尾";
  };
  auto remote_key = [](size_t index) {
    return "yun tong bu ce shi \t云同步测试" + std::to_string(index);
  };
  SyncRows expected_visible;
  auto* db_factory = rime::Db::Require("userdb");
  if (!db_factory) Fail("upstream user database factory unavailable");
  // Settings owns writable LevelDB mirrors for custom words and Text Expander,
  // while the Host loads the same names through Rime's read-only stabledb.
  // Only the caller-selected learning databases participate, regardless of
  // the unrelated mirror directory's .userdb suffix or loaded dictionary type.
  const std::string stable_collision_name = "linnet_sync_stable_collision";
  std::unique_ptr<rime::Db> stable_collision_shadow(
      db_factory->Create(stable_collision_name));
  if (!stable_collision_shadow || stable_collision_shadow->Exists() ||
      !stable_collision_shadow->Open() ||
      !stable_collision_shadow->Update("auxiliary \tshadow", "c=1 d=1 t=1") ||
      !stable_collision_shadow->Close())
    Fail("cannot seed the non-learning .userdb collision");
  {
    std::ofstream stable_file(
        rime::Service::instance().deployer().user_data_dir /
        (stable_collision_name + ".txt"));
    stable_file << "# Rime table\n# coding: utf-8\n"
                   "#@/db_name\t" << stable_collision_name << ".txt\n"
                   "#@/db_type\ttabledb\n#\n"
                   "Auxiliary\tauxiliary\n";
    if (!stable_file) Fail("cannot seed the stabledb side of the collision");
  }
  std::unique_ptr<rime::UserDictionary> stable_collision(
      component->Create(stable_collision_name, "stabledb"));
  if (!stable_collision) Fail("cannot create the non-learning stabledb collision");
  // StableDb is read-only and has no learning tick, so UserDictionary::Load()
  // returns false after successfully opening it. The loaded database is the
  // exact Host state that must be classified as non-learning.
  stable_collision->Load();
  if (!stable_collision->loaded())
    Fail("cannot load the non-learning stabledb collision");
  {
    std::unique_ptr<rime::Db> reference(db_factory->Create("linnet-sync-merge-oracle"));
    if (!reference || reference->Exists() || !reference->Open())
      Fail("cannot create an isolated upstream merge oracle");
    if (!database->MetaUpdate("/tick", "10") || !reference->MetaUpdate("/tick", "10"))
      Fail("cannot seed the independent local clocks");
    for (size_t index = 0; index < existing_rows; ++index) {
      const auto key = existing_key(index);
      if (!database->Update(key, local_value) || !reference->Update(key, local_value))
        Fail("cannot seed equal pre-existing local learning");
    }
    {
      rime::UserDbMerger oracle(reference.get());
      if (!oracle.MetaPut("/tick", "1000")) Fail("cannot seed the remote oracle clock");
      for (size_t index = 0; index < existing_rows; ++index)
        if (!oracle.Put(existing_key(index), remote_value)) Fail("upstream merge oracle failed");
      for (size_t index = 0; index < 4096; ++index)
        if (!oracle.Put(remote_key(index), remote_value)) Fail("upstream new-row oracle failed");
      if (!oracle.CloseMerge()) Fail("upstream merge oracle did not finish");
    }
    for (size_t index = 0; index < existing_rows; ++index) {
      const auto key = existing_key(index);
      std::string expected;
      if (!reference->Fetch(key, &expected)) Fail("upstream oracle lost an existing row");
      expected_existing.emplace_back(key, expected);
    }
    expected_visible = read_rows(reference.get());
    if (!reference->Close() || !reference->Remove())
      Fail("cannot remove the fixture-owned oracle before cloud discovery");
  }
  const auto directory = rime::Service::instance().deployer().user_data_dir / "online-sync";
  const auto peer = directory / "other-device";
  std::filesystem::create_directories(peer);
  const auto remote = peer / "linnet_zh.userdb.txt";
  {
    std::ofstream output(remote);
    output << "# Rime user dictionary\n#@/db_name\tlinnet_zh\n"
              "#@/db_type\tuserdb\n#@/user_id\tother-device\n#@/tick\t1000\n";
    for (size_t index = 0; index < existing_rows; ++index)
      output << existing_key(index) << '\t' << remote_value << '\n';
    for (int index = 0; index < 4096; ++index)
      output << remote_key(index) << '\t' << remote_value << '\n';
  }
  const std::string sync_directory = directory.string();
  std::vector<const char*> sync_names = {"linnet_zh", "linnet_en", nullptr};
  size_t samples = 0;
  std::vector<LatencySample> step_latency;
  std::vector<LatencySample> key_latency;
  std::vector<LatencySample> typing_latency;
  bool activation_checked = false;
  size_t waiting_samples = 0;
  auto step = [&] {
    const auto before = std::chrono::steady_clock::now();
    const int result = api->sync_user_data_step(sync_directory.c_str(), sync_names.data());
    if (result == 3) ++waiting_samples;
    step_latency.push_back(std::chrono::duration_cast<Nanoseconds>(
        std::chrono::steady_clock::now() - before).count());
    if (!api->find_session(chinese) || !api->find_session(english) ||
        api->is_maintenance_mode())
      Fail("learning sync destroyed live input sessions or entered maintenance");
    if (std::string(api->get_input(chinese)) != "niha" ||
        std::string(api->get_input(english)) != "workin")
      Fail("learning sync changed a live composition");
    std::string clock;
    if (!activation_checked && database->MetaFetch("/tick", &clock) && clock == "1000") {
      activation_checked = true;
      expect_view("first activation", database.get(), expected_visible, "1000");
    }
    return result;
  };
  auto tick = [&] {
    // Measure every physical key, not only the final pair after the sync step.
    for (const auto& [session, letters] : {
        std::make_pair(chinese, "niha"), std::make_pair(english, "workin")}) {
      if (const char* active = api->get_input(session); active && *active)
        api->clear_composition(session);
      for (const char* letter = letters; *letter; ++letter)
        typing_latency.push_back(MeasureKey(api, session, *letter));
    }
    const int result = step();
    const auto key_start = std::chrono::steady_clock::now();
    api->process_key(chinese, 'o', 0);
    api->process_key(english, 'g', 0);
    key_latency.push_back(std::chrono::duration_cast<Nanoseconds>(
        std::chrono::steady_clock::now() - key_start).count());
    CandidateIndex(api, chinese, "你好");
    NormalizedCandidateIndex(api, english, "working");
    ++samples;
    return result;
  };
  auto finish = [&](std::optional<int> expected_result = 0) {
    const auto started = std::chrono::steady_clock::now();
    const auto initial_samples = samples;
    const auto deadline = started + std::chrono::seconds(20);
    int result;
    do {
      result = tick();
      if (result != 1 && result != 3) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    } while (std::chrono::steady_clock::now() < deadline);
    if (expected_result && result != *expected_result) {
      std::string state, clock;
      database->Fetch("\x02", &state);
      database->MetaFetch("/tick", &clock);
      size_t pending = 0;
      auto records = database->Query("\x02/");
      std::string key, value;
      while (records && records->GetNextRecord(&key, &value)) ++pending;
      std::cerr << "sync timeout state=" << state << " pending=" << pending
                << " tick=" << clock << " transaction=" << transaction->in_transaction()
                << " samples=" << samples - initial_samples
                << " step_p99_ns=" << NearestRank(&step_latency, 99)
                << " step_max_ns=" << step_latency.back()
                << " two_keys_p99_ns=" << NearestRank(&key_latency, 99) << '\n';
      Fail("online learning sync returned " + std::to_string(result) +
           ", expected " + std::to_string(*expected_result));
    }
    std::cout << "live-sync cycle: result=" << result
              << " samples=" << samples - initial_samples << " elapsed_ms="
              << std::chrono::duration_cast<std::chrono::milliseconds>(
                     std::chrono::steady_clock::now() - started).count() << std::endl;
    return result;
  };
  // Pending reversible learning must not be committed, aborted or mixed into.
  // Prepare input first: normal input handling may finish an earlier learning
  // transaction independently of sync. No synthetic composition reset belongs
  // inside this undo boundary; concurrent typing is exercised by tick below.
  Enter(api, chinese, "niha");
  Enter(api, english, "workin");
  if (!transaction->BeginTransaction()) Fail("cannot create pending learning");
  database->Update("yun tong bu \t未提交", "c=1 d=1 t=2");
  for (int index = 0; index < 30; ++index) {
    const int result = step();
    if (result != 1 && result != 3)
      Fail("sync completed across a pending learning transaction");
    if (!transaction->in_transaction())
      Fail("pending learning ended inside the sync step");
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  if (!transaction->in_transaction() || !transaction->AbortTransaction())
    Fail("sync consumed the user's reversible learning transaction");
  std::string value;
  if (database->Fetch("yun tong bu \t未提交", &value))
    Fail("aborted local learning became durable during sync");
  finish();
  if (std::filesystem::exists(
          directory / rime::Service::instance().deployer().user_id /
          (stable_collision_name + ".userdb.txt")))
    Fail("learning sync published a non-learning stabledb mirror");
  stable_collision.reset();
  if (!stable_collision_shadow->Remove())
    Fail("cannot remove the non-learning .userdb collision");
  std::filesystem::remove(
      rime::Service::instance().deployer().user_data_dir /
      (stable_collision_name + ".txt"));
  if (!activation_checked) record_failure("the initial merge never published tick 1000");
  size_t differing_rows = 0;
  std::string first_difference;
  for (const auto& [key, expected] : expected_existing) {
    if (!database->Fetch(key, &value)) Fail("online sync lost pre-existing local learning");
    if (value != expected) {
      ++differing_rows;
      if (first_difference.empty())
        first_difference = key + ": expected " + expected + "; actual " + value;
    }
  }
  if (differing_rows != 0)
    Fail("cooperative sync differs from one upstream merge for " +
         std::to_string(differing_rows) + "/" + std::to_string(existing_rows) +
         " pre-existing rows (local tick 10, remote tick 1000): " + first_difference);
  if (!database->Fetch("yun tong bu ce shi \t云同步测试4095", &value) ||
      rime::UserDbValue(value).commits != 7)
    Fail("online sync did not import the last upstream-format row");
  std::string clock;
  database->MetaFetch("/tick", &clock);
  const auto imported_tick = std::stoull(clock);
  {
    std::unique_ptr<rime::UserDictionary> learning(component->Create("linnet_zh", "userdb"));
    if (!learning->Load() || !learning->NewTransaction()) Fail("learning unavailable after sync");
    rime::DictEntry entry;
    entry.text = "同步后学习";
    entry.custom_code = "tong bu hou xue xi ";
    learning->UpdateEntry(entry, 1);
    entry.text = "第二次学习";
    learning->UpdateEntry(entry, 1);
    if (!learning->CommitPendingTransaction()) Fail("cannot persist post-sync learning");
  }
  database->MetaFetch("/tick", &clock);
  if (std::stoull(clock) != imported_tick + 2)
    Fail("sync clock overwrote transaction-local learning increments");
  finish();
  const auto published = directory / rime::Service::instance().deployer().user_id /
                         "linnet_zh.userdb.txt";
  const auto written_at = std::filesystem::last_write_time(published);
  std::ifstream before_stream(published);
  const std::string before_contents((std::istreambuf_iterator<char>(before_stream)), {});
  finish();
  if (std::filesystem::last_write_time(published) != written_at) {
    std::ifstream after_stream(published);
    const std::string after_contents((std::istreambuf_iterator<char>(after_stream)), {});
    const auto mismatch = std::mismatch(before_contents.begin(), before_contents.end(),
                                        after_contents.begin(), after_contents.end());
    const auto offset = std::distance(before_contents.begin(), mismatch.first);
    std::cerr << "snapshot difference at " << offset << ": before="
              << before_contents.substr(offset, 180) << " after="
              << after_contents.substr(std::min<size_t>(offset, after_contents.size()), 180) << '\n';
    Fail("unchanged learning rewrote the cloud snapshot");
  }
  // Synchronize an existing cold database without constructing an input
  // session. Its remote row must merge while every pre-existing local row stays.
  const std::string cold_name = "linnet_sync_cold";
  std::unique_ptr<rime::Db> cold(db_factory->Create(cold_name));
  if (!cold->Open()) Fail("cannot seed the isolated cold dictionary");
  for (int index = 0; index < 512; ++index)
    cold->Update("leng ci ku \t冷词库" + std::to_string(index), "c=2 d=1 t=2");
  cold->Close();
  const auto cold_remote = peer / (cold_name + ".userdb.txt");
  {
    std::ofstream output(cold_remote);
    output << "#@/db_name\t" << cold_name << "\n#@/db_type\tuserdb\n#@/tick\t10\n"
              "yuan duan \t远端冷词\tc=3 d=1 t=10\n";
  }
  sync_names.insert(sync_names.end() - 1, cold_name.c_str());
  const auto cold_sample_start = step_latency.size();
  finish();
  const auto cold_max = *std::max_element(step_latency.begin() + cold_sample_start,
                                         step_latency.end());
  if (cold_max > 15'000'000) Fail("cold learning sync exceeded the 15ms step budget");
  std::cout << "cold sync maximum step ns=" << cold_max << '\n';
  if (!std::filesystem::exists(published.parent_path() / (cold_name + ".userdb.txt")) ||
      !cold->Open() || !cold->Fetch("yuan duan \t远端冷词", &value))
    Fail("cold learning did not complete import and export");
  for (int index = 0; index < 512; ++index)
    if (!cold->Fetch("leng ci ku \t冷词库" + std::to_string(index), &value))
      Fail("cold synchronization lost existing local learning");
  if (!cold->Close() || !cold->Remove()) Fail("cannot remove the fixture-owned cold dictionary");
  sync_names.erase(sync_names.end() - 2);
  std::filesystem::remove(cold_remote);
  std::filesystem::remove(published.parent_path() / (cold_name + ".userdb.txt"));

  // An exception after one successful write must abort exactly that sync batch.
  const std::string fault_name = "linnet_sync_fault";
  rime::Registry::instance().Register(fault_name, new SyncFaultDbFactory);
  sync_names.insert(sync_names.end() - 1, fault_name.c_str());
  const auto fault_remote = peer / (fault_name + ".userdb.txt");
  {
    std::unique_ptr<rime::UserDictionary> learning(component->Create(fault_name, fault_name));
    if (!learning->Load()) Fail("cannot create the fault-injection dictionary");
    auto fault = std::dynamic_pointer_cast<SyncFaultDb>(component->GetDb(fault_name, "userdb"));
    {
      std::ofstream output(fault_remote);
      output << "#@/db_name\t" << fault_name << "\n#@/db_type\tuserdb\n#@/tick\t10\n"
                "ce shi \t异常前\tc=2 d=1 t=10\nce shi \t异常时\tc=2 d=1 t=10\n";
    }
    fault->writes_until_throw = 2;
    finish(-1);
    if (fault->in_transaction() || fault->Fetch("ce shi \t异常前", &value))
      Fail("failed sync left a transaction or partial durable learning");
    rime::DictEntry entry;
    entry.text = "正常学习"; entry.custom_code = "zheng chang xue xi ";
    if (!learning->NewTransaction() || !learning->UpdateEntry(entry, 1) ||
        !learning->CommitPendingTransaction() || fault->Fetch("ce shi \t异常前", &value))
      Fail("subsequent learning committed an aborted sync batch");
  }
  sync_names.erase(sync_names.end() - 2);
  rime::Registry::instance().Unregister(fault_name);
  std::filesystem::remove(fault_remote);
  std::unique_ptr<rime::Db> fault_cleanup(db_factory->Create(fault_name));
  if (!fault_cleanup->Remove()) Fail("cannot remove the fixture-owned fault dictionary");

  enum class IncomingChange { missing, replaced, earlierPeer, unchanged };
  enum class LocalEdit { none, learn, erase, undo };
  struct RecoveryCase {
    const char* label;
    bool reopen;
    IncomingChange incoming;
    LocalEdit edit;
    bool staging = false;
  };
  const auto oracle_directory = directory / "one-shot-reference";
  std::filesystem::create_directories(oracle_directory);
  for (const auto& item : {
      RecoveryCase{"staging_missing", false, IncomingChange::missing, LocalEdit::none, true},
      RecoveryCase{"staging_reopen_replaced", true, IncomingChange::replaced, LocalEdit::none, true},
      RecoveryCase{"resume_missing", false, IncomingChange::missing, LocalEdit::none},
      RecoveryCase{"reopen_missing", true, IncomingChange::missing, LocalEdit::none},
      RecoveryCase{"resume_replaced", false, IncomingChange::replaced, LocalEdit::none},
      RecoveryCase{"reopen_replaced", true, IncomingChange::replaced, LocalEdit::none},
      RecoveryCase{"resume_peer_first", false, IncomingChange::earlierPeer, LocalEdit::none},
      RecoveryCase{"reopen_peer_first", true, IncomingChange::earlierPeer, LocalEdit::none},
      RecoveryCase{"tail_learn", false, IncomingChange::unchanged, LocalEdit::learn},
      RecoveryCase{"tail_delete", false, IncomingChange::unchanged, LocalEdit::erase},
      RecoveryCase{"tail_undo", false, IncomingChange::unchanged, LocalEdit::undo}}) {
    const std::string name = std::string("linnet_sync_") + item.label;
    sync_names.insert(sync_names.end() - 1, name.c_str());
    std::unique_ptr<rime::Db> cleanup(db_factory->Create(name));
    if (cleanup->Exists()) Fail("interrupted-sync fixture already exists");
    std::unique_ptr<rime::UserDictionary> learning(component->Create(name, "userdb"));
    if (!learning->Load()) Fail("cannot load the interrupted-sync dictionary");
    auto resumed_db = component->GetDb(name, "userdb");
    rime::an<rime::Db> reference(new rime::UserDbWrapper<rime::LevelDb>(
        oracle_directory / (name + ".userdb"), name));
    if (!reference->Open() || !resumed_db->MetaUpdate("/tick", "10") ||
        !reference->MetaUpdate("/tick", "10")) Fail("cannot seed interrupted-sync clocks");
    for (size_t index = 0; index < existing_rows; ++index) {
      if (!resumed_db->Update(existing_key(index), local_value) ||
          !reference->Update(existing_key(index), local_value))
        Fail("cannot seed interrupted-sync learning");
    }
    const auto before_activation = read_rows(reference.get());
    auto merge_oracle = [&](const std::string& remote_tick, const std::string& contents) {
      rime::UserDbMerger oracle(reference.get());
      if (!oracle.MetaPut("/tick", remote_tick)) Fail("cannot seed recovery oracle clock");
      // The extra row is absent locally and must appear in Query at activation.
      for (size_t index = 0; index <= existing_rows; ++index)
        if (!oracle.Put(existing_key(index), contents)) Fail("recovery oracle merge failed");
      if (!oracle.CloseMerge()) Fail("recovery oracle did not finish");
    };
    if (!item.staging) merge_oracle("1000", remote_value);
    const auto incoming = peer / (name + ".userdb.txt");
    auto write_incoming = [&](const std::filesystem::path& file, const std::string& remote_tick,
                               const std::string& contents) {
      std::ofstream output(file);
      output << "#@/db_name\t" << name << "\n#@/db_type\tuserdb\n#@/tick\t" << remote_tick << '\n';
      for (size_t index = 0; index <= existing_rows; ++index)
        output << existing_key(index) << '\t' << contents << '\n';
      if (!output) Fail("cannot write the recovery snapshot");
    };
    write_incoming(incoming, "1000", remote_value);
    // Publication of the new clock, not physical row count/write_revision,
    // is the observable boundary. No caller may see a half-merged dictionary.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    bool activated = false;
    while (std::chrono::steady_clock::now() < deadline) {
      const int result = tick();
      resumed_db->MetaFetch("/tick", &clock);
      if (item.staging) {
        auto pending = resumed_db->Query("\x02/");
        if (pending && !pending->exhausted() && clock == "10") { activated = true; break; }
      } else if (clock == "1000") { activated = true; break; }
      expect_view(name + " staging", resumed_db.get(), before_activation, "10");
      if (result != 1 && result != 3) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (!activated) Fail("recovery fixture never reached the atomic activation boundary");
    const std::string activation_clock = item.staging ? "10" : "1000";
    expect_view(name + " activation", resumed_db.get(), read_rows(reference.get()), activation_clock);
    if (!item.staging) {
      // Move the durable range once before cancellation, reopening or editing
      // the tail. Fetch/Query cover keys before, at and after that lower bound.
      if (tick() != 1) Fail("active recovery fixture completed before a materialization slice");
      expect_view(name + " partial materialization", resumed_db.get(), read_rows(reference.get()), "1000");
    }

    const auto other_peer = directory / "before-active-peer";
    const auto other_incoming = other_peer / (name + ".userdb.txt");
    if (item.edit != LocalEdit::none) {
      // Index 128 lies beyond a 64-row materialization slice. Use exactly the
      // same real UserDictionary operation against the one-shot reference.
      rime::UserDictionary reference_learning(name, reference);
      if (!reference_learning.Load() || !learning->NewTransaction() ||
          !reference_learning.NewTransaction()) Fail("tail learning transaction unavailable");
      rime::DictEntry entry;
      const auto key = existing_key(existing_rows - 1);
      const auto separator = key.find('\t');
      entry.custom_code = key.substr(0, separator);
      entry.text = key.substr(separator + 1);
      const int commits = item.edit == LocalEdit::erase ? -1 : 1;
      if (!learning->UpdateEntry(entry, commits) || !reference_learning.UpdateEntry(entry, commits))
        Fail("cannot apply identical tail learning operations");
      reference->MetaFetch("/tick", &clock);
      expect_view(name + " user transaction", resumed_db.get(), read_rows(reference.get()), clock);
      if (item.edit == LocalEdit::undo) {
        if (!learning->RevertRecentTransaction() || !reference_learning.RevertRecentTransaction())
          Fail("cannot undo identical tail learning operations");
        expect_view(name + " undo learning", resumed_db.get(), read_rows(reference.get()), "1000");
        // Erase must suppress an active intent too, and undo must restore it.
        if (!learning->NewTransaction() || !reference_learning.NewTransaction() ||
            !resumed_db->Erase(key) || !reference->Erase(key)) Fail("cannot erase the tail transactionally");
        expect_view(name + " erased tail", resumed_db.get(), read_rows(reference.get()), "1000");
        if (!learning->RevertRecentTransaction() || !reference_learning.RevertRecentTransaction())
          Fail("cannot undo identical tail erasures");
        if (!learning->NewTransaction() || !reference_learning.NewTransaction() ||
            !resumed_db->Erase(key) || !reference->Erase(key) ||
            !learning->CommitPendingTransaction() || !reference_learning.CommitPendingTransaction())
          Fail("cannot commit identical tail erasures");
        expect_view(name + " committed erase", resumed_db.get(), read_rows(reference.get()), "1000");
      } else if (!learning->CommitPendingTransaction() || !reference_learning.CommitPendingTransaction()) {
        Fail("cannot persist identical tail learning operations");
      }
    } else {
      api->sync_user_data_step(nullptr, nullptr);
      if (item.incoming == IncomingChange::missing || item.incoming == IncomingChange::earlierPeer)
        std::filesystem::remove(incoming);
      if (item.incoming == IncomingChange::replaced || item.incoming == IncomingChange::earlierPeer) {
        // Keep B weaker than A so its later clock cannot mask an unfinished A.
        const std::string newer = "c=3 d=0.25 t=2000";
        if (item.incoming == IncomingChange::earlierPeer) {
          // A is no longer in cloud discovery, so B is guaranteed to be the
          // first incoming snapshot; correctness cannot rely on directory order.
          std::filesystem::create_directories(other_peer);
          write_incoming(other_incoming, "2000", newer);
        } else {
          write_incoming(incoming, "2000", newer);
        }
        merge_oracle("2000", newer);
      }
      if (item.reopen) {
        resumed_db.reset();
        learning.reset();
        if (component->GetDb(name, "userdb")->loaded()) Fail("cancel retained the interrupted live Db");
        learning.reset(component->Create(name, "userdb"));
        if (!learning->Load()) Fail("cannot naturally reopen the interrupted dictionary");
        resumed_db = component->GetDb(name, "userdb");
      }
    }
    finish();
    reference->MetaFetch("/tick", &clock);
    expect_view(name + " recovered", resumed_db.get(), read_rows(reference.get()), clock);
    resumed_db.reset();
    learning.reset();
    if (!reference->Close() || !reference->Remove()) Fail("cannot remove the recovery oracle");
    sync_names.erase(sync_names.end() - 2);
    if (!cleanup->Remove()) Fail("cannot remove the fixture-owned interrupted dictionary");
    std::filesystem::remove(incoming);
    std::filesystem::remove(other_incoming);
    std::filesystem::remove(published.parent_path() / (name + ".userdb.txt"));
  }

  // A successful writer must never replace a readable snapshot with bytes
  // rejected by its own next read. Exercise actual Rime serialization.
  const std::string large_name = "linnet_sync_large";
  sync_names.insert(sync_names.end() - 1, large_name.c_str());
  std::unique_ptr<rime::Db> large_cleanup(db_factory->Create(large_name));
  if (large_cleanup->Exists()) Fail("large-sync fixture already exists");
  {
    std::unique_ptr<rime::UserDictionary> learning(component->Create(large_name, "userdb"));
    if (!learning->Load()) Fail("cannot load the large-sync dictionary");
    auto large_db = component->GetDb(large_name, "userdb");
    if (!large_db->Update("da ci ku \t旧快照", "c=1 d=1 t=1")) Fail("cannot seed old snapshot");
    finish();
    const auto target = published.parent_path() / (large_name + ".userdb.txt");
    auto* large_transaction = dynamic_cast<rime::Transactional*>(large_db.get());
    if (!large_transaction || !large_transaction->BeginTransaction())
      Fail("cannot seed a real large learning transaction");
    const std::string prefix = "da ci ku \t" + std::string(4 * 1024, 'x');
    for (int index = 0; index < 4352; ++index)
      if (!large_db->Update(prefix + std::to_string(index), "c=1 d=1 t=1"))
        Fail("cannot seed the large learning fixture");
    if (!large_transaction->CommitTransaction()) Fail("cannot commit the large learning fixture");
    const auto serialized = directory / "large-fixture.userdb.txt";
    if (!large_db->Backup(serialized)) Fail("cannot serialize the large learning fixture");
    const auto serialized_bytes = std::filesystem::file_size(serialized);
    if (serialized_bytes <= 16 * 1024 * 1024 || serialized_bytes >= 32 * 1024 * 1024)
      Fail("large-sync fixture is outside its required serialized-size boundary");
    std::filesystem::remove(serialized);
    finish();
    if (std::filesystem::file_size(target) != serialized_bytes)
      Fail("large learning snapshot was truncated during publication");
    // More than 32 MiB across peers is ordinary user data, not a failed cycle.
    const auto large_peer = peer / (large_name + ".userdb.txt");
    const auto second_peer = directory / "second-large-device";
    std::filesystem::create_directories(second_peer);
    std::filesystem::copy_file(target, large_peer);
    std::filesystem::copy_file(target, second_peer / large_peer.filename());
    finish();
    std::string imported;
    if (!large_db->Fetch(prefix + "4351", &imported))
      Fail("large peer snapshots lost the final learning row");
    std::filesystem::remove(large_peer);
    std::filesystem::remove_all(second_peer);
    std::filesystem::remove(target);
  }
  sync_names.erase(sync_names.end() - 2);
  if (!large_cleanup->Remove()) Fail("cannot remove the fixture-owned large dictionary");
  if (!recovery_failures.empty()) {
    std::ostringstream report;
    report << "live synchronization recovery contract failed:";
    for (const auto& failure : recovery_failures) report << "\n  " << failure;
    Fail(report.str());
  }

  // A stale local export is not a peer: it must not resurrect local rows.
  const std::string own_key = "ben ji kuai zhao \t本机旧快照";
  { std::ofstream own(published, std::ios::app); own << own_key << "\tc=99 d=99 t=1000\n"; }
  finish();
  std::string own_value;
  if (database->Fetch(own_key, &own_value))
    Fail("synchronization imported this device's own stale snapshot");

  // Malformed remote rows must fail, without damaging input or our last file.
  const auto before_corrupt_written_at = std::filesystem::last_write_time(published);
  { std::ofstream corrupt(remote, std::ios::app); corrupt << "broken-row\n"; }
  int failed = 1;
  for (int index = 0; index < 100 && (failed == 1 || failed == 3); ++index) {
    failed = tick();
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  if (failed != -1 || std::filesystem::last_write_time(published) != before_corrupt_written_at)
    Fail("corrupt remote learning reported success or overwrote a valid snapshot");
  if (waiting_samples == 0)
    Fail("learning sync never distinguished background I/O waiting from runnable work");
  api->sync_user_data_step(sync_directory.c_str(), sync_names.data());
  api->sync_user_data_step(nullptr, nullptr);
  Enter(api, chinese, "nihao");
  CandidateIndex(api, chinese, "你好");
  std::sort(step_latency.begin(), step_latency.end());
  std::sort(key_latency.begin(), key_latency.end());
  const auto p99_step = step_latency[step_latency.size() * 99 / 100];
  const auto p99_key = key_latency[key_latency.size() * 99 / 100];
  const auto p95_typing = NearestRank(&typing_latency, 95);
  const auto p99_typing = NearestRank(&typing_latency, 99);
  if (p99_step > 5'000'000 || p99_key > 15'000'000 ||
      p95_typing > 5'000'000 || p99_typing > 15'000'000)
    Fail("online sync exceeded the input latency budget");
  std::cout << "rime_smoke_test: live sync samples=" << samples
            << " step_p99_ns=" << p99_step << " step_max_ns=" << step_latency.back()
            << " two_keys_p99_ns=" << p99_key
            << " all_keys_p95_ns=" << p95_typing << " all_keys_p99_ns=" << p99_typing << '\n';
  api->destroy_session(chinese);
  api->destroy_session(english);
}

}  // namespace

static void ExpectCandidateForgetFocus(RimeApi_stdbool* api) {
  for (const auto& [schema, input] : std::vector<std::pair<std::string, std::string>>{
           {"linnet_zh_pinyin", "shi"}, {"linnet_en", "tes"}}) {
    for (size_t target : {size_t(0), size_t(8)}) {
      const auto session = CreateSchemaSession(api, schema.c_str());
      Enter(api, session, input);
      auto live = rime::Service::instance().GetSession(session);
      auto* context = live->context();
      auto menu = context->composition().back().menu;
      if (!menu || menu->Prepare(15) < 9 || !api->highlight_candidate(session, 2))
        Fail("forget focus fixture did not prepare a browsable menu");
      const auto selected = context->GetSelectedCandidate()->text();
      if (!api->delete_candidate(session, target) ||
          !context->GetSelectedCandidate() ||
          context->GetSelectedCandidate()->text() != selected ||
          context->input() != input)
        Fail(schema + ": forgetting another candidate moved focus or changed input");
      ExpectNoCommit(api, session, "forget another candidate");
      api->clear_composition(session);
      if (api->delete_candidate(session, 0))
        Fail("an absent forget target was accepted");
      api->destroy_session(session);
    }
  }
  std::cout << "candidate forget preserves Chinese/English focus before/after selection: PASS\n";
}

int main(int argc, char** argv) {
  const bool raw_editing_probe =
      argc == 4 && std::strcmp(argv[3], "--raw-editing-probe") == 0;
  const bool candidate_forget_probe =
      argc == 4 && std::strcmp(argv[3], "--candidate-forget-probe") == 0;
  const bool live_sync_probe =
      argc == 4 && std::strcmp(argv[3], "--live-sync-probe") == 0;
  const bool input_options_probe =
      argc == 4 && std::strcmp(argv[3], "--input-options-probe") == 0;
  const bool input_switches_probe =
      argc == 4 && std::strcmp(argv[3], "--input-switches-probe") == 0;
  const bool settings_off_probe =
      argc == 4 && std::strcmp(argv[3], "--settings-off-probe") == 0;
  const bool learning_off_probe =
      argc == 4 && std::strcmp(argv[3], "--learning-off-probe") == 0;
  const bool profile_key_matrix_probe =
      argc == 4 &&
      std::strcmp(argv[3], "--profile-key-matrix-probe") == 0;
  const bool lifecycle_raw_exit_probe =
      argc == 4 &&
      std::strcmp(argv[3], "--lifecycle-raw-exit-probe") == 0;
  const bool page_size_probe =
      argc == 5 && std::strcmp(argv[3], "--page-size-probe") == 0;
  const bool english_profile_probe =
      argc == 8 && std::strcmp(argv[3], "--english-profile-probe") == 0;
  const bool fast_config_reload_probe =
      argc == 4 && std::strcmp(argv[3], "--fast-config-reload-probe") == 0;
  const bool prediction_punctuation_probe =
      argc == 4 &&
      std::strcmp(argv[3], "--prediction-punctuation-probe") == 0;
  const bool mixed_input_probe =
      argc == 4 && std::strcmp(argv[3], "--mixed-input-probe") == 0;
  const bool mixed_learning_on_probe =
      argc == 4 &&
      std::strcmp(argv[3], "--mixed-learning-on-probe") == 0;
  const bool mixed_learning_off_probe =
      argc == 4 &&
      std::strcmp(argv[3], "--mixed-learning-off-probe") == 0;
  const bool mixed_latency_probe =
      argc == 4 && std::strcmp(argv[3], "--mixed-latency-probe") == 0;
  const bool warm_session_probe =
      argc == 4 && std::strcmp(argv[3], "--warm-session-probe") == 0;
  const bool cold_client_probe =
      argc == 4 && std::strcmp(argv[3], "--cold-client-probe") == 0;
  if (argc != 3 && !input_options_probe && !input_switches_probe &&
      !settings_off_probe && !learning_off_probe && !candidate_forget_probe && !raw_editing_probe &&
      !profile_key_matrix_probe &&
      !lifecycle_raw_exit_probe &&
      !page_size_probe && !english_profile_probe &&
      !fast_config_reload_probe && !prediction_punctuation_probe &&
      !mixed_input_probe &&
      !mixed_learning_on_probe &&
      !mixed_learning_off_probe &&
      !mixed_latency_probe && !warm_session_probe && !cold_client_probe && !live_sync_probe) {
    Fail("usage: rime_smoke_test SHARED_DATA_DIR USER_DATA_DIR "
         "[--input-options-probe|--input-switches-probe|--settings-off-probe|--learning-off-probe|"
         "--profile-key-matrix-probe|--candidate-forget-probe|--raw-editing-probe|"
         "--lifecycle-raw-exit-probe|"
         "--page-size-probe EXPECTED|"
         "--english-profile-probe PROFILE CHINESE_SCHEMA CODE PREFIX|"
         "--fast-config-reload-probe|--prediction-punctuation-probe|"
         "--mixed-input-probe|"
         "--mixed-learning-on-probe|"
         "--mixed-learning-off-probe|"
         "--mixed-latency-probe|--warm-session-probe|--cold-client-probe]");
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
  if (candidate_forget_probe) {
    ExpectCandidateForgetFocus(api);
    api->finalize();
    return 0;
  }
  if (raw_editing_probe) {
    ExpectRawLikeArrowEditing(api);
    api->finalize();
    return 0;
  }
  if (live_sync_probe) {
    ExpectLiveUserDataSync(api);
    api->finalize();
    std::cout << "rime_smoke_test: live user dictionary sync: PASS\n";
    return 0;
  }
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

  if (profile_key_matrix_probe) {
    ExpectFormalProfileKeyMatrix(api);
    ExpectSmartEnglishHyphenBoundary(api);
    ExpectNineCandidateSelectKeys(api, "linnet_en", "a");
    ExpectFormalSingleLetterMatrix(api);
    ExpectNaturalSingleKeyDefaultRanking(api);
    ExpectSpellingDerivedEnglishPreservesChinese(api);
    ExpectSmartEnglishSpellingDerivedCandidate(api);
    ExpectCandidateArrowNavigation(api);
    ExpectSingleSyllablePreferenceLearning(api);
    ExpectPartialSelectionRanksCurrentSegment(api);
    for (const auto& schema_id : RuntimeProductSchemaIDs(api)) {
      ExpectCapsLockRawPath(api, schema_id.c_str());
    }
    ExpectCapsLockPreservesExplicitPrefix(api);
    ExpectReturnPreservesExplicitPrefix(api);
    ExpectCapsLockDismissesPassivePrediction(api);
    ExpectDirectShiftSmartEnglish(api);
    ExpectPassivePredictionKeyboardSelection(api);
    api->finalize();
    std::cout << "rime_smoke_test: formal eight-profile key matrix: PASS\n";
    return 0;
  }

  if (lifecycle_raw_exit_probe) {
    ExpectLifecycleRawExitContract(api, true);
    api->finalize();
    std::cout << "rime_smoke_test: lifecycle raw-input exits: PASS\n";
    return 0;
  }

  if (mixed_input_probe) {
    ExpectSupplementalExtendedChineseCoverage(api);
    ExpectNativeMixedInput(api);
    BenchmarkSchema(api, "linnet_zh_pinyin", "xuexiCSjiting");
    api->finalize();
    std::cout << "rime_smoke_test: modeless mixed input: PASS\n";
    return 0;
  }

  if (mixed_learning_off_probe) {
    ExpectNativeMixedLearningDisabled(api);
    api->finalize();
    std::cout << "rime_smoke_test: modeless mixed learning disabled: PASS\n";
    return 0;
  }

  if (mixed_learning_on_probe) {
    ExpectNativeMixedLearningEnabled(api);
    api->finalize();
    std::cout << "rime_smoke_test: modeless mixed learning enabled: PASS\n";
    return 0;
  }

  if (mixed_latency_probe) {
    BenchmarkSchema(api, "linnet_zh_pinyin", "xuexiCSjiting", false);
    api->finalize();
    std::cout << "rime_smoke_test: mixed-input latency measurement: COMPLETE\n";
    return 0;
  }

  if (warm_session_probe) {
    ExpectRetainedWarmSessionLatency(api);
    api->finalize();
    std::cout << "rime_smoke_test: retained warm session: PASS\n";
    return 0;
  }

  if (cold_client_probe) {
    ExpectColdClientFirstKeyLatency(api);
    api->finalize();
    std::cout << "rime_smoke_test: cold-client first-key latency: PASS\n";
    return 0;
  }

  if (input_options_probe) {
    const RimeSessionId chinese =
        CreateSchemaSession(api, "linnet_zh_pinyin");
    if (!api->get_option(chinese, "traditionalization")) {
      Fail("the deployed graphical traditional-Chinese default remained disabled");
    }
    ExpectFirstCandidate(api, chinese, "ceshi", "測試");
    // Chinese mode keeps the explicit reverse-lookup command.
    ExpectCandidate(api, chinese, "|suanfa", "algorithm");
    api->destroy_session(chinese);

    const RimeSessionId english = CreateSchemaSession(api, "linnet_en");
    // The selected full-pinyin profile drives automatic Smart English lookup;
    // its punctuation remains host-owned.
    ExpectCandidate(api, english, "suanfa", "algorithm");
    const auto live_english = rime::Service::instance().GetSession(english);
    bool capitalization = true;
    bool space_adds_trailing_space = true;
    std::string tab_behavior;
    if (!live_english || !live_english->schema() ||
        !live_english->schema()->config() ||
        !live_english->schema()->config()->GetBool(
            "linnet_english_interaction/sentence_capitalization",
            &capitalization) ||
        capitalization ||
        !live_english->schema()->config()->GetString(
            "linnet_english_interaction/tab_behavior", &tab_behavior) ||
        tab_behavior != "pass" ||
        !live_english->schema()->config()->GetBool(
            "linnet_english_interaction/space_adds_trailing_space",
            &space_adds_trailing_space) ||
        space_adds_trailing_space) {
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

    const RimeSessionId unspaced = CreateSchemaSession(api, "linnet_en");
    Enter(api, unspaced, "world");
    const size_t world_index = CandidateIndex(api, unspaced, "world");
    const auto live_unspaced = rime::Service::instance().GetSession(unspaced);
    if (!live_unspaced || !live_unspaced->context() ||
        live_unspaced->context()->composition().empty()) {
      Fail("the no-trailing-space fixture has no active composition");
    }
    live_unspaced->context()->Highlight(world_index);
    if (!api->process_key(unspaced, XK_space, 0) ||
        TakeCommit(api, unspaced) != "world") {
      Fail("the graphical Space setting did not commit without a trailing space");
    }
    api->destroy_session(unspaced);
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
    ExpectCandidate(api, settings_off, "cloudd", "cloud");
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

  ExpectColdClientFirstKeyLatency(api);
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
  ExpectFormalProfileKeyMatrix(api);
  ExpectSmartEnglishHyphenBoundary(api);
  ExpectDateShortcutProfileIsolation(api);
  ExpectPinyinReverseUsesActiveProfiles(api);
  ExpectPinyinReverseTraversalBounded(api);
  ExpectPinyinReverseKeyLimit(api);
  ExpectAutomaticPinyinTailProjection(api);
  ExpectDeployedMenuPageSize(api, "linnet_zh", 9);
  ExpectDeployedMenuPageSize(api, "linnet_en", 9);
  for (const auto& schema_id : RuntimeProductSchemaIDs(api)) {
    ExpectCapsLockRawPath(api, schema_id.c_str());
  }
  ExpectCapsLockPreservesExplicitPrefix(api);
  ExpectReturnPreservesExplicitPrefix(api);
  ExpectDirectShiftSmartEnglish(api);
  ExpectSwitcherHotkeysPassThrough(api);
  ExpectModeSwitchClearsSmartEnglishState(api);
  ExpectNineCandidateSelectKeys(api, "linnet_en", "a");
  ExpectCandidateArrowNavigation(api);
  ExpectPassivePredictionExitContract(api);
  ExpectLifecycleRawExitContract(api);
  ExpectCapsLockDismissesPassivePrediction(api);
  ExpectPassivePredictionKeyboardSelection(api);
  ExpectPassivePredictionTabContracts(api);
  ExpectPredictionPunctuationExitContract(api);
  ExpectRawLikeArrowEditing(api);
  ExpectInvalidActiveSelectionKeysPassThrough(api);
  ExpectNonFormalPunctuationBoundaries(api);
  ExpectStatefulChinesePunctuation(api);
  ExpectHostModifierPassThrough(api);
  ExpectTrailingDeletePassThrough(api);
  ExpectPrintableAsciiMatrix(api);
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
  ExpectFrequentEnglishCompletions(api);
  ExpectImmediateEnglishSpaceCommit(api);
  ExpectCommentContains(api, english, "Dejavu", "Déjà vu", "似曾", "相识");
  ExpectCommentContains(api, english, "jwt", "jwt", "JSON Web Token", "令牌");
  ExpectCommentContains(api, english, "serialization", "serialization",
                        "序列化", "连载");
  ExpectCommentIncludesExcludes(
      api, english, "deserialization", "deserialization", "反序列化",
      "串并");
  ExpectCommentContains(api, english, "agent", "agent", "智能体", "代理人");
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
  const RimeSessionId tab_pinyin_phrase =
      CreateSchemaSession(api, "linnet_en");
  // Ordinary English input also offers pinyin translations. Select that
  // candidate without suppressing correction or assuming its rank; explicit
  // reverse lookup is a different segment and is not smart-complete input.
  Enter(api, tab_pinyin_phrase, "yunjisuan");
  const auto pinyin_before_tab = CandidateOrigins(tab_pinyin_phrase, 256);
  const auto pinyin_target = std::find_if(
      pinyin_before_tab.begin(), pinyin_before_tab.end(),
      [](const auto& candidate) {
        return BaseText(candidate.text) == "cloud computing" &&
               candidate.genuine_type == "linnet_pinyin";
      });
  if (pinyin_target == pinyin_before_tab.end()) {
    Fail("pinyin smart-complete fixture lost its multi-word candidate");
  }
  const size_t target_index = static_cast<size_t>(
      std::distance(pinyin_before_tab.begin(), pinyin_target));
  if (!api->highlight_candidate(tab_pinyin_phrase, target_index)) {
    Fail("could not highlight the automatic multi-word pinyin candidate");
  }
  const bool pinyin_tab_handled =
      api->process_key(tab_pinyin_phrase, kTab, 0);
  const std::string pinyin_tab_commit =
      BaseText(TakeCommit(api, tab_pinyin_phrase));
  if (!pinyin_tab_handled || pinyin_tab_commit != "cloud computing") {
    std::cerr << "Candidates before pinyin smart-complete Tab:";
    for (const auto& candidate : pinyin_before_tab) {
      std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                << candidate.genuine_type << "]";
    }
    std::cerr << "\nTab handled=" << pinyin_tab_handled << ", commit='"
              << pinyin_tab_commit << "'\n";
    Fail("smart-complete Tab skipped the highlighted automatic multi-word pinyin result " +
         std::to_string(target_index) + "/" +
         std::to_string(pinyin_before_tab.size()));
  }
  ExpectSessionPropertyAbsent(api, tab_pinyin_phrase,
                              kPredictContextProperty,
                              "multi-word pinyin smart-complete");
  api->destroy_session(tab_pinyin_phrase);
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

  const std::vector<AcceptanceCase> correction_cases = {
      acceptance_cases.at("correction_insertion"),
      acceptance_cases.at("correction_deletion"),
      acceptance_cases.at("correction_substitution"),
      acceptance_cases.at("correction_transposition"),
      {"developmebt", "development"},
      {"implemenration", "implementation"},
      {"configuratiob", "configuration"},
  };
  for (const auto& test_case : correction_cases) {
    Enter(api, english, test_case.query);
    const auto candidates = Candidates(api, english);
    if (candidates.empty() || candidates.front().text != test_case.query) {
      Fail("correction did not preserve raw input first: " + test_case.query);
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
  if (SelectNormalizedCandidate(api, explicit_pinyin_phrase, "|yunjisuan",
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

  Enter(api, isolated_session, "WAF");
  const auto acronym_prefix_candidates = Candidates(api, isolated_session);
  if (acronym_prefix_candidates.empty() ||
      acronym_prefix_candidates.front().text != "WAF") {
    Fail("uppercase acronym prefix did not preserve the user's exact input first");
  }
  NormalizedCandidateIndex(api, isolated_session, "WAFA");
  ExpectStandardTableOrigin(isolated_session, "WAFA");
  for (const auto& schema_id : RuntimeChineseSchemaIDs(api)) {
    const RimeSessionId acronym_prefix =
        CreateSchemaSession(api, schema_id.c_str());
    Enter(api, acronym_prefix, "WAF");
    const auto candidates = Candidates(api, acronym_prefix);
    if (candidates.empty() || candidates.front().text != "WAF") {
      std::cerr << "Origins for uppercase acronym prefix WAF in " << schema_id
                << ":";
      for (const auto& candidate : CandidateOrigins(acronym_prefix)) {
        std::cerr << " [" << candidate.text << ":" << candidate.type << ":"
                  << candidate.genuine_type << ":q=" << candidate.quality
                  << ":exact=" << candidate.phrase_exact << "]";
      }
      std::cerr << '\n';
      api->destroy_session(acronym_prefix);
      Fail(schema_id +
           " uppercase acronym prefix did not preserve the user's exact input first");
    }
    NormalizedCandidateIndex(api, acronym_prefix, "WAFA");
    ExpectStandardTableOrigin(acronym_prefix, "WAFA");
    api->destroy_session(acronym_prefix);
  }

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
  ExpectSpellingDerivedEnglishPreservesChinese(api);
  ExpectSmartEnglishSpellingDerivedCandidate(api);
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
  ExpectFormalSingleLetterMatrix(api);
  for (const auto& schema_id : RuntimeChineseSchemaIDs(api)) {
    const RimeSessionId profile_session =
        CreateSchemaSession(api, schema_id.c_str());
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

  ExpectFirstCandidate(api, chinese, "Don't", "Don't");

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
    std::string actual;
    for (const auto& candidate : apostrophe_origins)
      actual += " [" + candidate.text + ":" + candidate.type + "/" + candidate.genuine_type + "]";
    Fail("custom apostrophe word lost its original dictionary priority:" + actual);
  }
  SelectCurrentNormalizedCandidate(api, apostrophe_custom, "don't");
  const auto apostrophe_live = rime::Service::instance().GetSession(apostrophe_custom);
  if (apostrophe_live->context()->get_property(rime::predict::kContextProperty) != "hello don't" ||
      apostrophe_live->context()->get_property(rime::predict::kStaticKeyProperty).empty())
    Fail("committing an apostrophe word discarded prediction context");
  ContinueAndSelectNormalizedCandidate(api, apostrophe_custom, "cloud", "cloud");
  api->process_key(apostrophe_custom, kReturn, 0);
  SelectNormalizedCandidate(api, apostrophe_custom, "don't", "don't");
  ExpectPredictionMenu(api, apostrophe_custom, "learned contraction context");
  NormalizedCandidateIndex(api, apostrophe_custom, "cloud");
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
  ExpectNormalizedOrder(api, pinyin_reverse, "|yun",
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
                                   "|" + product_case.first,
                                   product_case.second);
  }
  ExpectCandidateAbsent(api, pinyin_reverse, "|zhinengti", "a gent");
  for (const auto& retained_sense :
       std::vector<std::pair<std::string, std::string>>{
           {"bu", "not"}, {"shuo", "speak"}, {"he", "with"},
           {"chu", "exit"}, {"chu", "leave"}, {"fa", "fine"}}) {
    ExpectNormalizedCandidate(
        api, pinyin_reverse, "|" + retained_sense.first,
        retained_sense.second);
  }
  for (const auto& rejected_candidate :
       std::vector<std::pair<std::string, std::string>>{
           {"aisang", "gonest"}, {"aisang", "lovedest"},
           {"aisang", "lovingest"}}) {
    ExpectCandidateAbsent(api, english, rejected_candidate.first,
                          rejected_candidate.second);
    ExpectCandidateAbsent(api, pinyin_reverse,
                          "|" + rejected_candidate.first,
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
  ExpectNativeMixedInput(api);
  ExpectNaturalSingleKeyDefaultRanking(api);
  ExpectSingleSyllablePreferenceLearning(api);
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
  BenchmarkSchema(api, "linnet_en", "developmebt");
  BenchmarkSchema(api, "linnet_en", "implemenration");
  BenchmarkSchema(api, "linnet_en", "configuratiob");
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
