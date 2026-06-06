# BdpanFinder — Architecture Document

## Overview

BdpanFinder is a macOS File Provider extension that mounts Baidu Pan (via the `bdpan` CLI) as a native Finder location. Files appear in Finder's sidebar under a "Baidu Pan" domain. The host app registers the domain; the extension handles all enumeration, download, upload, rename, move, and delete operations by shelling out to `bdpan`.

**Target macOS:** 12.0+  
**Language:** Swift 5.9  
**Framework:** FileProvider.framework (NSFileProviderReplicatedExtension)  
**Build system:** XcodeGen 2.x

---

## Bundle Identifiers

| Target | Bundle ID |
|--------|-----------|
| Host app | `com.wangjianshuo.BdpanFinder` |
| Extension | `com.wangjianshuo.BdpanFinder.Extension` |
| App Group | `group.com.wangjianshuo.BdpanFinder` |

The App Group identifier must appear verbatim in:
- Both targets' `com.apple.security.application-groups` entitlement
- Extension `Info.plist` key `NSExtensionFileProviderDocumentGroup`

---

## Project Directory Structure

```
/Users/jianshuo/code/bdpan-finder/
├── project.yml                          # XcodeGen config
├── BdpanFinder/                         # Host application
│   ├── AppDelegate.swift                # Domain registration / lifecycle
│   ├── MainWindowController.swift       # Minimal UI (status / re-auth button)
│   ├── BdpanFinder.entitlements
│   └── Info.plist
└── BdpanFinderExt/                      # File Provider Extension
    ├── Extension.swift                  # NSFileProviderReplicatedExtension impl
    ├── Item.swift                       # NSFileProviderItem impl
    ├── Enumerator.swift                 # NSFileProviderEnumerator impl
    ├── BdpanClient.swift                # bdpan CLI wrapper (Process())
    ├── Model.swift                      # Codable structs for bdpan JSON
    ├── BdpanFinderExt.entitlements
    └── Info.plist
```

---

## Sandbox Strategy

This is a personal developer tool distributed outside the App Store. The extension's sandbox is **disabled** (`com.apple.security.app-sandbox = false`) so that it can:

1. Call `bdpan` via `Process()` from any path on disk.
2. Read `~/.config/bdpan/config.json` directly for token validation.
3. Write downloaded files to `NSFileProviderManager`-provided temp directories without restriction.

The host app also has sandbox disabled to avoid XPC handshake complexity.

**Security note:** Never enable sandbox on the extension without also adding a full XPC-service bridge to the host app and bundling `bdpan` inside the app bundle.

---

## Root Path Mapping

| macOS FileProvider concept | bdpan path |
|---------------------------|------------|
| `.rootContainer` | `/apps/bdpan/` |
| Any `NSFileProviderItemIdentifier` | stored as the full `/apps/bdpan/...` path string |

`NSFileProviderItemIdentifier` values are constructed directly from the `path` field returned by `bdpan ls --json`. This is stable as long as the file is not moved. The `fs_id` field (int64) is stored as `versionIdentifier` for conflict detection.

User-facing display strips the `/apps/bdpan/` prefix. The Finder sidebar shows the domain's `displayName` ("Baidu Pan"), not the path.

---

## Authentication

`bdpan` stores its OAuth token at `~/.config/bdpan/config.json`. With sandbox disabled, the extension reads this file directly on startup to check whether the token is present. No OAuth flow is implemented in BdpanFinder — the user must authenticate separately using `bdpan login` in Terminal before launching the app. `AppDelegate` can surface a warning window if the config file is absent or the token appears expired (detected by a failed `bdpan ls /` call returning "Token expired" on stderr).

---

## bdpan JSON Model (`Model.swift`)

Exact Swift structs matching `bdpan ls --json` output:

