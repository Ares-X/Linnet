#pragma once

#include <windows.h>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <rime_api.h>
#include "linnet_shared_runtime.h"

namespace linnet_windows {

// Same upstream exclusion name for startup, Settings and deployment. The
// Configurator adds IPC pause/resume; the server must not send IPC to itself.
class MaintenanceLock {
 public:
  MaintenanceLock() {
    handle_ = CreateMutexW(nullptr, TRUE, L"LinnetDeployerMutex");
    if (!handle_) throw std::runtime_error("Cannot acquire Linnet deployment mutex");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
      Release();
      throw std::runtime_error("Another Linnet deployment operation is running");
    }
  }
  MaintenanceLock(const MaintenanceLock&) = delete;
  MaintenanceLock& operator=(const MaintenanceLock&) = delete;
  ~MaintenanceLock() { Release(); }
  void Release() { if (handle_) { CloseHandle(handle_); handle_ = nullptr; } }
 private:
  HANDLE handle_ = nullptr;
};

struct RuntimePaths {
  std::string shared, user, prebuilt, staging;
  RuntimePaths(const std::filesystem::path& core, const std::filesystem::path& user_root,
               const char* version, bool recover) {
#if defined(_M_X64)
    struct Result { RuntimePaths* paths; std::string error; } result{this, {}};
    const auto receive = [](void* context, const char* shared, const char* user,
                            const char* prebuilt, const char* staging) {
      auto& paths = *static_cast<Result*>(context)->paths;
      paths.shared = shared;
      paths.user = user;
      paths.prebuilt = prebuilt;
      paths.staging = staging;
    };
    const auto failed = [](void* context, const char* message) {
      static_cast<Result*>(context)->error = message;
    };
    if (linnet_data_setup(core.u8string().c_str(), user_root.u8string().c_str(),
                         version, recover ? 1 : 0, &result, receive, failed) != 0)
      throw std::runtime_error(result.error);
#else
    // The unshipped Win32 host remains buildable for upstream's x86 solution.
    // Installed x86 TIPs use the x64 host and never load Swift themselves.
    (void)version;
    (void)recover;
    shared = core.u8string();
    user = user_root.u8string();
    prebuilt = shared;
    staging = (user_root / "build").u8string();
#endif
  }
  void Apply(RimeTraits& traits) const {
    traits.shared_data_dir = shared.c_str();
    traits.user_data_dir = user.c_str();
    traits.prebuilt_data_dir = prebuilt.c_str();
    traits.staging_dir = staging.c_str();
  }
};

// Keep Rime's incremental deployment/cache as the only compiled-data owner.
// Running it on startup/resume also completes an interrupted rollback before
// accepting input; no parallel deployment receipt or cache-state parser.
inline bool DeployWorkspace() {
  auto* rime = rime_get_api();
  const bool workspace = rime->deploy();
  const bool frontend = rime->deploy_config_file("weasel.yaml", "config_version");
  return workspace && frontend;
}

}  // namespace linnet_windows
