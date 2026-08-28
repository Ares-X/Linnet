import CryptoKit
import Darwin
import Foundation
import zlib

/// Offline-only encoder for deterministic Linnet language packs.
/// Runtime targets own verification and extraction; release tooling alone owns creation.
enum LinnetPackEncoder {
  struct EncodedPayload: Equatable, Sendable {
    let unpackedBytes: UInt64
    let unpackedSHA256: String
  }

  static func compressZlib(source: URL, to output: URL) throws -> EncodedPayload {
    let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw LinnetPackContract.Failure.invalidContainer }
    let destination = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let input = try FileHandle(forReadingFrom: source)
    let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_048_576)
    let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1_048_576)
    defer {
      inputBuffer.deallocate()
      outputBuffer.deallocate()
      try? input.close()
      try? destination.close()
    }
    var stream = z_stream()
    guard deflateInit_(
      &stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { throw LinnetPackContract.Failure.invalidPayload("zlib initialization") }
    defer { deflateEnd(&stream) }

    var sourceEnded = false
    var unpackedBytes: UInt64 = 0
    var unpackedHasher = SHA256()
    while true {
      try refillInput(
        stream: &stream,
        sourceEnded: &sourceEnded,
        input: input,
        inputBuffer: inputBuffer,
        unpackedBytes: &unpackedBytes,
        unpackedHasher: &unpackedHasher
      )
      stream.next_out = outputBuffer
      stream.avail_out = 1_048_576
      let status = deflate(&stream, sourceEnded ? Z_FINISH : Z_NO_FLUSH)
      guard status == Z_OK || status == Z_STREAM_END else {
        throw LinnetPackContract.Failure.invalidPayload("zlib encoding")
      }
      let produced = 1_048_576 - Int(stream.avail_out)
      if produced > 0 {
        try destination.write(contentsOf: Data(bytes: outputBuffer, count: produced))
      }
      if status == Z_STREAM_END {
        guard sourceEnded, stream.avail_in == 0 else {
          throw LinnetPackContract.Failure.invalidPayload("zlib encoding input")
        }
        break
      }
      guard produced > 0 || stream.avail_in > 0 || !sourceEnded else {
        throw LinnetPackContract.Failure.invalidPayload("zlib encoding stalled")
      }
    }
    try destination.synchronize()
    return EncodedPayload(
      unpackedBytes: unpackedBytes,
      unpackedSHA256: hex(unpackedHasher.finalize()))
  }

  static func writeContainer(
    manifestData: Data,
    payload: URL,
    to output: URL
  ) throws {
    guard !manifestData.isEmpty,
      manifestData.count <= LinnetPackContract.maximumManifestBytes
    else { throw LinnetPackContract.Failure.invalidContainer }
    let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
    guard descriptor >= 0 else { throw LinnetPackContract.Failure.invalidContainer }
    let destination = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let source = try FileHandle(forReadingFrom: payload)
    defer {
      try? source.close()
      try? destination.close()
    }
    try destination.write(contentsOf: LinnetPackContract.magic)
    try destination.write(contentsOf: Data(bigEndianBytes(LinnetPackContract.containerVersion)))
    try destination.write(contentsOf: Data(bigEndianBytes(UInt32(manifestData.count))))
    try destination.write(contentsOf: manifestData)
    while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
      try destination.write(contentsOf: chunk)
    }
    try destination.synchronize()
  }

  private static func refillInput(
    stream: inout z_stream,
    sourceEnded: inout Bool,
    input: FileHandle,
    inputBuffer: UnsafeMutablePointer<UInt8>,
    unpackedBytes: inout UInt64,
    unpackedHasher: inout SHA256
  ) throws {
    guard stream.avail_in == 0, !sourceEnded else { return }
    let chunk = try input.read(upToCount: 1_048_576) ?? Data()
    guard !chunk.isEmpty else {
      sourceEnded = true
      return
    }
    chunk.copyBytes(to: inputBuffer, count: chunk.count)
    stream.next_in = inputBuffer
    stream.avail_in = UInt32(chunk.count)
    unpackedHasher.update(data: chunk)
    unpackedBytes += UInt64(chunk.count)
    guard unpackedBytes <= UInt64(LinnetPackContract.maximumPayloadBytes) else {
      throw LinnetPackContract.Failure.invalidPayload("unpacked size")
    }
  }

  private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    (0..<MemoryLayout<T>.size).reversed().map { shift in
      UInt8(truncatingIfNeeded: value >> T(shift * 8))
    }
  }

  private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
