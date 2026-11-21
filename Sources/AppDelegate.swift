import AppKit
import Combine
import SwiftUI

final class AppState: ObservableObject {
    @Published var ipAddress: String = NetworkUtils.localIPv4Address()
    @Published var port: UInt16 = 8765
    @Published var pinCode: String = AppState.loadOrCreatePIN()
    @Published var requirePIN: Bool = true
    @Published var connectedClients: Int = 0
    @Published var hasAccessibility: Bool = InputController.hasAccessibilityPermission(prompt: false)
    @Published var copiedNotice: Bool = false

    var baseURL: String {
        "http://\(ipAddress):\(port)"
    }

    var pairingURL: String {
        requirePIN ? "\(baseURL)/?pin=\(pinCode)" : baseURL
    }

    var qrImage: NSImage? {
        NetworkUtils.generateQRCode(from: pairingURL, size: 220)
    }

    static func loadOrCreatePIN() -> String {
        if let saved = UserDefaults.standard.string(forKey: "PocketPadPIN"), saved.count == 4 {
            return saved
        }
        let pin = String(format: "%04d", Int.random(in: 1000...9999))
        UserDefaults.standard.set(pin, forKey: "PocketPadPIN")
        return pin
    }

    func regeneratePIN() {
        let pin = String(format: "%04d", Int.random(in: 1000...9999))
        UserDefaults.standard.set(pin, forKey: "PocketPadPIN")
        pinCode = pin
    }

    func refreshStatus() {
        ipAddress = NetworkUtils.localIPv4Address()
        hasAccessibility = InputController.hasAccessibilityPermission(prompt: false)
    }
}

struct MenuPopoverView: View {
    @ObservedObject var state: AppState
    let onRegeneratePIN: () -> Void
    let onTogglePIN: (Bool) -> Void
    let onDisconnectAll: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.and.hand.point.up.left.filled")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("PocketPad")
                        .font(.system(size: 15, weight: .semibold))
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.connectedClients > 0 ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                    Text(state.connectedClients > 0 ? "已连接 \(state.connectedClients) 台" : "等待连接")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(state.connectedClients > 0 ? .primary : .secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
            }

            // Accessibility permission banner
            if !state.hasAccessibility {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("需要「辅助功能」权限才能控制鼠标和键盘")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text("授权后无需重启，界面会自动刷新状态。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("打开辅助功能设置") {
                        _ = InputController.hasAccessibilityPermission(prompt: true)
                        InputController.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // QR Code
            VStack(spacing: 10) {
                if let qr = state.qrImage {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 176, height: 176)
                        .padding(12)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                }

                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(state.baseURL)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                        Button(action: copyURL) {
                            Image(systemName: state.copiedNotice ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .help("复制连接地址")

                        Button(action: { state.refreshStatus() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .help("刷新局域网 IP 与权限状态")
                    }

                    Text("用 iPhone 相机扫码打开，添加到主屏幕即可全屏使用")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 4)

            Divider()

            // PIN controls
            HStack {
                Toggle("配对码保护", isOn: Binding(
                    get: { state.requirePIN },
                    set: { newVal in
                        state.requirePIN = newVal
                        onTogglePIN(newVal)
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))

                Spacer()

                if state.requirePIN {
                    HStack(spacing: 6) {
                        Text(state.pinCode)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button(action: onRegeneratePIN) {
                            Image(systemName: "key.radiowaves.forward")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .help("更换配对码")
                    }
                }
            }

            Divider()

            // Footer actions
            HStack {
                if state.connectedClients > 0 {
                    Button("断开手机") {
                        onDisconnectAll()
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("退出 PocketPad") {
                    onQuit()
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 296)
    }

    private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.pairingURL, forType: .string)
        state.copiedNotice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            state.copiedNotice = false
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let state = AppState()
    private let input = InputController()
    private var server: WebSocketServer!
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundledHTML = loadResourceData(name: "index", ext: "html") ?? Data("<h1>Missing index.html</h1>".utf8)
        let overrideHTMLURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PocketPad/index.html")
        let iconPngData = loadResourceData(name: "apple-touch-icon", ext: "png")

        server = WebSocketServer(
            port: 8765,
            pinCode: state.pinCode,
            input: input,
            htmlProvider: {
                if let liveData = try? Data(contentsOf: overrideHTMLURL), !liveData.isEmpty {
                    return liveData
                }
                return bundledHTML
            },
            iconPngData: iconPngData
        )
        server.requirePIN = state.requirePIN
        server.onServerReady = { [weak self] boundPort in
            self?.state.port = boundPort
        }
        server.onClientsChanged = { [weak self] count in
            self?.state.connectedClients = count
            self?.updateStatusIcon(connected: count > 0)
        }
        server.start()

        setupMenuBar()
        startPollingTimer()

        // Open popover automatically on launch so the user sees the QR code right away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showPopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        server?.stop()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(connected: false)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let contentView = MenuPopoverView(
            state: state,
            onRegeneratePIN: { [weak self] in
                guard let self else { return }
                self.state.regeneratePIN()
                self.server.pinCode = self.state.pinCode
                self.server.disconnectAllClients()
            },
            onTogglePIN: { [weak self] required in
                self?.server.requirePIN = required
            },
            onDisconnectAll: { [weak self] in
                self?.server.disconnectAllClients()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    private func updateStatusIcon(connected: Bool) {
        guard let button = statusItem?.button else { return }
        let symbolName = connected ? "hand.tap.fill" : "rectangle.and.hand.point.up.left.filled"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PocketPad") {
            img.isTemplate = true
            button.image = img
        } else {
            button.title = "Pad"
        }
    }

    private func startPollingTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = InputController.hasAccessibilityPermission(prompt: false)
            if trusted != self.state.hasAccessibility {
                self.state.hasAccessibility = trusted
            }
            if self.popover?.isShown == true {
                let ip = NetworkUtils.localIPv4Address()
                if ip != self.state.ipAddress {
                    self.state.ipAddress = ip
                }
            }
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        state.refreshStatus()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func loadResourceData(name: String, ext: String) -> Data? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let data = try? Data(contentsOf: url) {
            return data
        }
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(name).\(ext)")
        return try? Data(contentsOf: fallback)
    }
}
