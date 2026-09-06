#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include "rime_api.h"

namespace {

struct Candidate {
  std::string text;
  std::string comment;
};

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "linnet_windows_runtime_smoke: " << message << '\n';
  std::cerr.flush();
  std::_Exit(1);
}

std::string BaseText(const std::string& value) {
  return !value.empty() && value.front() == ' ' ? value.substr(1) : value;
}

std::vector<Candidate> Candidates(RimeApi* api, RimeSessionId session) {
  std::vector<Candidate> result;
  RimeCandidateListIterator iterator = {};
  if (!api->candidate_list_begin(session, &iterator)) {
    return result;
  }
  while (api->candidate_list_next(&iterator)) {
    result.push_back({iterator.candidate.text ? iterator.candidate.text : "",
                      iterator.candidate.comment
                          ? iterator.candidate.comment
                          : ""});
  }
  api->candidate_list_end(&iterator);
  return result;
}

RimeSessionId CreateSession(RimeApi* api, const char* schema) {
  const RimeSessionId session = api->create_session();
  if (!session || !api->select_schema(session, schema)) {
    Fail(std::string("could not activate schema: ") + schema);
  }
  return session;
}

std::vector<Candidate> Enter(RimeApi* api,
                             RimeSessionId session,
                             const char* input) {
  api->clear_composition(session);
  if (!api->simulate_key_sequence(session, input)) {
    Fail(std::string("could not simulate input: ") + input);
  }
  return Candidates(api, session);
}

const Candidate& Find(const std::vector<Candidate>& candidates,
                      const std::string& expected) {
  const auto found = std::find_if(
      candidates.begin(), candidates.end(), [&](const Candidate& candidate) {
        return BaseText(candidate.text) == expected;
      });
  if (found == candidates.end()) {
    std::cerr << "Candidates for '" << expected << "':";
    for (const auto& candidate : candidates) {
      std::cerr << " [" << candidate.text << " :: " << candidate.comment
                << "]";
    }
    std::cerr << '\n';
    Fail("expected candidate is missing: " + expected);
  }
  return *found;
}

void ExpectCandidate(RimeApi* api,
                     RimeSessionId session,
                     const char* input,
                     const char* expected) {
  Find(Enter(api, session, input), expected);
}

void ExpectCandidateContaining(RimeApi* api,
                               RimeSessionId session,
                               const char* input,
                               const char* expected_fragment) {
  const auto candidates = Enter(api, session, input);
  const auto found = std::find_if(
      candidates.begin(), candidates.end(), [&](const Candidate& candidate) {
        return candidate.text.find(expected_fragment) != std::string::npos;
      });
  if (found == candidates.end()) {
    Fail("candidate fragment is missing: " + std::string(expected_fragment));
  }
}

void ExpectComment(RimeApi* api,
                   RimeSessionId session,
                   const char* input,
                   const char* expected,
                   const char* first,
                   const char* second) {
  const Candidate candidate = Find(Enter(api, session, input), expected);
  if (candidate.comment.find(first) == std::string::npos ||
      candidate.comment.find(second) == std::string::npos) {
    Fail("candidate comment is incomplete for " + std::string(expected) +
         ": " + candidate.comment);
  }
}

void ExpectCorrection(RimeApi* api, RimeSessionId session) {
  const auto candidates = Enter(api, session, "deserilazation");
  if (candidates.empty() || candidates.front().text != "deserilazation") {
    Fail("spelling correction no longer preserves raw input first");
  }
  const Candidate corrected = Find(candidates, "deserialization");
  if (corrected.comment.find("反序列化") == std::string::npos) {
    Fail("corrected candidate lost its Chinese gloss");
  }
}

void ExpectPrediction(RimeApi* api, RimeSessionId session) {
  api->clear_composition(session);
  if (!api->simulate_key_sequence(session, "he ")) {
    Fail("could not commit the prediction seed");
  }
  RimeCommit commit = {};
  RIME_STRUCT_INIT(RimeCommit, commit);
  if (!api->get_commit(session, &commit)) {
    Fail("prediction seed did not produce a commit");
  }
  const std::string committed = commit.text ? commit.text : "";
  api->free_commit(&commit);
  if (committed != "he ") {
    Fail("prediction seed committed unexpected text: " + committed);
  }
  if (Candidates(api, session).empty()) {
    Fail("predict module produced no candidates after an English word");
  }
}

std::string TakeCommit(RimeApi* api, RimeSessionId session) {
  RimeCommit commit = {};
  RIME_STRUCT_INIT(RimeCommit, commit);
  if (!api->get_commit(session, &commit)) Fail("expected committed text");
  const std::string text = commit.text ? commit.text : "";
  api->free_commit(&commit);
  return text;
}

