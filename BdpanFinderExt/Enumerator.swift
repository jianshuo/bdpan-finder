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

    private static let cacheFileName = "file-provider-cache.json"
    private static var cacheLoaded = false

    /// Persist the in-memory cache so deletions are still detectable after the
    /// extension process is restarted by `fileproviderd`.
    static func loadCache() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        let url = URL(fileURLWithPath: BdpanClient.bdpanConfigDir())
            .appendingPathComponent(cacheFileName)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            return
        }
        cacheLock.lock()
        itemCache = dict.mapValues { Set($0) }
        cacheLock.unlock()
    }

    static func saveCache() {
        let dirURL = URL(fileURLWithPath: BdpanClient.bdpanConfigDir())
        let url = dirURL.appendingPathComponent(cacheFileName)
        cacheLock.lock()
        let dict = itemCache.mapValues { Array($0) }
        cacheLock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? FileManager.default.createDirectory(
            at: dirURL, withIntermediateDirectories: true, attributes: nil)
        try? data.write(to: url)
    }

    static func setCachedChildren(for path: String, children: Set<String>) {
        cacheLock.lock()
        itemCache[path] = children
        cacheLock.unlock()
        saveCache()
    }

    static func removeCachedPath(_ path: String) {
        cacheLock.lock()
        itemCache.removeValue(forKey: path)
        cacheLock.unlock()
        saveCache()
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let path = self.path
        let client = self.client
        Thread.detachNewThread {
            BdpanEnumerator.enumSemaphore.wait()
            defer { BdpanEnumerator.enumSemaphore.signal() }

            BdpanEnumerator.loadCache()

            func dblog(_ msg: String) {
                bdpanDebugLog("enumerateItems[\(path)]: \(msg)")
            }
            dblog("start")
            do {
                let entries = try client.listFiles(at: path)
                dblog("got \(entries.count) entries")

                // Update cache so WorkingSetEnumerator can detect deletions later.
                let currentPaths = Set(entries.map { $0.path })
                BdpanEnumerator.setCachedChildren(for: path, children: currentPaths)

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

            BdpanEnumerator.loadCache()

            let entries: [BdpanFileInfo]
            do {
                entries = try client.listFiles(at: path)
            } catch BdpanError.pathNotFound {
                // The directory itself was deleted remotely. Report all cached
                // children as deleted and remove the stale cache key.
                BdpanEnumerator.cacheLock.lock()
                let previousPaths = BdpanEnumerator.itemCache[path] ?? []
                BdpanEnumerator.itemCache.removeValue(forKey: path)
                BdpanEnumerator.cacheLock.unlock()
                BdpanEnumerator.saveCache()
                if !previousPaths.isEmpty {
                    observer.didDeleteItems(withIdentifiers: previousPaths.map { NSFileProviderItemIdentifier($0) })
                }
                let newAnchor = NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
                return
            } catch {
                observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
                return
            }

            let currentPaths = Set(entries.map { $0.path })

            BdpanEnumerator.cacheLock.lock()
            let previousPaths = BdpanEnumerator.itemCache[path] ?? currentPaths
            BdpanEnumerator.itemCache[path] = currentPaths
            BdpanEnumerator.cacheLock.unlock()
            BdpanEnumerator.saveCache()

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
            BdpanEnumerator.loadCache()

            // Snapshot the cache keys so we don't hold the lock during I/O.
            BdpanEnumerator.cacheLock.lock()
            let snapshot = BdpanEnumerator.itemCache
            BdpanEnumerator.cacheLock.unlock()

            for (path, previousPaths) in snapshot {
                BdpanEnumerator.enumSemaphore.wait()
                defer { BdpanEnumerator.enumSemaphore.signal() }

                let entries: [BdpanFileInfo]
                do {
                    entries = try client.listFiles(at: path)
                } catch BdpanError.pathNotFound {
                    // Directory was deleted remotely. Remove the stale cache key
                    // and report all previously-known children as deleted.
                    BdpanEnumerator.removeCachedPath(path)
                    if !previousPaths.isEmpty {
                        observer.didDeleteItems(withIdentifiers: previousPaths.map { NSFileProviderItemIdentifier($0) })
                    }
                    continue
                } catch {
                    // Network or auth error — leave cache untouched and retry next cycle.
                    continue
                }

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

            BdpanEnumerator.saveCache()

            let newAnchor = NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
            observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler completion: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let data = Data(String(Date().timeIntervalSince1970).utf8)
        completion(NSFileProviderSyncAnchor(data))
    }
}
