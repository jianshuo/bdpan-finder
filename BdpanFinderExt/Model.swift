import Foundation
import FileProvider

// MARK: - BdpanEntry
//
// Codable struct matching the JSON array returned by:
//   bdpan ls --json <path>
//
// Decode the full response with:
//   let entries = try JSONDecoder().decode([BdpanEntry].self, from: data)

struct BdpanEntry: Codable {
    /// "fs_id" — unique file ID; stable as long as the file is not moved.
    let fsId: Int64

    /// "path" — full absolute path, e.g. "/apps/bdpan/我的/video.mp4"
    let path: String

    /// "server_filename" — bare leaf name only, e.g. "video.mp4"
    let serverFilename: String

    /// "size" — file size in bytes; 0 for directories.
    let size: Int64

    /// "isdir" — true for directories, false for files.
    let isdir: Bool

    /// "md5" — MD5 hash of file contents; "" for directories.
    let md5: String

    /// "server_mtime" — modification time as ISO 8601 with timezone offset,
    /// e.g. "2026-06-05T22:32:12+08:00"
    let serverMtime: String

    /// "server_ctime" — creation time as ISO 8601 with timezone offset,
    /// e.g. "2026-03-03T06:13:59+08:00"
    let serverCtime: String

    enum CodingKeys: String, CodingKey {
        case fsId           = "fs_id"
        case path
        case serverFilename = "server_filename"
        case size
        case isdir
        case md5
        case serverMtime    = "server_mtime"
        case serverCtime    = "server_ctime"
    }

    // MARK: - Computed date properties (derived from the ISO 8601 strings)

    /// Shared formatter; ISO8601DateFormatter is thread-safe.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // withInternetDateTime covers date + time + timezone offset (e.g. +08:00)
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parsed modification date, or nil if the string is malformed.
    var modificationDate: Date? {
        BdpanEntry.isoFormatter.date(from: serverMtime)
    }

    /// Parsed creation date, or nil if the string is malformed.
    var creationDate: Date? {
        BdpanEntry.isoFormatter.date(from: serverCtime)
    }
}

/// Typealias so that any code referring to BdpanFileInfo still compiles.
typealias BdpanFileInfo = BdpanEntry

// MARK: - BdpanItemIdentifier
//
// A type-safe wrapper around full /apps/bdpan/... path strings.
// Used as the backing value for NSFileProviderItemIdentifier throughout
// the extension — the rawValue IS the complete remote path.

struct BdpanItemIdentifier: Hashable {

    /// The full absolute path, e.g. "/apps/bdpan/我的/video.mp4".
    /// Do NOT include a trailing slash.
    let path: String

    init(path: String) {
        self.path = path
    }

    /// The raw string value — identical to the underlying path.
    var rawValue: String { path }

    /// The logical root of the Baidu Pan drive.
    /// Corresponds to NSFileProviderItemIdentifier.rootContainer in the extension.
    static let rootContainer = BdpanItemIdentifier(path: "/apps/bdpan")

    /// Returns a new identifier formed by appending `filename` to this path.
    ///
    /// - Parameter filename: The bare leaf name (must not contain a slash).
    func childPath(filename: String) -> BdpanItemIdentifier {
        BdpanItemIdentifier(path: path + "/" + filename)
    }
}

// MARK: - NSFileProviderItemIdentifier + BdpanItemIdentifier

extension NSFileProviderItemIdentifier {

    /// Creates an NSFileProviderItemIdentifier whose rawValue equals the
    /// BdpanItemIdentifier's underlying path string.
    ///
    /// Usage:
    ///   NSFileProviderItemIdentifier(.rootContainer)   // rawValue == "/apps/bdpan"
    ///   NSFileProviderItemIdentifier(id)               // rawValue == id.path
    init(_ bdpanIdentifier: BdpanItemIdentifier) {
        self.init(rawValue: bdpanIdentifier.rawValue)
    }

    /// Returns the underlying bdpan path when this identifier represents a
    /// real bdpan file or directory (i.e. rawValue starts with "/apps/bdpan").
    ///
    /// Returns nil for the system-reserved identifiers such as
    /// .rootContainer ("NSFileProviderRootContainerItemIdentifier") and
    /// .workingSetContainer.
    ///
    /// Usage:
    ///   identifier.bdpanPath   // "/apps/bdpan/我的/video.mp4"  or  nil
    var bdpanPath: String? {
        guard rawValue.hasPrefix("/apps/bdpan") else { return nil }
        return rawValue
    }
}
