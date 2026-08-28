import Foundation

enum SettingsOperationKind: Equatable {
  case apply
  case legacy
  case portableExport
  case portableImport
  case restore
  case removeBackup
  case clearLearning
  case diagnostics
}

enum SettingsOperationPhase: Equatable {
  case preflight
  case pausing
  case snapshotting
  case staging
  case deploying
  case activating
  case verifying
  case cancelling
  case resuming
}

enum SettingsPresentationFailure: Equatable {
  case unavailable
  case invalidOperation
  case unsafePath
  case timedOut
  case hostBusy
  case deploymentFailed
  case appearanceRecoveryFailed
  case configurationRecoveryFailed
  case staleHostState
  case hostRejected
  case unknown
}

enum SettingsPresentationPack: Equatable {
  case languageData
  case longTailDictionaries
}

enum SettingsPresentationPackState: Equatable {
  case downloading
  case verifying
  case activating
  case active(version: String?)
  case cancelling
  case cancelled
  case verificationFailed
  case downloadFailed
  case offline
  case updateServiceUnavailable
  case activationFailed
  case busy
  case unavailable
  case storageFailed
}

enum SettingsPresentationSeverity: Equatable {
  case informational
  case success
  case progress
  case warning
  case error

  fileprivate var systemImage: String {
    switch self {
    case .informational: "info.circle"
    case .success: "checkmark.circle"
    case .progress: "arrow.triangle.2.circlepath"
    case .warning: "exclamationmark.triangle"
    case .error: "xmark.circle"
    }
  }

  fileprivate func accessibilityName(chinese: Bool) -> String {
    switch self {
    case .informational: chinese ? "状态" : "Status"
    case .success: chinese ? "成功" : "Success"
    case .progress: chinese ? "进行中" : "In progress"
    case .warning: chinese ? "警告" : "Warning"
    case .error: chinese ? "错误" : "Error"
    }
  }
}

struct SettingsStatusPresentation: Equatable {
  let text: String
  let severity: SettingsPresentationSeverity
  let systemImage: String
  let accessibilityLabel: String
}

enum SettingsPresentationStatus: Equatable {
  case ready
  case settingsLoadFailed
  case pack(SettingsPresentationPack, SettingsPresentationPackState)
  case backupRetentionSaved
  case hostUnavailable
  case dataFolderUnavailable
  case dataFolderOpenFailed
  case applied(backupName: String?)
  case legacyImported(substitutions: Int, learningRecords: Int)
  case portableExported(productName: String)
  case portableImported
  case cloudSyncEnabled
  case cloudSyncRequested
  case cloudBackupUploaded
  case cloudSyncDisabled
  case backupRestored
  case backupRecordRemoved
  case backupRecordRemovalFailed
  case learningCleared
  case diagnosticsRefreshed
  case diagnosticsUnreachable
  case diagnosticsCopied
  case diagnosticsSaved
  case diagnosticsSaveFailed
  case operationProgress(SettingsOperationKind, SettingsOperationPhase)
  case cancellingOperation
  case operationCancelled
  case staleDataReloaded
  case configurationConflict
  case operationFailed(SettingsPresentationFailure)
  case publishingAppearance
  case appearanceLive
  case appearanceStaleRetry
  case appearanceFailed(SettingsPresentationFailure)
  case backupsUnavailable
  case backupVerified(SettingsOperationKind)
  case backupIncomplete
  case backupInvalid
  case runtime(SettingsRuntimeReachability)

  func presentation(locale: Locale) -> SettingsStatusPresentation {
    let text = text(locale: locale)
    let severity = severity
    let chinese = locale.usesSimplifiedChineseSettingsCopy
    let accessibilityName = severity.accessibilityName(chinese: chinese)
    let accessibilityLabel = chinese
      ? "\(accessibilityName)：\(text)" : "\(accessibilityName): \(text)"
    return SettingsStatusPresentation(
      text: text,
      severity: severity,
      systemImage: severity.systemImage,
      accessibilityLabel: accessibilityLabel
    )
  }

