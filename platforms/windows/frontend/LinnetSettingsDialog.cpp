#include "stdafx.h"
#include "LinnetSettingsDialog.h"
#include "LinnetSettingsResource.h"
#include "Configurator.h"
#include <WeaselUtility.h>
#include <linnet_settings_model.h>
#include <rime_levers_api.h>
#include <fstream>
#include <sstream>
#include <regex>
#include <set>
#include <ShObjIdl.h>

namespace {
using linnet_windows::Config;
using linnet_windows::Settings;
namespace fs = std::filesystem;

std::string Read(const fs::path& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) throw std::runtime_error("Cannot read " + path.u8string());
  return {std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
}
void Write(const fs::path& path, const std::string& bytes) {
  const fs::path temporary = path.wstring() + L".pending";
  {
    std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
    stream.write(bytes.data(), bytes.size());
    stream.close();
    if (!stream) throw std::runtime_error("Cannot write " + path.u8string());
  }
  if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    throw std::runtime_error("Cannot publish " + path.u8string() + ": " + std::to_string(GetLastError()));
}

std::wstring Folder(HWND owner, const wchar_t* title) {
  CComPtr<IFileOpenDialog> dialog;
  if (FAILED(dialog.CoCreateInstance(CLSID_FileOpenDialog)))
    throw std::runtime_error("Windows folder picker is unavailable");
  DWORD options = 0;
  dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
  dialog->SetTitle(title);
  const auto result = dialog->Show(owner);
  if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return {};
  if (FAILED(result)) throw std::runtime_error("Cannot open folder picker");
  CComPtr<IShellItem> item;
  if (FAILED(dialog->GetResult(&item))) throw std::runtime_error("No selected folder");
  PWSTR path = nullptr;
  if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)))
    throw std::runtime_error("Selected folder is not a filesystem folder");
  const std::wstring value(path);
  CoTaskMemFree(path);
  return value;
}

struct Row { std::string code, text; };
std::vector<Row> ReadTable(const fs::path& path) {
  std::vector<Row> rows;
  if (!fs::exists(path)) return rows;
  std::istringstream stream(Read(path));
  std::string line;
  while (std::getline(stream, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty() || line.front() == '#') continue;
    const auto tab = line.find('\t');
    if (tab == std::string::npos || line.find('\t', tab + 1) != std::string::npos)
      throw std::runtime_error("Expected text<TAB>code in " + path.u8string());
    rows.push_back({line.substr(tab + 1), line.substr(0, tab)});
  }
  return rows;
}
void WriteTable(const fs::path& path, const std::vector<Row>& rows) {
  std::string result = "# Rime table\n";
  for (const auto& row : rows) result += row.text + "\t" + row.code + "\n";
  Write(path, result);
}

class SettingsDialog : public CDialogImpl<SettingsDialog> {
 public:
  enum { IDD = IDD_LINNET_SETTINGS };
  SettingsDialog(Configurator& configurator, const std::wstring& word)
      : configurator_(configurator), user_(WeaselUserDataPath()),
        settings_(WeaselSharedDataPath(), user_), draft_word_(word) { LoadPersonal(); }

  BEGIN_MSG_MAP(SettingsDialog)
    MESSAGE_HANDLER(WM_INITDIALOG, OnInit)
    MESSAGE_HANDLER(WM_CLOSE, OnClose)
    NOTIFY_HANDLER(IDC_LINNET_TABS, TCN_SELCHANGE, OnTab)
    NOTIFY_HANDLER(IDC_LINNET_LIST, LVN_ITEMCHANGED, OnItem)
    COMMAND_HANDLER(IDC_LINNET_CHOICE, CBN_SELCHANGE, OnChoice)
    COMMAND_ID_HANDLER(IDC_LINNET_ADD, OnEdit)
    COMMAND_ID_HANDLER(IDC_LINNET_REMOVE, OnRemove)
    COMMAND_ID_HANDLER(IDC_LINNET_APPLY, OnApply)
    COMMAND_ID_HANDLER(IDC_LINNET_RESET, OnReset)
    COMMAND_ID_HANDLER(IDC_LINNET_FONT, OnFont)
    COMMAND_RANGE_HANDLER(IDC_LINNET_BACKUP, IDC_LINNET_DICTIONARIES, OnData)
    COMMAND_ID_HANDLER(IDCANCEL, OnCancel)
  END_MSG_MAP()