```swift
import Foundation

// Top-level response is a JSON array: [BdpanEntry]
struct BdpanEntry: Codable {
    let fsId: Int64          // "fs_id"      — unique file ID (stable identifier)
    let path: String         // "path"       — full absolute path, e.g. "/apps/bdpan/foo/bar.mp4"
    let serverFilename: String  // "server_filename" — leaf name only, e.g. "bar.mp4"
    let size: Int64          // "size"       — bytes; 0 for directories
    let isdir: Bool          // "isdir"      — true for directories
    let md5: String          // "md5"        — MD5 hash; "" for directories
    let serverMtime: String  // "server_mtime" — ISO 8601, e.g. "2026-06-05T22:32:12+08:00"
    let serverCtime: String  // "server_ctime" — ISO 8601, e.g. "2026-03-03T06:13:59+08:00"

    enum CodingKeys: String, CodingKey {
        case fsId = "fs_id"
        case path
        case serverFilename = "server_filename"
        case size
        case isdir
        case md5
        case serverMtime = "server_mtime"
        case serverCtime = "server_ctime"
    }

    // Parsed dates (computed, not stored in JSON)
    var modificationDate: Date? {
        ISO8601DateFormatter().date(from: serverMtime)
    }
    var creationDate: Date? {
        ISO8601DateFormatter().date(from: serverCtime)
    }
}
```

Decode with:
```swift
let entries = try JSONDecoder().decode([BdpanEntry].self, from: data)
```

---

## BdpanClient (`BdpanClient.swift`)

Wraps every `bdpan` CLI call. All methods are async, throwing, and run on a background executor.

```swift
import Foundation

enum BdpanError: Error {
    case tokenExpired
    case pathNotFound
    case pathNotAllowed
    case processFailure(exitCode: Int32, stderr: String)
}

actor BdpanClient {
    // Path to bdpan binary. Defaults to /usr/local/bin/bdpan.
    // Override in unit tests by setting this to a stub.
    var bdpanPath: String = "/usr/local/bin/bdpan"

    // MARK: — List directory
    // remotePath: full /apps/bdpan/... path OR relative path
    func list(remotePath: String) async throws -> [BdpanEntry] {
        let output = try await run(["ls", "--json", remotePath])
        return try JSONDecoder().decode([BdpanEntry].self, from: Data(output.utf8))
    }

    // MARK: — Download a single file
    // remotePath: full absolute path (/apps/bdpan/...)
    // localURL:   destination file URL (will be created by bdpan)
    func download(remotePath: String, to localURL: URL) async throws {
        _ = try await run(["download", remotePath, localURL.path])
    }

    // MARK: — Upload a single file
    // localURL:   source file
    // remotePath: destination path under /apps/bdpan/ (no trailing slash for file)
    func upload(localURL: URL, to remotePath: String) async throws {
        _ = try await run(["upload", localURL.path, remotePath])
    }

    // MARK: — Create directory (multi-level)
    func mkdir(_ remotePath: String) async throws {
        _ = try await run(["mkdir", remotePath])
    }

    // MARK: — Delete (single path, force)
    func delete(remotePath: String) async throws {
        _ = try await run(["rm", "-f", remotePath])
    }

    // MARK: — Private runner
    private func run(_ args: [String]) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bdpanPath)
            process.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { p in
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""

                if stderr.contains("Token expired") {
                    continuation.resume(throwing: BdpanError.tokenExpired)
                } else if stderr.contains("File not found") {
                    continuation.resume(throwing: BdpanError.pathNotFound)
                } else if stderr.contains("Path not allowed") {
                    continuation.resume(throwing: BdpanError.pathNotAllowed)
                } else if p.terminationStatus != 0 {
                    continuation.resume(throwing: BdpanError.processFailure(
                        exitCode: p.terminationStatus, stderr: stderr))
                } else {
                    continuation.resume(returning: stdout)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
```

---

## NSFileProviderItem (`Item.swift`)

