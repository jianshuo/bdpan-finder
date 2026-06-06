import Foundation
import FileProvider
import UniformTypeIdentifiers

// MARK: - BdpanProviderItem
//
// A single NSFileProviderItem implementation that covers both real
// Baidu Pan files/directories (backed by BdpanFileInfo / BdpanEntry)
// and the synthetic root container sentinel.
//
// Usage:
//   BdpanProviderItem(fileInfo: entry)         // wraps a real remote entry
//   BdpanProviderItem.rootContainer()          // returns the root sentinel
//   BdpanProviderItem(rootContainer: ())       // same, via direct initializer

final class BdpanProviderItem: NSObject, NSFileProviderItem {

    // MARK: - Internal Storage

    private enum Storage {
        case file(BdpanFileInfo)
        case root
    }

    private let storage: Storage

    // MARK: - Initializers

    /// Wrap a real remote file or directory entry returned by `bdpan ls`.
    init(fileInfo: BdpanFileInfo) {
        self.storage = .file(fileInfo)
        super.init()
    }

    /// Create the synthetic root-container sentinel.
    /// The labelled `()` argument disambiguates the overload without
    /// requiring a separate type.
    init(rootContainer: ()) {
        self.storage = .root
        super.init()
    }

    // MARK: - Static Factory

    /// Convenience factory that returns the root container sentinel item.
    static func rootContainer() -> BdpanProviderItem {
        BdpanProviderItem(rootContainer: ())
    }

    // MARK: - NSFileProviderItem: itemIdentifier

    var itemIdentifier: NSFileProviderItemIdentifier {
        switch storage {
        case .root:
            return .rootContainer
        case .file(let info):
            // The full /apps/bdpan/... path IS the stable identifier.
            return NSFileProviderItemIdentifier(info.path)
        }
    }

    // MARK: - NSFileProviderItem: parentItemIdentifier

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        switch storage {
        case .root:
            // The root container is its own parent (required by the protocol).
            return .rootContainer
        case .file(let info):
            let parent = (info.path as NSString).deletingLastPathComponent
            // Items whose parent is the bdpan root map to .rootContainer.
            if parent == "/apps/bdpan" || parent == "/apps/bdpan/" {
                return .rootContainer
            }
            return NSFileProviderItemIdentifier(parent)
        }
    }

    // MARK: - NSFileProviderItem: filename

    /// The bare leaf name shown in Finder (no path components).
    var filename: String {
        switch storage {
        case .root:
            return "Baidu Pan"
        case .file(let info):
            return info.serverFilename
        }
    }

    // MARK: - NSFileProviderItem: contentType

    var contentType: UTType {
        switch storage {
        case .root:
            return .folder
        case .file(let info):
            if info.isdir {
                return .folder
            }
            // Explicit mapping for common types: dynamic UTType(filenameExtension:)
            // can resolve to an overly-generic supertype inside a sandboxed extension.
            let ext = (info.serverFilename as NSString).pathExtension.lowercased()
            switch ext {
            case "mp4", "m4v":       return .mpeg4Movie
            case "mov":              return .quickTimeMovie
            case "avi":              return .avi
            case "mp3":              return .mp3
            case "m4a", "aac":       return .mpeg4Audio
            case "wav":              return .wav
            case "flac":             return UTType(filenameExtension: "flac") ?? .audio
            case "jpg", "jpeg":      return .jpeg
            case "png":              return .png
            case "gif":              return .gif
            case "heic", "heif":     return .heic
            case "tiff", "tif":      return .tiff
            case "webp":             return UTType(filenameExtension: "webp") ?? .image
            case "pdf":              return .pdf
            case "zip":              return .zip
            case "gz":               return .gzip
            case "tar":              return UTType(filenameExtension: "tar") ?? .data
            case "txt":              return .plainText
            case "html", "htm":      return .html
            case "json":             return .json
            case "xml":              return .xml
            case "md":               return UTType(filenameExtension: "md") ?? .plainText
            case "doc", "docx":      return UTType(filenameExtension: ext) ?? .data
            case "xls", "xlsx":      return UTType(filenameExtension: ext) ?? .data
            case "ppt", "pptx":      return UTType(filenameExtension: ext) ?? .data
            default:                 return UTType(filenameExtension: ext) ?? .data
            }
        }
    }

    // MARK: - NSFileProviderItem: capabilities

    var capabilities: NSFileProviderItemCapabilities {
        switch storage {
        case .root:
            // Root container: browsing and adding items only.
            return [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating]
        case .file(let info):
            if info.isdir {
                // Folders expose the full set of capabilities.
                return [
                    .allowsReading,
                    .allowsWriting,
                    .allowsRenaming,
                    .allowsReparenting,
                    .allowsDeleting,
                    .allowsAddingSubItems,
                    .allowsContentEnumerating,
                    .allowsTrashing,
                    .allowsEvicting,
                    .allowsExcludingFromSync,
                ]
            }
            // Files: reading and deletion; writes handled via createItem/modifyItem.
            return [.allowsReading, .allowsDeleting]
        }
    }

    // MARK: - NSFileProviderItem: documentSize

    /// File size in bytes. nil for directories and the root container.
    var documentSize: NSNumber? {
        switch storage {
        case .root:
            return nil
        case .file(let info):
            return info.isdir ? nil : NSNumber(value: info.size)
        }
    }

    // MARK: - NSFileProviderItem: childItemCount

    /// Unknown until the system enumerates the container; always nil.
    /// The system will call the enumerator when it needs the actual count.
    var childItemCount: NSNumber? { nil }

    // MARK: - NSFileProviderItem: contentModificationDate

    var contentModificationDate: Date? {
        switch storage {
        case .root:
            return nil
        case .file(let info):
            return info.modificationDate   // parsed from server_mtime (ISO 8601)
        }
    }

    // MARK: - NSFileProviderItem: creationDate

    var creationDate: Date? {
        switch storage {
        case .root:
            return nil
        case .file(let info):
            return info.creationDate       // parsed from server_ctime (ISO 8601)
        }
    }

    // MARK: - NSFileProviderItem: itemVersion
    //
    // NSFileProviderReplicatedExtension requires every item to supply a non-nil
    // itemVersion. Absence triggers __FILEPROVIDER_BAD_ITEM_MISSING_ITEMVERSION__
    // and causes fileproviderd to abort the extension.

    var itemVersion: NSFileProviderItemVersion {
        switch storage {
        case .root:
            let v = Data("root-v1".utf8)
            return NSFileProviderItemVersion(contentVersion: v, metadataVersion: v)
        case .file(let info):
            let contentV = Data(info.md5.isEmpty ? String(info.fsId).utf8 : info.md5.utf8)
            let metaV = Data(info.serverMtime.utf8)
            return NSFileProviderItemVersion(contentVersion: contentV, metadataVersion: metaV)
        }
    }

    // MARK: - NSFileProviderItem: Transfer / Sync Status

    /// Set to true once the system has successfully fetched the file contents.
    var isDownloaded: Bool = false

    /// All items originate on the server, so they are considered uploaded.
    var isUploaded: Bool = true

    /// Tracks whether the locally cached copy matches the latest server version.
    /// Derived from isDownloaded: once downloaded, the version is current.
    var isMostRecentVersionDownloaded: Bool { isDownloaded }

    /// Baidu Pan items are not shared via collaborative links in this extension.
    var isShared: Bool { false }

}
