import Foundation
import FileProvider

// MARK: - BdpanEnumerator

/// Enumerates the contents of a single remote Baidu Pan directory.
///
/// One instance is created per directory the system wants to display.
/// The extension creates the enumerator with the full remote path and a
/// shared BdpanClient, then the FileProvider framework drives enumeration
/// by calling `enumerateItems(for:startingAt:)`.
///
/// Because BdpanClient is synchronous (Process.waitUntilExit), all work
/// is dispatched onto a global background queue rather than using async/await.
final class BdpanEnumerator: NSObject, NSFileProviderEnumerator {

    // MARK: - Properties

    /// Full remote path to enumerate, e.g. "/apps/bdpan" for root or
    /// "/apps/bdpan/我的视频" for a subdirectory.
    let path: String

    /// Shared CLI wrapper. Thread-safe because BdpanClient has no mutable state
    /// on its fast path (only bdpanPath, which is set once at startup).
    let client: BdpanClient

    // MARK: - Initializer

    init(path: String, client: BdpanClient) {
        self.path = path
        self.client = client
    }

    // MARK: - NSFileProviderEnumerator

    /// Called by the system to retrieve the full directory listing.
    ///
    /// BdpanFinder does not paginate — bdpan returns all entries in one CLI call.
    /// Every `page` value is therefore treated as "fetch everything from scratch".
    ///
    /// Dispatches to a global background queue so the synchronous Process call
    /// does not block the extension's main thread.
    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        DispatchQueue.global().async { [path, client] in
            func dblog(_ msg: String) {
                let line = "enumerateItems[\(path)]: \(msg)\n"
                if let d = line.data(using: .utf8) {
                    let url = URL(fileURLWithPath: "/tmp/bdpan-ext-debug.log")
                    if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
                }
            }
            dblog("start")
            do {
                let entries = try client.listFiles(at: path)
                dblog("got \(entries.count) entries")
                let items: [NSFileProviderItem] = entries.map { BdpanProviderItem(fileInfo: $0) }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch BdpanError.pathNotFound {
                dblog("error: pathNotFound")
                observer.finishEnumeratingWithError(
                    NSFileProviderError(.noSuchItem))
            } catch BdpanError.tokenExpired {
                dblog("error: tokenExpired")
                observer.finishEnumeratingWithError(
                    NSFileProviderError(.serverUnreachable))
            } catch {
                dblog("error: \(error)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    /// Called by the system for incremental sync (working set).
    ///
    /// bdpan CLI does not expose a server-side change cursor, so BdpanFinder
    /// reports no changes here and relies on full re-enumeration triggered by
    /// `NSFileProviderManager.signalEnumerator` from the host app instead.
    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    /// Returns a sync anchor based on the current wall-clock time.
    ///
    /// Using a timestamp means the anchor is always "new", which causes the
    /// system to call `enumerateChanges` on its next sync cycle. Combined with
    /// the no-op `enumerateChanges` implementation above, this achieves a
    /// simple pull-on-demand model without a real server-side cursor.
    func currentSyncAnchor(
        completionHandler completion: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        let data = Data(String(Date().timeIntervalSince1970).utf8)
        completion(NSFileProviderSyncAnchor(data))
    }

    /// Tear down any resources held by this enumerator instance.
    ///
    /// BdpanEnumerator has no long-lived resources (no open file handles,
    /// no background tasks), so nothing needs to be released here.
    func invalidate() {}
}