```swift
import FileProvider
import UniformTypeIdentifiers

final class BdpanItem: NSObject, NSFileProviderItem {

    // MARK: — Storage
    private let entry: BdpanEntry

    init(entry: BdpanEntry) {
        self.entry = entry
    }

    // MARK: — REQUIRED

    var itemIdentifier: NSFileProviderItemIdentifier {
        // Use full path as stable identifier.
        // Root container is special-cased in the enumerator.
        NSFileProviderItemIdentifier(entry.path)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        let parent = (entry.path as NSString).deletingLastPathComponent
        if parent == "/apps/bdpan" || parent == "/apps/bdpan/" {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(parent)
    }

    var filename: String {
        entry.serverFilename
    }

    var contentType: UTType {
        if entry.isdir {
            return .folder
        }
        // Derive from extension; fall back to .data
        let ext = (entry.serverFilename as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    // MARK: — STRONGLY RECOMMENDED

    var documentSize: NSNumber? {
        entry.isdir ? nil : NSNumber(value: entry.size)
    }

    var childItemCount: NSNumber? {
        // Unknown until enumerated; return nil. System will enumerate on demand.
        entry.isdir ? nil : nil
    }

    var contentModificationDate: Date? { entry.modificationDate }
    var creationDate: Date? { entry.creationDate }

    // MARK: — VERSION TRACKING
    // Encode fs_id as little-endian 8 bytes. Used for conflict detection.
    var versionIdentifier: Data? {
        withUnsafeBytes(of: entry.fsId.littleEndian) { Data($0) }
    }

    // MARK: — CAPABILITIES

    var capabilities: NSFileProviderItemCapabilities {
        if entry.isdir {
            return [.allowsAddingSubItems, .allowsContentEnumerating,
                    .allowsReading, .allowsDeleting, .allowsRenaming, .allowsReparenting]
        }
        return [.allowsReading, .allowsWriting, .allowsDeleting,
                .allowsRenaming, .allowsReparenting, .allowsTrashing]
    }

    // MARK: — TRANSFER STATUS (Finder progress indicators)
    var isDownloaded: Bool = true
    var isDownloading: Bool = false
    var downloadingError: Error? = nil
    var isUploaded: Bool = true
    var isUploading: Bool = false
    var uploadingError: Error? = nil
    var isMostRecentVersionDownloaded: Bool = true
}

// MARK: — Root container sentinel item
// Returned by item(for: .rootContainer)
final class RootItem: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "Baidu Pan" }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities {
        [.allowsAddingSubItems, .allowsContentEnumerating, .allowsReading]
    }
}
```

---

## NSFileProviderEnumerator (`Enumerator.swift`)

One enumerator class handles root, working set, and arbitrary folder identifiers.

```swift
import FileProvider

final class BdpanEnumerator: NSObject, NSFileProviderEnumerator {

    private let identifier: NSFileProviderItemIdentifier
    private let client: BdpanClient

    init(identifier: NSFileProviderItemIdentifier, client: BdpanClient) {
        self.identifier = identifier
        self.client = client
    }

    func invalidate() {}

    // MARK: — Full enumeration (called by system on first load and after signalEnumerator)

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        // BdpanFinder does not paginate — bdpan returns all entries in one call.
        // Always treat every page request as "start from beginning".

        Task {
            do {
                let remotePath = remotePathForIdentifier(identifier)
                let entries = try await client.list(remotePath: remotePath)
                let items = entries.map { BdpanItem(entry: $0) }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch BdpanError.pathNotFound {
                observer.finishEnumeratingWithError(
                    NSFileProviderError(.noSuchItem))
            } catch BdpanError.tokenExpired {
                observer.finishEnumeratingWithError(
                    NSFileProviderError(.serverUnreachable))
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    // MARK: — Change enumeration (working set only)
    // BdpanFinder uses a simple strategy: re-enumerate everything and let the
    // system diff. A real anchor-based approach would require bdpan server-side
    // cursor support, which bdpan CLI does not expose.

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        Task {
            do {
                let remotePath = remotePathForIdentifier(identifier)
                let entries = try await client.list(remotePath: remotePath)
                let items: [NSFileProviderItem] = entries.map { BdpanItem(entry: $0) }
                observer.didUpdate(items)
                // No deletions tracked in this simple implementation.
                let newAnchor = NSFileProviderSyncAnchor(
                    String(Date().timeIntervalSince1970).data(using: .utf8)!)
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        // Use current timestamp as anchor — triggers full re-sync on next check.
        let data = String(Date().timeIntervalSince1970).data(using: .utf8)!
        completionHandler(NSFileProviderSyncAnchor(data))
    }

    // MARK: — Helpers

    private func remotePathForIdentifier(
        _ id: NSFileProviderItemIdentifier
    ) -> String {
        switch id {
        case .rootContainer, .workingSetContainer:
            return "/apps/bdpan/"
        default:
            return id.rawValue  // raw value IS the full /apps/bdpan/... path
        }
    }
}
```

---

## NSFileProviderReplicatedExtension (`Extension.swift`)

