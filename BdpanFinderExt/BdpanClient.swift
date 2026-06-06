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

    /// Path to the bdpan binary.
    /// Override in unit tests by pointing to a stub executable.
    var bdpanPath: String = "/Users/jianshuo/.local/bin/bdpan"

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

    /// Download a single remote file into a local directory.
    ///
    /// Runs: `bdpan download <remotePath> <localURL.path>`
    ///
    /// bdpan places the downloaded file inside `localURL` using the remote
    /// file's basename, so the result appears at `localURL/<basename>`.
    ///
    /// - Parameters:
    ///   - remotePath: Full absolute remote path, e.g. `/apps/bdpan/我的/video.mp4`.
    ///   - localURL: Destination **directory** URL. Must exist before calling.
    /// - Throws: `BdpanError` on CLI failure.
    func downloadFile(from remotePath: String, to localURL: URL) throws {
        _ = try runBdpan(["download", remotePath, localURL.path])
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
    ///
    /// Runs: `bdpan mkdir <remotePath>`
    ///
    /// bdpan supports multi-level creation in a single call, so calling
    /// `createDirectory(at: "a/b/c")` is equivalent to `mkdir -p a/b/c`.
    ///
    /// - Parameter remotePath: Path relative to `/apps/bdpan/`, e.g. `backup/2026/06`.
    /// - Throws: `BdpanError` on CLI failure.
    func createDirectory(at remotePath: String) throws {
        _ = try runBdpan(["mkdir", remotePath])
    }

    /// Delete a file or directory on Baidu Pan.
    ///
    /// Runs: `bdpan rm -f <remotePath>`
    ///
    /// The `-f` / `--force` flag skips the interactive confirmation prompt.
    ///
    /// - Parameter remotePath: Path relative to `/apps/bdpan/`, e.g. `我的视频/old.mp4`.
    /// - Throws: `BdpanError` on CLI failure. Callers that treat deletion of a
    ///   non-existent item as a no-op should catch `.pathNotFound` and ignore it.
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
        guard FileManager.default.isExecutableFile(atPath: bdpanPath) else {
            throw BdpanError.binaryNotFound(path: bdpanPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bdpanPath)
        process.arguments = arguments

        // Propagate the user environment so bdpan can reach its OAuth config at
        // ~/.config/bdpan/config.json. In a sandboxed extension NSHomeDirectory()
        // returns the container path, so use getpwuid to get the real home.
        var env = ProcessInfo.processInfo.environment
        let realHome: String
        if let pwd = Darwin.getpwuid(Darwin.getuid()) {
            realHome = String(cString: pwd.pointee.pw_dir)
        } else {
            realHome = env["HOME"] ?? NSHomeDirectory()
        }
        env["HOME"] = realHome
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        func dblog(_ msg: String) {
            let line = "BdpanClient[\(arguments.first ?? "?")]: \(msg)\n"
            if let d = line.data(using: .utf8) {
                let url = URL(fileURLWithPath: "/tmp/bdpan-ext-debug.log")
                if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
            }
        }
        dblog("launching \(bdpanPath) \(arguments.joined(separator: " "))")
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
        if combined.contains("Token expired") {
            throw BdpanError.tokenExpired
        }
        if combined.contains("File not found") {
            throw BdpanError.pathNotFound
        }
        if combined.contains("Path not allowed") {
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
