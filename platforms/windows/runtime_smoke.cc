#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

#include "rime_api.h"
#include "rime_levers_api.h"
#include "settings_model.h"

#ifdef _WIN32
void CheckWindowsIPCArchive();
#endif

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

void ExpectEnglishSchemaSwitch(RimeApi* api, RimeSessionId session) {
  RimeConfig config = {};
  char english_name[128] = {};
  if (!api->schema_open("linnet_en", &config)) Fail("English schema unavailable");
  const bool has_name = api->config_get_string(
      &config, "schema/name", english_name, sizeof(english_name));
  api->config_close(&config);
  if (!has_name) Fail("English schema name unavailable");
  const auto menu = Enter(api, session, "{Control+grave}");
  const auto& english = Find(menu, english_name);
  if (!api->select_candidate(session, static_cast<size_t>(&english - menu.data())))
    Fail("English schema cannot be selected from the switcher");
  char current[128] = {};
  if (!api->get_current_schema(session, current, sizeof(current)) ||
      std::string(current) != "linnet_en") {
    Fail("schema shortcut did not activate Smart English");
  }
}

void SnapshotProbe(RimeApi* api, const char* user) {
  namespace fs = std::filesystem;
  const fs::path root(user);
  const auto sync = root / fs::u8path("sync-数据");
  linnet_windows::Config installation;
  installation.Load(root / "installation.yaml");
  installation.document.SetString("sync_dir", sync.u8string());
  installation.Save(root / "installation.yaml");
  if (!api->run_task("installation_update")) Fail("snapshot installation fixture failed");
  auto* levers = reinterpret_cast<RimeLeversApi*>(api->find_module("levers")->get_api());
  const char* dictionary = "linnet_snapshot_probe";
  const auto source = root / "snapshot-probe.userdb.txt";
  const std::string records =
      "bao liu \t保留学习\tc=12 d=1.25 t=19\n"
      "shan chu \t删除标记\tc=-5 d=0.75 t=19\n";
  {
    std::ofstream fixture(source, std::ios::binary);
    fixture.exceptions(std::ios::badbit | std::ios::failbit);
    fixture << "# Rime user dictionary\n#@/db_name\t" << dictionary
            << "\n#@/db_type\tuserdb\n#@/tick\t19\n#@/user_id\t"
            << api->get_user_id() << '\n' << records;
  }
  if (!levers->restore_user_dict(source.u8string().c_str()) ||
      !levers->backup_user_dict(dictionary)) Fail("native snapshot round-trip failed");
  char directory[32768] = {};
  api->get_user_data_sync_dir(directory, sizeof(directory) - 1);
  if (fs::path(directory) != sync / api->get_user_id())
    Fail("native snapshot getter changed the Unicode directory");
  const auto backup = fs::path(directory) / (std::string(dictionary) + ".userdb.txt");
  const auto read = [](const fs::path& file) {
    std::ifstream stream(file, std::ios::binary);
    if (!stream) Fail("cannot read snapshot fixture");
    std::string result((std::istreambuf_iterator<char>(stream)), {});
    result.erase(std::remove(result.begin(), result.end(), '\r'), result.end());
    return result;
  };
  const std::string before = read(backup);
  if (before.find(records) == std::string::npos)
    Fail("snapshot lost learning weights, ticks or deleted entries");
  const auto foreign = sync / "foreign-device";
  fs::create_directory(foreign);
  const auto table = foreign / backup.filename();
  if (levers->export_user_dict(dictionary, table.u8string().c_str()) != 1)
    Fail("native text export fixture failed");
  if (levers->restore_user_dict(table.u8string().c_str()))
    Fail("text table was accepted as a learning snapshot");
  if (!levers->backup_user_dict(dictionary) || read(backup) != before)
    Fail("rejected text-table restore changed native learning");
  if (levers->import_user_dict("linnet_import_probe", table.u8string().c_str()) != 1)
    Fail("native text-table import is no longer available");
  // sync_user_data returns scheduling status; the worker owns completion.
  // Rejecting a bad peer must fail the first cycle, not poison the next one.
  for (const bool valid : {false, true}) {
    if (valid) fs::remove(table);
    std::string completion;
    api->set_notification_handler([](void* context, RimeSessionId,
                                    const char* type, const char* value) {
      if (std::string(type) == "deploy")
        *static_cast<std::string*>(context) = value;
    }, &completion);
    const bool started = api->sync_user_data();
    if (started) api->join_maintenance_thread();
    api->set_notification_handler(nullptr, nullptr);
    if (!started || completion != (valid ? "success" : "failure"))
      Fail("native synchronization reported the wrong completion status: " + completion);
    if (read(backup) != before) Fail("synchronization changed protected snapshot records");
  }
  std::cout << "Windows Unicode snapshots/learning integrity/native sync result: PASS\n";
}

