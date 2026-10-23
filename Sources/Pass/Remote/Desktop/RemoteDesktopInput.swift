#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// Coordinates are fractions of the captured display, from its upper-left corner. The wire
/// adapter validates its own message schema before constructing one of these local events.
enum RemoteDesktopInputEvent: Decodable, Equatable {
    case mouseMove(x: Double, y: Double)
    case mouseButton(RemoteDesktopMouseButton, down: Bool, x: Double, y: Double)
    case scroll(x: Double, y: Double, deltaX: Double, deltaY: Double)
    case key(code: UInt16, down: Bool, isRepeat: Bool, modifiers: UInt64)
    case text(String)

    private enum CodingKeys: String, CodingKey {
        case type, action, x, y, button, buttons, deltaX, deltaY, code, key, modifiers, text
        case isRepeat = "repeat"
    }

    private struct BrowserModifiers: Decodable {
        var shift: Bool
        var control: Bool
        var alt: Bool
        var meta: Bool

        private enum CodingKeys: String, CodingKey { case shift, control, alt, meta }

        init() { shift = false; control = false; alt = false; meta = false }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            shift = try values.decodeIfPresent(Bool.self, forKey: .shift) ?? false
            control = try values.decodeIfPresent(Bool.self, forKey: .control) ?? false
            alt = try values.decodeIfPresent(Bool.self, forKey: .alt) ?? false
            meta = try values.decodeIfPresent(Bool.self, forKey: .meta) ?? false
        }

