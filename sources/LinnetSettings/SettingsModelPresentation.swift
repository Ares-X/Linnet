import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsOutcomeAcceptance {
  case accepted, conflict, rejected
}

struct SettingsOperationAcceptanceContext {
  let personalTicket: SettingsConfigurationSession.PersonalTicket?
  let documentTicket: SettingsConfigurationSession.DocumentTicket?
  let recoveryAfterCommit: Bool
}

@MainActor
extension SettingsModel {
  func observeCurrentConfiguration() -> SettingsConfigurationSession.ObservationResult? {
    guard let userDirectory else { return nil }
    do {
      let personalSnapshot = try LinnetPersonalDataStore.snapshot(from: userDirectory)
      let documentSnapshot = try LinnetSettingsDocumentStore.snapshot(from: userDirectory)
      let personal = configuration.observePersonal(personalSnapshot)
      let document = configuration.observeDocument(documentSnapshot)
      if personal == .conflict || document == .conflict { return .conflict }
      if personal == .reloaded || document == .reloaded { return .reloaded }
      if personal == .unchanged && document == .unchanged { return .unchanged }
      return .ignored
    } catch {
      configuration.markSourceUnreadable()
      logDiagnostic(error, context: "Personal data could not be reloaded")
      return nil
    }
  }

  func presentStaleOperation() {
    switch observeCurrentConfiguration() {
    case .reloaded:
      status = .staleDataReloaded
    case .conflict:
      status = .configurationConflict
    default:
      status = .operationFailed(.invalidOperation)
    }
  }

  func presentationPhase(
    _ phase: SettingsDataCoordinator.Phase
  ) -> SettingsOperationPhase? {
    switch phase {
    case .preflight: .preflight
    case .pausing: .pausing
    case .snapshotting: .snapshotting
    case .staging: .staging
    case .deploying: .deploying
    case .activating: .activating
    case .verifying: .verifying
    case .cancelling: .cancelling
    case .resuming: .resuming
    case .completed, .cancelled, .failed: nil
    }
  }

  func presentationFailure(_ error: Error) -> SettingsPresentationFailure {
    if error is LinnetBackupStore.Failure { return .incrementalBackupFailed }
    guard let failure = error as? SettingsDataCoordinator.Failure else { return .unknown }
    return switch failure {
    case .unavailable: .unavailable
    case .invalidOperation: .invalidOperation
    case .staleRevision: .staleHostState
    case .unsafePath: .unsafePath
    case .requestFailed(let code): presentationFailure(code)
    case .appearanceRestoreFailed: .appearanceRecoveryFailed
    case .configurationRestoreFailed: .configurationRecoveryFailed
    case .timedOut: .timedOut
    case .cancelled: .unknown
    case .cloudRecoveryRepairRequired: .invalidOperation
    }
  }

  private func presentationFailure(
    _ code: LinnetSettingsContract.RuntimeReplyCode
  ) -> SettingsPresentationFailure {
    return switch code {
    case .transactionBusy: .hostBusy
    case .appearanceDeployFailed: .deploymentFailed
    case .staleCandidate: .staleHostState
    default: .hostRejected
    }
  }

  func logDiagnostic(_ error: Error, context: String) {
    print("\(context): \(error.localizedDescription)")
  }

  var operationActive: Bool {
    activeOperation != nil || packDownloadActive || appearancePublishActive
      || updateChecker.activationInProgress
  }

  var migrationAvailable: Bool {
    if case .compatible = legacyImportState { return true }
    return false
  }

  var pendingChanges: Bool { configuration.pendingChanges }
  var canApplyChanges: Bool {
    configuration.canPersist && !personalValidationPending
      && personalValidation.isValid && !operationActive && pendingChanges
  }

  var displayedStatus: SettingsPresentationStatus {
    switch configuration.readiness {
    case .ready: status
    case .sourceUnreadable: .settingsLoadFailed
    case .servicesUnavailable: .operationFailed(.unavailable)
    }
  }

  var packDownloadActive: Bool { languageDataUpdateTarget != nil }
  var canRestoreBackup: Bool {
    dataServicesAvailable
      && (configuration.canPersist || configuration.readiness == .sourceUnreadable)
  }

  func saveBackupRetentionPolicy() {
    status = LinnetSettingsContract.setBackupRetentionPolicy(backupRetentionPolicy)
      ? .backupRetentionSaved
      : .hostUnavailable
  }

