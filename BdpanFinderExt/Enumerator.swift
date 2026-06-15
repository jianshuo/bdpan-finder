import Foundation
import FileProvider

// MARK: - BdpanEnumerator

final class BdpanEnumerator: NSObject, NSFileProviderEnumerator {

    let path: String
    let client: BdpanClient

    init(path: String, client: BdpanClient) {
        self.path = path
        self.client = client
    }

    // Cap concurrent enumerations so the GCD global pool stays free for
    // user-initiated ops (fetchContents, createItem). Thread.detachNewThread
    // keeps enumerations off GCD entirely.
    static let enumSemaphore = DispatchSemaphore(value: 6)

    // Cache of each enumerated path → set of child item paths.
    // Used by enumerateChanges and WorkingSetEnumerator to detect deletions.
    static var itemCache: [String: Set<String>] = [:]
    static let cacheLock = NSLock()

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let path = self.path
        let client = self.client
        Thread.detachNewThread {
            BdpanEnumerator.enumSemaphore.wait()
            defer { BdpanEnumerator.enumSemaphore.signal() }

            func dblog(_ msg: String) {
                bdpanDebugLog("enumerateItems[\(path)]: \(msg)")
            }
            dblog("start")
            do {
                let entries = try client.listFiles(at: path)
                dblog("got \(entries.count) entries")

                // Update cache so WorkingSetEnumerator can detect deletions later.
                let currentPaths = Set(entries.map { $0.path })
                BdpanEnumerator.cacheLock.lock()
                BdpanEnumerator.itemCache[path] = currentPaths
                BdpanEnumerator.cacheLock.unlock()

                observer.didEnumerate(entries.map { BdpanProviderItem(fileInfo: $0) })
                observer.finishEnumerating(upTo: nil)
            } catch BdpanError.pathNotFound {
                dblog("error: pathNotFound")
                observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            } catch BdpanError.tokenExpired {
                dblog("error: tokenExpired")
                observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            } catch {
                dblog("error: \(error)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        // Individual-container change enumeration: re-fetch this directory and
        // report deletions by diffing against the cached snapshot.
        let path = self.path
        let client = self.client
        Thread.detachNewThread {
            BdpanEnumerator.enumSemaphore.wait()
            defer { BdpanEnumerator.enumSemaphore.signal() }

            guard let entries = try? client.listFiles(at: path) else {
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }
            let currentPaths = Set(entries.map { $0.path })

            BdpanEnumerator.cacheLock.lock()
            let previousPaths = BdpanEnumerator.itemCache[path] ?? currentPaths
            BdpanEnumerator.itemCache[path] = currentPaths
            BdpanEnumerator.cacheLock.unlock()

            observer.didUpdate(entries.map { BdpanProviderItem(fileInfo: $0) })

            let deleted = previousPaths.subtracting(currentPaths)
                .map { NSFileProviderItemIdentifier($0) }
            if !deleted.isEmpty {
                observer.didDeleteItems(withIdentifiers: deleted)
            }

            let newAnchor = NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
            observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler completion: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let data = Data(String(Date().timeIntervalSince1970).utf8)
        completion(NSFileProviderSyncAnchor(data))
    }

    func invalidate() {}
}

// MARK: - EmptyEnumerator

// Used for containers that don't exist in Baidu Pan (e.g. trash).
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }
    func currentSyncAnchor(completionHandler completion: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completion(NSFileProviderSyncAnchor(Data("empty".utf8)))
    }
}

// MARK: - WorkingSetEnumerator

// The working set is the global change feed for NSFileProviderReplicatedExtension.
// When signaled, it scans all previously-visited directories, diffs against the
// cached snapshot, and reports additions/deletions — enabling remote-side changes
// (e.g. files deleted on Baidu Pan website) to propagate to Finder automatically.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {

    let client: BdpanClient

    init(client: BdpanClient) {
        self.client = client
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        let client = self.client
        Thread.detachNewThread {
            // Snapshot the cache keys so we don't hold the lock during I/O.
            BdpanEnumerator.cacheLock.lock()
            let snapshot = BdpanEnumerator.itemCache
            BdpanEnumerator.cacheLock.unlock()

            for (path, previousPaths) in snapshot {
                BdpanEnumerator.enumSemaphore.wait()
                let entries = (try? client.listFiles(at: path)) ?? []
                BdpanEnumerator.enumSemaphore.signal()

                let currentPaths = Set(entries.map { $0.path })

                BdpanEnumerator.cacheLock.lock()
                BdpanEnumerator.itemCache[path] = currentPaths
                BdpanEnumerator.cacheLock.unlock()

                if !entries.isEmpty {
                    observer.didUpdate(entries.map { BdpanProviderItem(fileInfo: $0) })
                }
                let deleted = previousPaths.subtracting(currentPaths)
                    .map { NSFileProviderItemIdentifier($0) }
                if !deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: deleted)
                }
            }

            let newAnchor = NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
            observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler completion: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let data = Data(String(Date().timeIntervalSince1970).utf8)
        completion(NSFileProviderSyncAnchor(data))
    }
}
