enum SettingsRuntimeReachability: String, Equatable, Sendable {
  case running
  case paused
  case degraded
  case unreachable
}
