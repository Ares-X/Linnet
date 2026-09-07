import Foundation

enum SettingsOperationPhase: String, CaseIterable, Equatable, Sendable {
  case preflight
  case pausing
  case snapshotting
  case staging
  case deploying
  case activating
  case verifying
  case cancelling
  case resuming
  case completed
  case cancelled
  case failed
}
