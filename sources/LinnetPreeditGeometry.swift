//
//  LinnetPreeditGeometry.swift
//  Linnet
//
//  Validates librime's UTF-8 byte offsets before they enter Swift String
//  indexing. Invalid engine/plugin output must hide the transient candidate
//  view, never terminate the system-wide input method process.
//

import Foundation

struct LinnetPreeditGeometry: Equatable {
  struct CandidatePreview: Equatable {
    let selectionStart: String.Index
    let cursor: String.Index
  }

  let selectionStart: String.Index
  let selectionEnd: String.Index
  let cursor: String.Index

  static func resolve(
    in text: String,
    selectionStartUTF8Offset: Int,
    selectionEndUTF8Offset: Int,
    cursorUTF8Offset: Int
  ) -> LinnetPreeditGeometry? {
    let byteCount = text.utf8.count
    guard (0...byteCount).contains(selectionStartUTF8Offset),
      (0...byteCount).contains(selectionEndUTF8Offset),
      (0...byteCount).contains(cursorUTF8Offset),
      selectionStartUTF8Offset <= selectionEndUTF8Offset
    else { return nil }

    func stringIndex(atUTF8Offset offset: Int) -> String.Index? {
      let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
      return String.Index(utf8Index, within: text)
    }

    guard let selectionStart = stringIndex(atUTF8Offset: selectionStartUTF8Offset),
      let selectionEnd = stringIndex(atUTF8Offset: selectionEndUTF8Offset),
      let cursor = stringIndex(atUTF8Offset: cursorUTF8Offset)
    else { return nil }
    return .init(selectionStart: selectionStart, selectionEnd: selectionEnd, cursor: cursor)
  }

  /// Projects preedit byte offsets into a candidate-preview string without
  /// sharing String.Index values between distinct strings or across mutation.
  /// The committed preview end is captured before any untranslated suffix is
  /// appended and resolved again against the final string.
  static func resolveCandidatePreview(
    in text: String,
    selectionStartUTF8Offset: Int,
    cursorUTF8Offset: Int,
    committedPreviewEndUTF8Offset: Int
  ) -> CandidatePreview? {
    let byteCount = text.utf8.count
    guard selectionStartUTF8Offset >= 0,
      cursorUTF8Offset >= 0,
      (0...byteCount).contains(committedPreviewEndUTF8Offset)
    else { return nil }

    let clampedSelectionStart = min(selectionStartUTF8Offset, byteCount)
    let projectedCursor = cursorUTF8Offset <= clampedSelectionStart
      ? cursorUTF8Offset
      : committedPreviewEndUTF8Offset

    func stringIndex(atUTF8Offset offset: Int) -> String.Index? {
      guard (0...byteCount).contains(offset) else { return nil }
      let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
      return String.Index(utf8Index, within: text)
    }

    guard let selectionStart = stringIndex(atUTF8Offset: clampedSelectionStart),
      let cursor = stringIndex(atUTF8Offset: projectedCursor)
    else { return nil }
    return .init(selectionStart: selectionStart, cursor: cursor)
  }
}