```swift
import FileProvider
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    let domain: NSFileProviderDomain
    private let client = BdpanClient()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    // MARK: — Item lookup

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        if identifier == .rootContainer {
            completionHandler(RootItem(), nil)
            progress.completedUnitCount = 1
            return progress
        }

        Task {
            do {
                // The identifier IS the full path. List parent directory and
                // find the matching entry.
                let path = identifier.rawValue
                let parent = (path as NSString).deletingLastPathComponent
                let entries = try await client.list(remotePath: parent)
                if let entry = entries.first(where: { $0.path == path }) {
                    completionHandler(BdpanItem(entry: entry), nil)
                } else {
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                }
            } catch {
                completionHandler(nil, mapError(error))
            }
            progress.completedUnitCount = 1
        }

        return progress
    }

    // MARK: — Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        return BdpanEnumerator(identifier: containerItemIdentifier, client: client)
    }

    // MARK: — Content download

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let remotePath = itemIdentifier.rawValue

                // Create a temp file URL. The system takes ownership after we
                // pass it to completionHandler — do NOT delete it.
                let tempDir = FileManager.default.temporaryDirectory
                let tempURL = tempDir.appendingPathComponent(UUID().uuidString)

                try await client.download(remotePath: remotePath, to: tempURL)
                progress.completedUnitCount = 100

                // Fetch updated metadata for the item
                let parent = (remotePath as NSString).deletingLastPathComponent
                let entries = try await client.list(remotePath: parent)
                let updatedItem = entries.first(where: { $0.path == remotePath })
                    .map { BdpanItem(entry: $0) }

                completionHandler(tempURL, updatedItem, nil)
            } catch {
                completionHandler(nil, nil, mapError(error))
            }
        }

        return progress
    }

    // MARK: — Create item (upload new file or create directory)

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let parentPath: String
                if itemTemplate.parentItemIdentifier == .rootContainer {
                    parentPath = "/apps/bdpan"
                } else {
                    parentPath = itemTemplate.parentItemIdentifier.rawValue
                }
                let remotePath = parentPath + "/" + itemTemplate.filename

                if itemTemplate.contentType == .folder {
                    try await client.mkdir(remotePath)
                    // Return a synthetic item; real metadata fetched on next enumeration.
                    let syntheticEntry = BdpanEntry(
                        fsId: 0,
                        path: remotePath,
                        serverFilename: itemTemplate.filename,
                        size: 0,
                        isdir: true,
                        md5: "",
                        serverMtime: ISO8601DateFormatter().string(from: Date()),
                        serverCtime: ISO8601DateFormatter().string(from: Date())
                    )
                    completionHandler(BdpanItem(entry: syntheticEntry), [], false, nil)
                } else if let localURL = url {
                    try await client.upload(localURL: localURL, to: remotePath)
                    // Re-fetch metadata from server to get real fs_id and mtime.
                    let parent = (remotePath as NSString).deletingLastPathComponent
                    let entries = try await client.list(remotePath: parent)
                    if let entry = entries.first(where: { $0.path == remotePath }) {
                        completionHandler(BdpanItem(entry: entry), [], false, nil)
                    } else {
                        // Item not found after upload — unusual; return nil and let system retry.
                        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    }
                } else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                }
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, [], false, mapError(error))
            }
        }

        return progress
    }

    // MARK: — Modify item (rename, move, re-upload)
    // changedFields bitmask tells us what changed.
    // This implementation handles: .filename (rename), .parentItemIdentifier (move),
    // .contents (re-upload). Combinations are handled sequentially.

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        // NOTE: bdpan CLI does not expose a rename/move command. Strategy:
        // For rename/move: download to temp, upload to new path, delete old.
        // For content change: re-upload to same path.
        // This is inefficient for large files. A future version could use the
        // Baidu PCS REST API directly for server-side move.

        Task {
            do {
                let oldPath = item.itemIdentifier.rawValue

                if changedFields.contains(.contents), let newContents = newContents {
                    try await client.upload(localURL: newContents, to: oldPath)
                }

                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let newParent: String
                    if item.parentItemIdentifier == .rootContainer {
                        newParent = "/apps/bdpan"
                    } else {
                        newParent = item.parentItemIdentifier.rawValue
                    }
                    let newPath = newParent + "/" + item.filename

                    // Download old, upload to new path, delete old
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    try await client.download(remotePath: oldPath, to: tempURL)
                    try await client.upload(localURL: tempURL, to: newPath)
                    try await client.delete(remotePath: oldPath)
                    try? FileManager.default.removeItem(at: tempURL)
                }

                progress.completedUnitCount = 100
                // Re-fetch updated item
                let currentPath: String
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let newParent = item.parentItemIdentifier == .rootContainer
                        ? "/apps/bdpan"
                        : item.parentItemIdentifier.rawValue
                    currentPath = newParent + "/" + item.filename
                } else {
                    currentPath = oldPath
                }

                let parent = (currentPath as NSString).deletingLastPathComponent
                let entries = try await client.list(remotePath: parent)
                if let entry = entries.first(where: { $0.path == currentPath }) {
                    completionHandler(BdpanItem(entry: entry), [], false, nil)
                } else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                }
            } catch {
                completionHandler(nil, [], false, mapError(error))
            }
        }

        return progress
    }

    // MARK: — Delete item

    func deleteItem(
        identifier itemIdentifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                try await client.delete(remotePath: itemIdentifier.rawValue)
                completionHandler(nil)
            } catch BdpanError.pathNotFound {
                // Already gone — treat as success
                completionHandler(nil)
            } catch {
                completionHandler(mapError(error))
            }
            progress.completedUnitCount = 1
        }

        return progress
    }

    // MARK: — Error mapping

    private func mapError(_ error: Error) -> Error {
        switch error {
        case BdpanError.pathNotFound:
            return NSFileProviderError(.noSuchItem)
        case BdpanError.tokenExpired:
            return NSFileProviderError(.serverUnreachable)
        default:
            return error
        }
    }
}
```

