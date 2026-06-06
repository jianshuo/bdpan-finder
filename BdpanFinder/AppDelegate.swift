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

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("BdpanFinder: applicationDidFinishLaunching called")
        print("BdpanFinder: applicationDidFinishLaunching called")
        let domain = NSFileProviderDomain(
            identifier: AppDelegate.domainIdentifier,
            displayName: AppDelegate.domainDisplayName
        )
        self.registeredDomain = domain

        NSFileProviderManager.add(domain) { error in
            if let nsError = error as NSError?,
               nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileWriteFileExistsError {
                NSLog("BdpanFinder: domain already registered")
                return
            }
            if let error = error {
                NSLog("BdpanFinder: failed to add domain: \(error)")
            } else {
                NSLog("BdpanFinder: domain added successfully")
            }
        }

        NSLog("BdpanFinder: calling setupStatusMenu")
        setupStatusMenu()
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
        guard let domain = registeredDomain,
              let manager = NSFileProviderManager(for: domain) else {
            NSLog("BdpanFinder: no manager available for domain")
            return
        }
        // Signalling the working set causes the system to call enumerateChanges,
        // which triggers a full re-enumeration of all visible folders.
        manager.signalEnumerator(for: .workingSet) { error in
            if let error = error {
                NSLog("BdpanFinder: signalEnumerator error: \(error)")
            }
        }
    }
}
