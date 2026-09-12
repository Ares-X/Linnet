#pragma once

#include <algorithm>
#include <filesystem>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include <rime_api.h>
#include <rime/config.h>

namespace linnet_windows {

// The native Rime parser and serializer own all YAML. This small model only
// applies the choices exported by the shared Swift settings renderer.
class Config {
 public:
  rime::Config document;
  // Rime's public C and C++ interfaces share the same Config object. Keep its
  // lifetime here; the C API borrows it for item/list operations.
  RimeConfig value = {&document};
  Config() = default;
  Config(const Config&) = delete;
  Config& operator=(const Config&) = delete;
  void Load(const std::filesystem::path& path) {
    if (!document.LoadFromFile(rime::path(path.native())))
      throw std::runtime_error("Cannot read configuration: " + path.u8string());
  }
  void Save(const std::filesystem::path& path) {
    if (!document.SaveToFile(rime::path(path.native())))
      throw std::runtime_error("Cannot save configuration: " + path.u8string());
  }
  std::string String(const std::string& key) {
    const char* text = rime_get_api()->config_get_cstring(&value, key.c_str());
    return text ? text : "";
  }
  int Int(const std::string& key, int fallback = 0) {
    int result = fallback;
    rime_get_api()->config_get_int(&value, key.c_str(), &result);
    return result;
  }
  size_t Size(const std::string& key) {
    return rime_get_api()->config_list_size(&value, key.c_str());
  }
};

struct Option {
  std::string id;
  std::string label;
  std::string group;
  std::vector<std::string> choices;
  std::vector<std::string> choice_ids;
  int selected = 0;
  int default_index = 0;
  int original = 0;
  bool reset = false;
};

class Settings {
 public:
  std::vector<Option> options;
  std::string font_face;
  bool reset_font = false;
  Settings(const std::filesystem::path& shared, const std::filesystem::path& user)
      : user_(user) {
    catalog_.Load(shared / "linnet_windows_settings_catalog.yaml");
    Config saved;
    const auto path = user / "linnet_windows_settings.yaml";
    if (std::filesystem::exists(path)) saved.Load(path);
    font_face = saved.String("appearance/font_face");
    for (size_t i = 0; i < catalog_.Size("options"); ++i) {
      const auto key = At("options", i);
      Option option;
      option.id = catalog_.String(key + "/id");
      option.label = catalog_.String(key + "/label");
      option.group = catalog_.String(key + "/group");
      option.default_index = catalog_.Int(key + "/defaultIndex");
      for (size_t j = 0; j < catalog_.Size(key + "/choices"); ++j) {
        option.choices.push_back(catalog_.String(At(key + "/choices", j) + "/label"));
        option.choice_ids.push_back(catalog_.String(At(key + "/choices", j) + "/id"));
      }
      const auto selection = saved.String("choices/" + option.id);
      const auto found = std::find(option.choice_ids.begin(), option.choice_ids.end(), selection);
      option.selected = selection.empty() ? option.default_index : int(found - option.choice_ids.begin());
      if (option.selected < 0 || size_t(option.selected) >= option.choices.size())
        throw std::runtime_error("Unsupported saved setting: " + option.id);
      options.push_back(std::move(option));
    }
    ReadNativeAppearance(shared);
    AcceptChanges();
  }

  std::vector<std::filesystem::path> OwnedFiles() {
    std::vector<std::filesystem::path> files = {user_ / "linnet_windows_settings.yaml"};
    for (const auto& schema : Schemas()) files.push_back(ProjectionPath(schema));
    return files;
  }

  void AcceptChanges() {
    for (auto& option : options) { option.original = option.selected; option.reset = false; }
    original_font_ = font_face;
    reset_font = false;
  }