        var cgFlags: UInt64 {
            (shift ? CGEventFlags.maskShift.rawValue : 0)
                | (control ? CGEventFlags.maskControl.rawValue : 0)
                | (alt ? CGEventFlags.maskAlternate.rawValue : 0)
                | (meta ? CGEventFlags.maskCommand.rawValue : 0)
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        switch type {
        case "pointer":
            let action = try values.decode(String.self, forKey: .action)
            let x = try Self.coordinate(.x, from: values)
            let y = try Self.coordinate(.y, from: values)
            // `buttons` is the browser's current bitmask. The host tracks presses itself so a
            // forged or out-of-order move cannot implicitly press a button.
            _ = try values.decodeIfPresent(Int.self, forKey: .buttons)
            switch action {
            case "move": self = .mouseMove(x: x, y: y)
            case "down", "up":
                let button = try Self.button(from: values)
                self = .mouseButton(button, down: action == "down", x: x, y: y)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .action, in: values, debugDescription: "Unsupported pointer action"
                )
            }

        case "wheel":
            let x = try Self.coordinate(.x, from: values)
            let y = try Self.coordinate(.y, from: values)
            let dx = try values.decode(Double.self, forKey: .deltaX)
            let dy = try values.decode(Double.self, forKey: .deltaY)
            guard dx.isFinite, dy.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deltaY, in: values, debugDescription: "Wheel deltas must be finite"
                )
            }
            self = .scroll(x: x, y: y, deltaX: dx, deltaY: dy)

        case "key":
            let action = try values.decode(String.self, forKey: .action)
            guard action == "down" || action == "up" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .action, in: values, debugDescription: "Unsupported key action"
                )
            }
            let browserCode = try values.decode(String.self, forKey: .code)
            guard let code = Self.keyCodes[browserCode] else {
                throw DecodingError.dataCorruptedError(
                    forKey: .code, in: values, debugDescription: "Unsupported keyboard code"
                )
            }
            _ = try values.decodeIfPresent(String.self, forKey: .key)
            let repeatKey = try values.decodeIfPresent(Bool.self, forKey: .isRepeat) ?? false
            let modifiers = try values.decodeIfPresent(BrowserModifiers.self, forKey: .modifiers)
                ?? BrowserModifiers()
            self = .key(code: code, down: action == "down", isRepeat: repeatKey, modifiers: modifiers.cgFlags)

        case "text":
            let text = try values.decode(String.self, forKey: .text)
            guard !text.isEmpty, text.utf8.count <= 1_024, text.count <= 256,
                  text.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\n" || $0 == "\t" }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .text, in: values, debugDescription: "Text input is empty, too long, or contains controls"
                )
            }
            self = .text(text)

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: values, debugDescription: "Unsupported remote input type"
            )
        }
    }

    private static func coordinate(
        _ key: CodingKeys,
        from values: KeyedDecodingContainer<CodingKeys>
    ) throws -> Double {
        let value = try values.decode(Double.self, forKey: key)
        guard value.isFinite, (0...1).contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: values, debugDescription: "Pointer coordinates must be between 0 and 1"
            )
        }
        return value
    }

    private static func button(from values: KeyedDecodingContainer<CodingKeys>) throws -> RemoteDesktopMouseButton {
        if let number = try? values.decode(Int.self, forKey: .button) {
            switch number {
            case 0: return .left
            case 1: return .middle
            case 2: return .right
            default: break
            }
        }
        if let name = try? values.decode(String.self, forKey: .button) {
            switch name {
            case "left": return .left
            case "middle": return .middle
            case "right": return .right
            default: break
            }
        }
        throw DecodingError.dataCorruptedError(
            forKey: .button, in: values, debugDescription: "Unsupported mouse button"
        )
    }

    /// Browser `KeyboardEvent.code` names describe physical key positions. These are the
    /// matching macOS virtual keycodes for the common ANSI keyboard and navigation keys.
    private static let keyCodes: [String: UInt16] = [
        "KeyA": 0, "KeyB": 11, "KeyC": 8, "KeyD": 2, "KeyE": 14, "KeyF": 3,
        "KeyG": 5, "KeyH": 4, "KeyI": 34, "KeyJ": 38, "KeyK": 40, "KeyL": 37,
        "KeyM": 46, "KeyN": 45, "KeyO": 31, "KeyP": 35, "KeyQ": 12, "KeyR": 15,
        "KeyS": 1, "KeyT": 17, "KeyU": 32, "KeyV": 9, "KeyW": 13, "KeyX": 7,
        "KeyY": 16, "KeyZ": 6,
        "Digit0": 29, "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21,
        "Digit5": 23, "Digit6": 22, "Digit7": 26, "Digit8": 28, "Digit9": 25,
        "Backquote": 50, "Minus": 27, "Equal": 24, "BracketLeft": 33,
        "BracketRight": 30, "Backslash": 42, "Semicolon": 41, "Quote": 39,
        "Comma": 43, "Period": 47, "Slash": 44, "IntlBackslash": 10,
        "Space": 49, "Tab": 48, "Enter": 36, "Backspace": 51, "Escape": 53,
        "Delete": 117, "Home": 115, "End": 119,
        "PageUp": 116, "PageDown": 121, "ArrowLeft": 123, "ArrowRight": 124,
        "ArrowDown": 125, "ArrowUp": 126,
        "ShiftLeft": 56, "ShiftRight": 60, "ControlLeft": 59, "ControlRight": 62,
        "AltLeft": 58, "AltRight": 61, "MetaLeft": 55, "MetaRight": 54,
        "CapsLock": 57, "F1": 122, "F2": 120, "F3": 99, "F4": 118,
        "F5": 96, "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109,
        "F11": 103, "F12": 111,
        "Numpad0": 82, "Numpad1": 83, "Numpad2": 84, "Numpad3": 85,
        "Numpad4": 86, "Numpad5": 87, "Numpad6": 88, "Numpad7": 89,
        "Numpad8": 91, "Numpad9": 92, "NumpadDecimal": 65,
        "NumpadMultiply": 67, "NumpadAdd": 69, "NumpadDivide": 75,
        "NumpadEnter": 76, "NumpadSubtract": 78,
    ]
}

enum RemoteDesktopMouseButton: Hashable {
    case left
    case right
    case middle

    var cgButton: CGMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .middle: .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .middle: .otherMouseUp
        }
    }
}

/// Runs only after the host has checked its local enablement, controller approval, active
/// capture, and Accessibility trust. Tracks held input so disconnect can release it promptly.
final class RemoteDesktopInputInjector {
    private var heldKeys: [UInt16: CGEventFlags] = [:]
    private var heldButtons: [RemoteDesktopMouseButton: CGPoint] = [:]
    private var lastPointer: CGPoint = .zero

