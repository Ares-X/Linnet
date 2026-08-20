import Foundation

@main
struct LinnetPreeditGeometryTests {
  static func main() {
    let ascii = "nihao"
    let asciiGeometry = LinnetPreeditGeometry.resolve(
      in: ascii, selectionStartUTF8Offset: 0,
      selectionEndUTF8Offset: 5, cursorUTF8Offset: 2)
    require(
      asciiGeometry?.selectionStart == ascii.startIndex
        && asciiGeometry?.selectionEnd == ascii.endIndex
        && asciiGeometry?.cursor == ascii.index(ascii.startIndex, offsetBy: 2),
      "ASCII offsets did not resolve"
    )

    let cjk = "你a好"
    let cjkGeometry = LinnetPreeditGeometry.resolve(
      in: cjk, selectionStartUTF8Offset: 3,
      selectionEndUTF8Offset: 4, cursorUTF8Offset: 7)
    require(
      cjkGeometry.map {
        String(cjk[$0.selectionStart..<$0.selectionEnd]) == "a" && $0.cursor == cjk.endIndex
      } == true,
      "UTF-8 byte boundaries did not resolve"
    )

    for invalid in [
      (-1, 0, 0),
      (0, 8, 0),
      (4, 3, 4),
      (1, 3, 3),
      (0, 3, 2),
    ] {
      require(
        LinnetPreeditGeometry.resolve(
          in: cjk,
          selectionStartUTF8Offset: invalid.0,
          selectionEndUTF8Offset: invalid.1,
          cursorUTF8Offset: invalid.2
        ) == nil,
        "invalid UTF-8 offset was accepted: \(invalid)"
      )
    }

    let preview = "已向左移动guangbiao"
    let previewGeometry = LinnetPreeditGeometry.resolveCandidatePreview(
      in: preview,
      selectionStartUTF8Offset: "已".utf8.count,
      cursorUTF8Offset: "已xiangzuoyi".utf8.count,
      committedPreviewEndUTF8Offset: "已向左移动".utf8.count
    )
    require(
      previewGeometry.map {
        String(preview[..<$0.selectionStart]) == "已"
          && String(preview[..<$0.cursor]) == "已向左移动"
      } == true,
      "candidate preview offsets did not resolve after suffix append"
    )

    let beforePreview = "已向左"
    let cursorBeforeSelection = LinnetPreeditGeometry.resolveCandidatePreview(
      in: beforePreview,
      selectionStartUTF8Offset: "已向".utf8.count,
      cursorUTF8Offset: "已".utf8.count,
      committedPreviewEndUTF8Offset: "已向左".utf8.count
    )
    require(
      cursorBeforeSelection.map { String(beforePreview[..<$0.cursor]) == "已" } == true,
      "candidate preview cursor before selection was not preserved"
    )

    require(
      LinnetPreeditGeometry.resolveCandidatePreview(
        in: "向左",
        selectionStartUTF8Offset: 1,
        cursorUTF8Offset: 0,
        committedPreviewEndUTF8Offset: "向左".utf8.count
      ) == nil,
      "candidate preview accepted a mid-codepoint selection offset"
    )

    print("LinnetPreeditGeometryTests: PASS")
  }

  private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("LinnetPreeditGeometryTests: FAIL: \(message)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
