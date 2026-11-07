import Foundation

/// A parsed `hotkey` setting: one modifier held alone, or a normal key combination.
public enum Hotkey: Equatable {
    case modifier(ModifierKey)
    case combo(keyCode: UInt32, modifiers: Set<ComboModifier>)

    public enum ModifierKey: String, CaseIterable {
        case fn
        case rightOption = "right_option", leftOption = "left_option"
        case rightCommand = "right_command", leftCommand = "left_command"
        case rightControl = "right_control", leftControl = "left_control"
        case rightShift = "right_shift", leftShift = "left_shift"

        /// Virtual key codes. Newer keyboards can report the Globe key as 179.
        public var keyCodes: Set<Int64> {
            switch self {
            case .fn: return [63, 179]
            case .rightOption: return [61]
            case .leftOption: return [58]
            case .rightCommand: return [54]
            case .leftCommand: return [55]
            case .rightControl: return [62]
            case .leftControl: return [59]
            case .rightShift: return [60]
            case .leftShift: return [56]
            }
        }

        /// Bit in the event flags showing this exact key is down. `nil` for fn,
        /// which uses the secondary-fn flag instead.
        public var deviceFlag: UInt64? {
            switch self {
            case .fn: return nil
            case .leftControl: return 0x0001
            case .leftShift: return 0x0002
            case .rightShift: return 0x0004
            case .leftCommand: return 0x0008
            case .rightCommand: return 0x0010
            case .leftOption: return 0x0020
            case .rightOption: return 0x0040
            case .rightControl: return 0x2000
            }
        }
    }

    public enum ComboModifier: String, Hashable {
        case command, option, control, shift
    }

    public struct ParseError: LocalizedError {
        public let errorDescription: String?
    }

    public static func parse(_ text: String) throws -> Hotkey {
        let cleaned = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let modifier = ModifierKey(rawValue: cleaned) {
            return .modifier(modifier)
        }

        var parts = cleaned.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let keyName = parts.popLast() else {
            throw ParseError(errorDescription: """
                Hotkey "\(text)" isn't valid. Use a single modifier such as "fn" or \
                "right_option", or a combination such as "control+option+space".
                """)
        }

        var modifiers = Set<ComboModifier>()
        for part in parts {
            guard let modifier = comboModifierNames[part] else {
                throw ParseError(errorDescription: "Hotkey \"\(text)\": \"\(part)\" isn't a modifier.")
            }
            modifiers.insert(modifier)
        }
        guard let keyCode = keyCodes[keyName] else {
            throw ParseError(errorDescription: "Hotkey \"\(text)\": unknown key \"\(keyName)\".")
        }
        return .combo(keyCode: keyCode, modifiers: modifiers)
    }

    private static let comboModifierNames: [String: ComboModifier] = [
        "cmd": .command, "command": .command,
        "opt": .option, "option": .option, "alt": .option,
        "ctrl": .control, "control": .control,
        "shift": .shift,
    ]

    // US layout positions. Esc is left out on purpose because it cancels.
    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "tab": 48, "space": 49, "delete": 51,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]
}
