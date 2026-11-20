import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key combination: modifiers only (held, like fn) or modifiers + one key (pressed, like ⌃⌘V).
struct Shortcut: Codable, Hashable {
    var mods: UInt64
    var key: UInt16?

    static let fn = CGEventFlags.maskSecondaryFn.rawValue, ctrl = CGEventFlags.maskControl.rawValue,
               opt = CGEventFlags.maskAlternate.rawValue, cmd = CGEventFlags.maskCommand.rawValue,
               shift = CGEventFlags.maskShift.rawValue
    static let mask = fn | ctrl | opt | cmd | shift

    static let defaults: [String: Shortcut] = [
        "ptt": Shortcut(mods: fn),
        "handsFree": Shortcut(mods: fn, key: UInt16(kVK_Space)),
        "command": Shortcut(mods: fn | ctrl),
        "pasteLast": Shortcut(mods: ctrl | cmd, key: UInt16(kVK_ANSI_V)),
        "copyLast": Shortcut(mods: ctrl | cmd, key: UInt16(kVK_ANSI_C)),
        "scratchpad": Shortcut(mods: opt, key: UInt16(kVK_ANSI_S)),
        "polish": Shortcut(mods: opt, key: UInt16(kVK_ANSI_1)),
        "promptEngineer": Shortcut(mods: opt, key: UInt16(kVK_ANSI_2)),
    ]
    static let titles: [(String, String)] = [
        ("ptt", "Push to talk"), ("handsFree", "Hands-free mode"), ("command", "Command Mode"),
        ("pasteLast", "Paste last transcript"), ("copyLast", "Copy last transcript"), ("scratchpad", "Open Scratchpad"),
        ("polish", "Polish"), ("promptEngineer", "Prompt Engineer"),
    ]

    var display: String {
        var s = ""
        if mods & Self.fn != 0 { s += "fn " }
        if mods & Self.ctrl != 0 { s += "⌃" }
        if mods & Self.opt != 0 { s += "⌥" }
        if mods & Self.shift != 0 { s += "⇧" }
        if mods & Self.cmd != 0 { s += "⌘" }
        if let key { s += Self.name(key) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func name(_ k: UInt16) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "Esc",
                                      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                      kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let s = special[Int(k)] { return s }
        // letter/number per the current keyboard layout
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(k)" }
        let layout = unsafeBitCast(ptr, to: CFData.self)
        var dead: UInt32 = 0, len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let ok = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, k, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                           &dead, 4, &len, &chars)
        }
        return ok == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(k)"
    }

    /// Why this can't be a shortcut, or nil if it's fine.
    var problem: String? {
        let n = [Self.fn, Self.ctrl, Self.opt, Self.cmd, Self.shift].filter { mods & $0 != 0 }.count
        if n == 0 { return "Shortcut must include a modifier key" }
        if n + (key == nil ? 0 : 1) > 3 { return "Shortcut must contain 3 or fewer keys" }
        if key == nil, mods == Self.cmd || mods == Self.shift { return "⌘ or ⇧ alone would break normal typing" }
        if let key, mods & ~Self.shift == Self.cmd {
            let reserved: Set<Int> = [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A, kVK_ANSI_Q, kVK_ANSI_W, kVK_Tab,
                                      kVK_Space, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_S, kVK_ANSI_T,
                                      kVK_ANSI_F, kVK_ANSI_R, kVK_ANSI_G, kVK_ANSI_B, kVK_ANSI_I, kVK_ANSI_U, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
            if reserved.contains(Int(key)) { return "This shortcut is reserved by macOS" }
        }
        return nil
    }
}

/// System-wide key tap. Hold shortcuts report press/release; key shortcuts report press and are swallowed
/// so they don't also type a character. Needs Accessibility.
final class HotkeyEngine {
    var bindings: [(Shortcut, String)] = []
    var onPress: (String) -> Void = { _ in }
    var onRelease: (String) -> Void = { _ in }
    var onOtherKey: () -> Void = {}          // a normal key while a hold shortcut is down (fn+arrow, ⌥+letter…)
    var onEscape: () -> Bool = { false }     // true = we used it (cancel), swallow it
    var paused = false                       // while recording a new shortcut in Settings
    private var tap: CFMachPort?
    private var held: (id: String, mods: UInt64)?
    private var swallowed = Set<Int64>()

