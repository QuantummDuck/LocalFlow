import AppKit
import AVFoundation
import FlowCore
import SwiftUI

enum HubPage: String, CaseIterable, Identifiable {
    case dictation, insights, dictionary, snippets, style, transforms, scratchpad
    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var icon: String {
        switch self {
        case .dictation: "mic"
        case .insights: "chart.bar"
        case .dictionary: "doc.text"
        case .snippets: "scissors"
        case .style: "textformat"
        case .transforms: "wand.and.rays"
        case .scratchpad: "square.and.pencil"
        }
    }
}

struct HubView: View {
    let openScratchpad: (UUID?) -> Void
    let dockChanged: () -> Void
    let themeChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var page = HubPage.dictation
    @State private var showSettings = false
    @State private var sidebar = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            T.bg
            if !model.settings.p.onboarded {
                OnboardingView()
            } else {
                HStack(spacing: 0) {
                    if sidebar {
                        Sidebar(page: $page, showSettings: $showSettings).frame(width: 206)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    ZStack { T.panel; content }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(T.line))
                        .padding(.top, 44).padding(.trailing, 10).padding(.bottom, 10).padding(.leading, sidebar ? 0 : 10)
                }
                TopBar(sidebar: $sidebar, themeChanged: themeChanged)
                if showSettings {
                    SettingsModal(close: { withAnimation(.easeOut(duration: 0.15)) { showSettings = false } },
                                  dockChanged: dockChanged, themeChanged: themeChanged)
                        .transition(.opacity)
                }
            }
        }
        .font(.ui(15))
        .foregroundStyle(T.text)
        .tint(T.ink)
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder var content: some View {
        switch page {
        case .dictation: HomeView(go: { page = $0 })
        case .insights: InsightsView()
        case .dictionary: DictionaryView()
        case .snippets: SnippetsView()
        case .style: StyleView()
        case .transforms: TransformsView()
        case .scratchpad: ScratchpadPage(open: openScratchpad)
        }
    }
}

struct TopBar: View {
    @Binding var sidebar: Bool
    let themeChanged: () -> Void
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 78)
            IconButton(icon: "sidebar.left", help: "Toggle sidebar") { withAnimation(.snappy(duration: 0.22)) { sidebar.toggle() } }
            Spacer()
            Menu {
                Picker("Theme", selection: Binding(get: { model.settings.p.theme }, set: { model.settings.p.theme = $0; themeChanged() })) {
                    Label("Light", systemImage: "sun.max").tag("light")
                    Label("Dark", systemImage: "moon").tag("dark")
                    Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                }.pickerStyle(.inline)
            } label: {
                Image(systemName: model.settings.p.theme == "dark" ? "sun.max" : "moon").font(.system(size: 15)).foregroundStyle(T.text2)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28)
            .help("Theme")
        }
        .padding(.horizontal, 10).frame(height: 44)
    }
}

struct Logo: View {
    var body: some View {
        HStack(spacing: 7) {
            HStack(alignment: .center, spacing: 2) {
                ForEach([7.0, 12, 17, 12, 9], id: \.self) { h in Capsule().fill(T.ink).frame(width: 2.6, height: h) }
            }
            Text("LocalFlow").font(.ui(21, .semibold)).tracking(-0.4)
        }
    }
}

struct Sidebar: View {
    @Binding var page: HubPage
    @Binding var showSettings: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Logo().padding(.leading, 10).padding(.top, 58).padding(.bottom, 22)
            ForEach(HubPage.allCases) { p in
                NavRow(icon: p.icon, title: p.title, selected: page == p) { page = p }
            }
            Spacer(minLength: 16)
            if !model.settings.p.dismissed.contains("getStarted") { GetStartedCard().padding(.bottom, 10) }
            Rectangle().fill(T.line).frame(height: 1).padding(.horizontal, 6).padding(.bottom, 6)
            NavRow(icon: "gearshape", title: "Settings", selected: false, badge: !(model.micOK && model.axOK)) { showSettings = true }
        }
        .padding(.horizontal, 12).padding(.bottom, 14)
    }
}

