import Darwin
import Foundation

/// Settings-only owner for choosing how canonical Linnet release URLs are fetched.
///
/// The canonical catalog owns GitHub URLs and artifact identity. A mirror changes
/// the Core and language-data request route; the catalog always comes directly
/// from the official HTTPS endpoint, and artifacts are verified by their owners.
struct LinnetSettingsDownloadSource: Equatable, Sendable {
  enum Mode: String, CaseIterable, Sendable {
    case github
    case publicMirror
    case customMirror
  }

  enum Failure: LocalizedError, Equatable {
    case invalidStoredMode
    case unavailablePublicMirror
    case invalidMirrorPrefix
    case invalidCanonicalURL
    case invalidRoutedURL

    var errorDescription: String? {
      switch self {
      case .invalidStoredMode: "The saved language-data download source is invalid."
      case .unavailablePublicMirror: "The saved public mirror is no longer available."
      case .invalidMirrorPrefix: "The mirror prefix is not a compatible HTTPS URL."
      case .invalidCanonicalURL: "The canonical language-data URL is not a GitHub URL."
      case .invalidRoutedURL: "The mirror could not route the canonical GitHub URL."
      }
    }
  }

  struct Preference: Equatable, Sendable {
    let mode: Mode
    let mirrorPrefix: String
    let source: LinnetSettingsDownloadSource?
    let failure: Failure?
  }

  static let preferenceDefaultsKey = "Linnet.Settings.LanguageDataDownloadSource.v1"
  private static let mirrorTokenPrefix = "mirror:"
  private static let presetTokenPrefix = "preset:"
  private static let publicMirrorPresetID = "gh-proxy-com-v1"
  static let canonicalCatalogURL = URL(
    string:
      "https://raw.githubusercontent.com/Ares-X/Linnet/data-channel/Linnet-Data-Channel.json"
  )!
  private static let publicMirrorOrigin = URL(string: "https://gh-proxy.com/")!
  static let publicMirrorInformationURL = publicMirrorOrigin.appending(path: "about")
  static let direct = LinnetSettingsDownloadSource(mode: .github, mirrorPrefix: nil)
  static let publicMirror = LinnetSettingsDownloadSource(
    mode: .publicMirror,
    mirrorPrefix: publicMirrorOrigin)

  let mode: Mode
  private let mirrorPrefix: URL?

  var mirrorPrefixString: String? {
    mode == .customMirror ? mirrorPrefix?.absoluteString : nil
  }

  static func customMirror(prefix: String) throws -> LinnetSettingsDownloadSource {
    LinnetSettingsDownloadSource(
      mode: .customMirror,
      mirrorPrefix: try validatedMirrorPrefix(prefix))
  }

  static func load(from defaults: UserDefaults = .standard) -> Preference {
    guard defaults.object(forKey: preferenceDefaultsKey) != nil else {
      return Preference(
        mode: .github, mirrorPrefix: "", source: .direct, failure: nil)
    }
    guard let token = defaults.string(forKey: preferenceDefaultsKey) else {
      return Preference(
        mode: .customMirror, mirrorPrefix: "", source: nil,
        failure: .invalidStoredMode)
    }
    if token == Mode.github.rawValue {
      return Preference(
        mode: .github, mirrorPrefix: "", source: .direct, failure: nil)
    }
    if token.hasPrefix(presetTokenPrefix) {
      let presetID = String(token.dropFirst(presetTokenPrefix.count))
      guard presetID == publicMirrorPresetID else {
        return Preference(
          mode: .publicMirror, mirrorPrefix: "", source: nil,
          failure: .unavailablePublicMirror)
      }
      return Preference(
        mode: .publicMirror, mirrorPrefix: "", source: .publicMirror, failure: nil)
    }
    if token.hasPrefix(mirrorTokenPrefix) {
      let mirrorText = String(token.dropFirst(mirrorTokenPrefix.count))
      do {
        let source = try customMirror(prefix: mirrorText)
        return Preference(
          mode: .customMirror, mirrorPrefix: source.mirrorPrefixString ?? mirrorText,
          source: source, failure: nil)
      } catch let failure as Failure {
        return Preference(
          mode: .customMirror, mirrorPrefix: mirrorText, source: nil, failure: failure)
      } catch {
        return Preference(
          mode: .customMirror, mirrorPrefix: mirrorText, source: nil,
          failure: .invalidMirrorPrefix)
      }
    }
    return Preference(
      mode: .customMirror, mirrorPrefix: "", source: nil,
      failure: .invalidStoredMode)
  }

