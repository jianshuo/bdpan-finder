import Cocoa

/// First-run onboarding: walks the user through logging in to Baidu Pan.
///
/// Shown automatically on launch when no valid login is found. The flow is the
/// out-of-band OAuth bdpan supports: open the auth page, the page shows an
/// authorization code, the user pastes it back here.
final class OnboardingWindowController: NSWindowController {

    private var codeField: NSTextField!
    private var statusLabel: NSTextField!
    private var finishButton: NSButton!
    private var onDone: (() -> Void)?

    convenience init(onDone: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "设置百度网盘"
        window.center()
        self.init(window: window)
        self.onDone = onDone
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        func label(_ text: String, size: CGFloat, bold: Bool = false, color: NSColor = .labelColor) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            l.textColor = color
            l.isEditable = false; l.isSelectable = false; l.drawsBackground = false; l.isBordered = false
            l.preferredMaxLayoutWidth = 412
            return l
        }

        stack.addArrangedSubview(label("把百度网盘接进 Finder", size: 17, bold: true))
        stack.addArrangedSubview(label("第一次使用，需要登录你自己的百度网盘账号。登录信息只保存在本机，授权后就能像 iCloud、OneDrive 一样在 Finder 边栏直接用。", size: 12, color: .secondaryLabelColor))

        stack.addArrangedSubview(label("① 打开百度授权页，用你的百度账号登录并同意授权。", size: 13))
        let openButton = NSButton(title: "打开百度授权页", target: self, action: #selector(openAuthPage))
        openButton.bezelStyle = .rounded
        stack.addArrangedSubview(openButton)

        stack.addArrangedSubview(label("② 授权后页面会显示一段「授权码」，复制后粘贴到这里：", size: 13))
        codeField = NSTextField()
        codeField.placeholderString = "在此粘贴授权码"
        codeField.translatesAutoresizingMaskIntoConstraints = false
        codeField.widthAnchor.constraint(equalToConstant: 412).isActive = true
        stack.addArrangedSubview(codeField)

        finishButton = NSButton(title: "③ 完成登录", target: self, action: #selector(finishLogin))
        finishButton.bezelStyle = .rounded
        finishButton.keyEquivalent = "\r"
        stack.addArrangedSubview(finishButton)

        statusLabel = label("", size: 12, color: .secondaryLabelColor)
        stack.addArrangedSubview(statusLabel)
    }

    @objc private func openAuthPage() {
        statusLabel.stringValue = "正在获取授权链接…"
        statusLabel.textColor = .secondaryLabelColor
        DispatchQueue.global().async {
            let url = BdpanSetup.authURL()
            DispatchQueue.main.async {
                guard let url = url, let u = URL(string: url) else {
                    self.statusLabel.stringValue = "获取授权链接失败，请重试。"
                    self.statusLabel.textColor = .systemRed
                    return
                }
                NSWorkspace.shared.open(u)
                self.statusLabel.stringValue = "已在浏览器打开授权页。授权后把页面上的授权码粘贴到上面。"
                self.statusLabel.textColor = .secondaryLabelColor
            }
        }
    }

    @objc private func finishLogin() {
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            statusLabel.stringValue = "请先粘贴授权码。"
            statusLabel.textColor = .systemRed
            return
        }
        finishButton.isEnabled = false
        statusLabel.stringValue = "正在登录…"
        statusLabel.textColor = .secondaryLabelColor
        DispatchQueue.global().async {
            let result = BdpanSetup.submitCode(code)
            DispatchQueue.main.async {
                self.finishButton.isEnabled = true
                if result.ok {
                    let name = BdpanSetup.loggedInUsername() ?? ""
                    self.statusLabel.stringValue = "登录成功\(name.isEmpty ? "" : "（\(name)）")！百度网盘已出现在 Finder 边栏。"
                    self.statusLabel.textColor = .systemGreen
                    self.onDone?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.close() }
                } else {
                    self.statusLabel.stringValue = "登录失败：\(result.message.isEmpty ? "授权码无效或已过期，请重新获取。" : result.message)"
                    self.statusLabel.textColor = .systemRed
                }
            }
        }
    }
}
