import Foundation

@main
struct LinnetSettingsDownloadSourceTests {
  private enum TestFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
      switch self { case .message(let message): message }
    }
  }

  static func main() {
    do {
      try routingMatrix()
      try persistenceMatrix()
      try invalidMirrorMatrix()
      try transferAllowlistMatrix()
      print("LinnetSettingsDownloadSourceTests: PASS")
    } catch {
      FileHandle.standardError.write(Data("Download source test failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func routingMatrix() throws {
    let catalog = LinnetSettingsDownloadSource.canonicalCatalogURL
    let pack = URL(
      string:
        "https://github.com/Ares-X/Linnet/releases/download/data-4/Linnet-Chinese.linnetpack"
    )!

    try require(
      try LinnetSettingsDownloadSource.direct.requestURL(for: catalog) == catalog,
      "direct catalog route")
    try require(
      try LinnetSettingsDownloadSource.direct.requestURL(for: pack) == pack,
      "direct pack route")

    let publicMirror = LinnetSettingsDownloadSource.publicMirror
    try require(publicMirror.mode == .publicMirror, "public mirror mode")
    try require(
      LinnetSettingsDownloadSource.publicMirrorInformationURL.absoluteString
        == "https://gh-proxy.com/about",
      "public mirror information URL")
    try require(
      try publicMirror.requestURL(for: catalog).absoluteString
        == "https://gh-proxy.com/https://raw.githubusercontent.com/Ares-X/Linnet/data-channel/Linnet-Data-Channel.json",
      "public mirror catalog route")
    try require(
      try publicMirror.requestURL(for: pack).absoluteString
        == "https://gh-proxy.com/https://github.com/Ares-X/Linnet/releases/download/data-4/Linnet-Chinese.linnetpack",
      "public mirror pack route")

    let mirror = try LinnetSettingsDownloadSource.customMirror(
      prefix: "https://mirror.example.com/")
    try require(
      try mirror.requestURL(for: catalog).absoluteString
        == "https://mirror.example.com/https://raw.githubusercontent.com/Ares-X/Linnet/data-channel/Linnet-Data-Channel.json",
      "mirror catalog route")
    try require(
      try mirror.requestURL(for: pack).absoluteString
        == "https://mirror.example.com/https://github.com/Ares-X/Linnet/releases/download/data-4/Linnet-Chinese.linnetpack",
      "mirror pack route")

    let normalizedMirror = try LinnetSettingsDownloadSource.customMirror(
      prefix: "https://MIRROR.EXAMPLE.COM")
    try require(
      normalizedMirror.mirrorPrefixString == "https://mirror.example.com/",
      "mirror root normalization")

    try expect(.invalidCanonicalURL) {
      _ = try mirror.requestURL(for: URL(string: "https://example.com/not-github")!)
    }
    try expect(.invalidCanonicalURL) {
      _ = try mirror.requestURL(for: URL(string: "http://github.com/Ares-X/Linnet")!)
    }
  }

  private static func persistenceMatrix() throws {
    let suite = "io.github.ares-x.linnet.download-source-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      throw TestFailure.message("could not create defaults suite")
    }
    defer { defaults.removePersistentDomain(forName: suite) }

    var preference = LinnetSettingsDownloadSource.load(from: defaults)
    try require(preference.mode == .github, "missing preference default")
    try require(preference.source == .direct, "missing preference source")
    try require(preference.failure == nil, "missing preference failure")

    let publicMirror = LinnetSettingsDownloadSource.publicMirror
    LinnetSettingsDownloadSource.save(publicMirror, to: defaults)
    try require(
      defaults.string(forKey: LinnetSettingsDownloadSource.preferenceDefaultsKey)
        == "preset:gh-proxy-com-v1",
      "public mirror stable preference token")
    preference = LinnetSettingsDownloadSource.load(from: defaults)
    try require(preference.mode == .publicMirror, "public mirror preference mode")
    try require(preference.source == publicMirror, "public mirror preference source")
    try require(preference.failure == nil, "public mirror preference failure")
    try require(preference.mirrorPrefix.isEmpty, "public preset exposed a custom field")

    let mirror = try LinnetSettingsDownloadSource.customMirror(
      prefix: "https://mirror.example.com/")
    LinnetSettingsDownloadSource.save(mirror, to: defaults)
    try require(
      defaults.dictionaryRepresentation().keys.filter {
        $0 == LinnetSettingsDownloadSource.preferenceDefaultsKey
      }.count == 1,
      "download source persisted more than one authoritative field")
    preference = LinnetSettingsDownloadSource.load(from: defaults)
    try require(preference.mode == .customMirror, "mirror preference mode")
    try require(preference.mirrorPrefix == "https://mirror.example.com/", "mirror text")
    try require(preference.source == mirror, "mirror preference source")
    try require(preference.failure == nil, "mirror preference failure")

    LinnetSettingsDownloadSource.save(.direct, to: defaults)
    preference = LinnetSettingsDownloadSource.load(from: defaults)
    try require(preference.mode == .github, "direct preference mode")
    try require(preference.source == .direct, "direct preference source")
    try require(preference.mirrorPrefix.isEmpty, "direct retained a second mirror field")

    defaults.set("future-mode", forKey: LinnetSettingsDownloadSource.preferenceDefaultsKey)
    preference = LinnetSettingsDownloadSource.load(from: defaults)
    try require(preference.source == nil, "unknown mode became authoritative")
    try require(preference.failure == .invalidStoredMode, "unknown mode failure")

    defaults.set(7, forKey: LinnetSettingsDownloadSource.preferenceDefaultsKey)
    preference = LinnetSettingsDownloadSource.load(from: defaults)
    try require(preference.source == nil, "non-string mode became authoritative")
    try require(preference.failure == .invalidStoredMode, "non-string mode failure")

    defaults.set(
      "preset:retired-public-mirror-v0",
      forKey: LinnetSettingsDownloadSource.preferenceDefaultsKey)
    preference = LinnetSettingsDownloadSource.load(from: defaults)
    try require(preference.mode == .publicMirror, "retired preset mode")
    try require(preference.source == nil, "retired preset became authoritative")
    try require(
      preference.failure == .unavailablePublicMirror,
      "retired preset failure")

    defaults.set(
      "mirror:http://mirror.example.com/",
      forKey: LinnetSettingsDownloadSource.preferenceDefaultsKey)
    preference = LinnetSettingsDownloadSource.load(from: defaults)
    try require(preference.source == nil, "unsafe stored mirror became authoritative")
    try require(preference.failure == .invalidMirrorPrefix, "unsafe stored mirror failure")
  }

  private static func invalidMirrorMatrix() throws {
    for prefix in [
      "",
      "http://mirror.example.com/",
      "https://user@mirror.example.com/",
      "https://mirror.example.com:8443/",
      "https://mirror.example.com/path",
      "https://mirror.example.com/path/",
      "https://mirror.example.com/?token=secret",
      "https://mirror.example.com/#fragment",
      "https://localhost/",
      "https://proxy.local/",
      "https://proxy.internal/",
      "https://proxy.home.arpa/",
      "https://proxy.test/",
      "https://proxy.invalid/",
      "https://127.0.0.1/",
      "https://[::1]/",
      "https://single-label/",
      "https://mirror.example.com./",
      "https://镜像.example.com/",
      "https://github.com/",
      "https://mirror.example.com/../proxy/",
    ] {
      try expect(.invalidMirrorPrefix) {
        _ = try LinnetSettingsDownloadSource.customMirror(prefix: prefix)
      }
    }
  }

  private static func transferAllowlistMatrix() throws {
    let direct = LinnetSettingsDownloadSource.direct
    try require(
      direct.allowsTransferURL(URL(string: "https://github.com/Ares-X/Linnet")!),
      "direct GitHub")
    try require(
      direct.allowsTransferURL(
        URL(string: "https://release-assets.githubusercontent.com/final?token=public")!),
      "direct GitHub asset redirect")
    try require(
      !direct.allowsTransferURL(URL(string: "https://mirror.example.com/final")!),
      "direct accepted mirror")

    let publicMirror = LinnetSettingsDownloadSource.publicMirror
    try require(
      publicMirror.allowsTransferURL(URL(string: "https://gh-proxy.com/result")!),
      "public mirror same origin")
    try require(
      !publicMirror.allowsTransferURL(URL(string: "https://github.com/Ares-X/Linnet")!),
      "public mirror allowed GitHub fallback")
    try require(
      !publicMirror.allowsTransferURL(URL(string: "https://cdn.gh-proxy.com/result")!),
      "public mirror accepted sibling origin")

    let mirror = try LinnetSettingsDownloadSource.customMirror(
      prefix: "https://mirror.example.com/")
    try require(
      mirror.allowsTransferURL(URL(string: "https://mirror.example.com/result")!),
      "mirror same origin")
    try require(
      !mirror.allowsTransferURL(URL(string: "https://github.com/Ares-X/Linnet")!),
      "mirror allowed an automatic GitHub fallback")
    try require(
      !mirror.allowsTransferURL(URL(string: "https://cdn.mirror.example.com/result")!),
      "mirror accepted sibling origin")
    try require(
      !mirror.allowsTransferURL(URL(string: "https://example.com/result")!),
      "mirror accepted unrelated redirect")
    try require(
      !mirror.allowsTransferURL(URL(string: "http://mirror.example.com/result")!),
      "mirror accepted HTTP")
  }

  private static func expect(
    _ expected: LinnetSettingsDownloadSource.Failure,
    operation: () throws -> Void
  ) throws {
    do {
      try operation()
      throw TestFailure.message("expected \(expected)")
    } catch let failure as LinnetSettingsDownloadSource.Failure {
      try require(failure == expected, "expected \(expected), got \(failure)")
    }
  }

  private static func require(
    _ condition: @autoclosure () throws -> Bool,
    _ message: String
  ) throws {
    guard try condition() else { throw TestFailure.message(message) }
  }
}
