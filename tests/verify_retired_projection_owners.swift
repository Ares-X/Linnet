import Foundation
import SwiftParser
import SwiftSyntax

private let registrationOwner = "sources/InputSource.swift"
private let downloadOwner =
  "sources/LinnetSettings/LinnetSettingsDownloadTransport.swift"
private let forbiddenMutationSymbols = Set([
  "TISDisableInputSource",
  "TISEnableInputSource",
  "TISSelectInputSource",
])
private let forbiddenNetworkSymbols = Set([
  "CFNetwork",
  "NWConnection",
  "NWPathMonitor",
  "SPUUpdater",
  "SUUpdater",
  "URLSessionWebSocketTask",
])

private var registrationUses = [String]()
private var downloadUses = [String]()
private var forbiddenUses = [String]()

private func inspect(_ syntax: Syntax, path: String) {
  let tokens = Array(syntax.tokens(viewMode: .sourceAccurate))
  for (index, token) in tokens.enumerated() {
    if case .stringSegment(let value) = token.tokenKind, value == "vim_mode" {
      forbiddenUses.append("\(path):vim_mode")
    }
    guard case .identifier(let name) = token.tokenKind else { continue }
    switch name {
    case "TISRegisterInputSource":
      registrationUses.append(path)
    case "URLSession":
      downloadUses.append(path)
    case let name where forbiddenMutationSymbols.contains(name)
      || forbiddenNetworkSymbols.contains(name):
      forbiddenUses.append("\(path):\(name)")
    default:
      break
    }
    if name == "set_option" {
      let arguments = tokens.dropFirst(index + 1).prefix(12)
      if arguments.contains(where: {
        if case .stringSegment(let value) = $0.tokenKind { return value == "ascii_mode" }
        return false
      }) {
        forbiddenUses.append("\(path):set_option(ascii_mode)")
      }
    }
  }
}

for path in CommandLine.arguments.dropFirst() {
  let source = try String(contentsOfFile: path, encoding: .utf8)
  inspect(Syntax(Parser.parse(source: source)), path: path)
}

guard registrationUses == [registrationOwner] else {
  fatalError("TIS registration escaped its single owner: \(registrationUses)")
}
guard Set(downloadUses) == [downloadOwner] else {
  fatalError("URLSession escaped its single download owner: \(downloadUses)")
}
guard forbiddenUses.isEmpty else {
  fatalError("a forbidden TIS, network, or Swift mode owner returned: \(forbiddenUses)")
}
