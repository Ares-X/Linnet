// Linnet auto_phrase probe — end-to-end verification of the Lua
// auto_phrase (无感造词) filter against a deployed linnet schema.
//
// Usage: auto_phrase_probe SHARED_DIR USER_DIR [SCHEMA_NAME]
//
// SCHEMA_NAME defaults to "linnet_zh_pinyin".
//
// Commands are read from stdin, one per line:
//
//   list <code>                     Print up to 30 candidates for <code>
//   learn <word> <full-code> <candidate>...
//                                   In one session: type <full-code>, then
//                                   pick the supplied word/character segments
//                                   from pageable menus and finish the commit.
//   delete <code> <index>           Delete the candidate at <index> via the
//                                   public API, then print the remaining
//                                   candidates.
//
// Output markers:
//   LIST\t<code>\n<RANK>\t<text>\t<comment>\nEND
//   LEARN\t<step>\t<text>\t<index>\n... LEARN_COMMIT\t<text>
//   DELETE\t<index>\n<remaining candidates>
//
// This probe drives only the public Rime API; no C++ internals.

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "rime_api_stdbool.h"
#include "rime_api.h"

namespace {

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "auto_phrase_probe: " << message << '\n';
  // A failed assertion can leave live librime sessions backed by dynamically
  // loaded filters. Avoid process-static teardown after those modules unload;
  // the failure text and status are the only required probe outputs.
  std::cerr.flush();
  std::_Exit(1);
}

constexpr int kMaxCandidates = 30;
constexpr int kSpace = 0x20;
constexpr int kPageDown = 0xff56;

class Probe {
 public:
  Probe(RimeApi_stdbool* api, RimeSessionId session,
        const std::string& schema)
      : api_(api), session_(session) {
    if (!api_->select_schema(session_, schema.c_str())) {
      Fail("schema unavailable: " + schema);
    }
  }

  void List(const std::string& code) {
    if (!api_->simulate_key_sequence(session_, code.c_str())) {
      std::cout << "LIST\t" << code << "\nREJECT\nEND\n";
      return;
    }
    std::cout << "LIST\t" << code << '\n';
    PrintCandidates(kMaxCandidates);
    std::cout << "END\n";
  }

  // Selects <target> from the current menu; returns its index or -1.
  int FindCandidate(const std::string& target) {
    RimeCandidateListIterator iterator = {};
    int index = 0;
    if (api_->candidate_list_begin(session_, &iterator)) {
      while (api_->candidate_list_next(&iterator)) {
        const char* text = iterator.candidate.text ? iterator.candidate.text : "";
        if (target == text) {
          api_->candidate_list_end(&iterator);
          return index;
        }
        ++index;
      }
      api_->candidate_list_end(&iterator);
    }
    return -1;
  }

  void Learn(const std::string& word,
             const std::string& full_code,
             const std::vector<std::string>& selections) {
    if (word.empty() || full_code.empty() || selections.size() < 2) {
      Fail("learn: word, full code, and at least two selections are required");
    }
    // Real-user flow: type the full code first, then pick each character or
    // word segment from pageable menus.  express_editor may auto-commit the
    // final selection; otherwise Space confirms what remains.
    if (!api_->simulate_key_sequence(session_, full_code.c_str())) {
      Fail("learn: key sequence rejected: " + full_code);
    }
    const int page_size = CurrentPageSize();
    for (size_t i = 0; i < selections.size(); ++i) {
      const auto& selection = selections[i];
      int index = FindCandidate(selection);
      std::cout << "LEARN\t" << (i + 1) << '\t' << selection << '\t'
                << index << '\n';
      if (index < 0) {
        std::cout << "LEARN_FAIL\t" << selection << " not found\n";
        return;
      }
      // Candidate digit keys act on the schema-owned current page size.
      const int page = index / page_size;
      for (int p = 0; p < page; ++p) {
        if (!api_->process_key(session_, kPageDown, 0)) {
          Fail("learn: page-down failed");
        }
      }
      const int digit_keycode = '1' + (index % page_size);
      if (!api_->process_key(session_, digit_keycode, 0)) {
        Fail("learn: digit key rejected");
      }
      std::cerr << "PROBE selected " << selection << " at " << index
                << " (page " << page << ", digit " << (index % page_size + 1)
                << ")\n";
    }
    // express_editor auto-commits when the final selected segment reaches the
    // end of the input.  Only send Space when a composition really remains;
    // an idle Space belongs to the host application.
    std::string committed = TakeCommit();
    if (committed.empty()) {
      if (!IsComposing()) {
        Fail("learn: composition ended without a commit");
      }
      std::cerr << "PROBE pressing space\n";
      if (!api_->process_key(session_, kSpace, 0)) {
        Fail("learn: space commit failed");
      }
      committed = TakeCommit();
    }
    if (committed != word) {
      Fail("learn: committed '" + committed + "', expected '" + word + "'");
    }
    std::cout << "LEARN_COMMIT\t" << committed << '\n';
  }

