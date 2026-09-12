#include <sstream>
#include <iostream>
#include <stdexcept>
#include <boost/archive/text_wiarchive.hpp>
#include <boost/archive/text_woarchive.hpp>
#include <WeaselIPCData.h>

// The pristine locked upstream header is the actual loaded-client contract,
// not a second hand-maintained description of its serialized field order.
#define weasel legacy_weasel
#include <linnet_legacy_ipc_data.h>
#undef weasel

namespace {
template <typename T>
std::wstring Encode(const T& value) {
  std::wostringstream stream;
  { boost::archive::text_woarchive archive(stream); archive << value; }
  return stream.str();
}

template <typename T>
T Decode(const std::wstring& data) {
  T result;
  std::wistringstream stream(data);
  boost::archive::text_wiarchive archive(stream);
  archive >> result;
  return result;
}

template <typename T>
void FillStyle(T& style) {
  style.font_face = L"Segoe UI, Microsoft YaHei";
  style.font_point = 21;
  style.comment_font_point = 15;
  style.max_width = 800;
  style.back_color = 0xff112233;
  style.hilited_candidate_back_color = 0xff445566;
  style.inline_preedit = true;
}

template <typename T>
void FillCandidates(T& candidates) {
  candidates.currentPage = 2;
  candidates.highlighted = 1;
  candidates.is_last_page = true;
  candidates.candies.emplace_back(L"cloud");
  candidates.candies.emplace_back(L"\u4e2d\u6587");
  candidates.comments.emplace_back(L"/kla\u028ad/ \u4e91");
  candidates.comments.emplace_back(L"\u8bcd\u6761");
  candidates.labels.emplace_back(L"1");
  candidates.labels.emplace_back(L"2");
}
}  // namespace

void CheckWindowsIPCArchive() {
  weasel::UIStyle currentStyle;
  legacy_weasel::UIStyle previousStyle;
  FillStyle(currentStyle);
  FillStyle(previousStyle);
  currentStyle.candidate_expansion_allowed = true;
  currentStyle.expanded_columns = 4;
  currentStyle.expanded_rows = 3;
  currentStyle.expanded_vertical_count = 7;
  currentStyle.detail_candidate_width = 160;
  currentStyle.detail_sidecar_width = 104;
  currentStyle.detail_footer_width = 256;
  const auto oldStyle = Encode(previousStyle);
  const auto newStyle = Encode(currentStyle);
  if (oldStyle != newStyle ||
      Decode<legacy_weasel::UIStyle>(newStyle).font_point != 21 ||
      Decode<weasel::UIStyle>(oldStyle).candidate_expansion_allowed) {
    throw std::runtime_error("Windows style archive breaks loaded-client compatibility");
  }

  weasel::CandidateInfo current;
  legacy_weasel::CandidateInfo previous;
  FillCandidates(current);
  FillCandidates(previous);
  current.expanded = true;
  current.detail = L"selected candidate detail";
  const auto oldCandidates = Encode(previous);
  const auto newCandidates = Encode(current);
  if (oldCandidates != newCandidates ||
      Decode<legacy_weasel::CandidateInfo>(newCandidates).candies.at(1).str != L"\u4e2d\u6587" ||
      Decode<weasel::CandidateInfo>(oldCandidates).expanded) {
    throw std::runtime_error("Windows candidate archive breaks loaded-client compatibility");
  }
  auto changed = current;
  changed.expanded = false;
  if (changed == current || !(changed != current))
    throw std::runtime_error("Disclosure change does not invalidate candidate presentation");
  changed = current;
  changed.detail = L"replacement detail";
  if (changed == current || !(changed != current))
    throw std::runtime_error("Detail change does not invalidate candidate presentation");
  changed.clear();
  if (!changed.empty() || !changed.comments.empty() || changed.expanded || !changed.detail.empty())
    throw std::runtime_error("Cleared candidates retain presentation from the previous composition");
  std::cout << "Windows candidate/style archive compatibility: PASS\n";
}

#ifdef LINNET_IPC_PROBE_STANDALONE
int main() {
  CheckWindowsIPCArchive();
}
#endif
