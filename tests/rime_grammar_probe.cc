#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>

#include "rime_api_stdbool.h"
#include "rime_api.h"

namespace {

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "rime_grammar_probe: " << message << '\n';
  std::cerr.flush();
  std::_Exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 4) {
    Fail("usage: SHARED_DIR USER_DIR KEY_SEQUENCE");
  }

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
  traits.distribution_name = "Linnet Grammar Test";
  traits.distribution_code_name = "linnet-grammar-test";
  traits.distribution_version = "0.1.0";
  traits.app_name = "rime.linnet-grammar-test";
  traits.min_log_level = 2;
  traits.log_dir = "";

  api->setup(&traits);
  api->initialize(nullptr);
  if (!api->find_module("octagram")) {
    api->finalize();
    Fail("octagram module was not loaded");
  }
  const auto started_at = std::chrono::steady_clock::now();
  const RimeSessionId session = api->create_session();
  if (!session || !api->select_schema(session, "linnet_zh_pinyin")) {
    api->finalize();
    Fail("full-pinyin session unavailable");
  }
  if (!api->simulate_key_sequence(session, argv[3])) {
    api->destroy_session(session);
    api->finalize();
    Fail("key sequence was rejected");
  }

  RimeCandidateListIterator iterator = {};
  if (!api->candidate_list_begin(session, &iterator)) {
    api->destroy_session(session);
    api->finalize();
    Fail("candidate list unavailable");
  }
  size_t count = 0;
  while (count < 20 && api->candidate_list_next(&iterator)) {
    std::cout << count << '\t'
              << (iterator.candidate.text ? iterator.candidate.text : "")
              << '\t'
              << (iterator.candidate.comment ? iterator.candidate.comment : "")
              << '\n';
    ++count;
  }
  api->candidate_list_end(&iterator);
  const auto cold_milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started_at).count();
  std::cerr << "cold_ms=" << cold_milliseconds << '\n';
  api->destroy_session(session);
  api->finalize();
  if (count == 0) {
    Fail("candidate list was empty");
  }
  return 0;
}
