import AppKit
import AVFoundation
import CoreAudio
import FluidAudio

// MARK: microphone

/// Mic capture at the device rate, resampled to 16 kHz mono once at the end.
final class Recorder {
    private var engine = AVAudioEngine()
    private var buffer: [Float] = []
    private var rate: Double = 48000
    private let lock = NSLock()
    private(set) var level: Float = 0
    private(set) var running = false

    func start(deviceUID: String?) throws {
        lock.lock(); buffer.removeAll(keepingCapacity: true); lock.unlock()
        engine = AVAudioEngine()  // fresh engine: a reused one breaks when the input device changes
        let input = engine.inputNode
        if let uid = deviceUID, var dev = AudioDevices.id(uid), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NSError(domain: "mic", code: 1) }
        rate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let p = UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))
            self.lock.lock(); self.buffer.append(contentsOf: p); self.lock.unlock()
            self.level = Self.rms(Array(p))
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() -> [Float] {
        guard running else { return [] }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); let raw = buffer; lock.unlock()
        level = 0
        return (try? AudioConverter().resample(raw, from: rate)) ?? []
    }

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    /// Whisper mode: lift quiet recordings to a normal level (gain capped at 20×).
    static func normalized(_ x: [Float]) -> [Float] {
        let peak = x.reduce(0) { max($0, abs($1)) }
        guard peak > 0.0005, peak < 0.3 else { return x }
        let g = min(20, 0.5 / peak)
        return x.map { $0 * g }
    }
}

enum AudioDevices {
    private static func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ empty: T) -> T {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v = empty, size = UInt32(MemoryLayout<T>.size)
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v)
        return v
    }

    /// (uid, name) of every device with input channels.
    static func inputs() -> [(uid: String, name: String)] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s)
            guard s > 0 else { return nil }
            let uid = prop(id, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, "" as CFString) as String
            let name = prop(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, "" as CFString) as String
            return uid.isEmpty ? nil : (uid, name)
        }
    }

    static func id(_ uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString, dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &dev)
        }
        return st == noErr && dev != 0 ? dev : nil
    }

    /// Mute the default output; returns true if we changed it (so we know to restore it).
    static func setOutputMuted(_ mute: Bool) -> Bool {
        let out: AudioDeviceID = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        guard out != 0, AudioObjectHasProperty(out, &addr) else { return false }
        let was: UInt32 = prop(out, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(0))
        guard (was != 0) != mute else { return false }
        var v: UInt32 = mute ? 1 : 0
        return AudioObjectSetPropertyData(out, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }
}

@MainActor enum Sounds {
    static func play(_ name: String) {
        guard Settings.shared.p.sounds, let s = NSSound(named: name)?.copy() as? NSSound else { return }
        s.volume = 0.25
        s.play()
    }
}

// MARK: context

struct AppInfo: @unchecked Sendable {
    var name = "", bundleID = ""
    var url: String?               // browser: the site's host
    var textBefore = ""            // up to 2,000 characters left of the cursor
    var selected = ""
    var selectionKnown = false     // the app told us its selection (so "" really means nothing selected)
    var element: AXUIElement?
    var location: Int?             // selection start, UTF-16
    var names: [String] = []       // identifiers and names near the cursor
    var charBefore: Character? { textBefore.last }
    var key: String { "\(bundleID) \(name) \(url ?? "")" }
}

