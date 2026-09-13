#pragma once

// The public verification key and per-native-OS feeds belong to Linnet, not
// Weasel. Private signing material must never be committed or packaged.
namespace linnet_update {
inline constexpr char public_key[] = "ZA8uOtq6ImYcLHOrUib7Kj9TdEepye2/nRFwb4xGuZc=";
inline constexpr char x64_feed[] =
    "https://raw.githubusercontent.com/Ares-X/Linnet/main/platforms/windows/appcast-x64.xml";
inline constexpr char arm64_feed[] =
    "https://raw.githubusercontent.com/Ares-X/Linnet/main/platforms/windows/appcast-arm64.xml";
}  // namespace linnet_update