struct NavRow: View {
    let icon: String, title: String, selected: Bool
    var badge = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                Text(title).font(.ui(15, .medium))
                Spacer()
                if badge { Circle().fill(Color(nsColor: NSColor(hex: 0xE5534B))).frame(width: 18, height: 18).overlay(Text("1").font(.ui(11, .semibold)).foregroundStyle(.white)) }
            }
            .foregroundStyle(T.text)
            .padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? T.navSel : hover ? T.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct GetStartedCard: View {
    @Environment(AppModel.self) private var model
    var items: [(String, Bool)] {
        let e = model.history.entries
        var r = [("Dictate with fn", e.contains { $0.mode == nil && !$0.imported }),
                 ("Try Command Mode", e.contains { $0.mode == "command" }),
                 ("Polish some text", e.contains { $0.mode == "transform" }),
                 ("Use a snippet", model.dict.file.snippets.contains { $0.uses > 0 })]
        if WisprImport.available { r.append(("Import from Wispr Flow", e.contains(where: \.imported))) }
        return r
    }
    var body: some View {
        let done = items.filter(\.1).count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Get started").font(.ui(13.5, .semibold))
                Spacer()
                Button { model.settings.p.dismissed.append("getStarted") } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(T.text3) }
                    .buttonStyle(.plain)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(T.empty)
                    Capsule().fill(T.teal).frame(width: g.size.width * CGFloat(done) / CGFloat(max(1, items.count)))
                }
            }.frame(height: 4)
            ForEach(items, id: \.0) { title, ok in
                HStack(spacing: 9) {
                    ZStack {
                        Circle().strokeBorder(ok ? .clear : T.text3, lineWidth: 1.3).background(Circle().fill(ok ? T.teal4 : .clear))
                        if ok { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(T.teal) }
                    }.frame(width: 17, height: 17)
                    Text(title).font(.ui(13)).foregroundStyle(ok ? T.text2 : T.text)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.card))
    }
}

// MARK: Home

func compact(_ n: Int) -> String {
    n >= 1000 ? String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K") : "\(n)"
}

func appName(_ e: Entry) -> String {
    if let n = e.appName, !n.isEmpty { return n }
    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.app) {
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    return e.app.split(separator: ".").last.map(String.init) ?? "App"
}

struct HomeView: View {
    let go: (HubPage) -> Void
    @Environment(AppModel.self) private var model

    var firstName: String { UserDefaults.standard.string(forKey: "name") ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? "" }

    var body: some View {
        let stats = Stats(model.history.entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(firstName.isEmpty ? "Welcome back" : "Welcome back, \(firstName)").font(.ui(26, .medium))
                if let p = model.downloadProgress {   // first launch: models are downloading
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.modelStatus).font(.ui(14, .medium))
                        ProgressView(value: p).tint(T.teal)
                        Text("One-time download. After this, LocalFlow works fully offline.").font(.ui(12.5)).foregroundStyle(T.text2)
                    }.padding(16).background(RoundedRectangle(cornerRadius: 12).fill(T.tile))
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 30) {
                        if !model.micOK || !model.axOK { PermissionBanner() }
                        else if !model.settings.p.dismissed.contains("homeHero") {
                            Hero(title: Text("Make LocalFlow sound like \(Text("you").font(.serif(33, italic: true)))"),
                                 subtitle: Text("Set up different writing styles for different apps."),
                                 onClose: { model.settings.p.dismissed.append("homeHero") }) {
                                HeroButton(title: "Start now") { go(.style) }
                            }
                        }
                        HistoryList()
                    }
                    .frame(maxWidth: .infinity)
                    StatsColumn(stats: stats).frame(width: 250)
                }
            }
            .padding(.horizontal, 40).padding(.top, 38).padding(.bottom, 40)
            .frame(maxWidth: 1120).frame(maxWidth: .infinity)
        }
    }
}

struct StatsColumn: View {
    let stats: Stats
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                stat(compact(stats.totalWords), "total words")
                stat("\(stats.wpm)", "wpm")
                stat("\(stats.streak)", "day streak")
            }.padding(22)
            Rectangle().fill(T.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(T.teal)
                    Text("100% on this Mac").font(.ui(15, .semibold))
                }
                Text("Speech recognition and AI editing run locally. Nothing you say leaves your computer.")
                    .font(.ui(13)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
            }.padding(22)
            Rectangle().fill(T.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 9) {
                Text("Shortcuts").font(.ui(15, .semibold))
                shortcut("Dictate", ["fn"])
                shortcut("Hands-free", ["fn", "Space"])
                shortcut("Command", ["fn", "⌃"])
                shortcut("Paste last", ["⌃", "⌘", "V"])
            }.padding(22)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(T.tile))
    }

    func stat(_ v: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(v).font(.serif(30))
            Text(label).font(.ui(16)).foregroundStyle(T.text2)
        }
    }

    func shortcut(_ title: String, _ keys: [String]) -> some View {
        HStack {
            Text(title).font(.ui(13.5)).foregroundStyle(T.text2)
            Spacer()
            HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(text: $0) } }
        }
    }
}

