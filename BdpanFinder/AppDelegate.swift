import Cocoa
import FileProvider

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    // MARK: - Domain Configuration

    private static let domainIdentifier = NSFileProviderDomainIdentifier(
        rawValue: "com.wangjianshuo.BdpanFinder"
    )
    private static let domainDisplayName = "百度网盘"

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var registeredDomain: NSFileProviderDomain?
    private var refreshTimer: Timer?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("BdpanFinder: applicationDidFinishLaunching called")
        let domain = NSFileProviderDomain(
            identifier: AppDelegate.domainIdentifier,
            displayName: AppDelegate.domainDisplayName
        )
        self.registeredDomain = domain
        setupStatusMenu()

        // Remove any existing domain first to clear stale local state, then re-add.
        // This ensures the File Provider's pending-operation queue is wiped on every
        // launch, preventing corrupted local state from replaying bad createItem calls.
        NSFileProviderManager.remove(domain) { _ in
            NSFileProviderManager.add(domain) { error in
                if let error = error {
                    NSLog("BdpanFinder: failed to add domain: \(error)")
                } else {
                    NSLog("BdpanFinder: domain added successfully")
                }
            }
        }

        startAutoRefresh()
    }

    // MARK: - Status Menu

    private func setupStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = item

        // Use an SF Symbol icon; fall back to a text label on macOS <12.
        if let button = item.button {
            if let icon = NSImage(
                systemSymbolName: "externaldrive.fill.badge.icloud",
                accessibilityDescription: "百度网盘"
            ) {
                button.image = icon
            } else {
                button.title = "BP"
            }
        }

        let menu = NSMenu()

        // Title — disabled, acts as a section header.
        let titleItem = NSMenuItem(
            title: "百度网盘",
            action: nil,
            keyEquivalent: ""
        )
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        // Open the file provider root in Finder.
        let openItem = NSMenuItem(
            title: "Open in Finder",
            action: #selector(openInFinder),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        // Force a full re-enumeration (pull from Baidu Pan).
        let reloadItem = NSMenuItem(
            title: "Reload",
            action: #selector(reload),
            keyEquivalent: ""
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(.separator())

        // Terminate the host app.  The extension process is managed by launchd
        // and will continue running independently until the domain is removed.
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        item.menu = menu
    }

    // MARK: - Actions

    @objc private func openInFinder() {
        guard let domain = registeredDomain,
              let manager = NSFileProviderManager(for: domain) else {
            NSLog("BdpanFinder: no manager available for domain")
            return
        }

        if #available(macOS 13.0, *) {
            // getUserVisibleURL returns the Finder-visible path for the root container.
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let error = error {
                    NSLog("BdpanFinder: getUserVisibleURL error: \(error)")
                    return
                }
                if let url = url {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else {
            // macOS 12 fallback: open the user's home directory and let them
            // navigate to the domain in the Finder sidebar manually.
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        }
    }

    @objc private func reload() {
        reimport()
    }

    private func reimport() {
        guard let domain = registeredDomain,
              let manager = NSFileProviderManager(for: domain) else {
            NSLog("BdpanFinder: no manager available for domain")
            return
        }
        // Signal the working set: triggers WorkingSetEnumerator.enumerateChanges,
        // which scans all previously-visited directories, diffs against the cache,
        // and reports additions and deletions — including items removed on the server.
        // Also signal root so newly added top-level items appear without browsing first.
        manager.signalEnumerator(for: .workingSet) { error in
            if let error = error {
                NSLog("BdpanFinder: signalEnumerator workingSet error: \(error)")
            }
        }
        manager.signalEnumerator(for: .rootContainer) { error in
            if let error = error {
                NSLog("BdpanFinder: signalEnumerator rootContainer error: \(error)")
            }
        }
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.reimport()
        }
    }
}
