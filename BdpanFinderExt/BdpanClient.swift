import Foundation
import Darwin

// MARK: - Error types

enum BdpanError: Error, LocalizedError {
    case binaryNotFound(path: String)
    case tokenExpired
    case pathNotFound
    case pathNotAllowed
    case processFailure(exitCode: Int32, stderr: String)
    case jsonDecodeFailure(underlying: Error, output: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "bdpan binary not found at \(path)"
        case .tokenExpired:
            return "bdpan token expired — run 'bdpan login' to re-authenticate"
        case .pathNotFound:
            return "Remote path not found"
        case .pathNotAllowed:
            return "Remote path not allowed"
        case .processFailure(let exitCode, let stderr):
            return "bdpan exited with code \(exitCode): \(stderr)"
        case .jsonDecodeFailure(let underlying, let output):
            return "Failed to decode bdpan JSON output: \(underlying). Raw output: \(output)"
        }
    }
}

// MARK: - BdpanClient

/// Synchronous wrapper around the bdpan CLI.
///
/// Every method blocks the calling thread via `Process.waitUntilExit()`.
/// This is intentional: the File Provider Extension framework manages concurrency
/// at a higher level (NSFileProviderReplicatedExtension callbacks arrive on
/// background threads), so synchronous subprocess calls are safe and simple here.
final class BdpanClient {

    // MARK: - Configuration

    /// Path to the bdpan binary. Resolves to the copy bundled inside this
    /// extension/app bundle so a sandboxed, notarized build can exec it with no
    /// temporary-exception entitlement. Override in unit tests.
    var bdpanPath: String = BdpanClient.bundledBdpanPath() ?? ""

    /// Bundle identifier of the File Provider extension.
    static let extensionBundleIdentifier = "com.wangjianshuo.BdpanFinder.Extension"