struct PermissionBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Hero(title: Text("One more \(Text("step").font(.serif(33, italic: true)))"),
             subtitle: Text(model.status + ". LocalFlow needs it to hear you and type for you. Nothing leaves your Mac."),
             art: [Color(nsColor: NSColor(hex: 0x1A1210)), Color(nsColor: NSColor(hex: 0x4A2A1C)), Color(nsColor: NSColor(hex: 0x9A5A34))]) {
            HeroButton(title: "Open System Settings") { Permissions.open(model.micOK ? .accessibility : .microphone) }
        }
    }
}

struct HistoryList: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var searching = false
    @State private var limit = 60

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mma"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f }()

    var entries: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.history.entries.filter { !$0.text.isEmpty }
        return q.isEmpty ? all : all.filter { $0.text.lowercased().contains(q) || $0.raw.lowercased().contains(q) || appName($0).lowercased().contains(q) }
    }

    var body: some View {
        let list = entries
        let days = Dictionary(grouping: list.prefix(limit)) { Calendar.current.startOfDay(for: $0.time) }
        let keys = days.keys.sorted(by: >)
        VStack(alignment: .leading, spacing: 14) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(T.text3)
                    TextField("Search your dictations", text: $query).textFieldStyle(.plain).font(.ui(15))
                    IconButton(icon: "xmark") { query = ""; searching = false }
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(T.card)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.line))
            }
            if list.isEmpty {
                HStack { UpperLabel("Today"); Spacer(); if !searching { IconButton(icon: "magnifyingglass") { searching = true } } }
                ListCard { Text(query.isEmpty ? "Your dictations will show up here. Hold fn and start talking." : "No matches.")
                    .font(.ui(15)).foregroundStyle(T.text2).padding(22).frame(maxWidth: .infinity, alignment: .leading) }
            }
            ForEach(keys, id: \.self) { day in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        UpperLabel(day.formatted(.dateTime.month(.wide).day().year()))
                        Spacer()
                        if day == keys.first, !searching { IconButton(icon: "magnifyingglass", help: "Search") { searching = true } }
                    }
                    ListCard {
                        ForEach(Array((days[day] ?? []).enumerated()), id: \.element.id) { i, e in
                            if i > 0 { Rectangle().fill(T.line).frame(height: 1) }
                            EntryRow(entry: e)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            if list.count > limit { SoftButton("Show more") { limit += 100 }.frame(maxWidth: .infinity) }
        }
    }
}

@MainActor enum AudioPlayback {
    static var player: AVAudioPlayer?
    static func play(_ url: URL) { player = try? AVAudioPlayer(contentsOf: url); player?.play() }
}

struct EntryRow: View {
    let entry: Entry
    @Environment(AppModel.self) private var model
    @State private var showRaw = false
    @State private var expanded = false
    @State private var retrying = false
    var shown: String { (showRaw ? entry.raw : entry.text).trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HoverRow { hover in
            HStack(alignment: .top, spacing: 0) {
                Text(HistoryList.time.string(from: entry.time)).font(.ui(14)).foregroundStyle(T.text2)
                    .frame(width: 100, alignment: .leading).padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    if let mode = entry.mode {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                            Text(mode == "command" ? "Command · \(entry.instruction ?? "")" : (entry.instruction ?? "Transform")).lineLimit(1)
                        }.font(.ui(12.5, .medium)).foregroundStyle(T.purple)
                    }
                    Text(shown).font(.ui(15.5)).lineSpacing(3.5).foregroundStyle(showRaw ? T.text2 : T.text)
                        .lineLimit(expanded ? nil : 8).textSelection(.enabled)
                        .onTapGesture(count: 2) { expanded.toggle() }
                    if showRaw { Text("Original transcript (AI edit undone)").font(.ui(12.5)).foregroundStyle(T.purple) }
                }
                Spacer(minLength: 16)
                HStack(spacing: 2) {
                    if retrying { ProgressView().controlSize(.small).frame(width: 28) }
                    IconButton(icon: "doc.on.doc", help: "Copy") { model.copy(shown) }
                    Menu {
                        Button("Copy") { model.copy(shown) }
                        if entry.mode == nil, entry.raw != entry.text, !entry.raw.isEmpty {
                            Button(showRaw ? "Redo AI edit" : "Undo AI edit") { showRaw.toggle() }
                        }
                        if let b = entry.before { Button("Copy original text") { model.copy(b) } }
                        if let a = entry.audioURL, FileManager.default.fileExists(atPath: a.path) {
                            Button("Play audio") { AudioPlayback.play(a) }
                            if entry.mode == nil { Button("Retry transcript") { retrying = true; Task { await model.retry(entry); retrying = false } } }
                        }
                        Divider()
                        Text(appName(entry))
                        Button("Delete", role: .destructive) { model.history.delete([entry.id]) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(T.text2).frame(width: 28, height: 28).rotationEffect(.degrees(90))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
                }
                .opacity(hover || retrying ? 1 : 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 18)
        }
    }
}

// MARK: Insights

struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "usage"

