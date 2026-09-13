#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <utility>
#include <vector>
#include <rime_api_stdbool.h>
#include <rime_api.h>

namespace {
void Require(bool value, const std::string& message) {
  if (!value) {
    std::cerr << "chinese_phrase_ranking_test: " << message << '\n';
    std::_Exit(1);
  }
}

std::vector<std::string> Split(const std::string& line) {
  std::vector<std::string> columns;
  size_t begin = 0;
  for (;;) {
    const auto end = line.find('\t', begin);
    columns.push_back(line.substr(begin, end - begin));
    if (end == std::string::npos) return columns;
    begin = end + 1;
  }
}

RimeSessionId Session(RimeApi_stdbool* api, const char* schema) {
  const auto id = api->create_session();
  Require(id && api->select_schema(id, schema), std::string("cannot select ") + schema);
  api->set_option(id, "ascii_mode", false);
  api->set_option(id, "emoji", false);
  return id;
}

std::vector<std::string> Candidates(RimeApi_stdbool* api, RimeSessionId id,
                                    size_t count = 10) {
  std::vector<std::string> words;
  RimeCandidateListIterator iterator = {};
  if (api->candidate_list_begin(id, &iterator)) {
    while (words.size() < count && api->candidate_list_next(&iterator))
      words.emplace_back(iterator.candidate.text);
    api->candidate_list_end(&iterator);
  }
  return words;
}

size_t Rank(const std::vector<std::string>& words, const std::string& target) {
  const auto at = std::find(words.begin(), words.end(), target);
  return at == words.end() ? 0 : at - words.begin() + 1;
}

void Enter(RimeApi_stdbool* api, RimeSessionId id, const std::string& code) {
  api->clear_composition(id);
  Require(api->simulate_key_sequence(id, code.c_str()), "rejected input " + code);
  Require(api->get_input(id) && code == api->get_input(id), "changed raw code " + code);
}

std::string Commit(RimeApi_stdbool* api, RimeSessionId id) {
  RimeCommit value = {};
  RIME_STRUCT_INIT(RimeCommit, value);
  Require(api->get_commit(id, &value), "missing commit");
  const std::string text = value.text;
  api->free_commit(&value);
  return text;
}

void Choose(RimeApi_stdbool* api, RimeSessionId id, const std::string& text) {
  const auto rank = Rank(Candidates(api, id, 128), text);
  Require(rank && api->select_candidate(id, rank - 1), "cannot select " + text);
}

void Corpus(RimeApi_stdbool* api, const char* fixture) {
  std::ifstream input(fixture);
  Require(input.good(), "cannot open semantic fixture");
  size_t count = 0;
  for (std::string line; std::getline(input, line);) {
    if (line.empty() || line.front() == '#' || line.rfind("category\t", 0) == 0) continue;
    const auto c = Split(line);
    Require(c.size() == 6, "invalid semantic fixture row");
    for (const auto& profile : std::vector<std::pair<const char*, size_t>>{
             {"linnet_zh_pinyin", 1}, {"linnet_zh", 2}}) {
      const auto id = Session(api, profile.first);
      Enter(api, id, c[profile.second]);
      const auto words = Candidates(api, id);
      std::cout << profile.first << '\t' << c[profile.second] << '\t';
      for (const auto& word : words) std::cout << '[' << word << ']';
      std::cout << '\n';
      Require(!words.empty() && (words.front() == c[3] || words.front() == c[4]),
              c[profile.second] + " unexpected first choice");
      // Genuine semantic ambiguity permits either first choice, but the user's
      // intended whole sentence must stay directly selectable on the first page.
      Require(Rank(words, c[3]) && Rank(words, c[3]) <= 3,
              c[profile.second] + " lost the intended composition " + c[3]);
      if (c[5] != "-") Require(Rank(words, c[5]), "lost technical term " + c[5]);
      // No selections here: every case sees empty learning state. Learning and
      // actual commits are exercised after all baseline queries below.
      api->destroy_session(id);
      ++count;
    }
  }
  Require(count > 0, "empty semantic fixture");
  std::cout << "semantic corpus: PASS (" << count << " cases)\n";
}

struct Profile { const char* schema; const char* code; };
const std::vector<Profile> profiles = {
    {"linnet_zh_pinyin", "yijinglianjie"}, {"linnet_zh", "yijylmjx"},
    {"linnet_zh_flypy", "yijklmjp"}, {"linnet_zh_mspy", "yij;lmjx"},
    {"linnet_zh_sogou", "yij;lmjx"}, {"linnet_zh_abc", "yijylwjx"},
    {"linnet_zh_ziguang", "yij;lfjd"}, {"linnet_zh_jiajia", "yijqljjm"}};

void SelectionAndLearning(RimeApi_stdbool* api) {
  // Verify the same reading across all layouts before any case trains userdb.
  for (const auto& p : profiles) {
    const auto id = Session(api, p.schema);
    Enter(api, id, p.code);
    const auto words = Candidates(api, id);
    Require(!words.empty() && (words[0] == "已经链接" || words[0] == "已经连接"),
            std::string(p.schema) + " complete homophone still blocks composition");
    Require(Rank(words, "已经链接") && Rank(words, "已经链接") <= 3 &&
                Rank(words, "异径连接"),
            std::string(p.schema) + " incomplete competing candidates");
    api->destroy_session(id);
  }
  // While a final syllable is still abbreviated, keep the useful whole-word
  // completion instead of expanding all homophonic suffixes prematurely.
  const auto pending = Session(api, "linnet_zh_pinyin");
  for (const auto& item : std::vector<std::pair<const char*, const char*>>{
           {"sichuanchengd", "四川成都"}, {"shijichengsh", "时机成熟"},
           {"yijingzhid", "已经知道"}, {"zhangsanf", "张三丰"}}) {
    Enter(api, pending, item.first);
    Require(Candidates(api, pending).front() == item.second,
            std::string(item.first) + " lost a pending-syllable completion");
  }
  api->destroy_session(pending);
  const auto id = Session(api, "linnet_zh");
  Enter(api, id, "yijylmjx");
  api->process_key(id, ' ', 0);
  const auto first = Commit(api, id);
  Require(first == "已经连接" || first == "已经链接", "space committed wrong first choice");
  Enter(api, id, "yijylmjx");
  Choose(api, id, "已经链接");
  Require(Commit(api, id) == "已经链接", "selection changed sentence text");
  for (const auto& p : profiles) {
    const auto next = Session(api, p.schema);
    Enter(api, next, p.code);
    Require(Candidates(api, next).front() == "已经链接",
            std::string(p.schema) + " did not retain learned choice");
    api->destroy_session(next);
  }
  Enter(api, id, "yijylmjx");
  Choose(api, id, "异径连接");
  Require(Commit(api, id) == "异径连接", "technical term cannot be committed");
  Enter(api, id, "yijylmjx");
  Require(Candidates(api, id).front() == "异径连接", "technical learning lost priority");

  // Partial selection retains the original syllable boundary and composes the
  // remainder; a new full-sentence candidate must not consume a prefix early.
  Enter(api, id, "yijylmjx");
  Choose(api, id, "已经");
  Choose(api, id, "链接");
  Require(Commit(api, id) == "已经链接", "partial selection changed consumption spans");
  Enter(api, id, "yijylmjx");
  api->process_key(id, 0xff08, 0);
  Require(std::string(api->get_input(id)) == "yijylmj", "backspace changed wrong span");
  api->process_key(id, 'x', 0);
  Require(Rank(Candidates(api, id), "已经链接"), "editing lost composed candidate");
  api->process_key(id, 0xff0d, 0);
  Require(Commit(api, id) == "yijylmjx", "Return lost raw code");
  Enter(api, id, "yijylmjx");
  api->process_key(id, 0xff1b, 0);
  Require(std::string(api->get_input(id)).empty(), "Escape retained composition");
  Enter(api, id, "nihk");
  Require(Candidates(api, id).front() == "你好", "next input lost continuity");
  api->destroy_session(id);
  std::cout << "selection, raw editing, eight-profile learning: PASS\n";
}
}  // namespace

int main(int argc, char** argv) {
  Require(argc == 4, "usage: SHARED USER FIXTURE");
  auto* api = rime_get_api_stdbool();
  const std::string staging = std::string(argv[2]) + "/build";
  const std::string prebuilt = std::string(argv[1]) + "/build";
  RimeTraits traits = {};
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.staging_dir = staging.c_str();
  traits.prebuilt_data_dir = prebuilt.c_str();
  traits.app_name = "rime.chinese-phrase-ranking-test";
  traits.min_log_level = 3;
  traits.log_dir = argv[2];
  api->setup(&traits);
  api->initialize(nullptr);
  Require(api->find_module("octagram"), "missing shipped grammar module");
  Corpus(api, argv[3]);
  SelectionAndLearning(api);
  api->finalize();
}