---

## Host App Domain Registration (`AppDelegate.swift`)

```swift
import AppKit
import FileProvider

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    static let domainIdentifier = NSFileProviderDomainIdentifier(
        rawValue: "com.wangjianshuo.BdpanFinder.domain")

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerDomain()
    }

    private func registerDomain() {
        let domain = NSFileProviderDomain(
            identifier: AppDelegate.domainIdentifier,
            displayName: "Baidu Pan"
        )

        NSFileProviderManager.add(domain) { error in
            if let error = error as NSError?,
               error.domain == NSCocoaErrorDomain,
               error.code == NSFileWriteFileExistsError {
                // Domain already registered — normal on relaunch
                return
            }
            if let error = error {
                NSLog("BdpanFinder: failed to add domain: \(error)")
            }
        }
    }

    // Call this to force a sync refresh (e.g. from a "Refresh" menu item)
    func signalWorkingSet() {
        let domain = NSFileProviderDomain(
            identifier: AppDelegate.domainIdentifier,
            displayName: "Baidu Pan"
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        // Always use workingSetContainerItemIdentifier — folder-level signaling
        // silently fails on macOS.
        manager.signalEnumerator(for: .workingSetContainerItemIdentifier) { error in
            if let error = error {
                NSLog("BdpanFinder: signalEnumerator error: \(error)")
            }
        }
    }
}
```

---

## `project.yml` (XcodeGen)

```yaml
name: BdpanFinder
options:
  deploymentTarget:
    macOS: "12.0"
  bundleIdPrefix: com.wangjianshuo

settings:
  SWIFT_VERSION: "5.9"
  MACOSX_DEPLOYMENT_TARGET: "12.0"

targets:

  # ── Host Application ──────────────────────────────────────────────────────
  BdpanFinder:
    type: application
    platform: macOS
    deploymentTarget: "12.0"
    sources:
      - path: BdpanFinder
    entitlements:
      path: BdpanFinder/BdpanFinder.entitlements
      properties:
        com.apple.security.app-sandbox: false
        com.apple.security.application-groups:
          - group.com.wangjianshuo.BdpanFinder
        com.apple.security.network.client: true
    info:
      path: BdpanFinder/Info.plist
      properties:
        CFBundleDisplayName: BdpanFinder
        CFBundleName: BdpanFinder
        NSHumanReadableCopyright: ""
        LSMinimumSystemVersion: "12.0"
        NSPrincipalClass: NSApplication
        NSApplicationActivationPolicy: accessory   # no Dock icon; lives in menu bar
    dependencies:
      - target: BdpanFinderExt
        embed: true
        codeSign: true
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.wangjianshuo.BdpanFinder
      ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon

  # ── File Provider Extension ───────────────────────────────────────────────
  BdpanFinderExt:
    type: app-extension
    platform: macOS
    deploymentTarget: "12.0"
    sources:
      - path: BdpanFinderExt
    entitlements:
      path: BdpanFinderExt/BdpanFinderExt.entitlements
      properties:
        com.apple.security.app-sandbox: false
        com.apple.security.application-groups:
          - group.com.wangjianshuo.BdpanFinder
        com.apple.security.network.client: true
    info:
      path: BdpanFinderExt/Info.plist
      properties:
        CFBundleDisplayName: BdpanFinderExt
        NSExtension:
          NSExtensionPointIdentifier: com.apple.fileprovider-nonui
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).FileProviderExtension
          NSExtensionFileProviderDocumentGroup: group.com.wangjianshuo.BdpanFinder
          NSExtensionFileProviderSupportsEnumeration: true
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.wangjianshuo.BdpanFinder.Extension
      LD_RUNPATH_SEARCH_PATHS:
        - $(inherited)
        - "@executable_path/Frameworks"
        - "@executable_path/../../Frameworks"
```

