import Cocoa

/// Setup / login helpers for the host app.
///
/// The host app is NOT sandboxed, so it can run the bundled `bdpan` binary and
/// write its login config into the File Provider extension's data container —
/// the one place the sandboxed extension can later read it from. This is what
/// lets the whole thing ship as a single notarized app with no separate bdpan
/// install and no App-Group provisioning.
enum BdpanSetup {

    static let extensionBundleIdentifier = "com.wangjianshuo.BdpanFinder.Extension"

    static func realHome() -> String {
        if let pwd = getpwuid(getuid()) { return String(cString: pwd.pointee.pw_dir) }
        return NSHomeDirectory()
    }

    /// The File Provider extension's data container (shared, sandbox-reachable).
    static func containerDir() -> String {
        realHome() + "/Library/Containers/\(extensionBundleIdentifier)/Data"
    }
    static func configDir() -> String { containerDir() + "/bdpan" }
    static func configPath() -> String { configDir() + "/config.json" }

    /// Path to the `bdpan` executable bundled in this app.
    static func bundledBdpanPath() -> String? {
        Bundle.main.url(forResource: "bdpan", withExtension: nil)?.path
    }

    /// Run bundled bdpan pinned to the shared config path. Returns exit code, stdout, stderr.
    @discardableResult
    static func runBdpan(_ args: [String]) -> (code: Int32, out: String, err: String) {
        guard let bin = bundledBdpanPath() else { return (-1, "", "bdpan 未打包进 app") }
        try? FileManager.default.createDirectory(
            atPath: configDir(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--config-path", configPath()] + args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = containerDir()
        p.environment = env
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (-1, "", "\(error.localizedDescription)") }
        let od = out.fileHandleForReading.readDataToEndOfFile()
        let ed = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: od, encoding: .utf8) ?? "",
                String(data: ed, encoding: .utf8) ?? "")
    }

    static func isLoggedIn() -> Bool {
        let r = runBdpan(["whoami", "--json"])
        guard r.code == 0, let d = r.out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return (j["authenticated"] as? Bool) == true && (j["has_valid_token"] as? Bool) == true
    }

    static func loggedInUsername() -> String? {
        let r = runBdpan(["whoami", "--json"])
        guard r.code == 0, let d = r.out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["username"] as? String
    }

    /// Fetch the Baidu OAuth authorization URL (out-of-band: page shows a code).
    static func authURL() -> String? {
        let r = runBdpan(["login", "--get-auth-url", "--accept-disclaimer", "--json"])
        guard r.code == 0, let d = r.out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let data = j["data"] as? [String: Any] else { return nil }
        return data["auth_url"] as? String
    }

    /// Complete login with the authorization code pasted by the user.
    static func submitCode(_ code: String) -> (ok: Bool, message: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = runBdpan(["login", "--set-code", trimmed, "--accept-disclaimer"])
        if r.code == 0 { return (true, "") }
        let msg = r.err.isEmpty ? r.out : r.err
        return (false, msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
