// Lua state lifetime probe.
//
// Exercises the librime-lua static-state patch
// (patches/librime-lua-linnet-state-lifetime.patch) end to end against a
// real deployment: repeated
//
//   RimeInitialize -> Lua composition ("rq" via
//   lua_translator@*date_translator) -> RimeFinalize -> RimeInitialize
//
// cycles, with two teardown variants:
//
//   clean          — destroy the session before finalize (session-first
//                    teardown, the ordering librime happens to make safe
//                    even upstream);
//   composition-alive — finalize while the composition menu (holding
//                    LuaTranslation chains) is still open — the Squirrel
//                    logout/power-off path that crashed before the
//                    process-lifetime mitigation.
//
// With the patch, the lua_State is a function-local static that survives
// Registry::Clear() at RimeFinalize: gear destructors (fini_ calls,
// LuaTranslation::gc, LuaObj::luaL_unref) always run against a live state,
// and re-initialization re-runs lua_init on the same state instead of
// creating a fresh one. A crash here — SIGSEGV/SIGABRT inside a Lua gear
// destructor, luaL_unref, or LuaTranslation::gc against a closed state —
// is a patch regression. A wrong result from the Lua translator after
// re-initialization is a re-init semantics regression (stale registry
// references on the reused state).

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

#include "rime_api_stdbool.h"
#include "rime_api.h"

namespace {

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "lua_lifetime_probe: FAIL: " << message << '\n';
  // The probe intentionally exercises finalize with live compositions. A
  // failed assertion must not run another process-static teardown and mask
  // the original failure with a destructor crash.
  std::cerr.flush();
  std::_Exit(1);
}

struct Result {
  size_t count = 0;
  std::string first;
};

// Reads the live candidate list. RimeCandidateListBegin/Next copy candidate
// text into the iterator; the iterator itself must be ended with
// RimeCandidateListEnd before the session goes away.
Result Candidates(RimeApi_stdbool* api, RimeSessionId session) {
  Result result;
  RimeCandidateListIterator iterator = {};
  if (!api->candidate_list_begin(session, &iterator)) {
    return result;
  }
  while (api->candidate_list_next(&iterator)) {
    if (result.count == 0 && iterator.candidate.text) {
      result.first = iterator.candidate.text;
    }
    ++result.count;
  }
  api->candidate_list_end(&iterator);
  return result;
}

// Types "rq" and asserts that the Lua date translator produced candidates.
void TypeDate(RimeApi_stdbool* api,
              RimeSessionId session,
              int cycle,
              const char* variant) {
  if (!api->simulate_key_sequence(session, "rq")) {
    Fail("simulate_key_sequence(rq) failed (cycle " + std::to_string(cycle) +
         ", " + variant + ")");
  }
  const Result result = Candidates(api, session);
  if (result.count == 0) {
    Fail("no candidates from lua_translator@*date_translator (cycle " +
         std::to_string(cycle) + ", " + variant + ")");
  }
  const bool looks_like_date =
      result.first.find('-') != std::string::npos ||
      result.first.find('/') != std::string::npos ||
      result.first.find('.') != std::string::npos ||
      result.first.find("\xe5\xb9\xb4") != std::string::npos;  // 年 (UTF-8)
  if (!looks_like_date) {
    Fail("first candidate '" + result.first + "' is not a date (cycle " +
         std::to_string(cycle) + ", " + variant + ")");
  }
  std::cout << "lua_lifetime_probe: cycle " << cycle << " (" << variant
            << "): " << result.count << " candidates, first='" << result.first
            << "'\n";
}