  func text(locale: Locale) -> String {
    let chinese = locale.usesSimplifiedChineseSettingsCopy
    let pair: (english: String, chinese: String)
    switch self {
    case .ready:
      pair = ("Settings are ready.", "设置已就绪。")
    case .settingsLoadFailed:
      pair = (
        "Settings data could not be read. Apply is disabled to protect existing data.",
        "无法读取设置数据。为保护已有数据，已停用“应用更改”。"
      )
    case .pack(let pack, let state):
      pair = packText(pack: pack, state: state)
    case .backupRetentionSaved:
      pair = ("Backup retention saved. It applies after the next successful backup.", "备份保留策略已保存，将在下次成功备份后生效。")
    case .hostUnavailable:
      pair = ("Settings could not locate the host input method.", "设置应用找不到输入法主程序。")
    case .dataFolderUnavailable:
      pair = ("The user data folder is unavailable.", "用户数据文件夹不可用。")
    case .dataFolderOpenFailed:
      pair = ("The user data folder could not be opened.", "无法打开用户数据文件夹。")
    case .applied(let backupName):
      if let backupName {
        pair = ("Applied settings. Backup: \(backupName).", "设置已应用。备份：\(backupName)。")
      } else {
        pair = ("Applied settings.", "设置已应用。")
      }
    case .legacyImported(let substitutions, let learningRecords):
      pair = (
        "Imported \(substitutions) substitutions and \(learningRecords) learning records.",
        "已导入 \(substitutions) 条替换规则和 \(learningRecords) 条学习记录。"
      )
    case .portableExported(let productName):
      pair = ("Portable \(productName) data exported.", "已导出可迁移的 \(productName) 数据。")
    case .portableImported:
      pair = ("Selected portable categories were replaced; other data was preserved.", "已替换所选迁移数据类别，其他数据保持不变。")
    case .cloudSyncEnabled:
      pair = ("iCloud Drive learning synchronization enabled.", "已启用 iCloud Drive 学习词同步。")
    case .cloudSyncRequested:
      pair = ("Learning synchronization requested.", "已请求同步学习词。")
    case .cloudBackupUploaded:
      pair = ("Full recovery backup uploaded.", "已上传完整恢复备份。")
    case .cloudSyncDisabled:
      pair = (
        "iCloud Drive learning synchronization disabled. No data was deleted.",
        "已停用 iCloud Drive 学习词同步，未删除任何数据。"
      )
    case .backupRestored:
      pair = ("Verified backup restored. The previous state was backed up first.", "已恢复通过校验的备份，并先备份了原状态。")
    case .backupRecordRemoved:
      pair = ("Removed the selected incomplete or invalid backup record.", "已移除所选的未完成或无效备份记录。")
    case .backupRecordRemovalFailed:
      pair = ("The backup record was not removed. Refresh and try again.", "未能移除备份记录，请刷新后重试。")
    case .learningCleared:
      pair = ("Selected learning data was cleared; personal data was preserved.", "已清除所选学习数据，个人数据保持不变。")
    case .diagnosticsRefreshed:
      pair = ("Privacy-safe diagnostics refreshed.", "已刷新隐私安全的诊断信息。")
    case .diagnosticsUnreachable:
      pair = ("The input runtime is unreachable. Enable and select Linnet, then refresh.", "无法连接输入法运行时。请启用并切换到 Linnet 后刷新。")
    case .diagnosticsCopied:
      pair = ("Copied privacy-safe diagnostics.", "已复制隐私安全的诊断信息。")
    case .diagnosticsSaved:
      pair = ("Privacy-safe diagnostics saved.", "已保存隐私安全的诊断信息。")
    case .diagnosticsSaveFailed:
      pair = ("Diagnostics could not be saved.", "无法保存诊断信息。")
    case .operationProgress(let kind, let phase):
      let operation = operationName(kind)
      let phaseName = phaseName(phase)
      pair = (
        "\(operation.english): \(phaseName.english)…",
        "\(operation.chinese)：\(phaseName.chinese)…"
      )
    case .cancellingOperation:
      pair = ("Finishing cancellation safely…", "正在安全结束操作…")
    case .operationCancelled:
      pair = ("Operation cancelled safely.", "操作已安全取消。")
    case .staleDataReloaded:
      pair = (
        "Personal data changed elsewhere. Current data was reloaded; review and apply again.",
        "个人数据已在其他位置更改。已重新载入当前数据，请检查后再次应用。"
      )
    case .configurationConflict:
      pair = (
        "Settings data changed elsewhere. Your unsaved draft was preserved for review.",
        "设置数据已在其他位置更改。未保存的草稿已保留，等待检查。"
      )
    case .operationFailed(let failure):
      pair = failureText(failure)
    case .publishingAppearance:
      pair = ("Publishing candidate appearance…", "正在发布候选窗口外观…")
    case .appearanceLive:
      pair = ("Candidate appearance is live.", "候选窗口外观已实时生效。")
    case .appearanceStaleRetry:
      pair = (
        "Personal data changed elsewhere. Retrying the candidate appearance…",
        "个人数据已在其他位置更改，正在重试候选窗口外观…"
      )
    case .appearanceFailed(let failure):
      let reason = failureText(failure)
      pair = (
        "Candidate appearance failed. \(reason.english)",
        "候选窗口外观发布失败。\(reason.chinese)"
      )
    case .backupsUnavailable:
      pair = ("Backups could not be read.", "无法读取备份。")
    case .backupVerified(let operation):
      let name = operationName(operation)
      pair = ("Verified · \(name.english)", "已校验 · \(name.chinese)")
    case .backupIncomplete:
      pair = ("Incomplete · not restorable", "未完成 · 无法恢复")
    case .backupInvalid:
      pair = ("Invalid · not restorable", "无效 · 无法恢复")
    case .runtime(let state):
      pair = runtimeText(state)
    }
    return chinese ? pair.chinese : pair.english
  }

