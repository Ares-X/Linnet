// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// Pinyin -> English lookup probe: loads a generated Linnet smart database and
// answers `p/<pinyin>` lookups through the same PredictEngine API the
// smart_english plugin uses, verifying the enriched vocabulary end to end.

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include <rime/predict/predict_db.h>
#include <rime/predict/predict_engine.h>

[[noreturn]] void Fail(const std::string& message) {
  std::cerr << "linnet_pinyin_probe: " << message << '\n';
  std::cerr.flush();
  std::_Exit(1);
}

bool Contains(const std::string& value, const std::string& needle) {
  return value.find(needle) != std::string::npos;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    Fail("usage: linnet_pinyin_probe <linnet.smart.db>");
  }
  auto db = std::make_shared<rime::PredictDb>(rime::path(argv[1]));
  if (!db->Load()) {
    Fail("could not load the smart database");
  }
  rime::PredictEngine engine(db, 0);
  (void)argc;
  std::vector<rime::predict::RawEntry> result;
  if (!engine.LookupCopy("p/suanfa", &result) || result.empty() ||
      !Contains(result[0].text, "algorithm")) {
    Fail("p/suanfa did not resolve to algorithm");
  }
  if (!engine.LookupCopy("p/huzao", &result) || result.empty() ||
      !Contains(result[0].text, "passport")) {
    Fail("p/huzao (fuzzy zh->z) did not resolve to passport");
  }
  if (!engine.LookupCopy("p/rgzn", &result) || result.empty() ||
      !Contains(result[0].text, "artificial intelligence")) {
    Fail("p/rgzn (abbreviation) did not resolve to artificial intelligence");
  }
  if (!engine.LookupCopy("p/weijifen", &result) || result.empty() ||
      !Contains(result[0].text, "calculus")) {
    Fail("p/weijifen did not resolve to calculus");
  }
  std::cout << "linnet pinyin probe: PASS (suanfa, huzao, rgzn, weijifen)\n";
  return 0;
}