  // The existing Configurator owns exclusion/maintenance and deployment. Native
  // .custom.yaml is the only user layer: edit the requested keys, retain others.
  void Save() {
    auto* rime = rime_get_api();
    std::map<std::string, rime::an<rime::ConfigMap>> patches;
    for (const auto& schema : Schemas())
      patches.emplace(schema, rime::New<rime::ConfigMap>());
    std::map<std::string, std::set<std::string>> changed;
    std::map<std::string, std::vector<std::string>> removals, additions;
    for (size_t i = 0; i < options.size(); ++i) {
      const auto& option = options[i];
      if (option.selected < 0 || size_t(option.selected) >= option.choices.size())
        throw std::runtime_error("Invalid choice: " + option.id);
      if (option.selected != option.original || option.reset) {
        for (size_t j = 0; j < catalog_.Size(At("options", i) + "/choices"); ++j) {
          const auto variant = At(At("options", i) + "/choices", j);
          for (size_t k = 0; k < catalog_.Size(variant + "/patches"); ++k) {
            const auto projected = At(variant + "/patches", k);
            const auto schema = catalog_.String(projected + "/schema");
            for (size_t n = 0; n < catalog_.Size(projected + "/entries"); ++n) {
              const auto name = catalog_.String(At(projected + "/entries", n) + "/key");
              changed[schema].insert(name == "linnet/windows_fuzzy" ? "speller/algebra" : name);
            }
          }
        }
      }
      // An existing custom theme is a read-only choice until the user edits it.
      if (size_t(option.selected) >= catalog_.Size(At("options", i) + "/choices")) continue;
      if (option.selected == option.default_index) continue;
      const auto choice = At(At("options", i) + "/choices", option.selected);
      for (size_t j = 0; j < catalog_.Size(choice + "/patches"); ++j) {
        const auto projected = At(choice + "/patches", j);
        const auto schema = catalog_.String(projected + "/schema");
        for (size_t k = 0; k < catalog_.Size(projected + "/entries"); ++k) {
          const auto entry = At(projected + "/entries", k);
          const auto name = catalog_.String(entry + "/key");
          if (name == "linnet/windows_fuzzy") {
            AppendStrings(entry + "/value/remove", removals[schema]);
            AppendStrings(entry + "/value/add", additions[schema]);
          } else {
            patches.at(schema)->Set(name, catalog_.document.GetMap(entry)->Get("value"));
          }
        }
      }
    }
    for (size_t i = 0; i < catalog_.Size("algebra"); ++i) {
      const auto key = At("algebra", i);
      const auto schema = catalog_.String(key + "/schema");
      if (!additions.count(schema)) continue;
      std::vector<std::string> rules;
      AppendStrings(key + "/rules", rules);
      const auto& removed = removals[schema];
      rules.erase(std::remove_if(rules.begin(), rules.end(), [&](const std::string& rule) {
        return std::find(removed.begin(), removed.end(), rule) != removed.end();
      }), rules.end());
      rules.insert(rules.end(), additions[schema].begin(), additions[schema].end());
      auto algebra = rime::New<rime::ConfigMap>();
      algebra->Set("__include", rime::New<rime::ConfigValue>(catalog_.String(key + "/include")));
      auto insertions = rime::New<rime::ConfigList>();
      // @before is a literal patch-map key, not a Config path/list index.
      // Insertion order is identical to the canonical renderer.
      for (auto rule = rules.rbegin(); rule != rules.rend(); ++rule) {
        auto insertion = rime::New<rime::ConfigMap>();
        insertion->Set("@before 0", rime::New<rime::ConfigValue>(*rule));
        insertions->Append(insertion);
      }
      algebra->Set("__patch", insertions);
      patches.at(schema)->Set("speller/algebra", algebra);
    }
    if (font_face != original_font_ || reset_font) {
      for (const auto* key : {"style/font_face", "style/label_font_face", "style/comment_font_face"})
        changed["weasel"].insert(key);
    }
    if (!font_face.empty()) {
      for (const auto* key : {"style/font_face", "style/label_font_face", "style/comment_font_face"})
        patches.at("weasel")->Set(key, rime::New<rime::ConfigValue>(font_face));
    }
    for (const auto& entry : changed) {
      Config projection;
      const auto path = ProjectionPath(entry.first);
      if (std::filesystem::exists(path)) projection.Load(path);
      auto merged = rime::New<rime::ConfigMap>();
      auto previous = projection.document.GetMap("patch");
      RimeConfigIterator iterator = {};
      rime->config_begin_map(&iterator, &projection.value, "patch");
      while (rime->config_next(&iterator)) {
        if (!entry.second.count(iterator.key)) merged->Set(iterator.key, previous->Get(iterator.key));
      }
      rime->config_end(&iterator);
      for (const auto& key : entry.second) {
        if (auto value = patches.at(entry.first)->Get(key)) merged->Set(key, value);
      }
      projection.document.SetItem("patch", merged);
      projection.Save(ProjectionPath(entry.first));
    }
    Config saved;
    for (const auto& option : options) {
      if (option.choice_ids[option.selected] != "custom")
        rime->config_set_string(&saved.value, ("choices/" + option.id).c_str(), option.choice_ids[option.selected].c_str());
    }
    rime->config_set_string(&saved.value, "appearance/font_face", font_face.c_str());
    saved.Save(user_ / "linnet_windows_settings.yaml");
  }