  private var severity: SettingsPresentationSeverity {
    switch self {
    case .ready,
      .operationCancelled,
      .pack(_, .cancelled),
      .runtime(.paused):
      .informational
    case .backupRetentionSaved,
      .applied,
      .legacyImported,
      .portableExported,
      .portableImported,
      .cloudSyncEnabled,
      .cloudSyncRequested,
      .cloudBackupUploaded,
      .cloudSyncDisabled,
      .backupRestored,
      .backupRecordRemoved,
      .learningCleared,
      .diagnosticsRefreshed,
      .diagnosticsCopied,
      .diagnosticsSaved,
      .appearanceLive,
      .backupVerified,
      .pack(_, .active),
      .runtime(.running):
      .success
    case .operationProgress,
      .cancellingOperation,
      .publishingAppearance,
      .appearanceStaleRetry,
      .pack(_, .downloading),
      .pack(_, .verifying),
      .pack(_, .activating),
      .pack(_, .cancelling):
      .progress
    case .staleDataReloaded,
      .configurationConflict,
      .diagnosticsUnreachable,
      .backupIncomplete,
      .pack(_, .offline),
      .pack(_, .updateServiceUnavailable),
      .pack(_, .busy),
      .pack(_, .unavailable),
      .runtime(.degraded),
      .runtime(.unreachable):
      .warning
    case .settingsLoadFailed,
      .hostUnavailable,
      .dataFolderUnavailable,
      .dataFolderOpenFailed,
      .backupRecordRemovalFailed,
      .diagnosticsSaveFailed,
      .operationFailed,
      .appearanceFailed,
      .backupsUnavailable,
      .backupInvalid,
      .pack(_, .verificationFailed),
      .pack(_, .downloadFailed),
      .pack(_, .activationFailed),
      .pack(_, .storageFailed):
      .error
    }
  }
}

enum SettingsBackupRemovalCopy {
  static func rowAction(locale: Locale) -> String {
    locale.usesSimplifiedChineseSettingsCopy ? "移除…" : "Remove…"
  }

  static func title(locale: Locale) -> String {
    locale.usesSimplifiedChineseSettingsCopy
      ? "永久移除此备份记录？" : "Permanently remove this backup record?"
  }

  static func confirmAction(locale: Locale) -> String {
    locale.usesSimplifiedChineseSettingsCopy ? "永久移除" : "Remove Permanently"
  }

  static func message(locale: Locale) -> String {
    locale.usesSimplifiedChineseSettingsCopy
      ? "此操作只会永久删除所选的未完成或无效备份记录，且无法撤销。已验证备份不能通过此处移除。"
      : "This permanently deletes only the selected incomplete or invalid backup record and cannot be undone. Verified backups cannot be removed here."
  }
}

enum SettingsFilePanelTitle: Equatable {
  case portableExport
  case portableImport
  case diagnosticsExport

  func text(productName: String, locale: Locale) -> String {
    let chinese = locale.usesSimplifiedChineseSettingsCopy
    switch self {
    case .portableExport:
      return chinese ? "导出 \(productName) 数据" : "Export \(productName) Data"
    case .portableImport:
      return chinese ? "导入 \(productName) 数据" : "Import \(productName) Data"
    case .diagnosticsExport:
      return chinese ? "导出 \(productName) 诊断报告" : "Export \(productName) Diagnostics"
    }
  }
}

extension Locale {
  /// Beta ships English and Simplified Chinese only. Unsupported Chinese
  /// scripts must follow the catalog's English fallback instead of mixing an
  /// English static surface with Simplified-Chinese dynamic status text.
  var usesSimplifiedChineseSettingsCopy: Bool {
    language.languageCode?.identifier == "zh" && language.script?.identifier == "Hans"
  }
}

private typealias SettingsLocalizedPair = (english: String, chinese: String)

