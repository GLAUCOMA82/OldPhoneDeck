import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI
import WebKit

// The Mac side of PhoneDeck: a menu bar extra, the app menus, the Command Center window
// (the /studio page in a native shell) and the Connect a Device window.

// MARK: Links and decks

/// Links use the Mac's .local name, so they survive network changes; `lan` is the numeric fallback.
struct DeckLinks {
    let host = localHostName()
    let lan = lanAddress()
    var deck: String { "http://\(host):\(opts.port)/#k=\(token)" }
    var profile: String { "http://\(host):\(opts.port)/phonedeck.mobileconfig" }
    var secure: String { "https://\(host):\(opts.port + 2)/#k=\(token)" }
}

enum DeckDevice: String, CaseIterable {
    case classic, phone, tablet

    var name: String {
        switch self { case .classic: "iPhone 4S"; case .phone: "iPhone 17"; case .tablet: "iPad mini" }
    }
    var symbol: String {
        switch self { case .classic: "iphone.gen1.landscape"; case .phone: "iphone.landscape"; case .tablet: "ipad.landscape" }
    }

    /// Connected while the deck has polled in the last 10 s (same rule as the Command Center sidebar).
    var status: (connected: Bool, text: String) {
        guard let c = server.queue.sync(execute: { clients[rawValue] }), let at = c["at"] as? Double else {
            return (false, "Not connected yet")
        }
        let seen = Date(timeIntervalSince1970: at / 1000)
        if Date().timeIntervalSince(seen) < 10 {
            let page = c["page"] as? Int ?? 0
            return (true, "Connected · " + (Layout.pageName(device: rawValue, index: page) ?? "Page \(page + 1)"))
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return (false, "Last seen " + f.localizedString(for: seen, relativeTo: Date()))
    }
}

/// A menu bar app has no Dock icon. While one of its windows is open it becomes a regular app,
/// so the window can take focus and the app menus (Edit, View, Window) appear.
enum AppWindows {
    static func opened(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    static func closing(_ window: NSWindow) {
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    // Opening PhoneDeck again (Finder, Spotlight, Launchpad) while it runs shows the Command Center.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { CommandCenter.shared.show() }
        return true
    }
}

// MARK: Menu bar extra

final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var timer: Timer?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.updateIcon() }
    }

    /// Filled icon while any deck is connected.
    private func updateIcon() {
        let connected = DeckDevice.allCases.filter { $0.status.connected }
        item.button?.image = NSImage(systemSymbolName: connected.isEmpty ? "square.grid.2x2" : "square.grid.2x2.fill",
                                     accessibilityDescription: "PhoneDeck")
        item.button?.toolTip = connected.isEmpty ? "PhoneDeck" : "PhoneDeck · " + connected.map(\.name).joined(separator: ", ")
    }

    // Rebuilt every time it opens, so device status and checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Devices"))
        for d in DeckDevice.allCases {
            let st = d.status
            let mi = add(menu, d.name, #selector(openDevice(_:)))
            mi.representedObject = d.rawValue
            mi.image = NSImage(systemSymbolName: d.symbol, accessibilityDescription: nil)
            if #available(macOS 14.4, *) { mi.subtitle = st.text } else { mi.title = "\(d.name) — \(st.text)" }
            mi.toolTip = "Edit the \(d.name) deck in the Command Center"
        }
        add(menu, "Connect a Device…", #selector(connectDevice))
        menu.addItem(.separator())
        add(menu, "Command Center…", #selector(openCommandCenter), key: ",")
        menu.addItem(.separator())
        add(menu, "Keep Mac Awake", #selector(toggleAwake)).state = MacControls.keepAwake ? .on : .off
        if Bundle.main.bundlePath.hasSuffix(".app") {
            add(menu, "Open at Login", #selector(toggleLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(.separator())
        add(menu, "Show Log", #selector(showLog))
        menu.addItem(withTitle: "Quit PhoneDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func openDevice(_ sender: NSMenuItem) { CommandCenter.shared.show(device: sender.representedObject as? String) }
    @objc private func connectDevice() { ConnectWindow.shared.show() }
    @objc private func openCommandCenter() { CommandCenter.shared.show() }
    @objc private func toggleAwake() { MacControls.toggleKeepAwake() }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            print("Open at Login: \(error.localizedDescription)")
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".phonedeck/log.txt"))
    }
}

// MARK: App menus (shown while a PhoneDeck window is open)

enum MainMenu {
    static func install() {
        let main = NSMenu()
        let cc = CommandCenter.shared

        let appMenu = submenu(main, "PhoneDeck")
        appMenu.addItem(withTitle: "About PhoneDeck", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        item(appMenu, "Connect a Device…", #selector(ConnectWindow.showFromMenu(_:)), target: ConnectWindow.shared)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide PhoneDeck", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", mods: [.command, .option])
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit PhoneDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        item(file, "New Page", #selector(CommandCenter.newPage(_:)), key: "n", target: cc)
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(main, "Edit")
        item(edit, "Undo", #selector(CommandCenter.undoChange(_:)), key: "z", target: cc)
        item(edit, "Redo", #selector(CommandCenter.redoChange(_:)), key: "z", mods: [.command, .shift], target: cc)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu(main, "View")
        for (i, d) in DeckDevice.allCases.enumerated() {
            item(view, d.name, #selector(CommandCenter.showDevice(_:)), key: "\(i + 1)", target: cc).representedObject = d.rawValue
        }
        view.addItem(.separator())
        item(view, "Appearance", #selector(CommandCenter.showPane(_:)), target: cc).representedObject = "look"
        item(view, "Notifications", #selector(CommandCenter.showPane(_:)), target: cc).representedObject = "notes"
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", mods: [.command, .control])

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        item(window, "Command Center", #selector(CommandCenter.showFromMenu(_:)), key: "0", target: cc)
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    @discardableResult
    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                             mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let mi = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mods
        mi.target = target
        return mi
    }
}

// MARK: Command Center (the /studio page in a native window)

final class CommandCenter: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate, NSMenuItemValidation {
    static let shared = CommandCenter()
    private var window: NSWindow?
    private var web: WKWebView?
    private var pendingJS: [String] = []

    func show(device: String? = nil) {
        if window == nil { makeWindow() }
        if let device { run("device('\(device)')") }
        AppWindows.opened(window!)
    }

    private func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Command Center"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 980, height: 640)
        w.isReleasedWhenClosed = false
        w.delegate = self

        let root = NSView(frame: w.contentView!.bounds)
        // The real macOS sidebar material, placed exactly under the page's sidebar (8 pt inset, 264 pt wide,
        // 20 pt corners). The page leaves that area clear when it runs here (html.native in studio.html).
        let side = NSVisualEffectView(frame: NSRect(x: 8, y: 8, width: 264, height: root.bounds.height - 16))
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.state = .followsWindowActiveState
        side.wantsLayer = true
        side.layer?.cornerRadius = 20
        side.layer?.cornerCurve = .continuous
        side.layer?.masksToBounds = true
        side.autoresizingMask = [.height]
        root.addSubview(side)

        let config = WKWebViewConfiguration()
        let setup = """
        document.documentElement.classList.add('native');
        // No browser context menu (Reload, Back) except where text can be edited or copied.
        document.addEventListener('contextmenu', e => {
          if (!e.target.closest('input, textarea, pre, code')) e.preventDefault();
        });
        """
        config.userContentController.addUserScript(WKUserScript(source: setup, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: root.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.uiDelegate = self
        web.navigationDelegate = self
        web.load(URLRequest(url: URL(string: "http://localhost:\(opts.port)/studio#k=\(token)")!))
        root.addSubview(web)

        w.contentView = root
        w.center()
        w.setFrameAutosaveName("PhoneDeckCommandCenter")
        window = w
        self.web = web
    }

    /// Calls the page's window.cc API; waits for the page if it is still loading.
    private func run(_ call: String) {
        guard let web, !web.isLoading else { pendingJS.append(call); return }
        web.evaluateJavaScript("window.cc && cc.\(call)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let calls = pendingJS
        pendingJS = []
        calls.forEach(run)
    }

    // Links that leave the Command Center (deck previews, docs) open in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url, url.path != "/studio" {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func windowWillClose(_ notification: Notification) { AppWindows.closing(window!) }

    // Menu actions
    @objc func showFromMenu(_ sender: Any?) { show() }
    @objc func newPage(_ sender: Any?) { run("newPage()") }
    @objc func undoChange(_ sender: Any?) { run("undo()") }
    @objc func redoChange(_ sender: Any?) { run("redo()") }
    @objc func showDevice(_ sender: NSMenuItem) { show(device: sender.representedObject as? String) }
    @objc func showPane(_ sender: NSMenuItem) {
        show()
        run("pane('\(sender.representedObject as? String ?? "")')")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showFromMenu(_:)), #selector(showDevice(_:)), #selector(showPane(_:)): return true
        default: return window?.isKeyWindow == true   // editing commands act on the Command Center only
        }
    }
}

// MARK: Connect a Device

final class ConnectWindow: NSObject, NSWindowDelegate {
    static let shared = ConnectWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ConnectView(links: DeckLinks())))
            w.title = "Connect a Device"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        AppWindows.opened(window!)
    }

    @objc func showFromMenu(_ sender: Any?) { show() }
    func windowWillClose(_ notification: Notification) { AppWindows.closing(window!) }
}

struct ConnectView: View {
    enum Kind { case classic, modern }
    let links: DeckLinks
    @State private var kind = Kind.modern

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Device", selection: $kind) {
                Text("iPhone 17 or iPad").tag(Kind.modern)
                Text("iPhone 4S").tag(Kind.classic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if kind == .modern {
                HStack(alignment: .top, spacing: 20) {
                    LinkStep(number: 1, title: "Install the profile", url: links.profile, showsCode: true,
                             detail: "Scan with the Camera app and install it. Then turn on PhoneDeck CA in Settings › General › About › Certificate Trust Settings. Only needed once.")
                    LinkStep(number: 2, title: "Open the deck", url: links.secure, showsCode: true,
                             detail: "Scan, then tap Share › Add to Home Screen and turn the device sideways. Camera, mic and voice work on this secure link.")
                }
            } else {
                // The 4S camera can't read QR codes (iOS 9), so the address is shown large to type into Safari.
                LinkStep(number: 1, title: "Open Safari on the iPhone 4S and type this address", url: links.deck, showsCode: false,
                         detail: "Then tap Share › Add to Home Screen and turn the phone sideways. You can also send the link with AirDrop or Messages.")
            }

            Label("The device needs to be on the same Wi-Fi network or hotspot as this Mac. These links use the Mac's name, so they keep working when you switch networks. If a device can't find \(links.host), replace it with \(links.lan) in the link.",
                  systemImage: "wifi")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LinkStep: View {
    let number: Int
    let title: String
    let url: String
    let showsCode: Bool
    let detail: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsCode, let qr = qrCode(url) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 168, height: 168)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("QR code for \(title)")
            }
            Text("\(number). \(title)").font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(url)
                .font(showsCode ? .system(.caption, design: .monospaced) : .system(.title3, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(showsCode ? 2 : 1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    copied = true
                }
                if let u = URL(string: url) { ShareLink(item: u) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func qrCode(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