 private:
  Config catalog_;
  std::filesystem::path user_;
  std::string original_font_;
  void ReadNativeAppearance(const std::filesystem::path& shared) {
    Config defaults, custom;
    defaults.Load(shared / "linnet_windows_appearance_defaults.yaml");
    const auto path = user_ / "weasel.custom.yaml";
    if (!std::filesystem::exists(path)) return;
    custom.Load(path);
    auto native = custom.document.GetMap("patch");
    if (!native) return;
    if (auto font = native->GetValue("style/font_face")) font_face = font->str();
    auto base = defaults.document.GetMap("patch");
    std::map<std::string, std::string> actual;
    for (const auto* key : {"style/color_scheme", "style/color_scheme_dark"}) {
      auto value = native->GetValue(key);
      actual[key] = value ? value->str() : base->GetValue(key)->str();
    }
    for (size_t i = 0; i < options.size(); ++i) {
      auto& option = options[i];
      if (option.id != "theme") continue;
      for (size_t j = 0; j < option.choices.size(); ++j) {
        std::map<std::string, std::string> expected;
        for (const auto& entry : actual) expected[entry.first] = base->GetValue(entry.first)->str();
        const auto choice = At(At("options", i) + "/choices", j);
        for (size_t k = 0; k < catalog_.Size(choice + "/patches"); ++k) {
          const auto patch = At(choice + "/patches", k);
          if (catalog_.String(patch + "/schema") != "weasel") continue;
          for (size_t n = 0; n < catalog_.Size(patch + "/entries"); ++n) {
            const auto entry = At(patch + "/entries", n);
            const auto key = catalog_.String(entry + "/key");
            if (expected.count(key)) expected[key] = catalog_.String(entry + "/value");
          }
        }
        if (actual == expected) { option.selected = int(j); return; }
      }
      option.selected = int(option.choices.size());
      option.choices.push_back("自定义（保留） / Custom (preserve)");
      option.choice_ids.push_back("custom");
    }
  }
  static std::string At(const std::string& path, size_t index) {
    return path + "/@" + std::to_string(index);
  }
  void AppendStrings(const std::string& key, std::vector<std::string>& result) {
    for (size_t i = 0; i < catalog_.Size(key); ++i)
      result.push_back(catalog_.String(At(key, i)));
  }
  std::vector<std::string> Schemas() {
    std::vector<std::string> result = {"default", "linnet_en", "weasel"};
    for (size_t i = 0; i < catalog_.Size("algebra"); ++i)
      result.push_back(catalog_.String(At("algebra", i) + "/schema"));
    return result;
  }
  std::filesystem::path ProjectionPath(const std::string& schema) {
    return user_ / (schema + ".custom.yaml");
  }
};

}  // namespace linnet_windows