---

## Info.plist — Host App (`BdpanFinder/Info.plist`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>BdpanFinder</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHumanReadableCopyright</key>
    <string></string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <!-- Run as agent (no Dock icon). Change to 0 if you want a full app. -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

---

## Info.plist — Extension (`BdpanFinderExt/Info.plist`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>BdpanFinderExt</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.fileprovider-nonui</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$(PRODUCT_MODULE_NAME).FileProviderExtension</string>
        <key>NSExtensionFileProviderDocumentGroup</key>
        <string>group.com.wangjianshuo.BdpanFinder</string>
        <key>NSExtensionFileProviderSupportsEnumeration</key>
        <true/>
    </dict>
</dict>
</plist>
```

---

## Entitlements — Host App (`BdpanFinder/BdpanFinder.entitlements`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Sandbox OFF: personal dev tool, not App Store -->
    <key>com.apple.security.app-sandbox</key>
    <false/>

    <!-- App Group for shared container with extension -->
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.wangjianshuo.BdpanFinder</string>
    </array>

    <!-- Network access for future direct API calls -->
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

---

## Entitlements — Extension (`BdpanFinderExt/BdpanFinderExt.entitlements`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Sandbox OFF: required to call bdpan via Process() and read ~/.config/bdpan/ -->
    <key>com.apple.security.app-sandbox</key>
    <false/>

    <!-- Must match NSExtensionFileProviderDocumentGroup exactly -->
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.wangjianshuo.BdpanFinder</string>
    </array>

    <!-- Network access -->
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

---

## Implementation Order (Recommended)

Follow WWDC21-10182 sequence, stopping after each step to verify in Finder:

1. **Scaffold** — create project with XcodeGen, add domain registration in `AppDelegate`. Verify "Baidu Pan" appears in Finder sidebar (may show spinner).

2. **Enumerate root** — implement `enumerator(for: .rootContainer)` + `BdpanEnumerator.enumerateItems` calling `bdpan ls /apps/bdpan/`. Verify top-level folders appear.

3. **Item lookup** — implement `item(for:request:completionHandler:)`. Required before Finder can show item details or open files.

4. **Download** — implement `fetchContents`. Verify double-clicking a file opens it.

5. **Create / upload** — implement `createItem`. Verify dragging a file into the Finder location uploads it.

6. **Modify / delete** — implement `modifyItem` and `deleteItem`.

7. **Working set changes** — implement `enumerateChanges` + `currentSyncAnchor` in `BdpanEnumerator`. Call `signalWorkingSet()` from app to trigger incremental refresh.

---

## Known Limitations and Future Work

| Limitation | Cause | Workaround / Future Fix |
|------------|-------|------------------------|
| Rename/move is download+reupload | `bdpan` CLI has no move command | Use Baidu PCS REST API (`/rest/2.0/xpan/file?method=filemanager`) directly via URLSession |
| No conflict detection | `bdpan` does not expose server-side ETag in CLI JSON | Parse `md5` field and compare; or use REST API |
| Full re-enumeration on every sync | bdpan CLI has no server-side change cursor | Use Baidu PCS `diff` API endpoint for delta sync |
| Progress reporting is binary (0/100) | `bdpan download` does not emit byte counts | Pipe stderr and parse progress output if bdpan prints it; otherwise accept |
| Token expiry not surfaced in Finder UI | Extension returns `.serverUnreachable`; Finder shows generic error | Add a NSUserNotification or menu-bar alert in host app |
| Extension binary location hardcoded | `/usr/local/bin/bdpan` | Read from `~/.config/bdpan/` or a preference file; allow override |
