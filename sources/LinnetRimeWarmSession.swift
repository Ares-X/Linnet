// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

/// Retains one composition-free Rime session for the Host lifetime so shared
/// dictionaries, grammar, and bilingual indexes are initialized off the first
/// client key path. Client composition remains owned by each IMK controller.
final class LinnetRimeWarmSession {
  private(set) var identifier: RimeSessionId = 0

  func prepare(using api: RimeApi_stdbool) -> RimeSessionId? {
    guard identifier == 0 else { return nil }
    let created = api.create_session()
    guard created != 0 else { return nil }
    identifier = created

    let primed = "ceshi".withCString {
      api.simulate_key_sequence(created, $0)
    }
    guard primed else {
      discard(using: api)
      return nil
    }
    api.clear_composition(created)
    return created
  }

  @discardableResult
  func refresh(using api: RimeApi_stdbool) -> Bool {
    guard identifier != 0, api.find_session(identifier) else {
      identifier = 0
      return false
    }
    return true
  }

  func discard(using api: RimeApi_stdbool) {
    let discarded = identifier
    identifier = 0
    if discarded != 0 {
      _ = api.destroy_session(discarded)
    }
  }

  /// cleanup_all_sessions owns destruction at runtime-generation boundaries.
  func retire() {
    identifier = 0
  }
}