    /// Real home directory (`/Users/<name>`), resolved even from inside the
    /// sandbox where `NSHomeDirectory()` returns the container path.
    static func realHome() -> String {
        if let pwd = Darwin.getpwuid(Darwin.getuid()) {
            return String(cString: pwd.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }

    /// The File Provider extension's data container. This is the one location
    /// both processes can reach without an authorized App Group:
    /// - the sandboxed extension owns it (it is its own sandbox home), and
    /// - the non-sandboxed host app can write into it as the same user.
    /// bdpan's login config (OAuth token + `.token_key`) lives here so the
    /// sandbox never needs to reach ~/.config and we avoid App-Group
    /// provisioning entirely.
    static func containerDir() -> String {
        return realHome() + "/Library/Containers/\(extensionBundleIdentifier)/Data"
    }

    /// Directory holding bdpan's config files inside the shared container.
    static func bdpanConfigDir() -> String {
        return containerDir() + "/bdpan"
    }

    /// Full path to bdpan's config file.
    static func configPath() -> String {
        return bdpanConfigDir() + "/config.json"
    }

    /// Locate the bundled `bdpan` executable.
    ///
    /// Shipped builds must embed the binary in the bundle's Resources. There is
    /// no fallback to a developer-machine path, because that path does not exist
    /// on users' Macs and would mask packaging bugs.
    static func bundledBdpanPath() -> String? {
        Bundle(for: BdpanClient.self).url(forResource: "bdpan", withExtension: nil)?.path
    }

    // MARK: - Public API

    /// List files and directories at a remote path.
    ///
    /// Runs: `bdpan ls --json <remotePath>`
    ///
    /// - Parameter remotePath: Full absolute path (e.g. `/apps/bdpan/`) or a path
    ///   relative to `/apps/bdpan/` (e.g. `我的视频`).
    /// - Returns: Array of `BdpanFileInfo` entries; empty array for an empty directory.
    /// - Throws: `BdpanError` on CLI failure or JSON decode error.
    func listFiles(at remotePath: String) throws -> [BdpanFileInfo] {
        let output = try runBdpan(["ls", "--json", remotePath])

        // bdpan may print nothing (empty directory) or return an empty JSON array.
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            return []
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw BdpanError.jsonDecodeFailure(
                underlying: CocoaError(.fileReadUnknownStringEncoding),
                output: trimmed
            )
        }

        do {
            return try JSONDecoder().decode([BdpanFileInfo].self, from: data)
        } catch {
            throw BdpanError.jsonDecodeFailure(underlying: error, output: trimmed)
        }
    }

    /// Download a single remote file to a local file path.
    ///
    /// Runs: `bdpan download <remotePath> <localFileURL.path>`
    ///
    /// `localFileURL` must be the **full destination file path** (not a directory).
    /// The parent directory must exist before calling.
    ///
    /// - Parameters:
    ///   - remotePath: Full absolute remote path, e.g. `/apps/bdpan/我的/video.mp4`.
    ///   - localFileURL: Destination file URL, e.g. `/tmp/uuid/video.mp4`.
    /// - Throws: `BdpanError` on CLI failure.
    func downloadFile(from remotePath: String, to localFileURL: URL) throws {
        _ = try runBdpan(["download", remotePath, localFileURL.path])
    }

    /// Upload a local file to Baidu Pan.
    ///
    /// Runs: `bdpan upload <localURL.path> <remotePath>`
    ///
    /// For a single-file upload, `remotePath` must NOT end with `/`.
    /// Example: `我的视频/vacation.mp4`
    ///
    /// - Parameters:
    ///   - localURL: Source file URL on disk.
    ///   - remotePath: Destination path relative to `/apps/bdpan/`.
    /// - Throws: `BdpanError` on CLI failure.
    func uploadFile(from localURL: URL, to remotePath: String) throws {
        _ = try runBdpan(["upload", localURL.path, remotePath])
    }

    /// Create a remote directory, including all intermediate components.
    func createDirectory(at remotePath: String) throws {
        _ = try runBdpan(["mkdir", remotePath])
    }

    /// Rename a file or directory in-place (same parent directory).
    ///
    /// Runs: `bdpan rename <remotePath> <newName>`
    ///
    /// `newName` is the bare leaf name only — no path separators.
    func renameItem(at remotePath: String, to newName: String) throws {
        _ = try runBdpan(["rename", remotePath, newName])
    }

    /// Move a file or directory to a different parent directory.
    ///
    /// Runs: `bdpan mv <remotePath> <destDir>`
    ///
    /// `destDir` is the destination **directory** path; the item keeps its basename.
    func moveItem(from remotePath: String, toDirectory destDir: String) throws {
        _ = try runBdpan(["mv", remotePath, destDir])
    }

    /// Copy a file or directory into a destination directory (server-side).
    ///
    /// Runs: `bdpan cp <remotePath> <destDir>`
    func copyItem(from remotePath: String, toDirectory destDir: String) throws {
        _ = try runBdpan(["cp", remotePath, destDir])
    }

    /// Delete a file or directory on Baidu Pan.
    ///
    /// Runs: `bdpan rm -f <remotePath>`
    func deleteItem(at remotePath: String) throws {
        _ = try runBdpan(["rm", "-f", remotePath])
    }

    // MARK: - Low-level runner

    /// Launch bdpan synchronously and return its standard output.
    ///
    /// Blocks the calling thread until the child process exits. Captures both
    /// stdout (returned) and stderr (inspected for well-known error strings).
    ///
    /// - Parameter arguments: Arguments forwarded verbatim to bdpan.
    /// - Returns: Captured stdout, trimmed of leading/trailing whitespace.
    /// - Throws:
    ///   - `BdpanError.binaryNotFound` – executable missing at `bdpanPath`.
    ///   - `BdpanError.tokenExpired`   – stderr/stdout contains "Token expired".
    ///   - `BdpanError.pathNotFound`   – stderr/stdout contains "File not found".
    ///   - `BdpanError.pathNotAllowed` – stderr/stdout contains "Path not allowed".
    ///   - `BdpanError.processFailure` – any other non-zero exit code.
    @discardableResult
    func runBdpan(_ arguments: [String]) throws -> String {
        guard !bdpanPath.isEmpty,
              FileManager.default.isExecutableFile(atPath: bdpanPath) else {
            let reportedPath = bdpanPath.isEmpty ? "<bundled bdpan missing>" : bdpanPath
            throw BdpanError.binaryNotFound(path: reportedPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bdpanPath)

        // Pin bdpan's config (OAuth token) to the App Group container so the
        // sandboxed extension and the host app share one login without ever
        // touching ~/.config. --config-path is a global flag and is valid before
        // the subcommand.
        // Pin bdpan's config (OAuth token + .token_key) to the shared container
        // directory. --config-path is a global flag, valid before the subcommand;
        // bdpan resolves .token_key next to it.
        // --no-check-update prevents update-check output from polluting stdout/stderr.
        let fullArgs = ["--no-check-update", "--config-path", BdpanClient.configPath()] + arguments
        process.arguments = fullArgs

        // Point HOME at the shared container so anything bdpan writes relative to
        // the home directory also lands in the sandbox-accessible container.
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = BdpanClient.containerDir()
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        func dblog(_ msg: String) {
            bdpanDebugLog("BdpanClient[\(arguments.first ?? "?")]: \(msg)")
        }
        dblog("launching \(bdpanPath) \(fullArgs.joined(separator: " "))")
        do {
            try process.run()
        } catch {
            dblog("launch failed: \(error)")
            throw BdpanError.processFailure(
                exitCode: -1,
                stderr: "Could not launch '\(bdpanPath)': \(error.localizedDescription)"
            )
        }

        // Read stdout/stderr on dedicated Threads (not GCD global pool) to avoid
        // two classes of deadlock:
        // 1. Pipe deadlock: bdpan fills the 64KB pipe buffer and blocks on write
        //    while waitUntilExit blocks on the process — drain the pipe concurrently.
        // 2. GCD thread pool exhaustion: enumerateItems callers already occupy global
        //    queue threads; DispatchQueue.global().async tasks for pipe reads queue
        //    behind them and never start. Using Thread bypasses the pool entirely.
        var stdoutData = Data()
        var stderrData = Data()
        let stdoutSem = DispatchSemaphore(value: 0)
        let stderrSem = DispatchSemaphore(value: 0)
        let stdoutThread = Thread {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutSem.signal()
        }
        let stderrThread = Thread {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrSem.signal()
        }
        stdoutThread.start()
        stderrThread.start()
        process.waitUntilExit()
        stdoutSem.wait()
        stderrSem.wait()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        dblog("exit=\(process.terminationStatus) stdout=\(stdout.prefix(200)) stderr=\(stderr.prefix(200))")

        // Map well-known error strings regardless of exit code, because some
        // bdpan versions exit 0 even when authentication has failed.
        let combined = stdout + stderr
        if combined.contains("Token expired")
            || combined.contains("获取 Token 失败")
            || combined.contains("请先执行 bdpan login")
            || combined.contains("请先执行 login") {
            throw BdpanError.tokenExpired
        }
        if combined.contains("File not found")
            || combined.contains("路径不存在")
            || combined.contains("文件不存在") {
            throw BdpanError.pathNotFound
        }
        if combined.contains("Path not allowed")
            || combined.contains("路径超出授权目录范围") {
            throw BdpanError.pathNotAllowed
        }

        guard process.terminationStatus == 0 else {
            // Prefer stderr for the error message; fall back to stdout if empty.
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BdpanError.processFailure(
                exitCode: process.terminationStatus,
                stderr: message.isEmpty ? fallback : message
            )
        }

        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