void ExpectMixedAndRawInput(RimeApi* api, RimeSessionId session) {
  for (const char* entity : {"WAF", "QZX"}) {
    Enter(api, session, "nihao");
    api->process_key(session, 0xffe1, 1);  // Shift_L down
    for (const char* key = entity; *key; ++key) {
      api->process_key(session, *key, 1);
    }
    api->process_key(session, 0xffe1, 1 << 30);  // Shift_L up
    api->simulate_key_sequence(session, "nihao");
    const std::string expected = "你好" + std::string(entity) + "你好";
    const auto candidates = Candidates(api, session);
    const auto& candidate = Find(candidates, expected);
    const auto index = &candidate - candidates.data();
    if (index >= 9 || !api->process_key(session, '1' + static_cast<int>(index), 0) ||
        TakeCommit(api, session) != expected) {
      Fail("mixed sentence cannot be selected and committed: " + expected);
    }
  }
  for (const char* input : {"https://api.example.com", "URLSession", "v0.1.19"}) {
    Enter(api, session, input);
    api->process_key(session, 0xff0d, 0);  // Return
    if (TakeCommit(api, session) != input) {
      Fail("code-shaped input changed on commit: " + std::string(input));
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    Fail("usage: runtime_smoke SHARED_DATA_DIR USER_DATA_DIR");
  }

  RimeApi* api = rime_get_api();
  if (!api) {
    Fail("librime API is unavailable");
  }

  const std::string staging_dir = std::string(argv[2]) + "/build";
  RimeTraits traits = {};
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.prebuilt_data_dir = argv[1];
  traits.staging_dir = staging_dir.c_str();
  traits.distribution_name = "Linnet Windows Smoke";
  traits.distribution_code_name = "linnet-windows-smoke";
  traits.distribution_version = "1";
  traits.app_name = "rime.linnet.windows-smoke";
  traits.min_log_level = 2;
  traits.log_dir = "";

  api->setup(&traits);
  api->initialize(nullptr);
  for (const char* module : {"lua", "octagram", "predict", "smart_english"}) {
    if (!api->find_module(module)) {
      Fail(std::string("merged runtime module is missing: ") + module);
    }
  }
  if (api->start_maintenance(true)) {
    api->join_maintenance_thread();
  }

  const RimeSessionId english = CreateSession(api, "linnet_en");
  ExpectComment(api, english, "cloud", "cloud", "klaʊd", "云");
  ExpectCorrection(api, english);
  ExpectCandidate(api, english, "yun", "cloud");
  ExpectPrediction(api, english);
  api->destroy_session(english);

  const RimeSessionId pinyin = CreateSession(api, "linnet_zh_pinyin");
  RimeConfig schema_config = {};
  if (!api->schema_open("linnet_zh_pinyin", &schema_config)) {
    Fail("deployed Chinese configuration is unavailable");
  }
  char grammar[128] = {};
  const bool has_grammar = api->config_get_string(
      &schema_config, "grammar/language", grammar, sizeof(grammar));
  api->config_close(&schema_config);
  if (!has_grammar || std::string(grammar) != "wanxiang-lts-zh-hans") {
    Fail("Windows must use the product LTS model, not the developer fixture");
  }
  ExpectCandidate(api, pinyin, "nihao", "你好");
  api->set_option(pinyin, "traditionalization", True);
  ExpectCandidate(api, pinyin, "ceshi", "測試");
  api->set_option(pinyin, "traditionalization", False);
  ExpectCandidate(api, pinyin, "ceshi", "测试");
  api->set_option(pinyin, "emoji", True);
  ExpectCandidateContaining(api, pinyin, "nihao", "👋");
  api->set_option(pinyin, "emoji", False);
  ExpectCandidate(api, pinyin, "xierwanasi", "希尔瓦娜斯");
  ExpectMixedAndRawInput(api, pinyin);
  api->destroy_session(pinyin);

  const RimeSessionId reverse = CreateSession(api, "linnet_zh");
  ExpectCandidate(api, reverse, "U4e2d", "中");
  api->destroy_session(reverse);

  for (const char* schema : {"linnet_zh_abc", "linnet_zh_flypy",
                             "linnet_zh_jiajia", "linnet_zh_mspy",
                             "linnet_zh_sogou", "linnet_zh_ziguang"}) {
    const RimeSessionId profile = CreateSession(api, schema);
    api->destroy_session(profile);
  }

  api->finalize();
  std::cout << "linnet_windows_runtime_smoke: PASS\n";
  return 0;
}
