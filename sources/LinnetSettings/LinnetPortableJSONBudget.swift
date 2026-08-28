import Foundation

/// Enforces allocation budgets before JSONDecoder constructs a portable archive graph.
enum LinnetPortableJSONBudget {
  enum Failure: Error {
    case malformed
    case resourceLimit
  }

  static func validate(
    _ data: Data,
    maximumArrayLength: Int,
    maximumTotalArrayElements: Int,
    maximumObjectMembers: Int,
    maximumStringBytes: Int,
    maximumDepth: Int = 32
  ) throws {
    try data.withUnsafeBytes { rawBuffer in
      var parser = Parser(
        bytes: rawBuffer.bindMemory(to: UInt8.self),
        maximumArrayLength: maximumArrayLength,
        maximumTotalArrayElements: maximumTotalArrayElements,
        maximumObjectMembers: maximumObjectMembers,
        maximumStringBytes: maximumStringBytes,
        maximumDepth: maximumDepth
      )
      try parser.parse()
    }
  }

  private struct Parser {
    let bytes: UnsafeBufferPointer<UInt8>
    let maximumArrayLength: Int
    let maximumTotalArrayElements: Int
    let maximumObjectMembers: Int
    let maximumStringBytes: Int
    let maximumDepth: Int
    var index = 0
    var arrayElements = 0
    var objectMembers = 0

    mutating func parse() throws {
      try parseValue(depth: 0)
      skipWhitespace()
      guard index == bytes.count else { throw Failure.malformed }
    }

    mutating func parseValue(depth: Int) throws {
      guard depth <= maximumDepth else { throw Failure.resourceLimit }
      skipWhitespace()
      guard index < bytes.count else { throw Failure.malformed }
      switch bytes[index] {
      case 0x7B: try parseObject(depth: depth)  // {
      case 0x5B: try parseArray(depth: depth)  // [
      case 0x22: try parseString()             // "
      case 0x74: try consumeLiteral("true")
      case 0x66: try consumeLiteral("false")
      case 0x6E: try consumeLiteral("null")
      case 0x2D, 0x30...0x39: try parseNumber()
      default: throw Failure.malformed
      }
    }

    mutating func parseObject(depth: Int) throws {
      index += 1
      skipWhitespace()
      if consume(0x7D) { return }
      while true {
        guard index < bytes.count, bytes[index] == 0x22 else { throw Failure.malformed }
        try parseString()
        skipWhitespace()
        guard consume(0x3A) else { throw Failure.malformed }
        guard objectMembers < maximumObjectMembers else { throw Failure.resourceLimit }
        objectMembers += 1
        try parseValue(depth: depth + 1)
        skipWhitespace()
        if consume(0x7D) { return }
        guard consume(0x2C) else { throw Failure.malformed }
        skipWhitespace()
      }
    }

    mutating func parseArray(depth: Int) throws {
      index += 1
      skipWhitespace()
      if consume(0x5D) { return }
      var localElements = 0
      while true {
        guard localElements < maximumArrayLength,
          arrayElements < maximumTotalArrayElements
        else { throw Failure.resourceLimit }
        localElements += 1
        arrayElements += 1
        try parseValue(depth: depth + 1)
        skipWhitespace()
        if consume(0x5D) { return }
        guard consume(0x2C) else { throw Failure.malformed }
        skipWhitespace()
      }
    }

    mutating func parseString() throws {
      guard consume(0x22) else { throw Failure.malformed }
      let start = index
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if index - start > maximumStringBytes { throw Failure.resourceLimit }
        if byte == 0x22 { return }
        guard byte >= 0x20 else { throw Failure.malformed }
        if byte == 0x5C {
          guard index < bytes.count else { throw Failure.malformed }
          let escape = bytes[index]
          index += 1
          if escape == 0x75 {
            guard index + 4 <= bytes.count,
              bytes[index..<index + 4].allSatisfy(isHexDigit)
            else { throw Failure.malformed }
            index += 4
          } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape) {
            throw Failure.malformed
          }
        }
      }
      throw Failure.malformed
    }

    mutating func parseNumber() throws {
      let start = index
      _ = consume(0x2D)
      try parseInteger()
      try parseFraction()
      try parseExponent()
      guard index - start <= 64 else { throw Failure.resourceLimit }
    }

    mutating func parseInteger() throws {
      guard index < bytes.count else { throw Failure.malformed }
      if consume(0x30) {
        guard index == bytes.count || !(0x30...0x39).contains(bytes[index]) else {
          throw Failure.malformed
        }
      } else {
        guard consumeDigit(0x31...0x39) else { throw Failure.malformed }
        while consumeDigit(0x30...0x39) {}
      }
    }

    mutating func parseFraction() throws {
      if consume(0x2E) {
        guard consumeDigit(0x30...0x39) else { throw Failure.malformed }
        while consumeDigit(0x30...0x39) {}
      }
    }

    mutating func parseExponent() throws {
      if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
        index += 1
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
        guard consumeDigit(0x30...0x39) else { throw Failure.malformed }
        while consumeDigit(0x30...0x39) {}
      }
    }

    mutating func consumeLiteral(_ literal: StaticString) throws {
      let expected = Array(String(describing: literal).utf8)
      guard index + expected.count <= bytes.count,
        bytes[index..<index + expected.count].elementsEqual(expected)
      else { throw Failure.malformed }
      index += expected.count
    }

    mutating func consume(_ byte: UInt8) -> Bool {
      guard index < bytes.count, bytes[index] == byte else { return false }
      index += 1
      return true
    }

    mutating func consumeDigit(_ range: ClosedRange<UInt8>) -> Bool {
      guard index < bytes.count, range.contains(bytes[index]) else { return false }
      index += 1
      return true
    }

    mutating func skipWhitespace() {
      while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
      (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte)
        || (0x61...0x66).contains(byte)
    }
  }
}
