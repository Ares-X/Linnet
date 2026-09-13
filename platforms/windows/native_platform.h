#pragma once
#include <windows.h>
#include <stdexcept>
#include <string>

namespace linnet_windows {
inline USHORT NativeMachine() {
  using Probe = BOOL(WINAPI*)(HANDLE, USHORT*, USHORT*);
  const auto probe = reinterpret_cast<Probe>(
      GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "IsWow64Process2"));
  // The installer requires Windows 10 1903+ (Windows 11 for ARM64). Do not
  // turn an unavailable native-machine API into a guessed AMD64 update feed.
  if (!probe) throw std::runtime_error("This Windows version cannot identify its native architecture");
  USHORT process = IMAGE_FILE_MACHINE_UNKNOWN, native = IMAGE_FILE_MACHINE_UNKNOWN;
  if (!probe(GetCurrentProcess(), &process, &native))
    throw std::runtime_error("Cannot identify native Windows architecture: " +
                             std::to_string(GetLastError()));
  return native;
}
}  // namespace linnet_windows
