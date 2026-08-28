import Foundation
import SwiftParser
import SwiftSyntax

private let watchedMembers = Set([
  "rootDirectory", "downloadsDirectory", "schemeID", "outcome", "fingerprint",
  "collisions", "existingConflicts"
])
private let watchedTypes = Set(["Outcome", "Collision", "ExistingConflict"])
private var memberPaths: [String] = []
private var typePaths: [String] = []

private func recordMember(_ name: String, owners: [String], insideCallable: Bool) {
  guard !insideCallable, !owners.isEmpty, watchedMembers.contains(name) else { return }
  memberPaths.append((owners + [name]).joined(separator: "."))
}

private func enteredOwners(for syntax: Syntax, inherited: [String]) -> [String] {
  let name: String?
  if let declaration = syntax.as(StructDeclSyntax.self) {
    name = declaration.name.text
  } else if let declaration = syntax.as(EnumDeclSyntax.self) {
    name = declaration.name.text
  } else if let declaration = syntax.as(ClassDeclSyntax.self) {
    name = declaration.name.text
  } else if let declaration = syntax.as(ActorDeclSyntax.self) {
    name = declaration.name.text
  } else if let declaration = syntax.as(ProtocolDeclSyntax.self) {
    name = declaration.name.text
  } else if let declaration = syntax.as(ExtensionDeclSyntax.self) {
    return [declaration.extendedType.trimmedDescription]
  } else {
    return inherited
  }
  guard let name else { return inherited }
  let owners = inherited + [name]
  if watchedTypes.contains(name) {
    typePaths.append(owners.joined(separator: "."))
  }
  return owners
}

private func declaredMemberNames(in syntax: Syntax) -> [String] {
  if let declaration = syntax.as(VariableDeclSyntax.self) {
    var names: [String] = []
    for binding in declaration.bindings {
      for token in binding.pattern.tokens(viewMode: .sourceAccurate) {
        names.append(token.text)
      }
    }
    return names
  }
  return syntax.as(FunctionDeclSyntax.self).map { [$0.name.text] } ?? []
}

private func startsCallableScope(_ syntax: Syntax) -> Bool {
  syntax.is(FunctionDeclSyntax.self)
    || syntax.is(InitializerDeclSyntax.self)
    || syntax.is(DeinitializerDeclSyntax.self)
    || syntax.is(AccessorDeclSyntax.self)
    || syntax.is(ClosureExprSyntax.self)
    || syntax.is(SubscriptDeclSyntax.self)
}

private func walk(_ syntax: Syntax, owners inheritedOwners: [String] = [], insideCallable inheritedCallable: Bool = false) {
  let owners = enteredOwners(for: syntax, inherited: inheritedOwners)
  if let declaration = syntax.as(TypeAliasDeclSyntax.self), watchedTypes.contains(declaration.name.text) {
    typePaths.append((owners + [declaration.name.text]).joined(separator: "."))
  }
  for name in declaredMemberNames(in: syntax) {
    recordMember(name, owners: owners, insideCallable: inheritedCallable)
  }
  let insideCallable = inheritedCallable || startsCallableScope(syntax)

  for child in syntax.children(viewMode: .sourceAccurate) {
    walk(child, owners: owners, insideCallable: insideCallable)
  }
}

for path in CommandLine.arguments.dropFirst() {
  let source = try String(contentsOfFile: path, encoding: .utf8)
  walk(Syntax(Parser.parse(source: source)))
}

let expectedMembers = [
  "HallelujahSubstitutionImporter.ExistingTableAccumulator.fingerprint",
  "HallelujahSubstitutionImporter.PreparedSource.fingerprint",
  "LinnetDataRegistry.downloadsDirectory",
  "LinnetDataRegistry.rootDirectory"
]
guard memberPaths.sorted() == expectedMembers else {
  fatalError("retired projection member inventory changed: \(memberPaths.sorted())")
}
guard typePaths.sorted() == ["SettingsDataCoordinator.Outcome"] else {
  fatalError("retired import result type inventory changed: \(typePaths.sorted())")
}