  func openDataFolder() {
    guard let directory = userDirectory else {
      status = .dataFolderUnavailable
      return
    }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      NSWorkspace.shared.open(directory)
    } catch {
      status = .dataFolderOpenFailed
    }
  }

  func addCustomWord() {
    configuration.personalDraft.customWords.append(.init(value: "", code: ""))
  }

  func customWordValueBinding(_ row: LinnetPersonalData.CustomWord) -> Binding<String> {
    LinnetStableRowTextBinding.make(
      draft: personalDraftBinding,
      rowIdentifier: row.id,
      fallback: row.value,
      field: .init(rows: \.customWords, identifier: \.id, value: \.value)
    )
  }

  func customWordCodeBinding(_ row: LinnetPersonalData.CustomWord) -> Binding<String> {
    LinnetStableRowTextBinding.make(
      draft: personalDraftBinding,
      rowIdentifier: row.id,
      fallback: row.code,
      field: .init(rows: \.customWords, identifier: \.id, value: \.code)
    )
  }

  func removeCustomWord(id wordID: UUID) {
    configuration.personalDraft.customWords.removeAll { $0.id == wordID }
  }

  func addDisabledWord() {
    configuration.personalDraft.disabledWords.append(.init(value: ""))
  }

  func disabledWordBinding(_ row: LinnetPersonalData.DisabledWord) -> Binding<String> {
    LinnetStableRowTextBinding.make(
      draft: personalDraftBinding,
      rowIdentifier: row.identifier,
      fallback: row.value,
      field: .init(rows: \.disabledWords, identifier: \.identifier, value: \.value)
    )
  }

  func removeDisabledWord(id wordID: UUID) {
    configuration.personalDraft.disabledWords.removeAll { $0.identifier == wordID }
  }

  func addExpansion() {
    configuration.personalDraft.expansions.append(.init(value: "", trigger: "x;"))
  }

  func expansionValueBinding(_ row: LinnetPersonalData.Expansion) -> Binding<String> {
    LinnetStableRowTextBinding.make(
      draft: personalDraftBinding,
      rowIdentifier: row.id,
      fallback: row.value,
      field: .init(rows: \.expansions, identifier: \.id, value: \.value)
    )
  }

  func expansionTriggerBinding(_ row: LinnetPersonalData.Expansion) -> Binding<String> {
    LinnetStableRowTextBinding.make(
      draft: personalDraftBinding,
      rowIdentifier: row.id,
      fallback: row.trigger,
      field: .init(rows: \.expansions, identifier: \.id, value: \.trigger)
    )
  }

  func removeExpansion(id expansionID: UUID) {
    configuration.personalDraft.expansions.removeAll { $0.id == expansionID }
  }

  private var personalDraftBinding: Binding<LinnetPersonalData> {
    Binding(
      get: { self.configuration.personalDraft },
      set: { self.configuration.personalDraft = $0 }
    )
  }

  func reloadExternalChanges() {
    guard configuration.resolveExternalConflictByReloading() else { return }
    status = .ready
  }

  func keepPendingDrafts() {
    guard configuration.resolveExternalConflictKeepingPending() else { return }
    status = .ready
  }

  func personalValidationMessage(locale: Locale) -> String? {
    guard let issue = personalValidation.firstIssue else { return nil }
    let chinese = locale.usesSimplifiedChineseSettingsCopy
    let location = personalValidationLocation(issue.location, chinese: chinese)
    let reason = switch issue.reason {
    case .missing: chinese ? "不能为空。" : "is required."
    case .invalid: chinese ? "格式无效。" : "has an invalid format."
    case .tooLarge: chinese ? "超过安全大小限制。" : "exceeds the safe size limit."
    case .duplicate: chinese ? "与另一行重复。" : "duplicates another row."
    case .tooMany: chinese ? "超过允许的行数。" : "has too many rows."
    }
    return chinese ? "\(location)\(reason)" : "\(location) \(reason)"
  }

  private func personalValidationLocation(
    _ issue: LinnetPersonalDataValidation.Location,
    chinese: Bool
  ) -> String {
    switch issue {
    case .customWord(let wordID, let field):
      return customWordLocation(wordID: wordID, field: field, chinese: chinese)
    case .disabledWord(let wordID):
      let row = configuration.personalDraft.disabledWords.firstIndex {
        $0.identifier == wordID
      }.map { $0 + 1 }
      return chinese ? "禁用词第 \(row ?? 0) 行" : "Disabled word row \(row ?? 0)"
    case .expansion(let expansionID, let field):
      return expansionLocation(expansionID: expansionID, field: field, chinese: chinese)
    case .collection(let collection):
      return collectionLocation(collection, chinese: chinese)
    }
  }

  private func customWordLocation(
    wordID: UUID,
    field: LinnetPersonalDataValidation.CustomField,
    chinese: Bool
  ) -> String {
    let row = configuration.personalDraft.customWords.firstIndex {
      $0.id == wordID
    }.map { $0 + 1 }
    let fieldName = switch field {
    case .value: chinese ? "词条" : "value"
    case .code: chinese ? "编码" : "code"
    }
    return chinese
      ? "自定义词第 \(row ?? 0) 行的\(fieldName)"
      : "Custom word row \(row ?? 0) \(fieldName)"
  }

  private func expansionLocation(
    expansionID: UUID,
    field: LinnetPersonalDataValidation.ExpansionField,
    chinese: Bool
  ) -> String {
    let row = configuration.personalDraft.expansions.firstIndex {
      $0.id == expansionID
    }.map { $0 + 1 }
    let fieldName = switch field {
    case .value: chinese ? "展开内容" : "expansion"
    case .trigger: chinese ? "触发码" : "trigger"
    }
    return chinese
      ? "文本展开第 \(row ?? 0) 行的\(fieldName)"
      : "Text Expander row \(row ?? 0) \(fieldName)"
  }

  private func collectionLocation(
    _ collection: LinnetPersonalDataValidation.Collection,
    chinese: Bool
  ) -> String {
    switch collection {
    case .customWords: chinese ? "自定义词" : "Custom words"
    case .disabledWords: chinese ? "禁用词" : "Disabled words"
    case .expansions: chinese ? "文本展开" : "Text Expander"
    }
  }

  func legacyImportSummary(
    _ candidate: SettingsDataCoordinator.LegacyImportCandidate,
    locale: Locale
  ) -> String {
    let chinese = locale.usesSimplifiedChineseSettingsCopy
    let sourceNames = candidate.sources.map {
      switch $0 {
      case .hallelujah: "Hallelujah"
      case .rime: chinese ? "旧 Rime 用户词典" : "legacy Rime user dictionaries"
      }
    }.joined(separator: chinese ? "、" : ", ")
    if chinese {
      return "已验证来源：\(sourceNames)。将合并 \(candidate.substitutionCount) 条替换规则和 "
        + "\(candidate.recognizedLearningDictionaryCount) 个已识别学习词典；操作前会自动备份当前状态。"
    }
    return "Verified sources: \(sourceNames). This will merge \(candidate.substitutionCount) "
      + "substitutions and \(candidate.recognizedLearningDictionaryCount) recognized learning "
      + "dictionaries after backing up the current state."
  }

  func portableImportSummary(
    _ candidate: SettingsDataCoordinator.PortableImportCandidate,
    locale: Locale
  ) -> String {
    let chinese = locale.usesSimplifiedChineseSettingsCopy
    let categories = candidate.categories.map { category in
      switch category {
      case .customWords: chinese ? "自定义词" : "Custom words"
      case .disabledWords: chinese ? "禁用词" : "Disabled words"
      case .textExpander: chinese ? "文本展开" : "Text Expander"
      case .chineseLearning: chinese ? "中文学习" : "Chinese learning"
      case .englishLearning: chinese ? "英文学习" : "English learning"
      }
    }.joined(separator: chinese ? "、" : ", ")
    if chinese {
      return "归档版本：应用 \(candidate.appVersion)，数据 \(candidate.dataVersion)。将替换："
        + "\(categories)（共 \(candidate.recordCount) 条记录）；其他类别保持不变，操作前会自动备份。"
    }
    return "Archive version: app \(candidate.appVersion), data \(candidate.dataVersion). "
      + "Replace \(categories) (\(candidate.recordCount) records); preserve all other categories "
      + "and back up the current state first."
  }

  var legacyImportCandidate: SettingsDataCoordinator.LegacyImportCandidate? {
    guard case .compatible(let candidate) = legacyImportState else { return nil }
    return candidate
  }

  func choosePortableImportSource(locale: Locale) -> URL? {
    guard !operationActive else { return nil }
    let panel = NSOpenPanel()
    panel.title = SettingsFilePanelTitle.portableImport.text(
      productName: productName, locale: locale)
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [
      UTType(filenameExtension: LinnetBackupStore.portableExtension) ?? .data
    ]
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  func reveal(_ record: LinnetBackupStore.BackupRecord) {
    let target = FileManager.default.fileExists(atPath: record.backupDirectory.path)
      ? record.backupDirectory : record.transactionDirectory
    NSWorkspace.shared.activateFileViewerSelecting([target])
  }

  func copyDiagnostics() {
    guard let report = diagnostics?.redactedReport else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(report, forType: .string)
    status = .diagnosticsCopied
  }

  func saveDiagnostics(locale: Locale) {
    guard let report = diagnostics?.redactedReport else { return }
    let panel = NSSavePanel()
    panel.title = SettingsFilePanelTitle.diagnosticsExport.text(
      productName: productName, locale: locale)
    panel.nameFieldStringValue = "\(productName)-diagnostics.txt"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.plainText]
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      try report.write(to: destination, atomically: true, encoding: .utf8)
      status = .diagnosticsSaved
    } catch {
      status = .diagnosticsSaveFailed
    }
  }

  func categorySelected(_ category: LinnetBackupStore.Category) -> Binding<Bool> {
    Binding(
      get: { self.exportCategories.contains(category) },
      set: { selected in
        if selected {
          self.exportCategories.insert(category)
        } else {
          self.exportCategories.remove(category)
        }
      }
    )
  }

}
