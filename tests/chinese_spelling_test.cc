#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <set>
#include <string>
#include <vector>
#include <rime_api_stdbool.h>
#include <rime/dict/prism.h>
#include <rime/dict/table.h>

namespace {
std::vector<double> keyLatencies;

void Require(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "chinese_spelling_test: " << message << '\n';
    std::exit(1);
  }
}

std::set<int> Spellings(rime::Prism& prism, const std::string& code) {
  int spelling = 0;
  Require(prism.GetValue(code, &spelling), "missing spelling " + code);
  std::set<int> result;
  for (auto entry = prism.QuerySpelling(spelling); !entry.exhausted(); entry.Next()) {
    if (!entry.properties().is_correction) result.insert(entry.syllable_id());
  }
  return result;
}

void CheckPair(const std::string& baseline, const std::string& current,
               const std::string& left, const std::string& right, bool enabled,
               const std::string& table_path) {
  rime::Prism before{rime::path(baseline)}, after{rime::path(current)};
  Require(before.Load() && after.Load(), "cannot load spelling indexes");
  auto original = Spellings(before, left);
  const auto alternative = Spellings(before, right);
  rime::Table table{rime::path(table_path)};
  Require(table.Load(), "cannot load syllable table");
  if (enabled) {
    for (int id : alternative) {
      const auto syllable = table.GetSyllableById(id);
      // The Chinese table also holds English entities such as LAN. Case-folded
      // codes can coincide, but a pronunciation toggle must not rewrite them.
      if (std::none_of(syllable.begin(), syllable.end(), [](unsigned char ch) {
            return ch >= 'A' && ch <= 'Z';
          })) original.insert(id);
    }
  }
  const auto actual = Spellings(after, left);
  Require(enabled ? std::includes(actual.begin(), actual.end(), original.begin(), original.end())
                  : actual == original,
          left + " does not preserve the expected pronunciations of " + right);
}

std::vector<std::string> Candidates(RimeApi_stdbool* api, RimeSessionId session) {
  std::vector<std::string> result;
  RimeCandidateListIterator it = {};
  if (api->candidate_list_begin(session, &it)) {
    while (result.size() < 128 && api->candidate_list_next(&it))
      result.emplace_back(it.candidate.text);
    api->candidate_list_end(&it);
  }
  return result;
}

void Enter(RimeApi_stdbool* api, RimeSessionId session, const std::string& input) {
  api->clear_composition(session);
  for (unsigned char key : input) {
    const auto start = std::chrono::steady_clock::now();
    api->process_key(session, key, 0);
    RimeContext_stdbool context = {};
    RIME_STRUCT_INIT(RimeContext_stdbool, context);
    if (api->get_context(session, &context)) api->free_context(&context);
    keyLatencies.push_back(std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count());
  }
}

void Expect(RimeApi_stdbool* api, RimeSessionId session, const std::string& input,
            const std::string& expected, bool commit = false) {
  Enter(api, session, input);
  const auto candidates = Candidates(api, session);
  const auto found = std::find(candidates.begin(), candidates.end(), expected);
  if (found == candidates.end()) {
    for (const auto& text : candidates) std::cerr << '[' << text << ']';
  }
  Require(found != candidates.end(), input + " is missing " + expected);
  Require(std::string(api->get_input(session)) == input, "correction changed raw input");
  std::cout << input << " -> " << expected << " rank=" << (found - candidates.begin() + 1) << '\n';
  if (commit) {
    Require(api->select_candidate(session, found - candidates.begin()), "cannot select correction");
    RimeCommit committed = {};
    RIME_STRUCT_INIT(RimeCommit, committed);
    Require(api->get_commit(session, &committed), "correction was not committed");
    Require(committed.text == expected, "incorrect committed text");
    api->free_commit(&committed);
  }
}
}  // namespace

