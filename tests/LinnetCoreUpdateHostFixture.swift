import AppKit
import Foundation

// A windowless, uniquely identified App, never an input source. Record the
// identity read by each actual process so recovery checks cannot infer running
// code from the canonical App's current files.
@main
struct LinnetCoreUpdateHostFixture {
  @MainActor static func main() throws {
    let bundle = Bundle.main
    let record = bundle.bundleURL.deletingLastPathComponent()
      .appending(path: "host-launches.jsonl")
    let versionURL = bundle.bundleURL.appending(
      path: "Contents/Resources/LinnetRelease/VERSION.json")
    var launch = try JSONSerialization.jsonObject(
      with: Data(contentsOf: versionURL)) as! [String: Any]
    launch["pid"] = getpid()
    var data = try JSONSerialization.data(withJSONObject: launch)
    data.append(0x0a)
    if !FileManager.default.fileExists(atPath: record.path) {
      _ = FileManager.default.createFile(atPath: record.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: record)
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.close()
    let app = NSApplication.shared
    _ = app.setActivationPolicy(.prohibited)
    app.run()
  }
}
