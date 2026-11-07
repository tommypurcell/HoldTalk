import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

/// The menu bar icon and menu.
@MainActor
public final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let enabledKey = "enabled"

    private var statusItem: NSStatusItem!
    private var controller: DictationController!
    private var config = Config()
    private var isRecording = false
    private var lastNotice: String?

    private var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let loaded = loadSettings()
        config = loaded.config
        lastNotice = loaded.error
        controller = DictationController(config: config, env: .load())
        controller.onRecordingChanged = { [weak self] recording in
            self?.isRecording = recording
            if recording { self?.lastNotice = nil }
            self?.updateIcon()
        }
        controller.onNotice = { [weak self] notice in self?.lastNotice = notice }
        updateIcon()
        requestPermissions()
        controller.setEnabled(isEnabled)
    }

    // MARK: - Settings file

    private func loadSettings() -> (config: Config, error: String?) {
        let manager = FileManager.default
        try? manager.createDirectory(at: Paths.folder, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        guard let data = try? Data(contentsOf: Paths.config) else {
            writeDefaultSettings()
            return (Config(), nil)
        }
        do {
            return (try Config.parse(data), nil)
        } catch {
            return (config, "Settings error: \(error.localizedDescription)")
        }
    }

    private func writeDefaultSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(Config()) { try? data.write(to: Paths.config) }
    }

    @objc private func reloadSettings() {
        let loaded = loadSettings()
        lastNotice = loaded.error
        // A broken file keeps the settings already running.
        guard loaded.error == nil else { return }
        config = loaded.config
        controller.apply(config: config, env: .load(), enabled: isEnabled)
    }

    @objc private func openSettings() {
        if !FileManager.default.fileExists(atPath: Paths.config.path) { writeDefaultSettings() }
        NSWorkspace.shared.open(Paths.config)
    }

    // MARK: - Permissions

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        _ = CGRequestListenEventAccess()
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    private func permissionItem(_ name: String, granted: Bool, pane: String) -> NSMenuItem {
        let item = NSMenuItem(title: granted ? "\(name): allowed" : "\(name): needed. Open Settings…",
                              action: granted ? nil : #selector(openPrivacyPane(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = pane
        item.isEnabled = !granted
        return item
    }

    @objc private func openPrivacyPane(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? String,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let onOff = NSMenuItem(title: "HoldTalk On", action: #selector(toggleEnabled), keyEquivalent: "")
        onOff.target = self
        onOff.state = isEnabled ? .on : .off
        menu.addItem(onOff)

        let summary = NSMenuItem(title: "Hotkey: \(config.hotkey) · \(config.transcriber) Whisper", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        if let lastNotice {
            let notice = NSMenuItem(title: String(lastNotice.prefix(70)), action: nil, keyEquivalent: "")
            notice.isEnabled = false
            menu.addItem(notice)
        }

        menu.addItem(.separator())
        menu.addItem(permissionItem("Microphone",
                                    granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                                    pane: "Privacy_Microphone"))
        menu.addItem(permissionItem("Input Monitoring",
                                    granted: CGPreflightListenEventAccess(),
                                    pane: "Privacy_ListenEvent"))
        menu.addItem(permissionItem("Accessibility",
                                    granted: AXIsProcessTrusted(),
                                    pane: "Privacy_Accessibility"))

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let open = NSMenuItem(title: "Open Settings File", action: #selector(openSettings), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        let reload = NSMenuItem(title: "Reload Settings", action: #selector(reloadSettings), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit HoldTalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        controller.setEnabled(isEnabled)
        updateIcon()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastNotice = "Launch at Login failed: \(error.localizedDescription)"
        }
    }

    private func updateIcon() {
        let symbol: String
        if !isEnabled {
            symbol = "mic.slash"
        } else {
            symbol = isRecording ? "mic.fill" : "mic"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HoldTalk")
    }
}
