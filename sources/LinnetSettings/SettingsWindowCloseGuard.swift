import AppKit
import SwiftUI

@MainActor
enum SettingsPendingChangesPrompt {
  enum Choice {
    case apply
    case cancel
    case discard
  }

  static func present(
    for window: NSWindow?,
    canApply: Bool,
    locale: Locale,
    completion: @escaping @MainActor (Choice) -> Void
  ) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = String(
      localized: "Apply your changes before closing?", bundle: .main, locale: locale)
    alert.informativeText = String(
      localized:
        "Input, English, candidate layout, and personal-data changes are not active until you apply them.",
      bundle: .main,
      locale: locale)
    let apply = alert.addButton(withTitle: String(
      localized: "Apply Changes", bundle: .main, locale: locale))
    apply.keyEquivalent = "\r"
    apply.isEnabled = canApply
    let cancel = alert.addButton(withTitle: String(
      localized: "Keep Editing", bundle: .main, locale: locale))
    cancel.keyEquivalent = "\u{1b}"
    let discard = alert.addButton(withTitle: String(
      localized: "Discard Changes", bundle: .main, locale: locale))
    discard.hasDestructiveAction = true

    let resolve: @MainActor (NSApplication.ModalResponse) -> Void = { response in
      switch response {
      case .alertFirstButtonReturn: completion(.apply)
      case .alertThirdButtonReturn: completion(.discard)
      default: completion(.cancel)
      }
    }
    if let window {
      alert.beginSheetModal(for: window, completionHandler: resolve)
    } else {
      resolve(alert.runModal())
    }
  }
}

/// Owns the AppKit close boundary while SettingsConfigurationSession remains
/// the only draft/baseline owner. The proxy forwards every unrelated window
/// delegate callback back to SwiftUI's original delegate.
@MainActor
final class SettingsWindowCloseCoordinator: NSObject, NSWindowDelegate {
  weak var model: SettingsModel?
  var locale = Locale.autoupdatingCurrent

  private weak var window: NSWindow?
  private weak var forwardedDelegate: (any NSWindowDelegate)?
  private var promptActive = false

  func attach(to candidate: NSWindow) {
    guard window !== candidate || candidate.delegate !== self else { return }
    detach()
    window = candidate
    forwardedDelegate = candidate.delegate
    candidate.delegate = self
    candidate.isDocumentEdited = model?.pendingChanges ?? false
  }

  func updateDocumentEditedState() {
    window?.isDocumentEdited = model?.pendingChanges ?? false
  }

  func detach() {
    if let window, window.delegate === self {
      window.delegate = forwardedDelegate
    }
    window = nil
    forwardedDelegate = nil
    promptActive = false
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard let model else {
      return forwardedDelegate?.windowShouldClose?(sender) ?? true
    }
    if model.operationActive {
      NSSound.beep()
      return false
    }
    guard model.pendingChanges else {
      return forwardedDelegate?.windowShouldClose?(sender) ?? true
    }
    guard !promptActive else { return false }
    promptActive = true
    SettingsPendingChangesPrompt.present(
      for: sender,
      canApply: model.canApplyChanges,
      locale: locale
    ) { [weak self, weak sender] choice in
      guard let self else { return }
      self.promptActive = false
      switch choice {
      case .apply:
        model.applyConfiguration { [weak self, weak sender] accepted in
          self?.completeApply(accepted: accepted, for: sender)
        }
      case .discard:
        model.discardPendingChanges()
        self.updateDocumentEditedState()
        sender?.close()
      case .cancel:
        break
      }
    }
    return false
  }

  /// Owns the terminal close transition after the asynchronous Apply result.
  /// Rejected applies leave both the draft and its window untouched.
  func completeApply(accepted: Bool, for sender: NSWindow?) {
    guard accepted, let sender else { return }
    updateDocumentEditedState()
    sender.close()
  }

  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    if forwardedDelegate?.responds(to: selector) == true {
      return forwardedDelegate
    }
    return super.forwardingTarget(for: selector)
  }
}

struct SettingsWindowCloseGuard: NSViewRepresentable {
  let model: SettingsModel
  let locale: Locale

  func makeCoordinator() -> SettingsWindowCloseCoordinator {
    let coordinator = SettingsWindowCloseCoordinator()
    coordinator.model = model
    coordinator.locale = locale
    return coordinator
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    attach(view, coordinator: context.coordinator)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.model = model
    context.coordinator.locale = locale
    context.coordinator.updateDocumentEditedState()
    attach(view, coordinator: context.coordinator)
  }

  static func dismantleNSView(
    _ view: NSView,
    coordinator: SettingsWindowCloseCoordinator
  ) {
    coordinator.detach()
  }

  private func attach(_ view: NSView, coordinator: SettingsWindowCloseCoordinator) {
    DispatchQueue.main.async { [weak view, weak coordinator] in
      guard let window = view?.window else { return }
      coordinator?.attach(to: window)
    }
  }
}