    init?() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ref in
            let me = Unmanaged<HotkeyEngine>.fromOpaque(ref!).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit { if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) } }

    static let fnKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 115, 119, 116, 121, 117, 123, 124, 125, 126]

    private func holdBinding(_ mods: UInt64) -> String? {
        mods == 0 ? nil : bindings.first { $0.0.key == nil && $0.0.mods == mods }?.1
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if paused { return pass }
        let mods = event.flags.rawValue & Shortcut.mask
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .flagsChanged:
            if let h = held {
                if mods & h.mods != h.mods { held = nil; onRelease(h.id) }                       // let go
                else if mods != h.mods, let up = holdBinding(mods) { held = (up, mods); onPress(up) }  // fn → fn+⌃
            } else if let id = holdBinding(mods) { held = (id, mods); onPress(id) }
            return pass
        case .keyDown:
            if key == Int64(kVK_Escape), mods == 0, onEscape() { swallowed.insert(key); return nil }
            var m = mods
            if Self.fnKeys.contains(key) { m &= ~Shortcut.fn }  // arrows, F-keys, Home/End carry the fn flag on their own
            if let b = bindings.first(where: { $0.0.key.map(Int64.init) == key && $0.0.mods == m }) {
                swallowed.insert(key)
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onPress(b.1) }
                return nil
            }
            if held != nil { onOtherKey() }
            return pass
        case .keyUp:
            return swallowed.remove(key) != nil ? nil : pass
        default:
            return pass
        }
    }
}

/// Click, then press the new combination. Modifier-only shortcuts save when you let go.
struct ShortcutField: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var recording = false
    @State private var monitor: Any?
    @State private var maxMods: UInt64 = 0
    @State private var error: String?

    var current: Shortcut? {
        id.hasPrefix("t:") ? model.settings.p.transforms.first { "t:\($0.id)" == id }?.shortcut : model.settings.p.shortcuts[id]
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button { recording ? stop() : start() } label: {
                HStack(spacing: 4) {
                    if recording {
                        if maxMods == 0 { Text("Press keys…").font(.ui(13.5, .medium)).foregroundStyle(T.purple) }
                        else { ForEach(Shortcut(mods: maxMods).parts, id: \.self) { Keycap(text: $0) } }
                    } else if let c = current {
                        ForEach(c.parts, id: \.self) { Keycap(text: $0) }
                    } else {
                        Text("Click to add a shortcut").font(.ui(13.5)).foregroundStyle(T.text3)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: recording ? "xmark" : "pencil").font(.system(size: 12)).foregroundStyle(T.text2)
                }
                .padding(.horizontal, 10).frame(width: 200, height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(T.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(recording ? T.ink : T.line, lineWidth: recording ? 1.5 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let error { Text(error).font(.ui(12)).foregroundStyle(.red).frame(width: 200, alignment: .trailing) }
        }
        .onDisappear { stop() }
    }

    func start() {
        error = nil; maxMods = 0; recording = true
        model.engine?.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { e in
            let m = Self.mods(e.modifierFlags)
            if e.type == .flagsChanged {
                maxMods |= m
                if m == 0, maxMods != 0 { finish(Shortcut(mods: maxMods)) }
            } else {
                if e.keyCode == UInt16(kVK_Escape), m == 0 { stop() } else { finish(Shortcut(mods: m, key: e.keyCode)) }
            }
            return nil
        }
    }

    func finish(_ s: Shortcut) {
        if let p = s.problem { error = p }
        else if let other = model.shortcutOwner(s), other != id { error = "Already used by \(other)" }
        else { model.setShortcut(id, s) }
        stop()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false
        model.engine?.paused = false
    }

    static func mods(_ f: NSEvent.ModifierFlags) -> UInt64 {
        var m: UInt64 = 0
        if f.contains(.function) { m |= Shortcut.fn }
        if f.contains(.control) { m |= Shortcut.ctrl }
        if f.contains(.option) { m |= Shortcut.opt }
        if f.contains(.command) { m |= Shortcut.cmd }
        if f.contains(.shift) { m |= Shortcut.shift }
        return m
    }
}
