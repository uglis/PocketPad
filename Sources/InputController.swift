import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class InputController {
    private let queue = DispatchQueue(label: "com.xinque.pocketpad.input", qos: .userInteractive)
    private var isDragging = false
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint: CGPoint = .zero
    private var clickState: Int64 = 1
    private var pasteGeneration: Int = 0
    private var savedClipboardItems: [[(NSPasteboard.PasteboardType, Data)]]?

    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Cursor & Mouse

    private func currentCursorPoint() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return point }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        // If point already lies inside any display, return directly.
        for id in displays {
            let rect = CGDisplayBounds(id)
            if rect.contains(point) {
                return point
            }
        }

        // Otherwise clamp to the nearest display bounds.
        var bestPoint = point
        var bestDist = CGFloat.greatestFiniteMagnitude
        for id in displays {
            let rect = CGDisplayBounds(id)
            let cx = min(max(point.x, rect.minX), rect.maxX - 1)
            let cy = min(max(point.y, rect.minY), rect.maxY - 1)
            let candidate = CGPoint(x: cx, y: cy)
            let dist = hypot(candidate.x - point.x, candidate.y - point.y)
            if dist < bestDist {
                bestDist = dist
                bestPoint = candidate
            }
        }
        return bestPoint
    }

    func moveBy(dx: Double, dy: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            let cur = self.currentCursorPoint()
            let next = self.clampToDisplays(CGPoint(x: cur.x + dx, y: cur.y + dy))
            let type: CGEventType = self.isDragging ? .leftMouseDragged : .mouseMoved
            if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: next, mouseButton: .left) {
                event.setDoubleValueField(.mouseEventDeltaX, value: dx)
                event.setDoubleValueField(.mouseEventDeltaY, value: dy)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    func click(button: String = "left", count: Int? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let pos = self.currentCursorPoint()
            let now = Date().timeIntervalSinceReferenceDate

            if button == "right" {
                self.postMouseEvent(type: .rightMouseDown, button: .right, at: pos, clickState: 1)
                self.postMouseEvent(type: .rightMouseUp, button: .right, at: pos, clickState: 1)
                return
            }

            // Release drag if active before performing a normal click
            if self.isDragging {
                self.isDragging = false
                self.postMouseEvent(type: .leftMouseUp, button: .left, at: pos, clickState: 1)
                return
            }

            if let explicitCount = count {
                for step in 1...max(1, min(explicitCount, 3)) {
                    self.postMouseEvent(type: .leftMouseDown, button: .left, at: pos, clickState: Int64(step))
                    self.postMouseEvent(type: .leftMouseUp, button: .left, at: pos, clickState: Int64(step))
                }
                self.lastClickTime = now
                self.lastClickPoint = pos
                self.clickState = Int64(explicitCount)
                return
            }

            let dt = now - self.lastClickTime
            let dist = hypot(pos.x - self.lastClickPoint.x, pos.y - self.lastClickPoint.y)
            if dt < 0.38 && dist < 8.0 {
                self.clickState = min(self.clickState + 1, 3)
            } else {
                self.clickState = 1
            }
            self.lastClickTime = now
            self.lastClickPoint = pos

            self.postMouseEvent(type: .leftMouseDown, button: .left, at: pos, clickState: self.clickState)
            self.postMouseEvent(type: .leftMouseUp, button: .left, at: pos, clickState: self.clickState)
        }
    }

    func mouseDown(button: String = "left") {
        queue.async { [weak self] in
            guard let self else { return }
            let pos = self.currentCursorPoint()
            if button == "right" {
                self.postMouseEvent(type: .rightMouseDown, button: .right, at: pos, clickState: 1)
            } else {
                self.isDragging = true
                self.postMouseEvent(type: .leftMouseDown, button: .left, at: pos, clickState: 1)
            }
        }
    }

    func mouseUp(button: String = "left") {
        queue.async { [weak self] in
            guard let self else { return }
            let pos = self.currentCursorPoint()
            if button == "right" {
                self.postMouseEvent(type: .rightMouseUp, button: .right, at: pos, clickState: 1)
            } else {
                self.isDragging = false
                self.postMouseEvent(type: .leftMouseUp, button: .left, at: pos, clickState: 1)
            }
        }
    }

    private func postMouseEvent(type: CGEventType, button: CGMouseButton, at point: CGPoint, clickState: Int64) {
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Scrolling

    func scroll(dx: Double, dy: Double) {
        queue.async {
            let wheelY = Int32(max(-500, min(500, Int(dy.rounded()))))
            let wheelX = Int32(max(-500, min(500, Int(dx.rounded()))))
            guard wheelX != 0 || wheelY != 0 else { return }
            if let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: wheelY,
                wheel2: wheelX,
                wheel3: 0
            ) {
                event.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Keyboard & Reliable Chinese/Unicode Text Input

    func typeText(_ text: String, pressEnter: Bool = false) {
        guard !text.isEmpty || pressEnter else { return }
        if text.isEmpty && pressEnter {
            pressKey("enter")
            return
        }

        queue.async { [weak self] in
            guard let self else { return }

            // 1. Save current clipboard & write text on Main Thread
            var expectedChangeCount = 0
            var myGen = 0
            DispatchQueue.main.sync {
                let pb = NSPasteboard.general
                if self.savedClipboardItems == nil {
                    var snapshot: [[(NSPasteboard.PasteboardType, Data)]] = []
                    for item in pb.pasteboardItems ?? [] {
                        var pairs: [(NSPasteboard.PasteboardType, Data)] = []
                        for type in item.types {
                            if let data = item.data(forType: type) {
                                pairs.append((type, data))
                            }
                        }
                        if !pairs.isEmpty { snapshot.append(pairs) }
                    }
                    self.savedClipboardItems = snapshot
                }
                self.pasteGeneration += 1
                myGen = self.pasteGeneration
                pb.clearContents()
                pb.setString(text, forType: .string)
                expectedChangeCount = pb.changeCount
            }

            // 2. Post hardware-faithful Cmd+V (works reliably across Electron, Chrome, WeChat, Chinese IME)
            usleep(20_000)
            self.postKey(code: 9, flags: [.maskCommand]) // Cmd + V

            // 3. Optionally wait for paste commit, then press Return
            if pressEnter {
                usleep(110_000)
                self.postKey(code: 36, flags: []) // Return
            }

            // 4. Restore original clipboard if nothing else modified it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                guard let self, self.pasteGeneration == myGen else { return }
                let pb = NSPasteboard.general
                if pb.changeCount == expectedChangeCount, let snapshot = self.savedClipboardItems {
                    pb.clearContents()
                    if !snapshot.isEmpty {
                        let restoredItems: [NSPasteboardItem] = snapshot.map { pairs in
                            let item = NSPasteboardItem()
                            for (type, data) in pairs {
                                item.setData(data, forType: type)
                            }
                            return item
                        }
                        pb.writeObjects(restoredItems)
                    }
                }
                self.savedClipboardItems = nil
            }
        }
    }

    func pressKey(_ key: String, modifiers: [String] = []) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let keyCode = Self.keyCodeMap[key.lowercased()] else { return }
            var flags: CGEventFlags = []
            for mod in modifiers {
                switch mod.lowercased() {
                case "cmd", "command", "meta": flags.insert(.maskCommand)
                case "opt", "alt", "option": flags.insert(.maskAlternate)
                case "ctrl", "control": flags.insert(.maskControl)
                case "shift": flags.insert(.maskShift)
                default: break
                }
            }
            self.postKey(code: keyCode, flags: flags)
        }
    }

    private func modifierKeyCodes(for flags: CGEventFlags) -> [(CGKeyCode, CGEventFlags)] {
        var result: [(CGKeyCode, CGEventFlags)] = []
        if flags.contains(.maskCommand) { result.append((55, .maskCommand)) }
        if flags.contains(.maskShift) { result.append((56, .maskShift)) }
        if flags.contains(.maskAlternate) { result.append((58, .maskAlternate)) }
        if flags.contains(.maskControl) { result.append((59, .maskControl)) }
        return result
    }

    private func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
        let tap: CGEventTapLocation = .cghidEventTap
        let src = CGEventSource(stateID: .hidSystemState)
        let mods = modifierKeyCodes(for: flags)

        // Press modifier keys down first
        var activeFlags: CGEventFlags = []
        for (modCode, modFlag) in mods {
            activeFlags.insert(modFlag)
            if let md = CGEvent(keyboardEventSource: src, virtualKey: modCode, keyDown: true) {
                md.flags = activeFlags
                md.post(tap: tap)
            }
            usleep(6_000)
        }

        // Press & release target key
        if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
            down.flags = flags
            up.flags = flags
            down.post(tap: tap)
            usleep(12_000)
            up.post(tap: tap)
        }

        // Release modifier keys in reverse order
        for (modCode, modFlag) in mods.reversed() {
            usleep(6_000)
            activeFlags.remove(modFlag)
            if let mu = CGEvent(keyboardEventSource: src, virtualKey: modCode, keyDown: false) {
                mu.flags = activeFlags
                mu.post(tap: tap)
            }
        }
    }

    // MARK: - Hardware Media Keys & System Actions

    func mediaKey(_ name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            switch name.lowercased() {
            case "vol_up": self.postSystemKey(0)           // NX_KEYTYPE_SOUND_UP
            case "vol_down": self.postSystemKey(1)         // NX_KEYTYPE_SOUND_DOWN
            case "brightness_up": self.postSystemKey(2)    // NX_KEYTYPE_BRIGHTNESS_UP
            case "brightness_down": self.postSystemKey(3)  // NX_KEYTYPE_BRIGHTNESS_DOWN
            case "mute": self.postSystemKey(7)             // NX_KEYTYPE_MUTE
            case "play_pause": self.postSystemKey(16)      // NX_KEYTYPE_PLAY
            case "next": self.postSystemKey(17)            // NX_KEYTYPE_NEXT
            case "prev": self.postSystemKey(18)            // NX_KEYTYPE_PREVIOUS
            default: break
            }
        }
    }

    private func postSystemKey(_ keyType: Int) {
        func send(isDown: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xa00 : 0xb00)
            let data1 = (keyType << 16) | ((isDown ? 0xa : 0xb) << 8)
            if let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) {
                event.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        send(isDown: true)
        send(isDown: false)
    }

    private func postControlArrow(code: CGKeyCode) {
        let ctrlCode: CGKeyCode = 59 // Left Control (0x3B)
        let tap: CGEventTapLocation = .cghidEventTap
        let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]

        if let ctrlDown = CGEvent(keyboardEventSource: nil, virtualKey: ctrlCode, keyDown: true) {
            ctrlDown.flags = .maskControl
            ctrlDown.post(tap: tap)
        }
        usleep(12_000)
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) {
            keyDown.flags = arrowFlags
            keyDown.post(tap: tap)
        }
        usleep(12_000)
        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) {
            keyUp.flags = arrowFlags
            keyUp.post(tap: tap)
        }
        usleep(12_000)
        if let ctrlUp = CGEvent(keyboardEventSource: nil, virtualKey: ctrlCode, keyDown: false) {
            ctrlUp.flags = []
            ctrlUp.post(tap: tap)
        }
    }

    private func launchMissionControl(arg: String? = nil) {
        let bin = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        let proc = Process()
        if FileManager.default.isExecutableFile(atPath: bin) {
            proc.executableURL = URL(fileURLWithPath: bin)
            if let arg { proc.arguments = [arg] }
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", "Mission Control"]
        }
        try? proc.run()
    }

    func systemAction(_ action: String) {
        queue.async { [weak self] in
            guard let self else { return }
            switch action.lowercased() {
            case "mission_control":
                self.launchMissionControl()
            case "app_expose":
                self.launchMissionControl(arg: "2")
            case "space_left":
                self.postControlArrow(code: 123) // Ctrl + Left
            case "space_right":
                self.postControlArrow(code: 124) // Ctrl + Right
            case "spotlight":
                self.postKey(code: 49, flags: [.maskCommand])  // Cmd + Space
            case "screenshot":
                self.postKey(code: 21, flags: [.maskCommand, .maskShift]) // Cmd + Shift + 4
            case "lock_screen":
                self.postKey(code: 12, flags: [.maskCommand, .maskControl]) // Ctrl + Cmd + Q
            case "sleep_display":
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                proc.arguments = ["displaysleepnow"]
                try? proc.run()
            case "zoom_in":
                self.postKey(code: 24, flags: [.maskCommand])  // Cmd + =
            case "zoom_out":
                self.postKey(code: 27, flags: [.maskCommand])  // Cmd + -
            case "zoom_reset":
                self.postKey(code: 29, flags: [.maskCommand])  // Cmd + 0
            case "ppt_start":
                self.postKey(code: 35, flags: [.maskCommand, .maskAlternate]) // Keynote Play (Cmd+Opt+P)
            case "ppt_black":
                self.postKey(code: 11, flags: []) // B
            case "ppt_exit":
                self.postKey(code: 53, flags: []) // Esc
            case "release_drag":
                if self.isDragging {
                    self.isDragging = false
                    let pos = self.currentCursorPoint()
                    self.postMouseEvent(type: .leftMouseUp, button: .left, at: pos, clickState: 1)
                }
            default:
                break
            }
        }
    }

    private static let keyCodeMap: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "enter": 36, "return": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50,
        "backspace": 51, "delete": 51,
        "esc": 53, "escape": 53,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f10": 109, "f12": 111,
        "home": 115, "pageup": 116, "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]
}