  void Delete(const std::string& code, size_t index) {
    if (!api_->simulate_key_sequence(session_, code.c_str())) {
      std::cout << "DELETE\t" << code << "\tREJECT\nEND\n";
      return;
    }
    if (!api_->delete_candidate(session_, index)) {
      Fail("delete_candidate failed");
    }
    std::cout << "DELETE\t" << index << '\n';
    PrintCandidates(kMaxCandidates);
    std::cout << "END\n";
  }

 private:
  std::string TakeCommit() {
    RimeCommit commit = {};
    if (!api_->get_commit(session_, &commit)) {
      return {};
    }
    const std::string text = commit.text ? commit.text : "";
    api_->free_commit(&commit);
    return text;
  }

  bool IsComposing() {
    RimeStatus_stdbool status = {};
    RIME_STRUCT_INIT(RimeStatus_stdbool, status);
    if (!api_->get_status(session_, &status)) {
      Fail("learn: could not inspect composition status");
    }
    const bool is_composing = status.is_composing;
    api_->free_status(&status);
    return is_composing;
  }

  int CurrentPageSize() {
    RimeContext_stdbool context = {};
    RIME_STRUCT_INIT(RimeContext_stdbool, context);
    if (!api_->get_context(session_, &context)) {
      Fail("learn: could not inspect current menu page size");
    }
    const int page_size = context.menu.page_size;
    api_->free_context(&context);
    if (page_size <= 0 || page_size > 9) {
      Fail("learn: invalid current menu page size");
    }
    return page_size;
  }

  void PrintCandidates(size_t top_n) {
    RimeCandidateListIterator iterator = {};
    size_t count = 0;
    if (api_->candidate_list_begin(session_, &iterator)) {
      while (count < top_n && api_->candidate_list_next(&iterator)) {
        std::cout << count << '\t'
                  << (iterator.candidate.text ? iterator.candidate.text : "")
                  << '\t'
                  << (iterator.candidate.comment ? iterator.candidate.comment
                                                 : "")
                  << '\n';
        ++count;
      }
      api_->candidate_list_end(&iterator);
    }
  }

  RimeApi_stdbool* api_;
  RimeSessionId session_;
};

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3 || argc > 4) {
    Fail("usage: SHARED_DIR USER_DIR [SCHEMA_NAME]");
  }
  const char* schema_name = argc >= 4 ? argv[3] : "linnet_zh_pinyin";

  auto* api = rime_get_api_stdbool();
  if (!api) {
    Fail("librime API unavailable");
  }
  const std::string staging_dir = std::string(argv[2]) + "/build";
  RimeTraits traits = {};
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.staging_dir = staging_dir.c_str();
  traits.distribution_name = "Linnet Auto Phrase Probe";
  traits.distribution_code_name = "linnet-auto-phrase-probe";
  traits.distribution_version = "0.1.0";
  traits.app_name = "rime.linnet-auto-phrase-probe";
  traits.min_log_level = 3;
  traits.log_dir = "";

  api->setup(&traits);
  api->initialize(nullptr);

  std::string line;
  while (std::getline(std::cin, line)) {
    std::istringstream input(line);
    std::string command;
    input >> command;
    if (command.empty() || command[0] == '#') {
      continue;
    }
    RimeSessionId session = api->create_session();
    if (!session) {
      Fail("session unavailable");
    }
    Probe probe(api, session, schema_name);
    if (command == "list" || command == "verify") {
      std::string code;
      input >> code;
      probe.List(code);
    } else if (command == "learn") {
      std::string word;
      std::string full_code;
      input >> word >> full_code;
      std::vector<std::string> selections;
      std::string selection;
      while (input >> selection) {
        selections.push_back(selection);
      }
      probe.Learn(word, full_code, selections);
    } else if (command == "delete") {
      std::string code;
      size_t index = 0;
      input >> code >> index;
      probe.Delete(code, index);
    } else {
      Fail("unknown command: " + command);
    }
    api->destroy_session(session);
  }

  api->finalize();
  return 0;
}