    static let cats: [(String, String, String)] = [   // name, icon, label
        ("AI prompts", "cpu", "AI prompts"), ("Other", "infinity", "other tasks"), ("Documents", "doc.text", "documents"),
        ("Personal messages", "bubble.left", "personal messages"), ("Emails", "envelope", "emails"), ("Work messages", "text.bubble", "work messages")]

    var body: some View {
        let s = Stats(model.history.entries)
        Page(width: 1044) {
            PageHeader("Insights")
            TabBar(items: [("usage", "Your usage")], selection: $tab).padding(.bottom, 10)
            HStack(alignment: .top, spacing: 22) {
                Tile {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(s.wpm)").font(.ui(30, .medium))
                        UpperLabel("Words per minute")
                        Gauge(value: Double(s.wpm), label: s.wpm > 0 ? String(format: "%.1f×", Double(s.wpm) / 40) : "–", caption: "vs typing")
                            .frame(width: 170, height: 92).padding(.top, 12)
                    }
                }.frame(height: 196)
                Tile {
                    VStack(alignment: .leading, spacing: 4) {
                        Text((s.fixes + s.dictFixes).formatted()).font(.ui(30, .medium))
                        UpperLabel("Fixes made by LocalFlow")
                        Rectangle().fill(T.line).frame(height: 1).padding(.vertical, 14)
                        fixRow("\(s.fixes.formatted())", "words corrected", "Fillers, backtracks and grammar fixed by the cleanup model")
                        fixRow("\(s.dictFixes.formatted())", "dictionary fixes", "Dictionary corrections and snippet expansions").padding(.top, 8)
                    }
                }.frame(height: 196)
                Tile {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top) {
                            Text(s.totalWords.formatted()).font(.ui(30, .medium))
                            Spacer()
                            if s.lastMonthWords > 0 {
                                let pct = Int((Double(s.monthWords - s.lastMonthWords) / Double(s.lastMonthWords) * 100).rounded())
                                Label("\(pct >= 0 ? "+" : "")\(pct)% this month", systemImage: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.ui(12.5, .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(T.card))
                            }
                        }
                        UpperLabel("Total words dictated")
                        Rectangle().fill(T.line).frame(height: 1).padding(.vertical, 14)
                        HStack(spacing: 8) { Image(systemName: "desktopcomputer").font(.system(size: 13)); Text("This Mac").font(.ui(15)) }
                        Text("\(s.totalWords.formatted()) words").font(.ui(15)).foregroundStyle(T.text2)
                    }
                }.frame(width: 480, height: 196)
            }
            HStack(alignment: .top, spacing: 22) {
                Tile(padding: 22) { usage(s) }.frame(height: 340)
                Tile(padding: 22) { StreakCalendar(daily: s.daily, streak: s.streak, longest: s.longest) }.frame(height: 340)
            }
        }
    }

    func fixRow(_ n: String, _ label: String, _ help: String) -> some View {
        HStack {
            Text("\(Text(n).font(.ui(15, .medium))) \(label)").font(.ui(15))
            Spacer()
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(T.text3).help(help)
        }
    }

    func usage(_ s: Stats) -> some View {
        let total = max(1, s.categories.map(\.1).reduce(0, +))
        let order = s.categories.map(\.0)
        let maxShare = Double(s.categories.first?.1 ?? 1) / Double(total)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Desktop usage").font(.ui(26, .medium))
                Spacer()
                UpperLabel("Total apps used | \(s.apps)")
            }.padding(.bottom, 4)
            ForEach(Array(order.enumerated()), id: \.element) { i, name in
                let info = Self.cats.first { $0.0 == name } ?? (name, "circle", name.lowercased())
                let words = s.categories.first { $0.0 == name }?.1 ?? 0
                let share = Double(words) / Double(total)
                HStack(spacing: 14) {
                    Image(systemName: info.1).font(.system(size: 15)).foregroundStyle(T.text).frame(width: 22)
                    Text("\(Int((share * 100).rounded()))%").font(.ui(12.5, .medium)).foregroundStyle(.white)
                        .frame(width: 36 + 64 * CGFloat(maxShare > 0 ? share / maxShare : 0), height: 28)
                        .background(RoundedRectangle(cornerRadius: 4).fill(i == 0 ? T.teal : i == 1 ? T.teal2 : T.teal3))
                    UpperLabel("\(s.counts[name] ?? 0) \(info.2)").foregroundStyle(T.text)
                }
                .help("\(words.formatted()) words · " + (words >= 10000 ? "Power usage" : words >= 1000 ? "Moderate usage" : "Light usage"))
            }
        }
    }
}

