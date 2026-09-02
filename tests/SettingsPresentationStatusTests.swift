import Darwin
import Foundation

@main
struct SettingsPresentationStatusTests {
  static func main() {
    let english = Locale(identifier: "en")
    let chinese = Locale(identifier: "zh-Hans")
    let chineseRegion = Locale(identifier: "zh-CN")
    let traditionalChinese = Locale(identifier: "zh-Hant")

    expect(.ready, en: "Settings are ready.", zh: "设置已就绪。", english, chinese)
    expect(
      .cloudSyncEnabled,
      en: "iCloud Drive learning synchronization enabled.",
      zh: "已启用 iCloud Drive 学习词同步。",
      english,
      chinese
    )
    expect(
      .cloudSyncCompleted,
      en: "Learning synchronization completed.",
      zh: "学习词同步已完成。",
      english,
      chinese
    )
    expect(
      .cloudBackupUploaded(Date(timeIntervalSince1970: 0)),
      en: "Incremental recovery backup verified at \(Date(timeIntervalSince1970: 0).formatted()).",
      zh: "增量恢复备份已于 \(Date(timeIntervalSince1970: 0).formatted()) 校验完成。",
      english,
      chinese
    )
    expect(
      .cloudSyncDisabled,
      en: "iCloud Drive learning synchronization disabled. No data was deleted.",
      zh: "已停用 iCloud Drive 学习词同步，未删除任何数据。",
      english,
      chinese
    )
    expect(
      .publishingAppearance,
      en: "Publishing candidate appearance…",
      zh: "正在发布候选窗口外观…",
      english,
      chinese
    )
    expect(
      .appearanceLive,
      en: "Candidate appearance is live.",
      zh: "候选窗口外观已实时生效。",
      english,
      chinese
    )
    expect(
      .appearanceStaleRetry,
      en: "Personal data changed elsewhere. Retrying the candidate appearance…",
      zh: "个人数据已在其他位置更改，正在重试候选窗口外观…",
      english,
      chinese
    )
    expect(
      .appearanceFailed(.timedOut),
      en: "Candidate appearance failed. The input method did not reply in time.",
      zh: "候选窗口外观发布失败。输入法未在规定时间内响应。",
      english,
      chinese
    )
    expect(
      .settingsLoadFailed,
      en: "Settings data could not be read. Apply is disabled to protect existing data.",
      zh: "无法读取设置数据。为保护已有数据，已停用“应用更改”。",
      english,
      chinese
    )
    expect(
      .applied(backupName: "backup-42"),
      en: "Applied settings. Backup: backup-42.",
      zh: "设置已应用。备份：backup-42。",
      english,
      chinese
    )
    expect(
      .cancellingOperation,
      en: "Finishing cancellation safely…",
      zh: "正在安全结束操作…",
      english,
      chinese
    )
    expect(
      .operationCancelled,
      en: "Operation cancelled safely.",
      zh: "操作已安全取消。",
      english,
      chinese
    )
    expect(
      .staleDataReloaded,
      en: "Personal data changed elsewhere. Current data was reloaded; review and apply again.",
      zh: "个人数据已在其他位置更改。已重新载入当前数据，请检查后再次应用。",
      english,
      chinese
    )
    expect(
      .configurationConflict,
      en: "Settings data changed elsewhere. Your unsaved draft was preserved for review.",
      zh: "设置数据已在其他位置更改。未保存的草稿已保留，等待检查。",
      english,
      chinese
    )
    expect(
      .operationFailed(.timedOut),
      en: "The input method did not reply in time.",
      zh: "输入法未在规定时间内响应。",
      english,
      chinese
    )
    expect(
      .operationFailed(.hostBusy),
      en: "The input method is busy with another settings operation.",
      zh: "输入法正在处理另一项设置操作。",
      english,
      chinese
    )
    expect(
      .operationFailed(.deploymentFailed),
      en: "The input method could not deploy the new configuration.",
      zh: "输入法无法部署新配置。",
      english,
      chinese
    )
    expect(
      .operationFailed(.incrementalBackupFailed),
      en: "The incremental backup could not be created. Existing settings and learning data were left unchanged.",
      zh: "无法创建增量备份；现有设置和学习数据均未更改。",
      english,
      chinese
    )
    expect(
      .operationFailed(.configurationRecoveryFailed),
      en: "The previous input configuration could not be restored. Reopen Settings after the input method is available.",
      zh: "无法恢复先前的输入配置。请在输入法可用后重新打开设置。",
      english,
      chinese
    )
    expect(
      .appearanceFailed(.appearanceRecoveryFailed),
      en: "Candidate appearance failed. The previous candidate appearance could not be restored. Reopen Settings after the input method is available.",
      zh: "候选窗口外观发布失败。无法恢复先前的候选窗口外观。请在输入法可用后重新打开设置。",
      english,
      chinese
    )
    expect(
      .operationFailed(.hostRejected),
      en: "The input method rejected the operation.",
      zh: "输入法拒绝了此操作。",
      english,
      chinese
    )
    expect(
      .operationFailed(.staleHostState),
      en: "Language data changed before activation. Refresh and try again.",
      zh: "语言数据在激活前已发生变化，请刷新后重试。",
      english,
      chinese
    )
    expect(
      .pack(.languageData, .verificationFailed),
      en: "Language data update failed integrity verification.",
      zh: "语言数据更新未通过完整性校验。",
      english,
      chinese
    )
    expect(
      .pack(.languageData, .offline),
      en: "Connect to the internet and try the language data update again.",
      zh: "请连接互联网后重新更新语言数据。",
      english,
      chinese
    )
    expect(
      .pack(.languageData, .updateServiceUnavailable),
      en: "The Linnet update service is not available yet. Your installed data was not changed.",
      zh: "Linnet 数据更新服务尚不可用；已安装的数据没有变化。",
      english,
      chinese
    )
    expect(
      .pack(.languageData, .busy),
      en: "Another Settings operation is using Linnet data. Try again when it finishes.",
      zh: "另一项设置操作正在使用 Linnet 数据，请等待其完成后重试。",
      english,
      chinese
    )
    expect(
      .pack(.languageData, .activating),
      en: "Activating language data…",
      zh: "正在激活语言数据…",
      english,
      chinese
    )

    expectPresentation(
      .ready,
      severity: .informational,
      systemImage: "info.circle",
      accessibilityLabel: "Status: Settings are ready.",
      locale: english
    )
    expectPresentation(
      .applied(backupName: nil),
      severity: .success,
      systemImage: "checkmark.circle",
      accessibilityLabel: "Success: Applied settings.",
      locale: english
    )
    expectPresentation(
      .operationProgress(.apply, .deploying),
      severity: .progress,
      systemImage: "arrow.triangle.2.circlepath",
      accessibilityLabel: "In progress: Apply settings: deploying…",
      locale: english
    )
    expectPresentation(
      .configurationConflict,
      severity: .warning,
      systemImage: "exclamationmark.triangle",
      accessibilityLabel: "Warning: Settings data changed elsewhere. Your unsaved draft was preserved for review.",
      locale: english
    )
    expectPresentation(
      .diagnosticsUnreachable,
      severity: .warning,
      systemImage: "exclamationmark.triangle",
      accessibilityLabel: "Warning: The input runtime is unreachable. Enable and select Linnet, then refresh.",
      locale: english
    )
    expect(
      .runtime(.running),
      en: "Runtime: running",
      zh: "运行时：正常",
      english,
      chinese
    )
    expectPresentation(
      .runtime(.running),
      severity: .success,
      systemImage: "checkmark.circle",
      accessibilityLabel: "Success: Runtime: running",
      locale: english
    )
    expect(
      .runtime(.paused),
      en: "Runtime: paused",
      zh: "运行时：已暂停",
      english,
      chinese
    )
    expectPresentation(
      .runtime(.paused),
      severity: .informational,
      systemImage: "info.circle",
      accessibilityLabel: "Status: Runtime: paused",
      locale: english
    )
    expect(
      .runtime(.degraded),
      en: "Runtime: degraded",
      zh: "运行时：降级",
      english,
      chinese
    )
    expectPresentation(
      .runtime(.degraded),
      severity: .warning,
      systemImage: "exclamationmark.triangle",
      accessibilityLabel: "Warning: Runtime: degraded",
      locale: english
    )
    expectPresentation(
      .runtime(.unreachable),
      severity: .warning,
      systemImage: "exclamationmark.triangle",
      accessibilityLabel: "警告：运行时：无法连接",
      locale: chinese
    )
    expectPresentation(
      .operationFailed(.unsafePath),
      severity: .error,
      systemImage: "xmark.circle",
      accessibilityLabel: "Error: The selected data path is unsafe.",
      locale: english
    )
    expectPresentation(
      .pack(.languageData, .verificationFailed),
      severity: .error,
      systemImage: "xmark.circle",
      accessibilityLabel: "Error: Language data update failed integrity verification.",
      locale: english
    )
    expectPanel(
      .portableExport,
      productName: "Linnet",
      en: "Export Linnet Data",
      zh: "导出 Linnet 数据",
      english,
      chinese
    )
    expectPanel(
      .portableImport,
      productName: "Linnet",
      en: "Import Linnet Data",
      zh: "导入 Linnet 数据",
      english,
      chinese
    )
    expectPanel(
      .diagnosticsExport,
      productName: "Linnet",
      en: "Export Linnet Diagnostics",
      zh: "导出 Linnet 诊断报告",
      english,
      chinese
    )
    expect(
      .backupVerified(.restore),
      en: "Verified · Restore backup",
      zh: "已校验 · 恢复备份",
      english,
      chinese
    )
    expect(
      .backupRecordRemoved,
      en: "Removed the selected incomplete or invalid backup record.",
      zh: "已移除所选的未完成或无效备份记录。",
      english,
      chinese
    )
    expect(
      .backupRecordRemovalFailed,
      en: "The backup record was not removed. Refresh and try again.",
      zh: "未能移除备份记录，请刷新后重试。",
      english,
      chinese
    )
    guard SettingsBackupRemovalCopy.rowAction(locale: english) == "Remove…",
      SettingsBackupRemovalCopy.rowAction(locale: chinese) == "移除…",
      SettingsBackupRemovalCopy.confirmAction(locale: english) == "Remove Permanently",
      SettingsBackupRemovalCopy.confirmAction(locale: chinese) == "永久移除",
      SettingsBackupRemovalCopy.message(locale: english).contains("cannot be undone"),
      SettingsBackupRemovalCopy.message(locale: chinese).contains("无法撤销")
    else { fail("backup-removal confirmation copy is not fixed and bilingual") }

    guard SettingsPresentationStatus.ready.text(locale: traditionalChinese)
      == "Settings are ready."
    else {
      fail("the unsupported Traditional Chinese locale did not fall back to English")
    }
    guard SettingsPresentationStatus.ready.text(locale: chineseRegion) == "设置已就绪。" else {
      fail("the Simplified Chinese region locale did not use Simplified Chinese copy")
    }
    guard SettingsFilePanelTitle.portableExport.text(
      productName: "Linnet", locale: traditionalChinese) == "Export Linnet Data"
    else {
      fail("the unsupported Traditional Chinese file-panel locale did not fall back to English")
    }

    print("SettingsPresentationStatusTests: PASS")
  }