private func failureText(_ failure: SettingsPresentationFailure) -> SettingsLocalizedPair {
  switch failure {
  case .unavailable: ("Data services are unavailable.", "数据服务不可用。")
  case .invalidOperation: ("The requested data operation is invalid.", "请求的数据操作无效。")
  case .unsafePath: ("The selected data path is unsafe.", "所选数据路径不安全。")
  case .timedOut: ("The input method did not reply in time.", "输入法未在规定时间内响应。")
  case .hostBusy: ("The input method is busy with another settings operation.", "输入法正在处理另一项设置操作。")
  case .deploymentFailed: ("The input method could not deploy the new configuration.", "输入法无法部署新配置。")
  case .appearanceRecoveryFailed:
    (
      "The previous candidate appearance could not be restored. Reopen Settings after the input method is available.",
      "无法恢复先前的候选窗口外观。请在输入法可用后重新打开设置。"
    )
  case .configurationRecoveryFailed:
    (
      "The previous input configuration could not be restored. Reopen Settings after the input method is available.",
      "无法恢复先前的输入配置。请在输入法可用后重新打开设置。"
    )
  case .staleHostState: ("Language data changed before activation. Refresh and try again.", "语言数据在激活前已发生变化，请刷新后重试。")
  case .hostRejected: ("The input method rejected the operation.", "输入法拒绝了此操作。")
  case .unknown: ("The operation failed.", "操作失败。")
  }
}

private func packText(
  pack: SettingsPresentationPack,
  state: SettingsPresentationPackState
) -> SettingsLocalizedPair {
  let name: SettingsLocalizedPair
  switch pack {
  case .languageData: name = ("language data", "语言数据")
  case .longTailDictionaries: name = ("long-tail dictionaries", "长尾词典")
  }
  let titleName = pack == .languageData ? "Language data" : "Long-tail dictionaries"
  switch state {
  case .downloading: return ("Downloading \(name.english)…", "正在下载\(name.chinese)…")
  case .verifying: return ("Verifying \(name.english)…", "正在校验\(name.chinese)…")
  case .activating: return ("Activating \(name.english)…", "正在激活\(name.chinese)…")
  case .active(let version):
    let suffix = version.map { " \($0)" } ?? ""
    return ("\(titleName)\(suffix) is active.", "\(name.chinese)\(suffix) 已启用。")
  case .cancelling: return ("Cancelling the \(name.english) download…", "正在取消\(name.chinese)下载…")
  case .cancelled: return ("Cancelled the \(name.english) download.", "已取消\(name.chinese)下载。")
  case .verificationFailed: return ("\(titleName) update failed integrity verification.", "\(name.chinese)更新未通过完整性校验。")
  case .downloadFailed: return ("\(titleName) download failed.", "\(name.chinese)下载失败。")
  case .offline:
    return (
      "Connect to the internet and try the \(name.english) update again.",
      "请连接互联网后重新更新\(name.chinese)。"
    )
  case .updateServiceUnavailable:
    return (
      "The Linnet update service is not available yet. Your installed data was not changed.",
      "Linnet 数据更新服务尚不可用；已安装的数据没有变化。"
    )
  case .activationFailed: return ("\(titleName) could not be activated.", "无法激活\(name.chinese)。")
  case .busy:
    return (
      "Another Settings operation is using Linnet data. Try again when it finishes.",
      "另一项设置操作正在使用 Linnet 数据，请等待其完成后重试。"
    )
  case .unavailable: return ("Trusted \(name.english) update data is unavailable.", "可信的\(name.chinese)更新数据不可用。")
  case .storageFailed: return ("\(titleName) could not be written to disk.", "无法将\(name.chinese)写入磁盘。")
  }
}

private func operationName(_ kind: SettingsOperationKind) -> SettingsLocalizedPair {
  switch kind {
  case .apply: ("Apply settings", "应用设置")
  case .legacy: ("Import existing data", "导入现有数据")
  case .portableExport: ("Export portable data", "导出迁移数据")
  case .portableImport: ("Import portable data", "导入迁移数据")
  case .restore: ("Restore backup", "恢复备份")
  case .removeBackup: ("Remove backup record", "移除备份记录")
  case .clearLearning: ("Clear learning", "清除学习数据")
  case .diagnostics: ("Refresh diagnostics", "刷新诊断信息")
  }
}

private func phaseName(_ phase: SettingsOperationPhase) -> SettingsLocalizedPair {
  switch phase {
  case .preflight: ("preflight", "预检")
  case .pausing: ("pausing input runtime", "暂停输入法运行时")
  case .snapshotting: ("creating backup", "创建备份")
  case .staging: ("staging files", "准备文件")
  case .deploying: ("deploying", "部署")
  case .activating: ("activating", "激活")
  case .verifying: ("verifying", "校验")
  case .cancelling: ("cancelling", "取消")
  case .resuming: ("resuming input runtime", "恢复输入法运行时")
  }
}

private func runtimeText(_ state: SettingsRuntimeReachability) -> SettingsLocalizedPair {
  switch state {
  case .running: ("Runtime: running", "运行时：正常")
  case .paused: ("Runtime: paused", "运行时：已暂停")
  case .degraded: ("Runtime: degraded", "运行时：降级")
  case .unreachable: ("Runtime: unreachable", "运行时：无法连接")
  }
}
