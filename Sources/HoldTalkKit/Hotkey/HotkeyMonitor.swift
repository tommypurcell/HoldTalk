import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Watches the keyboard.
///
/// The event tap is listen-only: it can't change or block any key, so Esc and
/// everything else always reach the app you're typing in. It looks only at key
/// codes to spot the hotkey and Esc, and never stores or logs what you type.
///
/// Combinations such as control+option+space go through the Carbon hotkey API
/// instead, which delivers press and release and keeps the key out of the app.
@MainActor
public final class HotkeyMonitor {
    public enum Signal {
        case hotkeyDown, hotkeyUp, otherKey, escape
    }

    public var onSignal: ((Signal) -> Void)?

    private var hotkey: Hotkey?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var modifierIsDown = false

    private var carbonHotkey: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?

    private static let escapeKeyCode: Int64 = 53
    private static let modifierKeyCodes: Set<Int64> = Set(Hotkey.ModifierKey.allCases.flatMap(\.keyCodes))

    public init() {}

    /// True once the event tap exists. Without it Esc can't be seen, and modifier
    /// hotkeys won't work at all.
    public var isWatching: Bool { tap != nil }

    /// Sets the hotkey without touching the system, so key handling can be tested.
    func prepare(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    public func start(hotkey: Hotkey) {
        stop()
        prepare(hotkey: hotkey)
        if case let .combo(keyCode, modifiers) = hotkey {
            registerCarbon(keyCode: keyCode, modifiers: modifiers)
        }
        if !installTap() {
            // Input Monitoring isn't granted yet. Keep trying so a grant takes effect.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.installTap() == true {
                        self?.retryTimer?.invalidate()
                        self?.retryTimer = nil
                    }
                }
            }
        }
    }

    public func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
        modifierIsDown = false
        if let carbonHotkey { UnregisterEventHotKey(carbonHotkey) }
        if let carbonHandler { RemoveEventHandler(carbonHandler) }
        carbonHotkey = nil
        carbonHandler = nil
        hotkey = nil
    }

    // MARK: - Event tap

    private func installTap() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        tapSource = source
        return true
    }

    func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            releaseIfMissedWhileDisabled()
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Self.escapeKeyCode {
                onSignal?(.escape)
            } else if modifierIsDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onSignal?(.otherKey)
            }
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard case .modifier(let key) = hotkey else { return }
        if key.keyCodes.contains(code) {
            let isDown = Self.isDown(key, flags: event.flags)
            guard isDown != modifierIsDown else { return }
            modifierIsDown = isDown
            onSignal?(isDown ? .hotkeyDown : .hotkeyUp)
        } else if modifierIsDown, Self.modifierKeyCodes.contains(code) {
            onSignal?(.otherKey)
        }
    }

    private func releaseIfMissedWhileDisabled() {
        guard modifierIsDown, case .modifier(let key) = hotkey else { return }
        if !Self.isDown(key, flags: CGEventSource.flagsState(.combinedSessionState)) {
            modifierIsDown = false
            onSignal?(.hotkeyUp)
        }
    }

    private static func isDown(_ key: Hotkey.ModifierKey, flags: CGEventFlags) -> Bool {
        if let bit = key.deviceFlag { return flags.rawValue & bit != 0 }
        return flags.contains(.maskSecondaryFn)
    }

    // MARK: - Carbon combination hotkey

    private func registerCarbon(keyCode: UInt32, modifiers: Set<Hotkey.ComboModifier>) {
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                MainActor.assumeIsolated { monitor.onSignal?(pressed ? .hotkeyDown : .hotkeyUp) }
                return noErr
            },
            types.count, &types,
            Unmanaged.passUnretained(self).toOpaque(),
            &carbonHandler)

        let id = EventHotKeyID(signature: OSType(0x484C_544B), id: 1) // "HLTK"
        RegisterEventHotKey(keyCode, carbonModifiers, id, GetApplicationEventTarget(), 0, &carbonHotkey)
    }
}
