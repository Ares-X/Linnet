// Linnet golden test probe — batch keystroke simulation for candidate
// quality regression testing.
//
// Usage: rime_golden_probe SHARED_DIR USER_DIR [TOP_N [SCHEMA_NAME]]
//
// SCHEMA_NAME defaults to "linnet_zh_pinyin" and must match the deployed
// build (the caller detects it from the staged shared dir, e.g.
// linnet_zh_pinyin after a product rename).
//
// Reads one pinyin key sequence per line from stdin (blank lines and lines
// starting with '#' are ignored).  For every input the probe creates a
// fresh session, selects the linnet_zh_pinyin schema, simulates the key
// sequence, and prints up to TOP_N candidates as:
//
//   INPUT\t<key sequence>
//   <rank>\t<candidate text>
//   END
//
// An input whose key sequence is rejected prints:
//
//   INPUT\t<key sequence>
//   REJECT\t<reason>
//   END
//
// and the probe continues with the next input.  The librime runtime is
// initialized once so the whole corpus is cheap to run even with the
// grammar model loaded.  The time spent on the slowest candidate query is
// printed as COLD_MS\t<milliseconds> — with the grammar model this is the
// cold grammar-load cost.
//
// The caller (tests/verify_profile_golden.rb) deploys the shared/user data
// with bin/rime_deployer before invoking this probe.

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>

#include "rime_api_stdbool.h"
#include "rime_api.h"

namespace {

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "rime_golden_probe: " << message << '\n';
  std::cerr.flush();
  std::_Exit(1);
}

int ParseTopN(const char* text) {
  if (!text || *text == '\0') {
    return 5;
  }
  char* end = nullptr;
  long value = std::strtol(text, &end, 10);
  if (!end || *end != '\0' || value < 1 || value > 20) {
    Fail("TOP_N must be an integer in [1, 20]");
  }
  return static_cast<int>(value);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3 || argc > 5) {
    Fail("usage: SHARED_DIR USER_DIR [TOP_N [SCHEMA_NAME]]");
  }
  const int top_n = ParseTopN(argc >= 4 ? argv[3] : nullptr);
  const char* schema_name = argc >= 5 ? argv[4] : "linnet_zh_pinyin";

  auto* api = rime_get_api_stdbool();
  if (!api) {
    Fail("librime API unavailable");
  }
  const std::string staging_dir = std::string(argv[2]) + "/build";
  RimeTraits traits = {};
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.staging_dir = staging_dir.c_str();
  traits.distribution_name = "Linnet Golden Test";
  traits.distribution_code_name = "linnet-golden-test";
  traits.distribution_version = "0.1.0";
  traits.app_name = "rime.linnet-golden-test";
  traits.min_log_level = 3;
  traits.log_dir = "";

  api->setup(&traits);
  api->initialize(nullptr);
  if (!api->find_module("octagram")) {
    api->finalize();
    Fail("octagram module was not loaded");
  }

  long long max_query_ms = 0;
  std::string line;
  while (std::getline(std::cin, line)) {
    std::string key_sequence;
    for (char ch : line) {
      if (ch != ' ') {
        key_sequence.push_back(ch);
      }
    }
    if (key_sequence.empty() || key_sequence[0] == '#') {
      continue;
    }

    std::cout << "INPUT\t" << key_sequence << '\n';
    // The first session of a run pays the grammar-model load; measure from
    // session creation so COLD_MS reports it.
    const auto session_started_at = std::chrono::steady_clock::now();
    RimeSessionId session = api->create_session();
    if (!session) {
      std::cout << "REJECT\tsession unavailable\nEND\n";
      continue;
    }
    if (!api->select_schema(session, schema_name)) {
      std::cout << "REJECT\tfull-pinyin schema unavailable\nEND\n";
      api->destroy_session(session);
      continue;
    }
    if (!api->simulate_key_sequence(session, key_sequence.c_str())) {
      std::cout << "REJECT\tkey sequence rejected\nEND\n";
      api->destroy_session(session);
      continue;
    }

    RimeCandidateListIterator iterator = {};
    size_t count = 0;
    if (api->candidate_list_begin(session, &iterator)) {
      while (count < static_cast<size_t>(top_n) &&
             api->candidate_list_next(&iterator)) {
        std::cout << count << '\t'
                  << (iterator.candidate.text ? iterator.candidate.text : "")
                  << '\n';
        ++count;
      }
      api->candidate_list_end(&iterator);
    }
    const auto query_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - session_started_at).count();
    if (query_ms > max_query_ms) {
      max_query_ms = query_ms;
    }
    std::cout << "END\n";
    api->destroy_session(session);
  }

  std::cout << "COLD_MS\t" << max_query_ms << '\n';
  api->finalize();
  return 0;
}