void UnknownModuleFailsClosed(RimeApi_stdbool* api, int cycle) {
  const RimeSessionId session = api->create_session();
  if (!session) {
    Fail("unknown module: create_session failed (cycle " + std::to_string(cycle) + ")");
  }
  if (!api->select_schema(session, "lua_unknown_test")) {
    api->destroy_session(session);
    Fail("unknown module: select_schema failed (cycle " + std::to_string(cycle) + ")");
  }
  if (!api->simulate_key_sequence(session, "zz")) {
    api->destroy_session(session);
    Fail("unknown module: simulate_key_sequence failed (cycle " +
         std::to_string(cycle) + ")");
  }
  const Result result = Candidates(api, session);
  api->destroy_session(session);
  if (result.count != 0) {
    Fail("unknown Lua module produced a candidate (cycle " +
         std::to_string(cycle) + ")");
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: lua_lifetime_probe SHARED_DATA_DIR USER_DATA_DIR\n";
    return 2;
  }
  const char* shared_data_dir = argv[1];
  const char* user_data_dir = argv[2];

  auto* api = rime_get_api_stdbool();
  if (!api) {
    Fail("librime API unavailable");
  }

  constexpr int kCycles = 5;
  for (int cycle = 0; cycle < kCycles; ++cycle) {
    const bool alive_variant = (cycle % 2) == 1;  // finalize, composition open

    RimeTraits traits = {};
    RIME_STRUCT_INIT(RimeTraits, traits);
    traits.shared_data_dir = shared_data_dir;
    traits.user_data_dir = user_data_dir;
    const std::string staging_dir = std::string(user_data_dir) + "/build";
    traits.staging_dir = staging_dir.c_str();
    traits.distribution_name = "Linnet Lua Lifetime Test";
    traits.distribution_code_name = "linnet-lua-lifetime";
    traits.distribution_version = "0.1.0";
    traits.app_name = "rime.linnet-lua-lifetime";
    traits.min_log_level = 2;
    traits.log_dir = "";

    api->setup(&traits);
    api->initialize(nullptr);

    const RimeSessionId session = api->create_session();
    if (!session) {
      Fail("create_session failed (cycle " + std::to_string(cycle) + ")");
    }
    if (!api->select_schema(session, "lua_date_test")) {
      api->destroy_session(session);
      Fail("select_schema(lua_date_test) failed (cycle " +
           std::to_string(cycle) + ")");
    }
    TypeDate(api, session, cycle,
             alive_variant ? "composition-alive" : "clean");
    UnknownModuleFailsClosed(api, cycle);

    if (alive_variant) {
      // App crash path: RimeFinalize while the composition menu (with its
      // LuaTranslation chains) is still open.
      api->finalize();
    } else {
      api->destroy_session(session);
      api->finalize();
    }
  }

  // One final end-to-end pass after all cycles, proving the runtime still
  // works after the last finalize.
  {
    RimeTraits traits = {};
    RIME_STRUCT_INIT(RimeTraits, traits);
    traits.shared_data_dir = shared_data_dir;
    traits.user_data_dir = user_data_dir;
    const std::string staging_dir = std::string(user_data_dir) + "/build";
    traits.staging_dir = staging_dir.c_str();
    traits.distribution_name = "Linnet Lua Lifetime Test";
    traits.distribution_code_name = "linnet-lua-lifetime";
    traits.distribution_version = "0.1.0";
    traits.app_name = "rime.linnet-lua-lifetime";
    traits.min_log_level = 2;
    traits.log_dir = "";

    api->setup(&traits);
    api->initialize(nullptr);
    const RimeSessionId session = api->create_session();
    if (!session) {
      Fail("final pass: create_session failed");
    }
    if (!api->select_schema(session, "lua_date_test")) {
      api->destroy_session(session);
      Fail("final pass: select_schema(lua_date_test) failed");
    }
    TypeDate(api, session, kCycles, "final-pass");
    UnknownModuleFailsClosed(api, kCycles);
    api->destroy_session(session);
    api->finalize();
  }

  std::cout << "lua_lifetime_probe: PASS: " << kCycles
            << " init/use/finalize cycles plus final pass, "
            << "no crashes, Lua translator correct after re-initialization\n";
  return 0;
}