void SettingsProbe(RimeApi* api, const char* shared, const char* user) {
  // Match the existing native installer/theme-selector output, plus an
  // unrelated user customization that a Settings Apply must not remove.
  const auto native_path = std::filesystem::path(user) / "weasel.custom.yaml";
  linnet_windows::Config native;
  auto native_patch = rime::New<rime::ConfigMap>();
  native_patch->Set("style/color_scheme", rime::New<rime::ConfigValue>("linnet_glass_light"));
  native_patch->Set("style/color_scheme_dark", rime::New<rime::ConfigValue>("linnet_glass_dark"));
  native_patch->Set("style/border_width", rime::New<rime::ConfigValue>(3));
  native.document.SetItem("patch", native_patch);
  native.Save(native_path);
  linnet_windows::Settings settings(shared, user);
  for (auto& option : settings.options) {
    if (option.id == "theme" && option.choice_ids[option.selected] != "native_glass/system")
      Fail("Settings did not read the existing native theme");
    if (option.id == "fuzzy_n_l" || option.id == "fuzzy_en_eng") option.selected = 1;
    if (option.id == "ipa" || option.id == "translation") option.selected = 0;
    if (option.id == "page_size") option.selected = 1;  // five candidates
    if (option.id == "font_point" || option.id == "theme" || option.id == "chinese_layout") {
      const std::string value = option.id == "font_point" ? "24" :
                                option.id == "theme" ? "moon_jade/dark" : "vertical";
      const auto selected = std::find(option.choice_ids.begin(), option.choice_ids.end(), value);
      if (selected == option.choice_ids.end()) Fail("settings choice unavailable: " + value);
      option.selected = int(selected - option.choice_ids.begin());
    }
  }
  settings.font_face = "Consolas";
  // A real filesystem failure must not report success or publish UI choices
  // that the input runtime could not receive. The caller uses isolated data.
  const auto blocked = std::filesystem::path(user) /
                       "linnet_en.custom.yaml";
  if (!std::filesystem::create_directory(blocked))
    Fail("settings failure fixture already exists");
  bool write_failed = false;
  try { settings.Save(); }
  catch (const std::runtime_error&) { write_failed = true; }
  std::filesystem::remove(blocked);
  if (!write_failed) Fail("settings accepted a failed projection write");
  if (std::filesystem::exists(std::filesystem::path(user) / "linnet_windows_settings.yaml"))
    Fail("failed projection write published the saved choices");
  settings.Save();
  linnet_windows::Settings reread(shared, user);
  if (reread.font_face != "Consolas" || reread.options.size() != settings.options.size())
    Fail("native settings did not persist");
  for (size_t i = 0; i < settings.options.size(); ++i)
    if (settings.options[i].selected != reread.options[i].selected)
      Fail("setting did not round-trip: " + settings.options[i].id);
  if (!api->deploy()) Fail("settings could not deploy");
  RimeConfig config = {};
  if (!api->schema_open("linnet_zh_pinyin", &config)) Fail("settings schema unavailable");
  Bool ipa = True, translation = True;
  api->config_get_bool(&config, "linnet_english_interaction/show_ipa", &ipa);
  api->config_get_bool(&config, "linnet_english_interaction/show_translation", &translation);
  if (ipa || translation) Fail("metadata visibility settings were ignored");
  bool nasal = false, initials = false;
  RimeConfigIterator algebra = {};
  api->config_begin_list(&algebra, &config, "speller/algebra");
  while (api->config_next(&algebra)) {
    const char* value = api->config_get_cstring(&config, algebra.path);
    const std::string rule = value ? value : "";
    initials |= rule == "fuzz/^n/l/";
    nasal |= rule == "fuzz/(e|ē|é|ě|è)n$/$1ng/";
  }
  api->config_end(&algebra);
  api->config_close(&config);
  if (!nasal || !initials) Fail("combined fuzzy choices overwrote each other");
  if (!api->config_open("default", &config)) Fail("deployed defaults unavailable");
  int page_size = 0;
  api->config_get_int(&config, "menu/page_size", &page_size);
  api->config_close(&config);
  if (page_size != 5) Fail("candidate page size did not apply");
  if (!api->deploy_config_file("weasel.yaml", "config_version") ||
      !api->config_open("weasel", &config)) Fail("appearance settings could not deploy");
  int font_point = 0;
  api->config_get_int(&config, "style/font_point", &font_point);
  const char* scheme = api->config_get_cstring(&config, "style/color_scheme");
  const char* dark = api->config_get_cstring(&config, "style/color_scheme_dark");
  const char* font = api->config_get_cstring(&config, "style/font_face");
  if (font_point != 24 || !scheme || std::string(scheme) != "linnet_moon_jade_dark" ||
      !dark || std::string(dark) != scheme || !font || std::string(font) != "Consolas")
    Fail("appearance choices were not projected to Weasel");
  int candidate_width = 0, sidecar_width = 0, footer_width = 0;
  api->config_get_int(&config, "style/linnet_detail_candidate_width", &candidate_width);
  api->config_get_int(&config, "style/linnet_detail_sidecar_width", &sidecar_width);
  api->config_get_int(&config, "style/linnet_detail_footer_width", &footer_width);
  if (candidate_width != 240 || sidecar_width != 104 || footer_width != 360)
    Fail("candidate detail geometry did not follow the selected font size");
  int border_width = 0;
  api->config_get_int(&config, "style/border_width", &border_width);
  if (border_width != 3) Fail("Settings Apply discarded unrelated native customization");
  api->config_close(&config);
  if (!api->schema_open("linnet_zh_pinyin", &config)) Fail("layout schema unavailable");
  Bool horizontal = True;
  api->config_get_bool(&config, "style/horizontal", &horizontal);
  api->config_close(&config);
  if (horizontal) Fail("vertical candidate layout was not projected to Weasel");
  settings.AcceptChanges();
  for (auto& option : settings.options) { option.selected = option.default_index; option.reset = true; }
  settings.font_face.clear();
  settings.Save();
  if (!api->deploy()) Fail("default settings could not be restored");
  if (!api->config_open("default", &config)) Fail("restored defaults unavailable");
  api->config_get_int(&config, "menu/page_size", &page_size);
  api->config_close(&config);
  if (page_size != 9) Fail("candidate page size did not reset");
  if (!api->deploy_config_file("weasel.yaml", "config_version") ||
      !api->config_open("weasel", &config)) Fail("appearance reset could not deploy");
  api->config_get_int(&config, "style/font_point", &font_point);
  font = api->config_get_cstring(&config, "style/font_face");
  scheme = api->config_get_cstring(&config, "style/color_scheme");
  if (font_point != 16 || !font || std::string(font) == "Consolas" ||
      !scheme || std::string(scheme) != "linnet_paper_light")
    Fail("appearance reset retained previous user choices");
  api->config_get_int(&config, "style/linnet_detail_candidate_width", &candidate_width);
  api->config_get_int(&config, "style/linnet_detail_sidecar_width", &sidecar_width);
  api->config_get_int(&config, "style/linnet_detail_footer_width", &footer_width);
  if (candidate_width != 160 || sidecar_width != 104 || footer_width != 256)
    Fail("candidate detail geometry did not reset with the font size");
  api->config_close(&config);
  // Unknown native themes must remain selectable as custom, not be shown as a
  // stock theme or replaced while the user edits an unrelated setting.
  native_patch->Set("style/color_scheme", rime::New<rime::ConfigValue>("personal_theme"));
  native_patch->Set("style/color_scheme_dark", rime::New<rime::ConfigValue>("personal_dark"));
  native.Save(native_path);
  linnet_windows::Settings custom(shared, user);
  for (auto& option : custom.options) {
    if (option.id == "theme" && option.choice_ids[option.selected] != "custom")
      Fail("unknown native theme was misrepresented as a stock theme");
    if (option.id == "ipa") option.selected = 0;
  }
  custom.Save();
  linnet_windows::Config preserved;
  preserved.Load(native_path);
  if (preserved.document.GetMap("patch")->GetValue("style/color_scheme")->str() != "personal_theme")
    Fail("editing input settings replaced an unrelated custom theme");
  std::cout << "Windows native settings persistence/composition/deployment: PASS\n";
  SnapshotProbe(api, user);
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
#ifdef _WIN32
  CheckWindowsIPCArchive();
#endif
  if (argc != 3 && !(argc == 4 && (std::string(argv[3]) == "--expect-deploy-failure" || std::string(argv[3]) == "--settings-probe"))) {
    Fail("usage: runtime_smoke SHARED_DATA_DIR USER_DATA_DIR [--expect-deploy-failure|--settings-probe]");
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
  if (argc == 4 && std::string(argv[3]) == "--settings-probe") {
    api->deployer_initialize(nullptr);
    try { SettingsProbe(api, argv[1], argv[2]); }
    catch (const std::exception& error) { Fail(error.what()); }
    api->finalize();
    return 0;
  }
  if (argc == 4) {
    api->deployer_initialize(nullptr);
    const bool deployed = api->deploy();
    api->finalize();
    if (deployed) Fail("missing user-selected schema was ignored during deployment");
    std::cout << "linnet_windows_runtime_smoke: user customization deployment failure PASS\n";
    return 0;
  }
  api->initialize(nullptr);
  for (const char* module : {"lua", "octagram", "predict", "smart_english"}) {
    if (!api->find_module(module)) {
      Fail(std::string("merged runtime module is missing: ") + module);
    }
  }
  if (api->start_maintenance(true)) {
    api->join_maintenance_thread();
  }

  const RimeSessionId english = CreateSession(api, "linnet_zh_pinyin");
  ExpectEnglishSchemaSwitch(api, english);
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
  for (const auto& sample : std::vector<std::pair<const char*, const char*>>{
           {"kuaregiondemigration", "跨region的migration"},
           {"womenxuyaoalignyixiazhegegapdesolution", "我们需要align一下这个gap的solution"},
           {"nihap", "你好"}, {"henghao", "很好"}}) {
    const auto candidates = Enter(api, pinyin, sample.first);
    const auto& candidate = Find(candidates, sample.second);
    const auto index = &candidate - candidates.data();
    if (!api->select_candidate(pinyin, static_cast<size_t>(index)) ||
        TakeCommit(api, pinyin) != sample.second) {
      Fail("new shared input behavior cannot commit: " + std::string(sample.first));
    }
  }
  api->destroy_session(pinyin);

  const RimeSessionId reverse = CreateSession(api, "linnet_zh");
  ExpectCandidate(api, reverse, "U4e2d", "中");
  ExpectCandidate(api, reverse, "uUheng", "一");
  ExpectCandidate(api, reverse, "uUrener", "你");
  ExpectCandidate(api, reverse, "cC1+1", "2");
  ExpectCandidate(api, reverse, "V1", "一");
  ExpectCandidate(api, reverse, "kwregiondemigration", "跨region的migration");
  ExpectCandidate(api, reverse, "nihj", "你好");
  api->destroy_session(reverse);

  for (const auto& sample : std::vector<std::pair<const char*, const char*>>{
           {"linnet_zh_abc", "spfa"}, {"linnet_zh_flypy", "srfa"},
           {"linnet_zh_jiajia", "scfa"}, {"linnet_zh_mspy", "srfa"},
           {"linnet_zh_sogou", "srfa"}, {"linnet_zh_ziguang", "slfa"}}) {
    const RimeSessionId profile = CreateSession(api, sample.first);
    ExpectCandidate(api, profile, sample.second, "算法");
    api->destroy_session(profile);
  }

  api->finalize();
  std::cout << "linnet_windows_runtime_smoke: PASS\n";
  return 0;
}