 private:
  Configurator& configurator_;
  fs::path user_;
  Settings settings_;
  std::wstring draft_word_;
  std::vector<Row> words_, expansions_, disabled_;
  CTabCtrl tabs_;
  CListViewCtrl list_;
  CComboBox choice_;
  std::vector<size_t> visible_;
  bool dirty_ = false;
  std::set<int> dirty_personal_;
  int editing_row_ = -1;
  const std::vector<std::wstring> pages_ = {
    L"输入 / Input", L"英文 / English", L"外观 / Appearance", L"模糊音 / Fuzzy",
    L"个人词 / Words", L"禁用词 / Blocked", L"短语 / Snippets", L"数据 / Data"};

  int Page() { return tabs_.GetCurSel(); }
  bool Personal() { return Page() >= 4 && Page() <= 6; }
  std::vector<Row>& Rows() { return Page() == 4 ? words_ : Page() == 5 ? disabled_ : expansions_; }
  void Status(const std::wstring& text) { SetDlgItemTextW(IDC_LINNET_STATUS, text.c_str()); }
  void Error(const std::exception& error) {
    Status(L"失败 / Failed");
    MessageBoxW(u8tow(error.what()).c_str(), L"Linnet", MB_ICONERROR);
  }
  std::string Text(int id) {
    CString text;
    GetDlgItemText(id, text);
    return wtou8(std::wstring(text.GetString()));
  }
  std::vector<fs::path> PersonalFiles() {
    return {user_ / "linnet_custom_words.txt", user_ / "linnet_text_expander.txt",
            user_ / "linnet_user.custom.yaml"};
  }
  void LoadPersonal() {
    words_ = ReadTable(user_ / "linnet_custom_words.txt");
    expansions_ = ReadTable(user_ / "linnet_text_expander.txt");
    disabled_.clear();
    const auto custom = user_ / "linnet_user.custom.yaml";
    const auto legacy = user_ / "linnet_user.yaml";
    if (!fs::exists(custom) && !fs::exists(legacy)) return;
    Config config;
    config.Load(fs::exists(custom) ? custom : legacy);
    const std::string prefix = fs::exists(custom) ? "patch/disabled_words" : "disabled_words";
    for (size_t i = 0; i < config.Size(prefix); ++i)
      disabled_.push_back({"", config.String(prefix + "/@" + std::to_string(i))});
  }
  void SavePersonal() {
    if (dirty_personal_.count(4)) WriteTable(user_ / "linnet_custom_words.txt", words_);
    if (dirty_personal_.count(6)) WriteTable(user_ / "linnet_text_expander.txt", expansions_);
    if (!dirty_personal_.count(5)) return;
    Config config;
    const auto path = user_ / "linnet_user.custom.yaml";
    if (fs::exists(path)) config.Load(path);
    auto* rime = rime_get_api();
    rime->config_create_list(&config.value, "patch/disabled_words");
    for (size_t i = 0; i < disabled_.size(); ++i)
      rime->config_set_string(&config.value, ("patch/disabled_words/@" + std::to_string(i)).c_str(),
                              disabled_[i].text.c_str());
    config.Save(path);
  }
  LRESULT OnInit(UINT, WPARAM, LPARAM, BOOL&) {
    tabs_.Attach(GetDlgItem(IDC_LINNET_TABS));
    list_.Attach(GetDlgItem(IDC_LINNET_LIST));
    choice_.Attach(GetDlgItem(IDC_LINNET_CHOICE));
    list_.SetExtendedListViewStyle(LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
    for (const auto& page : pages_) tabs_.AddItem(page.c_str());
    CRect list_bounds;
    list_.GetClientRect(&list_bounds);
    const int column_width = list_bounds.Width() / 2 - GetSystemMetrics(SM_CXVSCROLL);
    list_.InsertColumn(0, L"选项 / Code", LVCFMT_LEFT, column_width);
    list_.InsertColumn(1, L"当前值 / Text", LVCFMT_LEFT, column_width);
    tabs_.SetCurSel(draft_word_.empty() ? 0 : 4);
    ShowPage();
    if (!draft_word_.empty()) {
      SetDlgItemTextW(IDC_LINNET_TEXT, draft_word_.c_str());
      Status(L"词条仅为草稿：输入编码，添加后再应用 / Draft only: enter a code, add, then apply.");
    }
    CenterWindow();
    return TRUE;
  }
  void ShowPage() {
    list_.DeleteAllItems();
    visible_.clear();
    choice_.ResetContent();
    editing_row_ = -1;
    for (const auto id : {IDC_LINNET_CODE, IDC_LINNET_TEXT, IDC_LINNET_ADD, IDC_LINNET_REMOVE})
      GetDlgItem(id).ShowWindow(Personal() ? SW_SHOW : SW_HIDE);
    GetDlgItem(IDC_LINNET_CODE).EnableWindow(Page() != 5);
    for (int id = IDC_LINNET_BACKUP; id <= IDC_LINNET_DATA_NOTE; ++id)
      GetDlgItem(id).ShowWindow(Page() == 7 ? SW_SHOW : SW_HIDE);
    GetDlgItem(IDC_LINNET_FONT).ShowWindow(Page() == 2 ? SW_SHOW : SW_HIDE);
    GetDlgItem(IDC_LINNET_RESET).ShowWindow(Page() < 4 ? SW_SHOW : SW_HIDE);
    choice_.ShowWindow(Page() < 4 ? SW_SHOW : SW_HIDE);
    list_.ShowWindow(Page() == 7 ? SW_HIDE : SW_SHOW);
    if (Personal()) {
      const auto& rows = Rows();
      for (size_t i = 0; i < rows.size(); ++i) {
        list_.InsertItem(int(i), u8tow(rows[i].code).c_str());
        list_.SetItemText(int(i), 1, u8tow(rows[i].text).c_str());
      }
      SetDlgItemTextW(IDC_LINNET_CODE, L"");
      SetDlgItemTextW(IDC_LINNET_TEXT, L"");
    } else if (Page() < 4) {
      for (size_t i = 0; i < settings_.options.size(); ++i) {
        const auto& option = settings_.options[i];
        const auto group = u8tow(option.group);
        if (group.substr(0, group.find(L" /")) != pages_[Page()].substr(0, pages_[Page()].find(L" /"))) continue;
        const int row = int(visible_.size());
        visible_.push_back(i);
        list_.InsertItem(row, u8tow(option.label).c_str());
        list_.SetItemText(row, 1, u8tow(option.choices[option.selected]).c_str());
      }
      if (!visible_.empty()) list_.SetItemState(0, LVIS_SELECTED | LVIS_FOCUSED, LVIS_SELECTED | LVIS_FOCUSED);
    } else {
      SetDlgItemTextW(IDC_LINNET_DATA_NOTE,
        L"备份使用 Rime 原生词典快照及配置文件；恢复会合并学习记录，并替换备份中明确包含的设置。\r\n"
        L"Backups contain Rime snapshots and settings. Restore merges learning and replaces included settings.\r\n\r\n"
        L"同步文件夹可放在 OneDrive 等已同步的目录中；不要让两台机器共享正在使用的 userdb。\r\n"
        L"Use an already-synchronized folder, never a shared live userdb.\r\n\r\n"
        L"Windows 尚未发布正式更新通道。升级请使用经验证的 Linnet Windows 安装包。\r\n"
        L"No Windows public update feed yet. Use a verified Linnet Windows installer.");
    }
  }
  LRESULT OnTab(int, LPNMHDR, BOOL&) { ShowPage(); return 0; }
  LRESULT OnItem(int, LPNMHDR header, BOOL&) {
    auto* changed = reinterpret_cast<NMLISTVIEW*>(header);
    if (!(changed->uNewState & LVIS_SELECTED)) return 0;
    const int row = changed->iItem;
    if (Personal() && row >= 0 && size_t(row) < Rows().size()) {
      editing_row_ = row;
      SetDlgItemTextW(IDC_LINNET_CODE, u8tow(Rows()[row].code).c_str());
      SetDlgItemTextW(IDC_LINNET_TEXT, u8tow(Rows()[row].text).c_str());
    } else if (Page() < 4 && row >= 0 && size_t(row) < visible_.size()) {
      const auto& option = settings_.options[visible_[row]];
      choice_.ResetContent();
      for (const auto& item : option.choices) choice_.AddString(u8tow(item).c_str());
      choice_.SetCurSel(option.selected);
    }
    return 0;
  }
  LRESULT OnChoice(WORD, WORD, HWND, BOOL&) {
    const int row = list_.GetNextItem(-1, LVNI_SELECTED);
    const int selected = choice_.GetCurSel();
    if (row < 0 || size_t(row) >= visible_.size() || selected < 0) return 0;
    auto& option = settings_.options[visible_[row]];
    option.selected = selected;
    list_.SetItemText(row, 1, u8tow(option.choices[selected]).c_str());
    dirty_ = true;
    Status(L"尚未应用 / Unsaved changes");
    return 0;
  }
  LRESULT OnEdit(WORD, WORD, HWND, BOOL&) {
    if (!Personal()) return 0;
    try {
      Row row{Page() == 5 ? "" : Text(IDC_LINNET_CODE), Text(IDC_LINNET_TEXT)};
      if (row.text.empty() || row.text.find_first_of("\t\r\n") != std::string::npos)
        throw std::runtime_error("Enter nonempty text without tabs or line breaks");
      if (Page() == 4) {
        std::transform(row.code.begin(), row.code.end(), row.code.begin(), [](unsigned char c) {
          return c >= 'A' && c <= 'Z' ? char(c + 'a' - 'A') : char(c);
        });
        if (!std::regex_match(row.code, std::regex("[a-z0-9;']+( [a-z0-9;']+)*")))
          throw std::runtime_error("Code must use lowercase letters, digits, ; or apostrophe");
      } else if (Page() == 6 && !std::regex_match(row.code, std::regex("x;[-0-9A-Za-z_]+"))) {
        throw std::runtime_error("Snippet trigger must start with x; (for example x;addr)");
      }
      auto& rows = Rows();
      for (size_t i = 0; i < rows.size(); ++i)
        if (int(i) != editing_row_ && (Page() == 5 ? rows[i].text == row.text : rows[i].code == row.code))
          throw std::runtime_error("This code or blocked word already exists");
      if (editing_row_ >= 0) rows.at(editing_row_) = row;
      else rows.push_back(row);
      dirty_personal_.insert(Page());
      dirty_ = true;
      ShowPage();
      Status(L"尚未应用 / Unsaved changes");
    } catch (const std::exception& error) { Error(error); }
    return 0;
  }
  LRESULT OnRemove(WORD, WORD, HWND, BOOL&) {
    if (Personal() && editing_row_ >= 0) {
      Rows().erase(Rows().begin() + editing_row_);
      dirty_personal_.insert(Page());
      dirty_ = true;
      ShowPage();
      Status(L"尚未应用 / Unsaved changes");
    }
    return 0;
  }
  LRESULT OnReset(WORD, WORD, HWND, BOOL&) {
    for (const auto index : visible_) {
      settings_.options[index].selected = settings_.options[index].default_index;
      settings_.options[index].reset = true;
    }
    if (Page() == 2) { settings_.font_face.clear(); settings_.reset_font = true; }
    dirty_ = true;
    ShowPage();
    return 0;
  }
  LRESULT OnFont(WORD, WORD, HWND, BOOL&) {
    LOGFONTW font = {};
    font.lfCharSet = DEFAULT_CHARSET;
    wcsncpy_s(font.lfFaceName, u8tow(settings_.font_face).c_str(), _TRUNCATE);
    CHOOSEFONTW picker = {sizeof(picker)};
    picker.hwndOwner = m_hWnd;
    picker.lpLogFont = &font;
    picker.Flags = CF_SCREENFONTS | CF_INITTOLOGFONTSTRUCT | CF_NOSIZESEL | CF_NOSTYLESEL | CF_NOSCRIPTSEL;
    if (ChooseFontW(&picker)) { settings_.font_face = wtou8(font.lfFaceName); dirty_ = true; Status(L"字体尚未应用 / Font not applied"); }
    return 0;
  }
  bool Apply() {
    if (!dirty_) return true;
    std::map<fs::path, std::string> before;
    std::vector<fs::path> absent;
    auto files = settings_.OwnedFiles();
    const auto personal = PersonalFiles();
    files.insert(files.end(), personal.begin(), personal.end());
    try {
      for (const auto& path : files) {
        if (fs::exists(path)) before[path] = Read(path);
        else absent.push_back(path);
      }
      Status(L"正在应用并部署 / Applying and deploying…");
      GetDlgItem(IDC_LINNET_APPLY).EnableWindow(FALSE);
      const auto result = configurator_.UpdateWorkspace(true, [&] {
        settings_.Save();
        SavePersonal();
      }, [&] {
        for (const auto& item : before) Write(item.first, item.second);
        for (const auto& path : absent) if (fs::exists(path)) fs::remove(path);
      });
      GetDlgItem(IDC_LINNET_APPLY).EnableWindow(TRUE);
      if (result != 0) {
        Status(L"未应用；请查看错误详情 / Not applied; see error details");
        return false;
      }
      settings_.AcceptChanges();
      dirty_personal_.clear();
      dirty_ = false;
      Status(L"已应用 / Applied");
      GetDlgItem(IDC_LINNET_APPLY).EnableWindow(TRUE);
      return true;
    } catch (const std::exception& error) {
      GetDlgItem(IDC_LINNET_APPLY).EnableWindow(TRUE);
      Error(error);
      return false;
    }
  }
  LRESULT OnApply(WORD, WORD, HWND, BOOL&) { Apply(); return 0; }

  void Backup(const fs::path& folder) {
    auto* rime = rime_get_api();
    auto* levers = reinterpret_cast<RimeLeversApi*>(rime->find_module("levers")->get_api());
    fs::create_directories(folder);
    RimeUserDictIterator iterator = {};
    levers->user_dict_iterator_init(&iterator);
    std::vector<std::string> dictionaries;
    while (const auto* name = levers->next_user_dict(&iterator)) dictionaries.emplace_back(name);
    levers->user_dict_iterator_destroy(&iterator);
    char sync_dir[32768] = {};
    rime->get_user_data_sync_dir(sync_dir, sizeof(sync_dir) - 1);
    for (const auto& name : dictionaries) {
      if (!levers->backup_user_dict(name.c_str()))
        throw std::runtime_error("Cannot snapshot learning dictionary: " + name);
      // The native snapshot retains deleted entries, dynamic weights and ticks.
      // Rime's directory getter uses the native narrow path encoding, not UTF-8.
      const auto filename = fs::u8path(name + ".userdb.txt");
      fs::copy_file(fs::path(sync_dir) / filename, folder / filename,
                    fs::copy_options::overwrite_existing);
    }
    for (const auto& item : fs::directory_iterator(user_)) {
      const auto name = item.path().filename().u8string();
      if (!item.is_regular_file()) continue;
      if (item.path().extension() == ".yaml" || name == "linnet_custom_words.txt" || name == "linnet_text_expander.txt")
        fs::copy_file(item.path(), folder / item.path().filename(), fs::copy_options::overwrite_existing);
    }
  }
  void Restore(const fs::path& folder) {
    const auto recovery = user_ / "backups" / ("before-restore-" + std::to_string(GetTickCount64()));
    std::map<fs::path, std::string> before;
    std::vector<fs::path> absent;
    const auto result = configurator_.UpdateWorkspace(true, [&] {
      Backup(recovery);
      std::vector<fs::path> configurations, dictionaries;
      for (const auto& item : fs::directory_iterator(folder)) {
        if (!item.is_regular_file()) continue;
        const auto name = item.path().filename().u8string();
        if (name.size() > 11 && name.substr(name.size() - 11) == ".userdb.txt") {
          std::ifstream stream(item.path(), std::ios::binary);
          std::string header;
          if (!std::getline(stream, header))
            throw std::runtime_error("Cannot read learning snapshot: " + item.path().u8string());
          if (!header.empty() && header.back() == '\r') header.pop_back();
          if (header == "# Rime user dictionary export")
            throw std::runtime_error("This backup contains text tables, not learning snapshots. Use Dictionaries > Import Text Table: " + item.path().u8string());
          dictionaries.push_back(item.path());
        } else if ((item.path().extension() == ".yaml" && name != "installation.yaml" && name != "user.yaml") ||
                   name == "linnet_custom_words.txt" || name == "linnet_text_expander.txt") {
          if (item.path().extension() == ".yaml") { Config parsed; parsed.Load(item.path()); }
          else ReadTable(item.path());
          configurations.push_back(item.path());
        }
      }
      for (const auto& source : configurations) {
        const auto target = user_ / source.filename();
        if (fs::exists(target)) before[target] = Read(target);
        else absent.push_back(target);
        Write(target, Read(source));
      }
      auto* levers = reinterpret_cast<RimeLeversApi*>(rime_get_api()->find_module("levers")->get_api());
      for (const auto& source : dictionaries) {
        if (!levers->restore_user_dict(source.u8string().c_str()))
          throw std::runtime_error("Cannot merge learning snapshot: " + source.u8string());
      }
    }, [&] {
      for (const auto& item : before) Write(item.first, item.second);
      for (const auto& path : absent) if (fs::exists(path)) fs::remove(path);
    });
    if (result != 0) {
      Status(L"恢复未完成；先前数据备份：" + recovery.wstring());
      return;
    }
    // Reopen so the controls cannot retain the pre-restore draft.
    EndDialog(IDOK);
  }
  LRESULT OnData(WORD, WORD id, HWND, BOOL&) {
    try {
      if (!Apply()) return 0;
      if (id == IDC_LINNET_BACKUP) {
        const auto folder = Folder(m_hWnd, L"选择备份父文件夹 / Backup destination");
        if (folder.empty()) return 0;
        const auto target = fs::path(folder) / ("Linnet-backup-" + std::to_string(GetTickCount64()));
        if (configurator_.WithMaintenance([&] { Backup(target); return 0; }) != 0) {
          Status(L"备份未完成 / Backup incomplete");
          return 0;
        }
        ShellExecuteW(m_hWnd, L"open", target.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
      } else if (id == IDC_LINNET_RESTORE) {
        const auto folder = Folder(m_hWnd, L"选择 Rime/Linnet 备份文件夹 / Restore source");
        if (folder.empty()) return 0;
        if (MessageBoxW(L"将合并学习数据并替换备份中的设置。当前数据会先备份。\nMerge learning and replace included settings? Current data will be backed up.",
                        L"Linnet", MB_OKCANCEL | MB_ICONQUESTION) == IDOK) Restore(folder);
        return 0;
      } else if (id == IDC_LINNET_SYNC_FOLDER) {
        const auto folder = Folder(m_hWnd, L"选择已同步的文件夹 / Select synchronized folder");
        if (folder.empty()) return 0;
        const auto path = user_ / "installation.yaml";
        const auto previous = Read(path);
        if (configurator_.UpdateWorkspace(true, [&] {
          Config installation;
          installation.Load(path);
          rime_get_api()->config_set_string(&installation.value, "sync_dir", wtou8(folder).c_str());
          installation.Save(path);
        }, [&] { Write(path, previous); }) != 0) {
          Status(L"同步文件夹未应用 / Sync folder not applied");
          return 0;
        }
      } else if (id == IDC_LINNET_SYNC) {
        if (configurator_.SyncUserData() != 0) { Status(L"同步失败 / Synchronization failed"); return 0; }
      } else if (id == IDC_LINNET_DICTIONARIES) {
        if (configurator_.DictManagement() != 0) { Status(L"词典操作失败 / Dictionary operation failed"); return 0; }
      } else if (id == IDC_LINNET_DIAGNOSTICS) {
        const auto folder = Folder(m_hWnd, L"诊断导出目录 / Diagnostics destination");
        if (folder.empty()) return 0;
        std::string report = "Linnet Windows diagnostics\nNo input text, learning data or user names are included.\n";
        const auto manifest = WeaselSharedDataPath().parent_path() / "linnet-windows-manifest.json";
        if (fs::exists(manifest)) report += Read(manifest);
        SYSTEM_INFO system = {};
        GetNativeSystemInfo(&system);
        report += "\nNative processor architecture: " + std::to_string(system.wProcessorArchitecture) + "\n";
        for (const auto& option : settings_.options)
          report += option.id + "=" + option.choices[option.selected] + "\n";
        Write(fs::path(folder) / "Linnet-diagnostics.txt", report);
      }
      Status(L"操作完成 / Completed");
    } catch (const std::exception& error) { Error(error); }
    return 0;
  }
  bool Close() {
    if (dirty_) {
      const auto result = MessageBoxW(L"保存尚未应用的修改？\nApply unsaved changes?", L"Linnet", MB_YESNOCANCEL | MB_ICONQUESTION);
      if (result == IDCANCEL || (result == IDYES && !Apply())) return false;
    }
    EndDialog(IDCANCEL);
    return true;
  }
  LRESULT OnClose(UINT, WPARAM, LPARAM, BOOL&) { Close(); return 0; }
  LRESULT OnCancel(WORD, WORD, HWND, BOOL&) { Close(); return 0; }
};
}  // namespace

int RunLinnetSettings(Configurator& configurator, const std::wstring& custom_word) {
  try {
    SettingsDialog dialog(configurator, custom_word);
    return dialog.DoModal() == -1 ? 1 : 0;
  } catch (const std::exception& error) {
    MessageBoxW(nullptr, u8tow(error.what()).c_str(), L"Linnet Settings", MB_OK | MB_ICONERROR);
    return 1;
  }
}