int main(int argc, char** argv) {
  Require(argc >= 3, "expected shared and user roots");
  const std::string staging = std::string(argv[2]) + "/build";
  auto* api = rime_get_api_stdbool();
  RimeTraits traits = {};
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.staging_dir = staging.c_str();
  traits.app_name = "rime.chinese-spelling-test";
  traits.min_log_level = 3;
  traits.log_dir = "";
  api->setup(&traits);
  if (argc == 8 && std::string(argv[3]) == "--fuzzy") {
    const std::string schema = argv[4];
    const std::string base = std::string(argv[2]) + "/baseline/" + schema + ".prism.bin";
    const std::string current = staging + "/" + schema + ".prism.bin";
    const bool enabled = std::string(argv[7]) == "on";
    const auto table = std::string(argv[1]) + "/build/linnet_zh.table.bin";
    CheckPair(base, current, argv[5], argv[6], enabled, table);
    CheckPair(base, current, argv[6], argv[5], enabled, table);
    std::cout << schema << ' ' << argv[5] << '/' << argv[6] << ' ' << argv[7] << ": PASS\n";
    return 0;
  }
  if (argc >= 5 && std::string(argv[3]) == "--deploy") {
    api->deployer_initialize(nullptr);
    const auto start = std::chrono::steady_clock::now();
    for (int i = 4; i < argc; ++i) {
      const auto schema = std::string(argv[1]) + "/" + argv[i] + ".schema.yaml";
      Require(api->deploy_schema(schema.c_str()), "cannot deploy " + schema);
    }
    std::cout << "deploy_schema " << argc - 4 << " profiles: "
              << std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count()
              << " seconds\n";
    api->finalize();
    return 0;
  }
  api->initialize(nullptr);
  struct Profile { const char* schema; const char* typo; const char* good; const char* better; };
  for (const auto& profile : std::vector<Profile>{
      {"linnet_zh", "hghk", "hfhk", "gghk"},
      {"linnet_zh_flypy", "hghc", "hfhc", "gghc"},
      {"linnet_zh_mspy", "hghk", "hfhk", "gghk"},
      {"linnet_zh_sogou", "hghk", "hfhk", "gghk"},
      {"linnet_zh_abc", "hghk", "hfhk", "gghk"},
      {"linnet_zh_ziguang", "hthq", "hwhq", "gthq"},
      {"linnet_zh_jiajia", "hthd", "hrhd", "gthd"}}) {
    const auto session = api->create_session();
    Require(api->select_schema(session, profile.schema), std::string("cannot select ") + profile.schema);
    api->set_option(session, "ascii_mode", false);
    std::cout << profile.schema << '\n';
    Expect(api, session, profile.typo, "更好");
    Expect(api, session, profile.typo, "很好");
    Expect(api, session, profile.good, "很好");
    Require(Candidates(api, session).front() == "很好", "normal double-pinyin word lost first choice");
    Expect(api, session, profile.better, "更好");
    Require(Candidates(api, session).front() == "更好", "normal double-pinyin word lost first choice");
    api->destroy_session(session);
  }
  const auto session = api->create_session();
  api->select_schema(session, "linnet_zh_pinyin");
  Expect(api, session, "nihao", "你好");
  Expect(api, session, "nihap", "你好", true);
  Expect(api, session, "shnaghai", "上海");
  Expect(api, session, "henghao", "很好");
  api->select_schema(session, "linnet_zh");
  Expect(api, session, "hk", "好");
  Expect(api, session, "hg", "哼");
  Expect(api, session, "nihk", "你好");
  Expect(api, session, "nihj", "你好", true);
  Expect(api, session, "hghk", "很好", true);
  // Committing a correction must keep normal pronunciation and later input usable.
  Expect(api, session, "hfhk", "很好");
  Enter(api, session, "hk");
  api->process_key(session, 0xff0d, 0);  // Return commits the untouched raw code.
  RimeCommit raw = {};
  RIME_STRUCT_INIT(RimeCommit, raw);
  Require(api->get_commit(session, &raw) && std::string(raw.text) == "hk", "raw Return changed");
  api->free_commit(&raw);
  api->destroy_session(session);
  api->finalize();
  std::sort(keyLatencies.begin(), keyLatencies.end());
  std::cout << "Key + visible context latency: samples=" << keyLatencies.size()
            << " p50=" << keyLatencies[keyLatencies.size() / 2]
            << " p95=" << keyLatencies[keyLatencies.size() * 95 / 100]
            << " max=" << keyLatencies.back() << " ms\n";
  std::cout << "Chinese spelling, correction selection and continuity: PASS\n";
}
