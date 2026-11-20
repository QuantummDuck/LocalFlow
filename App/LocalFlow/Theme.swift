import AppKit
import CoreText
import SwiftUI

// Design tokens measured from the Wispr Flow hub (light), with a matching dark variant.

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light) })
    }
}

enum T {
    static let bg = Color.dyn(0xF7F6F3, 0x1A1A19)        // window + sidebar
    static let panel = Color.dyn(0xFCFCFC, 0x222221)     // big content panel
    static let card = Color.dyn(0xFFFFFF, 0x282826)      // white list cards inside the panel
    static let tile = Color.dyn(0xF7F6F3, 0x2B2B29)      // grey tiles (stats, settings groups)
    static let line = Color.dyn(0xEBE9E4, 0x363634)
    static let hover = Color.dyn(0xF5F4F1, 0x2F2F2D)
    static let navSel = Color.dyn(0xEDEBE6, 0x2D2D2B)
    static let text = Color.dyn(0x1F1F1E, 0xEDECE9)
    static let text2 = Color.dyn(0x6F6D68, 0xA4A29C)
    static let text3 = Color.dyn(0x9E9C96, 0x77756F)
    static let ink = Color.dyn(0x222222, 0xF0EFEC)       // black buttons/toggles (light buttons in dark mode)
    static let onInk = Color.dyn(0xFFFFFF, 0x1A1A19)
    static let soft = Color.dyn(0xEFEDE8, 0x353533)      // grey buttons
    static let toggleOff = Color.dyn(0xE2DFD9, 0x45453F)
    static let teal = Color.dyn(0x2F6B66, 0x6FB5AC)
    static let teal2 = Color.dyn(0x65A198, 0x4A8984)
    static let teal3 = Color.dyn(0xA2D4CC, 0x2F5F59)
    static let teal4 = Color.dyn(0xDBF0EE, 0x24413E)
    static let empty = Color.dyn(0xE7E4DE, 0x31312F)
    static let lavender = Color.dyn(0xF2ECF5, 0x2F2A36)
    static let purple = Color.dyn(0x8A5CC2, 0xC2A3EA)
    static let badge = Color.dyn(0xEADFF4, 0x3B3148)
}

extension Font {
    enum W: String { case regular = "Regular", medium = "Medium", semibold = "SemiBold", bold = "Bold" }
    /// Figtree, the interface face.
    static func ui(_ size: CGFloat, _ w: W = .regular, italic: Bool = false) -> Font {
        .custom(italic ? (w == .regular ? "Figtree-Italic" : "Figtree-\(w.rawValue)Italic") : "Figtree-\(w.rawValue)", size: size)
    }
    /// EB Garamond, for headlines and big numbers.
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font { .custom(italic ? "EBGaramond-Italic" : "EBGaramond-Regular", size: size) }
}

enum Fonts {
    static func register() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: building blocks

struct UpperLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text.uppercased()).font(.ui(12, .medium)).tracking(1.1).foregroundStyle(T.text2) }
}

struct InkButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) { self.title = title; self.icon = icon; self.action = action }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.ui(14.5, .medium))
            }
            .foregroundStyle(T.onInk).padding(.horizontal, 16).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.ink))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct SoftButton: View {
    let title: String
    var destructive = false
    let action: () -> Void
    init(_ title: String, destructive: Bool = false, action: @escaping () -> Void) { self.title = title; self.destructive = destructive; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(14.5, .medium)).foregroundStyle(destructive ? Color.red : T.text)
                .padding(.horizontal, 16).frame(minWidth: 96).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.soft))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// The light pill used on dark hero banners.
struct HeroButton: View {
    let title: String
    var ghost = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.ui(14.5, .medium)).foregroundStyle(ghost ? .white : Color(nsColor: NSColor(hex: 0x1F1F1E)))
                .padding(.horizontal, 16).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ghost ? Color.white.opacity(0.22) : Color(nsColor: NSColor(hex: 0xF4F2EE))))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct IconButton: View {
    let icon: String
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .regular)).foregroundStyle(T.text2).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }
}

