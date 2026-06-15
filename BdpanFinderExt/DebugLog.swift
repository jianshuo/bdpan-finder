import Foundation

/// Append a line to a debug log inside the extension's own data container.
///
/// The sandboxed extension cannot write to /tmp once the development
/// temporary-exception entitlements are removed, but it can always write into
/// its own sandbox home (`NSHomeDirectory()`), which the non-sandboxed host app
/// can also read for diagnostics.
func bdpanDebugLog(_ message: String) {
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
