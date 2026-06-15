import Foundation

/// Append a line to a debug log inside the extension's own data container.
///
/// Disabled by default: only writes when the `BDPAN_DEBUG` environment variable
/// is set, so a shipped build never grows a log file. To troubleshoot, launch
/// the app with `BDPAN_DEBUG=1`. The log lands in the extension's sandbox home
/// (`NSHomeDirectory()`), which the non-sandboxed host app can also read.
func bdpanDebugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["BDPAN_DEBUG"] != nil else { return }
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let logURL = URL(fileURLWithPath:
        (NSHomeDirectory() as NSString).appendingPathComponent("bdpan-ext-debug.log"))
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    if let fh = try? FileHandle(forWritingTo: logURL) {
        fh.seekToEndOfFile(); fh.write(data); try? fh.close()
    }
}
