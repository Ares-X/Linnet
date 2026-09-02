// Copyright Linnet contributors
// SPDX-License-Identifier: GPL-3.0-or-later

/// Retains one composition-free Rime session for the Host lifetime so shared
/// dictionaries, grammar, and bilingual indexes are initialized off the first
/// client key path. Client composition remains owned by each IMK controller.
final class LinnetRimeWarmSession {
  private var lease: LinnetRimeSessionLease?
  var identifier: RimeSessionId { lease?.identifier ?? 0 }

  func prepare(using api: RimeApi_stdbool, schemaID: String) -> RimeSessionId? {
    guard identifier == 0, !schemaID.isEmpty else { return nil }
    let created = api.create_session()
    guard let acquired = LinnetRimeSessionLease.acquire(identifier: created) else { return nil }
    lease = acquired

    let selected = schemaID.withCString { api.select_schema(created, $0) }
    let primed = selected && "ceshi".withCString {
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
    guard let lease, lease.isCurrent(sessionExists: { api.find_session($0) }) else {
      retire()
      return false
    }
    return true
  }

  func discard(using api: RimeApi_stdbool) {
    guard let discarded = lease else { return }
    let isCurrent = discarded.isCurrent(sessionExists: { api.find_session($0) })
    retire()
    if isCurrent {
      _ = api.destroy_session(discarded.identifier)
    }
  }

  /// cleanup_all_sessions owns destruction at runtime-generation boundaries.
  func retire() {
    lease?.retire()
    lease = nil
  }
}