struct Badge: View {
    let text: String
    var dark = false
    var body: some View {
        Text(text).font(.ui(11.5, .semibold)).foregroundStyle(dark ? T.onInk : T.purple)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(dark ? T.ink : T.badge))
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.ui(12.5, .medium)).foregroundStyle(T.text)
            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(T.card))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(T.line))
    }
}

extension Shortcut {
    /// Display parts for keycaps: "fn", "⌃", "⌥ Opt", "Space"…
    var parts: [String] {
        var p: [String] = []
        if mods & Self.fn != 0 { p.append("fn") }
        if mods & Self.ctrl != 0 { p.append("⌃ Ctrl") }
        if mods & Self.opt != 0 { p.append("⌥ Opt") }
        if mods & Self.shift != 0 { p.append("⇧ Shift") }
        if mods & Self.cmd != 0 { p.append("⌘ Cmd") }
        if let key { p.append(Self.name(key)) }
        return p
    }
}

struct InkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? T.ink : T.toggleOff).frame(width: 40, height: 24)
                Circle().fill(configuration.isOn ? T.onInk : Color.white).frame(width: 20, height: 20).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .animation(.snappy(duration: 0.18), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

/// Underlined text tabs with a hairline under the whole row.
struct TabBar<Trailing: View>: View {
    let items: [(String, String)]           // (id, title)
    @Binding var selection: String
    var badges: [String: String] = [:]
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ForEach(items, id: \.0) { id, title in
                Button { selection = id } label: {
                    VStack(spacing: 9) {
                        HStack(spacing: 7) {
                            Text(title).font(.ui(15, .medium)).foregroundStyle(selection == id ? T.text : T.text2)
                            if let b = badges[id] { Badge(text: b) }
                        }
                        Rectangle().fill(selection == id ? T.ink : .clear).frame(height: 2)
                    }.fixedSize().contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
            trailing.padding(.bottom, 8)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }
}

extension TabBar where Trailing == EmptyView {
    init(items: [(String, String)], selection: Binding<String>, badges: [String: String] = [:]) {
        self.init(items: items, selection: selection, badges: badges) { EmptyView() }
    }
}

/// Dark banner with a warm abstract backdrop (our own artwork), serif headline and actions.
struct Hero<Actions: View>: View {
    let title: Text
    var subtitle: Text?
    var height: CGFloat = 180
    var onClose: (() -> Void)?
    var art: [Color] = [Color(nsColor: NSColor(hex: 0x0E0C0B)), Color(nsColor: NSColor(hex: 0x2B1E17)), Color(nsColor: NSColor(hex: 0x6E4A30))]
    @ViewBuilder var actions: Actions

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: art, startPoint: .leading, endPoint: .trailing)
            // soft light blooms
            Circle().fill(Color(nsColor: NSColor(hex: 0xE7A86C)).opacity(0.35)).frame(width: 260).blur(radius: 70).offset(x: 520, y: -40)
            Circle().fill(Color(nsColor: NSColor(hex: 0x8DB6C9)).opacity(0.18)).frame(width: 220).blur(radius: 70).offset(x: 680, y: 60)
            VStack(alignment: .leading, spacing: 10) {
                title.font(.serif(33)).foregroundStyle(.white)
                if let subtitle { subtitle.font(.ui(15)).foregroundStyle(.white.opacity(0.86)).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 6)
                HStack(spacing: 10) { actions }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                        .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.2)))
                }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .topTrailing).padding(14)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// White card holding rows separated by hairlines.
struct ListCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.card))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(T.line))
    }
}

struct Tile<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.tile))
    }
}

/// Page scaffold: scrollable, centered column.
struct Page<Content: View>: View {
    var width: CGFloat = 800
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: width, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 38).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var badge: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title).font(.ui(26, .medium)).foregroundStyle(T.text)
            if let badge { Badge(text: badge, dark: true) }
            Spacer()
            trailing
        }.frame(minHeight: 40)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, badge: String? = nil) { self.init(title: title, badge: badge) { EmptyView() } }
}

/// Row with hover background, used in list cards.
struct HoverRow<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hover = false
    var body: some View {
        content(hover)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? T.hover : .clear)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}
