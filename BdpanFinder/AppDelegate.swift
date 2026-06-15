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
        rawValue: "com.wangjianshuo.百度网盘"
    )
    private static let domainDisplayName = "百度网盘"

    // MARK: - State

    private var statusItem: NSStatusItem?
    private var registeredDomain: NSFileProviderDomain?
    private var refreshTimer: Timer?
    private var onboarding: OnboardingWindowController?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("BdpanFinder: applicationDidFinishLaunching called")
        let domain = NSFileProviderDomain(
            identifier: AppDelegate.domainIdentifier,
            displayName: AppDelegate.domainDisplayName
        )
        self.registeredDomain = domain
        setupStatusMenu()

        // Remove ALL registered domains before re-adding ours.
        // This handles identifier migrations: if a previous build registered a
        // custom-identifier domain (e.g. "com.wangjianshuo.BdpanFinder"), simply
        // removing the current domain wouldn't touch it — old entries would
        // persist in Finder's sidebar with the wrong label.
        NSFileProviderManager.getDomainsWithCompletionHandler { existing, _ in
            let group = DispatchGroup()
            for old in existing ?? [] {
                group.enter()
                NSFileProviderManager.remove(old) { _ in group.leave() }
            }
            group.notify(queue: .global()) {
                NSFileProviderManager.add(domain) { error in
                    if let error = error {
                        NSLog("BdpanFinder: failed to add domain: \(error)")
                    } else {
                        NSLog("BdpanFinder: domain added successfully")
                    }
                    // Once the domain (and thus the extension container) exists,
                    // make sure the user is logged in — otherwise guide them.
                    DispatchQueue.main.async { self.showOnboardingIfNeeded() }
                }
            }
        }

        startAutoRefresh()
    }

    // MARK: - Onboarding

    private func appLog(_ s: String) {
        NSLog("BdpanFinder: \(s)")
    }

    /// Show the login window unless bdpan already has a valid token.
    private func showOnboardingIfNeeded() {
        appLog("showOnboardingIfNeeded called")
        DispatchQueue.global().async {
            let loggedIn = BdpanSetup.isLoggedIn()
            self.appLog("isLoggedIn=\(loggedIn) cfg=\(BdpanSetup.configPath()) bdpan=\(BdpanSetup.bundledBdpanPath() ?? "NIL")")
            DispatchQueue.main.async {
                if !loggedIn { self.presentOnboarding() }
            }
        }
    }

    @objc private func presentOnboarding() {
        appLog("presentOnboarding called")
        if onboarding == nil {
            onboarding = OnboardingWindowController(onDone: { [weak self] in
                self?.reload()
            })
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.showWindow(nil)
        onboarding?.window?.center()
        onboarding?.window?.makeKeyAndOrderFront(nil)
        onboarding?.window?.orderFrontRegardless()
        appLog("presentOnboarding shown window=\(String(describing: onboarding?.window))")
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

        // Log in / switch Baidu account.
        let loginItem = NSMenuItem(
            title: "登录 / 重新登录…",
            action: #selector(presentOnboarding),
            keyEquivalent: ""
        )
        loginItem.target = self
        menu.addItem(loginItem)

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