  private static func expect(
    _ status: SettingsPresentationStatus,
    en: String,
    zh: String,
    _ english: Locale,
    _ chinese: Locale
  ) {
    guard status.text(locale: english) == en, status.text(locale: chinese) == zh else {
      fail("status did not render in both selected languages: \(status)")
    }
  }

  private static func expectPanel(
    _ panel: SettingsFilePanelTitle,
    productName: String,
    en: String,
    zh: String,
    _ english: Locale,
    _ chinese: Locale
  ) {
    guard panel.text(productName: productName, locale: english) == en,
      panel.text(productName: productName, locale: chinese) == zh
    else {
      fail("file panel title did not render in both selected languages: \(panel)")
    }
  }

  private static func expectPresentation(
    _ status: SettingsPresentationStatus,
    severity: SettingsPresentationSeverity,
    systemImage: String,
    accessibilityLabel: String,
    locale: Locale
  ) {
    let presentation = status.presentation(locale: locale)
    guard presentation.text == status.text(locale: locale),
      presentation.severity == severity,
      presentation.systemImage == systemImage,
      presentation.accessibilityLabel == accessibilityLabel
    else {
      fail("typed presentation does not own status semantics: \(status), \(presentation)")
    }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("SettingsPresentationStatusTests: FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }
}