enum Context {
    static let browsers = ["chrome", "safari", "arc", "brave", "edge", "firefox", "zen", "opera", "vivaldi", "dia", "comet", "orion"]

    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func range(_ e: AXUIElement) -> CFRange? {
        guard let v = attr(e, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    /// Everything we read through Accessibility at the start of a dictation. Safe off the main thread.
    static func capture(deep: Bool = true) -> AppInfo {
        let app = NSWorkspace.shared.frontmostApplication
        var info = AppInfo(name: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "")
        guard let pid = app?.processIdentifier else { return info }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.15)
        // Electron/Chromium apps only build their AX tree when asked.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let f = attr(appEl, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return info }
        let el = f as! AXUIElement
        info.element = el
        if let s = attr(el, kAXSelectedTextAttribute) as? String { info.selected = s; info.selectionKnown = true }
        if let r = range(el) {
            info.location = r.location
            if let value = attr(el, kAXValueAttribute) as? String {
                let u = Array(value.utf16), end = min(max(r.location, 0), u.count)
                info.textBefore = slice(u, end - 2000, end)
                if deep { info.names = names(slice(u, end - 4000, end + 1000)) }
            }
        }
        if deep, browsers.contains(where: info.bundleID.lowercased().contains) { info.url = site(el, appEl) }
        return info
    }

    /// UTF-16 units [a, b) clamped to the buffer.
    static func slice(_ u: [UInt16], _ a: Int, _ b: Int) -> String {
        let a = max(0, min(a, u.count)), b = max(a, min(b, u.count))
        return String(utf16CodeUnits: Array(u[a..<b]), count: b - a)
    }

    /// The page's host, from the web area above the focused element (or the window's document).
    static func site(_ el: AXUIElement, _ appEl: AXUIElement) -> String? {
        var cur: AXUIElement? = el
        for _ in 0..<30 {
            guard let c = cur else { break }
            if attr(c, kAXRoleAttribute) as? String == "AXWebArea", let u = attr(c, "AXURL") {
                if CFGetTypeID(u) == CFURLGetTypeID() { return (u as! URL).host }
            }
            cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        if let w = attr(appEl, kAXFocusedWindowAttribute), let doc = attr(w as! AXUIElement, kAXDocumentAttribute) as? String {
            return URL(string: doc)?.host
        }
        return nil
    }

    /// camelCase / snake_case identifiers, file names and capitalized names in the text around the cursor,
    /// nearest last, so the cleanup model spells them the way they appear on screen.
    static func names(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "\\b([a-z]+[A-Z][A-Za-z0-9]*|[A-Za-z0-9]+_[A-Za-z0-9_]+|[\\w-]+\\.(?:swift|py|ts|tsx|js|jsx|md|json|yml|yaml|rs|go|java|kt|css|html|sh)|(?<=[a-z,] )[A-Z][a-z]{3,})\\b")
        var seen: [String] = []
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            let w = String(s[r])
            seen.removeAll { $0 == w }; seen.append(w)
        }
        return Array(seen.suffix(12))
    }
}

// MARK: inserting text

enum Inserter {
    /// Add a leading space when continuing after a word or sentence.
    static func spaced(_ text: String, after c: Character?) -> String {
        guard let c, !c.isWhitespace, !"([{\"'“‘/@#".contains(c), let f = text.first, !f.isWhitespace, !",.;:!?)".contains(f) else { return text }
        return " " + text
    }

    /// Continuing mid-sentence (after a letter or comma): don't start with a capital.
    static func matchCase(_ text: String, before: String, keep: Set<String>) -> String {
        guard let prev = before.last(where: { !$0.isWhitespace }), prev.isLetter || prev.isNumber || ",;:".contains(prev),
              before.last != "\n", let first = text.split(separator: " ").first.map(String.init) else { return text }
        let w = first.trimmingCharacters(in: .punctuationCharacters)
        guard w.count > 0, w.first!.isUppercase, w != "I", !w.hasPrefix("I'"), !w.hasPrefix("I’"),
              !(w.count > 1 && w == w.uppercased()), !keep.contains(w) else { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// ⌘ and ⇧ held don't change what ⌘V does; ⌥, ⌃ and fn do (⌥⌘V moves files, ⌃⌘V is our own shortcut).
    static func modifiersDown() -> Bool {
        !CGEventSource.flagsState(.combinedSessionState).intersection([.maskAlternate, .maskControl, .maskSecondaryFn]).isEmpty
    }

    /// Wait (≤ 1 s) for the user to let go of ⌥/⌃/fn after a shortcut.
    static func waitForKeysUp() async {
        for _ in 0..<20 where modifiersDown() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Paste via the clipboard, then restore what was there (unless something else wrote it meanwhile).
    @MainActor static func paste(_ text: String) async {
        await waitForKeysUp()
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ours = pb.changeCount
        key(9, flags: .maskCommand)  // ⌘V
        // ponytail: fixed restore delay; per-app delays (remote desktop, Office) if pastes go missing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.changeCount == ours else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }

    /// Selected text via ⌘C, for apps that don't expose their selection to Accessibility. Clipboard restored.
    @MainActor static func copySelection() async -> String? {
        await waitForKeysUp()
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        let before = pb.changeCount
        key(8, flags: .maskCommand)  // ⌘C
        for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(40)); if pb.changeCount != before { break } }
        guard pb.changeCount != before else { return nil }
        let s = pb.string(forType: .string)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        return s
    }

    /// Select the whole field (for a transform with no selection).
    static func selectAll(_ el: AXUIElement) -> String? {
        guard let s = Context.attr(el, kAXValueAttribute) as? String, !s.isEmpty else { return nil }
        var r = CFRange(location: 0, length: s.utf16.count)
        guard let v = AXValueCreate(.cfRange, &r),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success else { return nil }
        return s
    }
}