    func inject(_ input: RemoteDesktopInputEvent, displayID: CGDirectDisplayID) throws {
        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else { throw RemoteDesktopHostError.displayUnavailable }

        switch input {
        case .mouseMove(let x, let y):
            let point = try displayPoint(x: x, y: y, bounds: bounds)
            let dragButton: RemoteDesktopMouseButton? =
                heldButtons[.left] != nil ? .left :
                heldButtons[.right] != nil ? .right :
                heldButtons[.middle] != nil ? .middle : nil
            let type: CGEventType
            switch dragButton {
            case .left: type = .leftMouseDragged
            case .right: type = .rightMouseDragged
            case .middle: type = .otherMouseDragged
            case nil: type = .mouseMoved
            }
            try postMouse(type: type, button: dragButton ?? .left, point: point)
            lastPointer = point

        case .mouseButton(let button, let down, let x, let y):
            let point = try displayPoint(x: x, y: y, bounds: bounds)
            try postMouse(type: down ? button.downType : button.upType, button: button, point: point)
            if down { heldButtons[button] = point } else { heldButtons.removeValue(forKey: button) }
            lastPointer = point

        case .scroll(let x, let y, let deltaX, let deltaY):
            let point = try displayPoint(x: x, y: y, bounds: bounds)
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Self.clampedScroll(deltaY),
                wheel2: Self.clampedScroll(deltaX),
                wheel3: 0
            ) else { throw RemoteDesktopHostError.inputUnavailable }
            event.location = point
            event.post(tap: .cghidEventTap)
            lastPointer = point

        case .key(let code, let down, let isRepeat, let modifiers):
            let flags = Self.allowedFlags(modifiers)
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            else { throw RemoteDesktopHostError.inputUnavailable }
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: down && isRepeat ? 1 : 0)
            event.post(tap: .cghidEventTap)
            if down { heldKeys[code] = flags } else { heldKeys.removeValue(forKey: code) }

        case .text(let text):
            guard !text.isEmpty, text.utf8.count <= 1_024, text.count <= 256,
                  text.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\n" || $0 == "\t" }) else {
                throw RemoteDesktopHostError.invalidInput
            }
            let characters = text.map { Array(String($0).utf16) }
            guard characters.allSatisfy({ $0.count <= 20 }) else {
                throw RemoteDesktopHostError.invalidInput
            }
            // A Unicode CGEvent inserts committed text, including composed Korean text,
            // without guessing physical keycodes or the receiving app's keyboard layout.
            releaseAllInput()
            for units in characters {
                try postUnicode(units)
            }
        }
    }

    func releaseAllInput() {
        defer {
            heldKeys.removeAll()
            heldButtons.removeAll()
        }
        guard AXIsProcessTrusted() else { return }
        for (code, flags) in heldKeys {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        for (button, _) in heldButtons {
            CGEvent(
                mouseEventSource: nil,
                mouseType: button.upType,
                mouseCursorPosition: lastPointer,
                mouseButton: button.cgButton
            )?.post(tap: .cghidEventTap)
        }
    }

    private func postMouse(type: CGEventType, button: RemoteDesktopMouseButton, point: CGPoint) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button.cgButton
        ) else { throw RemoteDesktopHostError.inputUnavailable }
        event.post(tap: .cghidEventTap)
    }

    private func postUnicode(_ units: [UInt16]) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw RemoteDesktopHostError.inputUnavailable
        }
        units.withUnsafeBufferPointer { buffer in
            guard let address = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func displayPoint(x: Double, y: Double, bounds: CGRect) throws -> CGPoint {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw RemoteDesktopHostError.invalidInput
        }
        return CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
    }

    private static func clampedScroll(_ value: Double) -> Int32 {
        Int32(max(-120, min(120, value)).rounded())
    }

    private static func allowedFlags(_ raw: UInt64) -> CGEventFlags {
        let allowed = CGEventFlags.maskAlphaShift.rawValue
            | CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskNumericPad.rawValue
            | CGEventFlags.maskSecondaryFn.rawValue
        return CGEventFlags(rawValue: raw & allowed)
    }
}
#endif
