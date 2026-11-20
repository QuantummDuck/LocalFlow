import AppKit
import ServiceManagement
import SwiftUI

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    let model = AppModel()
    var statusItem: NSStatusItem!
    var hub: NSWindow?
    var scratchpad: NSPanel?

    func applicationDidFinishLaunching(_ note: Notification) {
        Fonts.register()
        applyTheme()
        applyDockPolicy()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "LocalFlow")
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        model.onScratchpad = { [weak self] in self?.toggleScratchpad(nil) }
        model.refreshPermissions()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshPermissions() }
        }
        if !model.settings.p.onboarded || !model.axOK || !model.micOK { openHub() }
        // Test hook: a distributed notification carrying a WAV path runs the full pipeline (no mic).
        DistributedNotificationCenter.default().addObserver(forName: .init("local.flow.test"), object: nil, queue: .main) { [weak self] n in
            guard let path = n.object as? String else { return }
            MainActor.assumeIsolated { self?.model.testFile(path) }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("local.flow.test.command"), object: nil, queue: .main) { [weak self] n in
            guard let path = n.object as? String else { return }
            MainActor.assumeIsolated { self?.model.testFile(path, mode: .command) }
        }
        Task { await model.loadModels() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { openHub(); return true }

    func applyDockPolicy() { NSApp.setActivationPolicy(model.settings.p.showInDock ? .regular : .accessory) }

    /// Light (Wispr's default), dark, or follow the system.
    func applyTheme() {
        switch model.settings.p.theme {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    func openHub() {
        if hub == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1350, height: 850),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "LocalFlow"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 900, height: 600)
            w.backgroundColor = NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x1A1A19) : NSColor(hex: 0xF7F6F3) }
            w.contentView = NSHostingView(rootView: HubView(openScratchpad: { [weak self] id in self?.toggleScratchpad(id) },
                                                            dockChanged: { [weak self] in self?.applyDockPolicy() },
                                                            themeChanged: { [weak self] in self?.applyTheme() })
                .environment(model))
            w.center()
            w.setFrameAutosaveName("Hub2")
            hub = w
        }
        NSApp.activate(ignoringOtherApps: true)
        hub?.makeKeyAndOrderFront(nil)
    }

    /// Floating notepad (⌥S). Dictating into it works like any other app.
    func toggleScratchpad(_ note: UUID?) {
        if note == nil, let s = scratchpad, s.isVisible, s.isKeyWindow { s.orderOut(nil); return }
        model.scratchNote = note
        if scratchpad == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
            p.title = "Scratchpad"
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: ScratchpadView().environment(model))
            if let f = NSScreen.main?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.maxX - 450, y: f.maxY - 500)) }
            p.setFrameAutosaveName("Scratchpad")
            scratchpad = p
        }
        NSApp.activate(ignoringOtherApps: true)
        scratchpad?.makeKeyAndOrderFront(nil)
    }

    // MARK: menu bar

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        m.addItem(withTitle: "LocalFlow — \(model.status)", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(.separator())
        m.addItem(withTitle: "Open LocalFlow…", action: #selector(openHubAction), keyEquivalent: "")
        m.addItem(withTitle: "Scratchpad", action: #selector(scratchpadAction), keyEquivalent: "")
        m.addItem(withTitle: "Paste last transcript", action: #selector(pasteLastAction), keyEquivalent: "")
        m.addItem(withTitle: "Copy last transcript", action: #selector(copyLastAction), keyEquivalent: "")
        m.addItem(.separator())
        let c = m.addItem(withTitle: "AI cleanup", action: #selector(toggleCleanup), keyEquivalent: "")
        c.state = model.settings.p.cleanup == .none ? .off : .on
        m.addItem(.separator())
        m.addItem(withTitle: "Quit LocalFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
    }

    @objc func openHubAction() { openHub() }
    @objc func scratchpadAction() { toggleScratchpad(nil) }
    @objc func pasteLastAction() { model.pasteLast() }
    @objc func copyLastAction() { model.copyLast() }
    @objc func toggleCleanup() { model.settings.p.cleanup = model.settings.p.cleanup == .none ? .light : .none }
}
