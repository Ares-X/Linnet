import Foundation

/// Test-only executable that asks the production renderer to populate a
/// temporary Rime user directory. Native runtime tests consume these bytes;
/// no handwritten YAML fixture duplicates the Settings projection contract.
@main
struct LinnetSettingsProjectionFixture {
  static func main() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else { fail() }
    var document = LinnetSettingsDocument.default
    var runtimePersonal: LinnetPersonalData?
    let directory: URL

    switch arguments[1] {
    case "default":
      guard arguments.count == 3 else { fail() }
      directory = URL(filePath: arguments[2], directoryHint: .isDirectory)
    case "profile":
      guard arguments.count == 5,
        let profile = LinnetSettingsContract.ChineseProfile(rawValue: arguments[2]),
        let trigger = LinnetSettingsDocument.PinyinReverseTrigger(rawValue: arguments[3])
      else { fail() }
      document.input.chineseProfile = profile
      document.input.pinyinReverseTrigger = trigger
      directory = URL(filePath: arguments[4], directoryHint: .isDirectory)
    case "page-size":
      guard arguments.count == 4,
        let pageSize = Int(arguments[2]),
        LinnetSettingsDocument.Appearance.pageSizeOptions.contains(pageSize)
      else { fail() }
      document.appearance.pageSize = pageSize
      directory = URL(filePath: arguments[3], directoryHint: .isDirectory)
    case "english-learning-off":
      guard arguments.count == 3 else { fail() }
      document.input.chineseProfile = .jiajia
      document.input.pinyinReverseTrigger = .verticalBar
      document.english.learnFromSelections = false
      directory = URL(filePath: arguments[2], directoryHint: .isDirectory)
    case "english-suggestions-off":
      guard arguments.count == 3 else { fail() }
      document.input.chineseProfile = .jiajia
      document.input.pinyinReverseTrigger = .verticalBar
      document.english.showIPA = false
      document.english.showTranslation = false
      document.english.predictionEnabled = false
      document.english.spellingCorrection = false
      directory = URL(filePath: arguments[2], directoryHint: .isDirectory)
    case "input-options":
      guard arguments.count == 3 else { fail() }
      document.input.chineseProfile = .fullPinyin
      document.input.pinyinReverseTrigger = .verticalBar
      document.input.traditionalChinese = true
      document.english.sentenceCapitalization = false
      document.english.tabBehavior = .pass
      runtimePersonal = .init(
        customWords: [], disabledWords: ["hello"], expansions: [])
      directory = URL(filePath: arguments[2], directoryHint: .isDirectory)
    case "input-switches":
      guard arguments.count == 3 else { fail() }
      document.input.chineseProfile = .fullPinyin
      document.input.emojiEnabled = false
      document.input.asciiPunctuationDefault = true
      document.input.singleCharacterSearchDefault = true
      directory = URL(filePath: arguments[2], directoryHint: .isDirectory)
    case "chinese-learning":
      guard arguments.count == 4,
        let policy = LinnetSettingsDocument.ChineseLearningPolicy(
          rawValue: arguments[2])
      else { fail() }
      document.input.chineseProfile = .fullPinyin
      document.input.chineseLearningPolicy = policy
      directory = URL(filePath: arguments[3], directoryHint: .isDirectory)
    default:
      fail()
    }

    try LinnetSettingsProjectionRenderer.reconcile(
      document: document, to: directory)
    if let runtimePersonal {
      try LinnetPersonalDataStore.writeRuntimeSettings(runtimePersonal, to: directory)
    }
  }

  private static func fail() -> Never {
    FileHandle.standardError.write(Data(
      "usage: projection-fixture default USER_DIR | profile PROFILE TRIGGER USER_DIR | page-size SIZE USER_DIR | english-learning-off USER_DIR | english-suggestions-off USER_DIR | input-options USER_DIR | input-switches USER_DIR | chinese-learning POLICY USER_DIR\n".utf8
    ))
    exit(EXIT_FAILURE)
  }
}
