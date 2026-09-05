// Read-only semantic comparison using the locked Octagram loader and Darts API.
// Output weights are stored integers: log(frequency) * GramDb::kValueScale.
#include <cstdint>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <stdexcept>
#include <utf8.h>
#include "gram_db.h"
#include "gram_encoding.h"

namespace {
struct Model {
  rime::GramDb db;
  Darts::DoubleArray trie;
  explicit Model(const char* path) : db(rime::path{path}) {
    if (!db.Load()) throw std::runtime_error("cannot load grammar");
    const auto* metadata = db.Find<rime::grammar::Metadata>(0);
    trie.set_array(metadata->double_array.get(), metadata->double_array_size);
  }
};

std::string hex(const std::string& key) {
  std::ostringstream out;
  for (unsigned char c : key)
    out << std::hex << std::setfill('0') << std::setw(2) << unsigned(c);
  return out.str();
}

// The pinned encoder loses information for some non-CJK Unicode. Never guess
// those characters: raw hex remains the authoritative identity in the report.
std::string readable(const std::string& key) {
  std::string text;
  for (size_t i = 0; i < key.size();) {
    unsigned char c = key[i++];
    uint32_t u;
    if (c >= 0x20 && c < 0x7f) u = c;
    else if (c >= 0x80 && c < 0xe0 && i < key.size())
      u = ((c - 0x40) << 8) | static_cast<unsigned char>(key[i++]);
    else if (c == 0xe1 && i < key.size()) {
      unsigned char next = key[i++];
      if (next < 0x80 || next >= 0xe0) return "";
      u = (next - 0x40) << 8;
    } else return "";
    utf8::append(u, std::back_inserter(text));
  }
  if (utf8::distance(text.begin(), text.end()) > rime::grammar::kMaxEncodedUnicode)
    return "";
  return rime::grammar::encode(text) == key ? text : "";
}

struct Delta {
  Model& old_model;
  Model& new_model;
  uint64_t added = 0, removed = 0, reweighted = 0, unchanged = 0, unreadable = 0;
  std::string key;

  // Walk both tries in byte order. Only changed records leave the process;
  // memory use is two mapped models plus the current key/recursion stack.
  void visit(bool old_exists, size_t old_node, int old_value,
             bool new_exists, size_t new_node, int new_value) {
    if (old_value >= 0 || new_value >= 0) {
      if (old_value == new_value) ++unchanged;
      else {
        const char* kind;
        if (old_value < 0) { ++added; kind = "added"; }
        else if (new_value < 0) { ++removed; kind = "removed"; }
        else { ++reweighted; kind = "reweighted"; }
        auto text = readable(key);
        if (text.empty()) ++unreadable;
        std::cout << kind << '\t' << hex(key) << '\t' << text << '\t'
                  << old_value << '\t' << new_value << '\n';
      }
    }
    for (unsigned int byte = 1; byte <= 255; ++byte) {
      char c = static_cast<char>(byte);
      size_t old_next = old_node, new_next = new_node, pos = 0;
      int a = old_exists ? old_model.trie.traverse(&c, old_next, pos, 1) : -2;
      pos = 0;
      int b = new_exists ? new_model.trie.traverse(&c, new_next, pos, 1) : -2;
      if (a == -2 && b == -2) continue;
      key.push_back(c);
      visit(a != -2, old_next, a, b != -2, new_next, b);
      key.pop_back();
    }
  }
};
}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 3) throw std::runtime_error("usage: grammar-delta OLD.gram NEW.gram");
    Model old_model(argv[1]), new_model(argv[2]);
    std::cout << "change\tencoded_hex\ttext\told_weight\tnew_weight\n";
    Delta delta{old_model, new_model};
    delta.visit(true, 0, old_model.trie.exactMatchSearch<int>(""),
                true, 0, new_model.trie.exactMatchSearch<int>(""));
    std::cerr << "SUMMARY added=" << delta.added << " removed=" << delta.removed
              << " reweighted=" << delta.reweighted << " unchanged=" << delta.unchanged
              << " unreadable=" << delta.unreadable << '\n';
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