struct Gauge: View {
    let value: Double
    let label: String, caption: String
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.5).stroke(T.empty, style: StrokeStyle(lineWidth: 16, lineCap: .round)).rotationEffect(.degrees(180))
            Circle().trim(from: 0, to: 0.5 * min(1, value / 200)).stroke(T.teal, style: StrokeStyle(lineWidth: 16, lineCap: .round)).rotationEffect(.degrees(180))
            VStack(spacing: 0) {
                Text(caption).font(.ui(13)).foregroundStyle(T.text2)
                Text(label).font(.ui(19, .medium))
            }.offset(y: -16)
        }
        .frame(width: 150, height: 150)
        .frame(height: 80, alignment: .top)
    }
}

struct StreakCalendar: View {
    let daily: [Date: Int]
    let streak: Int, longest: Int
    @State private var offset = 0          // weeks back from now
    let weeks = 17

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let start = cal.date(byAdding: .weekOfYear, value: -(weeks - 1) - offset, to: thisWeek)!
        let earliest = daily.keys.min() ?? today
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(streak) day streak").font(.ui(26, .medium))
                Spacer()
                UpperLabel("Longest streak | \(longest) day\(longest == 1 ? "" : "s")")
            }
            HStack(spacing: 0) {
                Button { offset += 4 } label: { Image(systemName: "chevron.left").foregroundStyle(start > earliest ? T.text : T.text3) }
                    .buttonStyle(.plain).disabled(start <= earliest).frame(width: 34, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach(0..<weeks, id: \.self) { w in
                        let d = cal.date(byAdding: .weekOfYear, value: w, to: start)!
                        let first = w == 0 || cal.component(.month, from: d) != cal.component(.month, from: cal.date(byAdding: .weekOfYear, value: -1, to: d)!)
                        Text(first ? d.formatted(.dateTime.month(.abbreviated)) : "").font(.ui(11.5)).foregroundStyle(T.text2)
                            .fixedSize().frame(width: 18, alignment: .leading)
                    }
                }
                Spacer()
                Button { offset = max(0, offset - 4) } label: { Image(systemName: "chevron.right").foregroundStyle(offset > 0 ? T.text : T.text3) }
                    .buttonStyle(.plain).disabled(offset == 0)
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { Text($0).font(.ui(11.5)).foregroundStyle(T.text2).frame(height: 18) }
                }.frame(width: 34, alignment: .leading)
                HStack(spacing: 6) {
                    ForEach(0..<weeks, id: \.self) { w in
                        VStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { d in
                                let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                                let n = daily[day] ?? 0
                                RoundedRectangle(cornerRadius: 3).fill(day > today ? Color.clear : color(n)).frame(width: 18, height: 18)
                                    .help(day > today ? "" : "\(day.formatted(date: .abbreviated, time: .omitted)) · \(n) words")
                            }
                        }
                    }
                }
            }
            HStack(spacing: 5) {
                Text("More").font(.ui(12)).foregroundStyle(T.text2)
                ForEach([800, 600, 300, 100], id: \.self) { RoundedRectangle(cornerRadius: 3).fill(color($0)).frame(width: 14, height: 14) }
                Text("Less").font(.ui(12)).foregroundStyle(T.text2)
            }
        }
    }

    func color(_ n: Int) -> Color {
        switch n {
        case 0: return T.empty
        case 1..<250: return T.teal4
        case 250..<500: return T.teal3
        case 500..<750: return T.teal2
        default: return T.teal
        }
    }
}

enum Permissions {
    enum Kind { case microphone, accessibility, keyboard }
    static func open(_ k: Kind) {
        switch k {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                if !ok { DispatchQueue.main.async { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) } }
            }
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case .keyboard:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        }
    }
}
