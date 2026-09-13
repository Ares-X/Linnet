#pragma once

#if defined(_M_X64)
#include <linnet_shared_runtime.h>
#include <linnet_settings_model.h>
#include <WeaselUtility.h>
#include <Windows.h>
#include <cmath>

namespace linnet_windows {

inline bool RecordLearningSyncAttempt(double seconds) {
  const ULONGLONG milliseconds = ULONGLONG(seconds * 1000);
  const auto status = RegSetKeyValueW(HKEY_CURRENT_USER, LearningSyncRegistryKey, L"LastAttempt",
      REG_QWORD, &milliseconds, sizeof(milliseconds));
  if (status != ERROR_SUCCESS) LOG(ERROR) << "Cannot record learning sync time: " << status;
  return status == ERROR_SUCCESS;
}

inline void RecordLearningSyncResult(int result) {
  const auto status = RegSetKeyValueW(HKEY_CURRENT_USER, LearningSyncRegistryKey, L"LastResult",
      REG_DWORD, &result, sizeof(result));
  if (status != ERROR_SUCCESS) LOG(ERROR) << "Cannot record learning sync result: " << status;
  LOG(INFO) << "Learning sync result: " << result;
}

// Native storage/Rime callbacks for the shared controller. The IPC server calls
// Poll on its GUI thread while holding its existing Rime-call lock.
class LearningSync {
 public:
  explicit LearningSync(const bool& disabled) : disabled_(disabled) {}
  ~LearningSync() { Reset(); }

  unsigned Poll(bool reload) {
    if (reload) {
      Reset();
      if (!disabled_) {
        try {
          Config installation;
          installation.Load(WeaselUserDataPath() / "installation.yaml");
          Bool enabled = False;
          rime_get_api()->config_get_bool(&installation.value, "linnet_auto_sync", &enabled);
          const auto directory = installation.String("sync_dir");
          if (enabled && !directory.empty()) {
            Config catalog;
            catalog.Load(WeaselSharedDataPath() / "linnet_windows_settings_catalog.yaml");
            dictionaries_.clear();
            for (size_t i = 0; i < catalog.Size("learning_dictionaries"); ++i)
              dictionaries_.push_back(catalog.String("learning_dictionaries/@" + std::to_string(i)));
            if (dictionaries_.empty()) throw std::runtime_error("Missing shared learning dictionary inventory");
            ULONGLONG last_attempt = 0;
            DWORD size = sizeof(last_attempt);
            const auto status = RegGetValueW(HKEY_CURRENT_USER, LearningSyncRegistryKey, L"LastAttempt",
                RRF_RT_REG_QWORD, nullptr, &last_attempt, &size);
            if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND)
              throw std::runtime_error("Cannot read learning sync time: " + std::to_string(status));
            handle_ = linnet_sync_create(directory.c_str(), double(last_attempt) / 1000,
                this, Step,
                [](void*, double seconds) -> int { return RecordLearningSyncAttempt(seconds); },
                [](void*, int result) { RecordLearningSyncResult(result); });
          }
        } catch (const std::exception& error) {
          LOG(ERROR) << "Learning sync configuration: " << error.what();
          RecordLearningSyncResult(-2);
        }
      }
    }
    if (!handle_) return 1000;
    const double next = linnet_sync_poll(handle_);
    // The 1s ceiling observes native maintenance/configuration changes; the
    // shared controller alone determines whether a synchronization is due.
    return next < 0 ? 1000 : unsigned(std::clamp(std::ceil(next * 1000), 10.0, 1000.0));
  }

 private:
  void Reset() {
    if (handle_) linnet_sync_destroy(handle_);
    handle_ = nullptr;
  }
  static int Step(void* context, const char* directory) {
    const auto& self = *static_cast<LearningSync*>(context);
    // Finalize has already cancelled the core operation during maintenance.
    if (self.disabled_) return directory ? 4 : 0;
    auto* api = rime_get_api();
    if (!directory) return api->sync_user_data_step(nullptr, nullptr);
    std::vector<const char*> names;
    for (const auto& name : self.dictionaries_) names.push_back(name.c_str());
    names.push_back(nullptr);
    return api->sync_user_data_step(directory, names.data());
  }
  const bool& disabled_;
  void* handle_ = nullptr;
  std::vector<std::string> dictionaries_;
};
}  // namespace linnet_windows
#endif