  static func save(
    _ source: LinnetSettingsDownloadSource,
    to defaults: UserDefaults = .standard
  ) {
    let token: String
    switch source.mode {
    case .github:
      token = Mode.github.rawValue
    case .publicMirror:
      token = presetTokenPrefix + publicMirrorPresetID
    case .customMirror:
      guard let prefix = source.mirrorPrefixString else { return }
      token = mirrorTokenPrefix + prefix
    }
    defaults.set(token, forKey: preferenceDefaultsKey)
  }

  func requestURL(for canonicalURL: URL) throws -> URL {
    guard Self.isCanonicalGitHubURL(canonicalURL) else {
      throw Failure.invalidCanonicalURL
    }
    switch mode {
    case .github:
      return canonicalURL
    case .publicMirror, .customMirror:
      guard let mirrorPrefix,
        let routed = URL(string: mirrorPrefix.absoluteString + canonicalURL.absoluteString),
        Self.sameOrigin(routed, mirrorPrefix)
      else { throw Failure.invalidRoutedURL }
      return routed
    }
  }

  func allowsTransferURL(_ url: URL) -> Bool {
    switch mode {
    case .github:
      return Self.isOfficialGitHubTransferURL(url)
    case .publicMirror, .customMirror:
      guard let mirrorPrefix else { return false }
      return Self.safeHTTPSShape(url) && Self.sameOrigin(url, mirrorPrefix)
    }
  }

  private init(mode: Mode, mirrorPrefix: URL?) {
    self.mode = mode
    self.mirrorPrefix = mirrorPrefix
  }

  private static func validatedMirrorPrefix(_ value: String) throws -> URL {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 512,
      trimmed.unicodeScalars.allSatisfy({ $0.isASCII }),
      let components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "https",
      components.user == nil, components.password == nil,
      components.port == nil || components.port == 443,
      components.query == nil, components.fragment == nil,
      let rawHost = components.host?.lowercased(),
      isPublicDNSHost(rawHost),
      !isOfficialGitHubHost(rawHost),
      components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/"
    else { throw Failure.invalidMirrorPrefix }
    var normalized = components
    normalized.scheme = "https"
    normalized.host = rawHost
    normalized.port = nil
    normalized.percentEncodedPath = "/"
    guard let url = normalized.url,
      safeHTTPSShape(url)
    else { throw Failure.invalidMirrorPrefix }
    return url
  }

  private static func isCanonicalGitHubURL(_ url: URL) -> Bool {
    guard safeHTTPSShape(url), let host = url.host?.lowercased(),
      host == "github.com" || host == "raw.githubusercontent.com"
    else { return false }
    return url.query == nil && url.fragment == nil
  }

  private static func isOfficialGitHubTransferURL(_ url: URL) -> Bool {
    guard safeHTTPSShape(url), let host = url.host?.lowercased() else { return false }
    return isOfficialGitHubHost(host)
  }

  private static func isOfficialGitHubHost(_ host: String) -> Bool {
    host == "github.com" || host == "raw.githubusercontent.com"
      || host == "release-assets.githubusercontent.com"
  }

  private static func safeHTTPSShape(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
      && (url.port == nil || url.port == 443) && url.host != nil
  }

  private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && effectivePort(lhs) == effectivePort(rhs)
  }

  private static func effectivePort(_ url: URL) -> Int? {
    if let port = url.port { return port }
    return url.scheme?.lowercased() == "https" ? 443 : nil
  }

  private static func isPublicDNSHost(_ value: String) -> Bool {
    let host = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let rejectedSuffixes = [
      ".localhost", ".local", ".internal", ".home.arpa", ".test", ".example", ".invalid"
    ]
    guard host.contains("."), host != "localhost", !host.hasSuffix("."),
      host.unicodeScalars.allSatisfy({ $0.isASCII }),
      !rejectedSuffixes.contains(where: host.hasSuffix),
      host.split(separator: ".").allSatisfy({ label in
        !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
          && label.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...122).contains($0.value) || $0.value == 45
          }
      })
    else { return false }

    var address4 = in_addr()
    if host.withCString({ inet_pton(AF_INET, $0, &address4) }) == 1 { return false }
    var address6 = in6_addr()
    if host.withCString({ inet_pton(AF_INET6, $0, &address6) }) == 1 { return false }
    return true
  }
}
