import FileProvider
import UniformTypeIdentifiers

// NSExtensionPrincipalClass in Info.plist = $(PRODUCT_MODULE_NAME).FileProviderExtension
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    // MARK: - Properties

    let domain: NSFileProviderDomain
    let client: BdpanClient

    /// Returns a fresh NSFileProviderManager for the domain each time.
    var manager: NSFileProviderManager? {
        NSFileProviderManager(for: domain)
    }

    // MARK: - Lifecycle

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.client = BdpanClient()
        super.init()
        let msg = "BdpanFinderExt init at \(Date()) domain=\(domain.identifier.rawValue)\n"
        if let data = msg.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/bdpan-ext-debug.log")
            if FileManager.default.fileExists(atPath: url.path) {
                if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(data); try? fh.close() }
            } else {
                try? data.write(to: url)
            }
        }
    }

    func invalidate() {}

    // MARK: - Item Lookup

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: 1)

        if identifier == .rootContainer {
            completionHandler(BdpanProviderItem.rootContainer(), nil)
            progress.completedUnitCount = 1
            return progress
        }

        DispatchQueue.global(qos: .userInitiated).async { [client] in
            defer { progress.completedUnitCount = 1 }
            let path = identifier.rawValue
            let parent = (path as NSString).deletingLastPathComponent
            do {
                let entries = try client.listFiles(at: parent)
                if let entry = entries.first(where: { $0.path == path }) {
                    completionHandler(BdpanProviderItem(fileInfo: entry), nil)
                } else {
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                }
            } catch {
                completionHandler(nil, FileProviderExtension.mapError(error))
            }
        }

        return progress
    }

    // MARK: - Content Fetch (Download)

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: 1)

        DispatchQueue.global(qos: .userInitiated).async { [client] in
            defer { progress.completedUnitCount = 1 }

            let remotePath = itemIdentifier.rawValue
            let basename = (remotePath as NSString).lastPathComponent

            // bdpan download requires the full destination file path (not a directory).
            // Create a unique temp directory, then pass dir/basename as the destination.
            let tempDirURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fileURL = tempDirURL.appendingPathComponent(basename)

            do {
                try FileManager.default.createDirectory(
                    at: tempDirURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try client.downloadFile(from: remotePath, to: fileURL)

                // Re-fetch metadata to hand back an updated item (best-effort).
                let parentPath = (remotePath as NSString).deletingLastPathComponent
                let updatedItem = (try? client.listFiles(at: parentPath))?
                    .first(where: { $0.path == remotePath })
                    .map { BdpanProviderItem(fileInfo: $0) }

                completionHandler(fileURL, updatedItem, nil)
            } catch {
                completionHandler(nil, nil, FileProviderExtension.mapError(error))
            }
        }

        return progress
    }

    // MARK: - Create Item (upload file or mkdir)

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
        let progress = Progress.discreteProgress(totalUnitCount: 1)

        DispatchQueue.global(qos: .userInitiated).async { [client] in
            defer { progress.completedUnitCount = 1 }

            let parentPath: String
            if itemTemplate.parentItemIdentifier == .rootContainer {
                parentPath = "/apps/bdpan"
            } else {
                parentPath = itemTemplate.parentItemIdentifier.rawValue
            }
            let remotePath = parentPath + "/" + itemTemplate.filename

            do {
                if let localURL = url {
                    // File upload.
                    try client.uploadFile(from: localURL, to: remotePath)
                    // Re-fetch from server to obtain real fs_id and server mtime.
                    let entries = try client.listFiles(at: parentPath)
                    if let entry = entries.first(where: { $0.path == remotePath }) {
                        completionHandler(BdpanProviderItem(fileInfo: entry), [], false, nil)
                    } else {
                        // Upload succeeded but item not visible yet; let the system retry.
                        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    }
                } else {
                    // Directory creation — check server first to avoid creating
                    // directories for items that already exist (files or dirs).
                    // This guards against the File Provider system replaying
                    // stale "pending create" operations from a corrupted local DB.
                    let siblings = try? client.listFiles(at: parentPath)
                    if let existing = siblings?.first(where: { $0.path == remotePath }) {
                        completionHandler(BdpanProviderItem(fileInfo: existing), [], false, nil)
                        return
                    }
                    try client.createDirectory(at: remotePath)
                    let isoNow = ISO8601DateFormatter().string(from: Date())
                    let syntheticEntry = BdpanFileInfo(
                        fsId: 0,
                        path: remotePath,
                        serverFilename: itemTemplate.filename,
                        size: 0,
                        isdir: true,
                        md5: "",
                        serverMtime: isoNow,
                        serverCtime: isoNow
                    )
                    completionHandler(BdpanProviderItem(fileInfo: syntheticEntry), [], false, nil)
                }
            } catch {
                completionHandler(nil, [], false, FileProviderExtension.mapError(error))
            }
        }

        return progress
    }

    // MARK: - Modify Item (rename / move / re-upload)

    // bdpan CLI has no server-side move command, so rename/move is implemented as
    // download-then-upload-then-delete. Content-only changes re-upload in place.

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
        let progress = Progress.discreteProgress(totalUnitCount: 1)

        DispatchQueue.global(qos: .userInitiated).async { [client] in
            defer { progress.completedUnitCount = 1 }

            let oldPath = item.itemIdentifier.rawValue

            do {
                // Re-upload content if the file body changed.
                if changedFields.contains(.contents), let newContents = newContents {
                    try client.uploadFile(from: newContents, to: oldPath)
                }

                // Rename or reparent: download old → upload to new path → delete old.
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let newParent: String
                    if item.parentItemIdentifier == .rootContainer {
                        newParent = "/apps/bdpan"
                    } else {
                        newParent = item.parentItemIdentifier.rawValue
                    }
                    let newPath = newParent + "/" + item.filename
                    let basename = (oldPath as NSString).lastPathComponent

                    let tempDirURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: tempDirURL,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try client.downloadFile(from: oldPath, to: tempDirURL)
                    let tempFileURL = tempDirURL.appendingPathComponent(basename)
                    try client.uploadFile(from: tempFileURL, to: newPath)
                    try client.deleteItem(at: oldPath)
                    try? FileManager.default.removeItem(at: tempDirURL)
                }

                // Determine the post-modification path to re-fetch fresh metadata.
                let currentPath: String
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let newParent = item.parentItemIdentifier == .rootContainer
                        ? "/apps/bdpan"
                        : item.parentItemIdentifier.rawValue
                    currentPath = newParent + "/" + item.filename
                } else {
                    currentPath = oldPath
                }

                let parentPath = (currentPath as NSString).deletingLastPathComponent
                let entries = try client.listFiles(at: parentPath)
                if let entry = entries.first(where: { $0.path == currentPath }) {
                    completionHandler(BdpanProviderItem(fileInfo: entry), [], false, nil)
                } else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                }
            } catch {
                completionHandler(nil, [], false, FileProviderExtension.mapError(error))
            }
        }

        return progress
    }

    // MARK: - Delete Item

    func deleteItem(
        identifier itemIdentifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress.discreteProgress(totalUnitCount: 1)

        let path = itemIdentifier.rawValue
        DispatchQueue.global(qos: .userInitiated).async { [client] in
            defer { progress.completedUnitCount = 1 }
            NSLog("BdpanFinderExt: deleteItem \(path)")
            do {
                try client.deleteItem(at: path)
                NSLog("BdpanFinderExt: deleteItem success \(path)")
                completionHandler(nil)
            } catch BdpanError.pathNotFound {
                // Item already gone on the server — treat as success.
                NSLog("BdpanFinderExt: deleteItem pathNotFound (treated as success) \(path)")
                completionHandler(nil)
            } catch {
                NSLog("BdpanFinderExt: deleteItem error \(path): \(error)")
                completionHandler(FileProviderExtension.mapError(error))
            }
        }

        return progress
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        let logMsg = "enumerator called for: \(containerItemIdentifier.rawValue)\n"
        if let d = logMsg.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/bdpan-ext-debug.log")
            if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        }
        let path: String
        if containerItemIdentifier == .rootContainer
            || containerItemIdentifier == .workingSet {
            path = "/apps/bdpan"
        } else {
            // rawValue IS the full /apps/bdpan/... remote path.
            path = containerItemIdentifier.rawValue
        }
        return BdpanEnumerator(path: path, client: client)
    }

    // MARK: - Error Mapping

    private static func mapError(_ error: Error) -> Error {
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
