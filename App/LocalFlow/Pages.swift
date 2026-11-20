import AppKit
import FlowCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: Dictionary

struct DictionaryView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "all"
    @State private var query = ""
    @State private var searching = false
    @State private var sort = "recent"
    @State private var editing: WordEntry?
    @State private var message: String?
    @State private var suggestions: [String] = []

    var body: some View {
        Page {
            PageHeader(title: "Dictionary") {
                HStack(spacing: 8) {
                    InkButton("Import") { importFile() }
                    InkButton("Add new") { editing = WordEntry(word: "") }
                }
            }
            TabBar(items: [("all", "All"), ("starred", "Starred"), ("learned", "Learned"), ("corrections", "Corrections")], selection: $tab) {
                HStack(spacing: 2) {
                    IconButton(icon: "magnifyingglass", help: "Search") { searching.toggle(); if !searching { query = "" } }
                    Menu {
                        Picker("Sort", selection: $sort) {
                            Text("Most recent").tag("recent"); Text("Most used").tag("used"); Text("A–Z").tag("az")
                        }.pickerStyle(.inline)
                    } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 13)).foregroundStyle(T.text2) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28)
                }
            }
            if searching { SearchField(text: $query, prompt: "Search words") }
            if !model.settings.p.dismissed.contains("dictHero") {
                Hero(title: Text("LocalFlow spells the way \(Text("you").font(.serif(33, italic: true))) do."),
                     subtitle: Text("Correct a spelling once or add it here, so your \(Text("names, jargon and uncommon words").font(.ui(15, .semibold))) are always spelled right."),
                     height: 210, onClose: { model.settings.p.dismissed.append("dictHero") },
                     art: [Color(nsColor: NSColor(hex: 0x241A14)), Color(nsColor: NSColor(hex: 0x5A3E2A)), Color(nsColor: NSColor(hex: 0x9C7652))]) {
                    HeroButton(title: "Add new word") { editing = WordEntry(word: "") }
                    ForEach(suggestions.prefix(4), id: \.self) { w in
                        HeroButton(title: w, ghost: true) { _ = model.dict.saveWord(WordEntry(word: w)); suggestions.removeAll { $0 == w } }
                            .help("Add “\(w)” to your dictionary")
                    }
                }
            }
            if let message { Text(message).font(.ui(13.5)).foregroundStyle(T.text2) }
            let rows = words
            if rows.isEmpty {
                ListCard { Text(query.isEmpty ? "Nothing here yet." : "No matches.").font(.ui(15)).foregroundStyle(T.text2).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                ListCard {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, w in
                        if i > 0 { Rectangle().fill(T.line).frame(height: 1) }
                        WordRow(word: w, edit: { editing = w })
                    }
                }
            }
        }
        .sheet(item: $editing) { WordSheet(entry: $0) }
        .task { suggestions = Self.suggest(model) }
    }

    var words: [WordEntry] {
        let q = query.lowercased()
        var r = model.dict.file.words.filter {
            (q.isEmpty || $0.word.lowercased().contains(q) || ($0.misspelling?.lowercased().contains(q) ?? false))
                && (tab == "all" || (tab == "starred" && $0.starred) || (tab == "learned" && $0.learned) || (tab == "corrections" && $0.misspelling != nil))
        }
        switch sort {
        case "used": r.sort { $0.uses > $1.uses }
        case "az": r.sort { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        default: r.sort { $0.added > $1.added }
        }
        return r
    }

    /// Names and jargon you dictate often that aren't in the dictionary yet (capitalized mid-sentence, unknown to the spell checker).
    static func suggest(_ model: AppModel) -> [String] {
        var counts: [String: Int] = [:]
        let re = try! NSRegularExpression(pattern: "(?<=[a-z,] )[A-Z][A-Za-z]{2,}")
        for e in model.history.entries.prefix(400) {
            let t = e.text
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) { if let r = Range(m.range, in: t) { counts[String(t[r]), default: 0] += 1 } }
        }
        return counts.filter { $0.value >= 2 && !model.dict.contains($0.key) && AppModel.distinctive($0.key, heard: $0.key) }
            .sorted { $0.value > $1.value }.map(\.key)
    }

    func importFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json, .plainText, .commaSeparatedText]
        guard p.runModal() == .OK, let url = p.url else { return }
        message = "Imported \(model.dict.importFile(url)) entries (duplicates skipped)."
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(T.text3)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.ui(15))
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10).fill(T.card)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.line))
    }
}

struct WordRow: View {
    let word: WordEntry
    let edit: () -> Void
    @Environment(AppModel.self) private var model
    @State private var confirm = false

    var body: some View {
        HoverRow { hover in
            HStack(spacing: 10) {
                if let m = word.misspelling {
                    Text(m).font(.ui(15.5)).foregroundStyle(T.text2)
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(T.text3)
                }
                Text(word.word).font(.ui(15.5))
                if word.learned { Text("✨").font(.system(size: 12)).help(word.heard.map { "Learned from your edit of “\($0)”" } ?? "Learned from your edits") }
                Spacer()
                if word.uses > 0, hover { Text("used \(word.uses)×").font(.ui(12.5)).foregroundStyle(T.text3) }
                HStack(spacing: 4) {
                    if hover {
                        IconButton(icon: "pencil", help: "Edit", action: edit)
                        IconButton(icon: "trash", help: "Delete") { confirm = true }
                    }
                    if hover || word.starred {
                        Button { model.dict.toggleStar(word.id) } label: {
                            Image(systemName: word.starred ? "star.fill" : "star").font(.system(size: 14)).foregroundStyle(word.starred ? T.text : T.text2).frame(width: 28, height: 28)
                        }.buttonStyle(.plain).help("Star key terms")
                    }
                }.frame(minWidth: 28)
            }
            .padding(.horizontal, 18).frame(height: 53)
        }
        .confirmationDialog("Delete “\(word.word)”?", isPresented: $confirm) {
            Button("Yes, delete it", role: .destructive) { model.dict.deleteWords([word.id]) }
        }
    }
}

struct SheetFrame<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.ui(20, .semibold))
            content
        }
        .padding(26).frame(width: 470)
        .background(T.panel)
        .font(.ui(15)).foregroundStyle(T.text)
    }
}

struct Field: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.ui(13, .medium)).foregroundStyle(T.text2)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.ui(15))
                .padding(.horizontal, 12).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(T.card)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(T.line))
        }
    }
}

struct WordSheet: View {
    @State var entry: WordEntry
    @State private var correct = false
    @State private var misspelling = ""
    @State private var error: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isNew: Bool { !model.dict.file.words.contains { $0.id == entry.id } }

    var body: some View {
        SheetFrame(title: isNew ? "Add to dictionary" : "Edit word") {
            Field(label: "Word or phrase", text: $entry.word, prompt: "e.g. Anthropic, GSAP, Maria Clara")
            Toggle("Correct a misspelling", isOn: $correct).toggleStyle(InkToggleStyle()).font(.ui(15))
            if correct {
                Field(label: "Misspelling", text: $misspelling, prompt: "What gets written instead, e.g. Entropic")
                Text("Whole words, any capitalization. The output keeps your spelling exactly.").font(.ui(12.5)).foregroundStyle(T.text2)
            }
            if let error { Text(error).font(.ui(13.5)).foregroundStyle(.red) }
            HStack {
                Spacer()
                SoftButton("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                InkButton(isNew ? "Add word" : "Save changes") {
                    entry.misspelling = correct ? misspelling : nil
                    error = model.dict.saveWord(entry)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { correct = entry.misspelling != nil; misspelling = entry.misspelling ?? "" }
    }
}

// MARK: Snippets

struct SnippetsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var searching = false
    @State private var editing: Snippet?
    @State private var tab = "all"

    var rows: [Snippet] {
        let r = model.dict.file.snippets.filter { query.isEmpty || $0.trigger.localizedCaseInsensitiveContains(query) || $0.expansion.localizedCaseInsensitiveContains(query) }
        return tab == "used" ? r.sorted { $0.uses > $1.uses } : r
    }

    var body: some View {
        Page {
            PageHeader(title: "Snippets") {
                InkButton("Add new") { editing = Snippet(trigger: "", expansion: "") }
            }
            TabBar(items: [("all", "All"), ("used", "Most used")], selection: $tab) {
                IconButton(icon: "magnifyingglass", help: "Search") { searching.toggle(); if !searching { query = "" } }
            }
            if searching { SearchField(text: $query, prompt: "Search snippets") }
            if !model.settings.p.dismissed.contains("snipHero") {
                Hero(title: Text("The stuff \(Text("you").font(.serif(33, italic: true))) shouldn't have to re-type."),
                     subtitle: Text("Save text you type often (a link, an intro, a prompt), then say a word to drop it in instantly."),
                     height: 268, onClose: { model.settings.p.dismissed.append("snipHero") },
                     art: [Color(nsColor: NSColor(hex: 0x15161C)), Color(nsColor: NSColor(hex: 0x3A3346)), Color(nsColor: NSColor(hex: 0x7B5E4A))]) {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 7) {
                            example("“my calendar link”", "https://cal.com/you/30min")
                            example("“review prompt”", "Review this code for bugs and edge cases…")
                            example("“sign off”", "Best, and talk soon!")
                        }
                        HeroButton(title: "Add new snippet") { editing = Snippet(trigger: "", expansion: "") }.padding(.top, 6)
                    }
                }
            }
            let list = rows
            if !list.isEmpty {
                ListCard {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Rectangle().fill(T.line).frame(height: 1) }
                        SnippetRow(snippet: s, edit: { editing = s })
                    }
                }
            }
        }
        .sheet(item: $editing) { SnippetSheet(snippet: $0) }
    }

    func example(_ a: String, _ b: String) -> some View {
        HStack(spacing: 8) {
            Text(a).font(.ui(13.5, .semibold, italic: true)).padding(.horizontal, 10).frame(height: 30).background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.75)))
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            Text(b).font(.ui(13.5, .medium)).padding(.horizontal, 10).frame(height: 30).background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.6)))
        }.foregroundStyle(Color(nsColor: NSColor(hex: 0x1F1F1E)))
    }
}

struct SnippetRow: View {
    let snippet: Snippet
    let edit: () -> Void
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    var body: some View {
        HoverRow { hover in
            HStack(spacing: 10) {
                Text("\(snippet.trigger) → \(snippet.expansion.replacingOccurrences(of: "\n", with: " "))").font(.ui(15)).lineLimit(1)
                Spacer()
                if hover {
                    if snippet.uses > 0 { Text("used \(snippet.uses)×").font(.ui(12.5)).foregroundStyle(T.text3) }
                    IconButton(icon: "pencil", help: "Edit", action: edit)
                    IconButton(icon: "trash", help: "Delete") { confirm = true }
                }
            }
            .padding(.horizontal, 16).frame(height: 52)
        }
        .confirmationDialog("Delete this snippet?", isPresented: $confirm) {
            Button("Delete", role: .destructive) { model.dict.deleteSnippets([snippet.id]) }
        }
    }
}

struct SnippetSheet: View {
    @State var snippet: Snippet
    @State private var error: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isNew: Bool { !model.dict.file.snippets.contains { $0.id == snippet.id } }

    var body: some View {
        SheetFrame(title: isNew ? "Add snippet" : "Edit snippet") {
            Field(label: "Snippet", text: $snippet.trigger, prompt: "What you say, e.g. my calendar link")
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Expansion").font(.ui(13, .medium)).foregroundStyle(T.text2); Spacer(); Text("\(snippet.expansion.count)/4000").font(.ui(12)).foregroundStyle(T.text3) }
                TextEditor(text: $snippet.expansion).font(.ui(15)).scrollContentBackground(.hidden).padding(8).frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 9).fill(T.card)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(T.line))
            }
            if let error { Text(error).font(.ui(13.5)).foregroundStyle(.red) }
            HStack {
                Spacer()
                SoftButton("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                InkButton(isNew ? "Add snippet" : "Save changes") {
                    error = model.dict.saveSnippet(snippet)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}

// MARK: Style

struct StyleView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "personal"

    static let titles = ["personal": "Personal messages", "work": "Work messages", "email": "Email", "other": "Other"]
    static let apps = ["personal": "WhatsApp, Messages, Telegram, Signal, Discord, Instagram", "work": "Slack, Teams, LinkedIn, Google Chat",
                       "email": "Mail, Gmail, Outlook, Superhuman, Spark", "other": "everything else: AI chats, documents, notes, code"]
    static let samples = ["personal": "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.",
                          "work": "Hi team, the release is ready for review. Please take a look before the 3 PM sync.",
                          "email": "Hi Maria, thanks for the quick reply. I'll send the signed contract by Friday.",
                          "other": "Summarize the main risks in this plan and suggest two alternatives."]
    static let toneInfo: [Tone: (String, String)] = [.formal: ("Formal.", "Caps + Punctuation"), .casual: ("Casual", "Caps + Less punctuation"),
                                                     .veryCasual: ("very casual", "No caps + Less punctuation"), .excited: ("Excited!", "More exclamations")]

    var body: some View {
        Page {
            PageHeader("Style")
            TabBar(items: StyleCategory.allCases.map { ($0.rawValue, Self.titles[$0.rawValue]!) } + [("cleanup", "Auto cleanup")],
                   selection: $tab, badges: ["cleanup": "Beta"])
            if tab == "cleanup" { cleanup } else if let cat = StyleCategory(rawValue: tab) { category(cat) }
        }
    }

    func category(_ cat: StyleCategory) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Applies in \(Self.apps[cat.rawValue]!).").font(.ui(14)).foregroundStyle(T.text2)
            HStack(alignment: .top, spacing: 16) {
                ForEach(cat.tones) { tone in
                    let info = Self.toneInfo[tone]!
                    OptionCard(title: info.0, detail: info.1,
                               example: Text.styled(Self.samples[cat.rawValue]!, tone: tone, keep: ["Maria"]),
                               selected: model.settings.tone(cat) == tone) { model.settings.p.tones[cat.rawValue] = tone }
                }
            }
        }
    }

    var cleanup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Hero(title: Text("Auto Cleanup applies to all your dictations"),
                 subtitle: Text("Choose how much cleanup is applied every time, in every app.\nYour original words are never lost: on the Dictation page, open the ⋯ menu on any entry and choose “Undo AI edit”."),
                 height: 168, art: [Color(nsColor: NSColor(hex: 0x1B2A30)), Color(nsColor: NSColor(hex: 0x3B3A35)), Color(nsColor: NSColor(hex: 0x6D7C77))]) { EmptyView() }
            HStack(alignment: .top, spacing: 16) {
                OptionCard(title: "None", detail: "Pastes exactly what you said, including mistakes",
                           example: "so um i think we should move the demo to thursday no wait friday because the client is traveling",
                           selected: model.settings.p.cleanup == .none) { model.settings.p.cleanup = .none }
                OptionCard(title: "Light", detail: "Removes filler words, applies your corrections, fixes grammar",
                           example: "So I think we should move the demo to Friday because the client is traveling.",
                           selected: model.settings.p.cleanup == .light) { model.settings.p.cleanup = .light }
                OptionCard(title: "Medium", detail: "Also edits for clarity and conciseness",
                           example: "Let's move the demo to Friday, since the client is traveling.",
                           selected: model.settings.p.cleanup == .medium) { model.settings.p.cleanup = .medium }
            }
        }
    }
}

struct OptionCard: View {
    let title: String, detail: String, example: String, selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.serif(30)).foregroundStyle(T.text)
                Text(detail).font(.ui(14.5)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
                Text(example).font(.ui(13.5, italic: true)).foregroundStyle(T.text).lineSpacing(3)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.lavender))
            }
            .padding(12).padding(.top, 2)
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? T.ink : T.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: Transforms

struct Ident: Identifiable { let id: String }

struct TransformsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Ident?           // "polish", "promptEngineer" or a custom transform id
    @State private var trying = false

    var body: some View {
        @Bindable var s = model.settings
        Page {
            PageHeader(title: "Transforms", badge: "Beta") {
                Toggle(isOn: $s.p.transformsOn) { Text("Opt in").font(.ui(14.5)) }.toggleStyle(InkToggleStyle()).fixedSize()
                    .onChange(of: s.p.transformsOn) { model.updateBindings() }
            }
            if !model.assistant.isAvailable { Text("The Transforms model isn't installed. Run scripts/install.sh.").font(.ui(14)).foregroundStyle(.orange) }
            Hero(title: Text("Transform works anywhere you write"),
                 subtitle: Text("Select text in any app and press a shortcut to rewrite, clean up or restructure it, right on this Mac."),
                 art: [Color(nsColor: NSColor(hex: 0x14201F)), Color(nsColor: NSColor(hex: 0x2E4441)), Color(nsColor: NSColor(hex: 0x7E8C7C))]) {
                HeroButton(title: "Try it out") { trying = true }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto Apply After Dictation").font(.ui(15, .medium))
                    Text("Run a transform on everything you dictate, automatically.").font(.ui(13)).foregroundStyle(T.text2)
                }
                Spacer()
                Picker("", selection: $s.p.autoApply) {
                    Text("Polish").tag("polish"); Text("Prompt Engineer").tag("promptEngineer")
                    ForEach(s.p.transforms) { Text($0.name).tag($0.id.uuidString) }
                }.frame(width: 170).labelsHidden()
                Toggle("", isOn: $s.p.autoApplyOn).toggleStyle(InkToggleStyle()).labelsHidden().fixedSize()
            }
            HStack(alignment: .center) {
                Text("My Transforms").font(.serif(30))
                Spacer()
                Button { resetDefaults() } label: { Label("Reset to defaults", systemImage: "arrow.counterclockwise").font(.ui(14.5, .medium)) }
                    .buttonStyle(.plain).padding(.trailing, 6)
                InkButton("Create New") { createNew() }
            }.padding(.top, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                TransformCard(shortcut: s.p.shortcuts["polish"], title: "Polish", detail: "Improve clarity and conciseness") { editing = Ident(id: "polish") }
                TransformCard(shortcut: s.p.shortcuts["promptEngineer"], title: "Prompt Engineer", detail: "Turn rambling into a clear AI prompt") { editing = Ident(id: "promptEngineer") }
                ForEach(s.p.transforms) { t in
                    TransformCard(shortcut: t.shortcut, title: t.name, detail: t.prompt.isEmpty ? "No prompt yet" : t.prompt) { editing = Ident(id: t.id.uuidString) }
                }
                if s.p.transforms.count < 8 {
                    TransformCard(shortcut: nil, title: "Create your own", detail: "Write your own prompt", plus: true) { createNew() }
                }
            }
        }
        .sheet(item: $editing) { TransformSheet(id: $0.id) }
        .sheet(isPresented: $trying) { TryTransform() }
    }

    func createNew() {
        guard model.settings.p.transforms.count < 8 else { return }
        let t = Transform(name: "New transform", prompt: "")
        model.settings.p.transforms.append(t)
        editing = Ident(id: t.id.uuidString)
    }

    func resetDefaults() {
        model.settings.p.polishRules = [true, true, true, true, true]
        model.settings.p.customRules = []
        model.settings.p.shortcuts["polish"] = Shortcut.defaults["polish"]
        model.settings.p.shortcuts["promptEngineer"] = Shortcut.defaults["promptEngineer"]
        model.updateBindings()
    }
}

struct TransformCard: View {
    let shortcut: Shortcut?
    let title: String, detail: String
    var plus = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    if plus { Keycap(text: "+") }
                    else if let shortcut { ForEach(shortcut.parts, id: \.self) { Keycap(text: $0) } }
                    else { Keycap(text: "No shortcut").opacity(0.6) }
                }.padding(.bottom, 12)
                Text(title).font(.ui(15.5, .semibold))
                Text(detail).font(.ui(14)).foregroundStyle(T.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? T.hover : T.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(T.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

struct TransformSheet: View {
    let id: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newRule = ""

    var body: some View {
        @Bindable var s = model.settings
        let index = s.p.transforms.firstIndex { $0.id.uuidString == id }
        SheetFrame(title: id == "polish" ? "Polish" : id == "promptEngineer" ? "Prompt Engineer" : "Custom transform") {
            HStack { Text("Shortcut").font(.ui(13, .medium)).foregroundStyle(T.text2); Spacer(); ShortcutField(id: index == nil ? id : "t:\(id)") }
            if id == "polish" {
                ForEach(Array(Assistant.polishRules.enumerated()), id: \.offset) { i, rule in
                    Toggle(rule, isOn: Binding(get: { s.p.polishRules[i] }, set: { s.p.polishRules[i] = $0 })).toggleStyle(InkToggleStyle())
                }
                Text("Your rules").font(.ui(13, .medium)).foregroundStyle(T.text2).padding(.top, 4)
                ForEach(Array(s.p.customRules.enumerated()), id: \.offset) { i, r in
                    HStack { Text(r).font(.ui(14.5)); Spacer(); IconButton(icon: "minus.circle") { s.p.customRules.remove(at: i) } }
                }
                HStack {
                    TextField("e.g. Never use em dashes", text: $newRule).textFieldStyle(.plain).font(.ui(14.5)).padding(.horizontal, 10).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(T.card)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(T.line))
                        .onSubmit(addRule)
                    SoftButton("Add", action: addRule)
                }
            } else if id == "promptEngineer" {
                Text("Turns unstructured spoken thoughts into a clear prompt: goal, context, requirements and the output you want.")
                    .font(.ui(14.5)).foregroundStyle(T.text2)
            } else if let i = index {
                Field(label: "Name", text: $s.p.transforms[i].name)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Customize prompt").font(.ui(13, .medium)).foregroundStyle(T.text2)
                    TextEditor(text: $s.p.transforms[i].prompt).font(.ui(14.5)).scrollContentBackground(.hidden).padding(8).frame(height: 130)
                        .background(RoundedRectangle(cornerRadius: 9).fill(T.card)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(T.line))
                    Text("For example: “Translate to English”, “Turn into a bullet list”, “Make it friendlier”.").font(.ui(12.5)).foregroundStyle(T.text3)
                }
            }
            HStack {
                if index != nil {
                    Button("Delete transform", role: .destructive) { s.p.transforms.removeAll { $0.id.uuidString == id }; model.updateBindings(); dismiss() }
                        .buttonStyle(.plain).font(.ui(14.5, .medium)).foregroundStyle(.red)
                }
                Spacer()
                InkButton("Done") { model.updateBindings(); dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(.top, 4)
        }
    }

    func addRule() {
        let r = newRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, !model.settings.p.customRules.contains(r) else { return }
        model.settings.p.customRules.append(r); newRule = ""
    }
}

struct TryTransform: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = "hey so i wanted to give you a quick update on the project we finished the design part last week and um the development is going ok but we might need one more week because the api changed and also we need to test it on mobile which we havent done yet"
    var body: some View {
        SheetFrame(title: "Try a transform") {
            Text("Select the text below, then press \(model.settings.p.shortcuts["polish"]?.display ?? "⌥1") to Polish it.").font(.ui(14.5)).foregroundStyle(T.text2)
            TextEditor(text: $text).font(.ui(15)).scrollContentBackground(.hidden).padding(10).frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 10).fill(T.card)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.line))
            HStack { Spacer(); InkButton("Done") { dismiss() } }
        }
    }
}

// MARK: Scratchpad

struct ScratchpadPage: View {
    let open: (UUID?) -> Void
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var searching = false

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mma"; f.amSymbol = "am"; f.pmSymbol = "pm"; return f }()

    var body: some View {
        Page {
            PageHeader(title: "Scratchpad", badge: "Beta") {
                HStack(spacing: 6) {
                    Text("Open anywhere with").font(.ui(14)).foregroundStyle(T.text2)
                    ForEach(model.settings.p.shortcuts["scratchpad"]?.parts ?? ["⌥ Opt", "S"], id: \.self) { Keycap(text: $0) }
                }
            }
            Hero(title: Text("For quick thoughts you want to come back to"),
                 subtitle: Text("Drop a to-do list, polish a message before you send it, brain dump an idea. Dictate straight into it."),
                 art: [Color(nsColor: NSColor(hex: 0x1E1611)), Color(nsColor: NSColor(hex: 0x5B4128)), Color(nsColor: NSColor(hex: 0xB08A5C))]) {
                HeroButton(title: "Start new note") { open(model.notes.new()) }
            }
            VStack(spacing: 10) {
                HStack {
                    Text("Recents").font(.ui(15.5, .medium))
                    Spacer()
                    IconButton(icon: "magnifyingglass", help: "Search") { searching.toggle(); if !searching { query = "" } }
                    IconButton(icon: "plus", help: "New note") { open(model.notes.new()) }
                }
                Rectangle().fill(T.line).frame(height: 1)
            }
            if searching { SearchField(text: $query, prompt: "Search notes") }
            let notes = model.notes.notes.filter { !$0.text.isEmpty && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }
            if notes.isEmpty { Text("No notes yet.").font(.ui(15)).foregroundStyle(T.text2) }
            ForEach(notes) { n in NoteCard(note: n) { open(n.id) } }
        }
    }
}

struct NoteCard: View {
    let note: Note
    let open: () -> Void
    @Environment(AppModel.self) private var model
    var preview: String {
        let rest = note.text.split(separator: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? note.text : rest
    }
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                Text(note.title).font(.ui(15, .semibold))
                Text(preview).font(.ui(14)).foregroundStyle(T.text2).lineLimit(3).lineSpacing(2)
                HStack {
                    Text(note.updated.formatted(.dateTime.month(.abbreviated).day())).font(.ui(13)).foregroundStyle(T.text3)
                    Spacer()
                    Text(ScratchpadPage.time.string(from: note.updated)).font(.ui(13)).foregroundStyle(T.text3)
                }.padding(.top, 2)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Delete", role: .destructive) { model.notes.delete(note.id) } }
    }
}

struct NoteEditor: View {
    let id: UUID
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text).font(.ui(15.5)).lineSpacing(3).scrollContentBackground(.hidden).padding(.horizontal, 22).padding(.vertical, 14)
            .focused($focused)
            .onAppear { text = model.notes.notes.first { $0.id == id }?.text ?? ""; focused = true }
            .onChange(of: text) { model.notes.set(id, text: text) }
            .overlay(alignment: .topLeading) {
                if text.isEmpty { Text("Hold fn and start talking…").font(.ui(15.5)).foregroundStyle(T.text3).padding(.horizontal, 27).padding(.vertical, 14).allowsHitTesting(false) }
            }
    }
}

/// The floating window (⌥S).
struct ScratchpadView: View {
    @Environment(AppModel.self) private var model
    @State private var id: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(model.notes.notes.prefix(20)) { n in Button(n.title) { id = n.id } }
                } label: { Text(model.notes.notes.first { $0.id == id }?.title ?? "Untitled").font(.ui(14, .medium)) }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                IconButton(icon: "square.and.pencil", help: "New note") { id = model.notes.new() }
                IconButton(icon: "doc.on.doc", help: "Copy all") { if let id { model.copy(model.notes.notes.first { $0.id == id }?.text ?? "") } }
            }
            .padding(.leading, 78).padding(.trailing, 10).frame(height: 40)
            Rectangle().fill(T.line).frame(height: 1)
            if let id { NoteEditor(id: id).id(id) }
        }
        .background(T.panel)
        .font(.ui(15)).foregroundStyle(T.text).tint(T.ink)
        .ignoresSafeArea()
        .frame(minWidth: 340, idealWidth: 420, minHeight: 320, idealHeight: 460)
        .onAppear { id = model.scratchNote ?? model.notes.notes.first?.id ?? model.notes.new() }
        .onChange(of: model.scratchNote) { if let n = model.scratchNote { id = n } }
    }
}

// MARK: Settings (a modal over the hub, like Wispr's)

struct SettingsModal: View {
    let close: () -> Void
    let dockChanged: () -> Void
    let themeChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var section = "general"
    @State private var shortcuts = false

    static let titles = ["general": "General", "system": "System", "experimental": "Experimental", "privacy": "Data and Privacy"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.22).onTapGesture(perform: close)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    UpperLabel("Settings").padding(.horizontal, 10).padding(.bottom, 8)
                    NavRow(icon: "slider.horizontal.3", title: "General", selected: section == "general", badge: !(model.micOK && model.axOK)) { section = "general" }
                    NavRow(icon: "laptopcomputer", title: "System", selected: section == "system") { section = "system" }
                    NavRow(icon: "flask", title: "Experimental", selected: section == "experimental") { section = "experimental" }
                    UpperLabel("Data").padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 8)
                    NavRow(icon: "checkmark.shield", title: "Data and Privacy", selected: section == "privacy") { section = "privacy" }
                    Spacer()
                    HStack {
                        Text("LocalFlow v1.0").font(.ui(12.5)).foregroundStyle(T.text2)
                        Spacer()
                        Circle().fill(model.asrReady && model.micOK && model.axOK ? Color.green : .orange).frame(width: 7, height: 7)
                    }.padding(.horizontal, 10)
                }
                .padding(.vertical, 22).padding(.horizontal, 10)
                .frame(width: 210)
                .background(T.tile)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(Self.titles[section] ?? "").font(.serif(32))
                        switch section {
                        case "system": SystemSettings(dockChanged: dockChanged)
                        case "experimental": ExperimentalSettings()
                        case "privacy": PrivacySettings()
                        default: GeneralSettings(openShortcuts: { shortcuts = true }, themeChanged: themeChanged)
                        }
                    }
                    .padding(.horizontal, 36).padding(.vertical, 34)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(T.panel)
            }
            .frame(width: 900, height: 640)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 10)
            .overlay(alignment: .topTrailing) { IconButton(icon: "xmark", help: "Close", action: close).padding(12) }
            if shortcuts {
                Color.black.opacity(0.12).onTapGesture { shortcuts = false }
                ShortcutsDialog(close: { shortcuts = false })
            }
        }
        .onExitCommand(perform: close)
    }
}

/// Grey rounded group with hairlines between its rows.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.ui(15, .medium)) }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Rectangle().fill(T.line).frame(height: 1).padding(.horizontal, 16) }
                        row
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.tile))
        }
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(15, .medium))
                if let detail { Text(detail).font(.ui(13.5)).foregroundStyle(T.text2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var body: some View {
        SettingRow(title: title, detail: detail) { Toggle("", isOn: $isOn).toggleStyle(InkToggleStyle()).labelsHidden().fixedSize() }
    }
}

struct GeneralSettings: View {
    let openShortcuts: () -> Void
    let themeChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var devices = AudioDevices.inputs()
    var body: some View {
        @Bindable var s = model.settings
        VStack(alignment: .leading, spacing: 22) {
            if !model.micOK || !model.axOK {
                SettingsGroup {
                    SettingRow(title: model.status, detail: "macOS needs your approval. Nothing you say leaves this Mac.") {
                        SoftButton("Open") { Permissions.open(model.micOK ? .accessibility : .microphone) }
                    }
                }
            }
            SettingsGroup {
                SettingRow(title: "Shortcuts", detail: "Hold \(s.p.shortcuts["ptt"]?.display ?? "fn") and speak.") { SoftButton("Change", action: openShortcuts) }
                SettingRow(title: "Microphone", detail: devices.first { $0.uid == s.p.micUID }?.name ?? "Automatic (system default)") {
                    Menu {
                        Button("Automatic (system default)") { s.p.micUID = nil }
                        Divider()
                        ForEach(devices, id: \.uid) { d in Button(d.name) { s.p.micUID = d.uid } }
                    } label: {
                        Text("Change").font(.ui(14.5, .medium)).foregroundStyle(T.text).padding(.horizontal, 16).frame(minWidth: 96).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(T.soft))
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                SettingRow(title: "Test microphone", detail: "Speak; the bar should move.") { MicTestRow().frame(width: 220) }
                SettingRow(title: "My languages", detail: "English · Portuguese (Português), detected automatically") { EmptyView() }
                SettingRow(title: "Theme") {
                    Picker("", selection: Binding(get: { s.p.theme }, set: { s.p.theme = $0; themeChanged() })) {
                        Text("Light").tag("light"); Text("Dark").tag("dark"); Text("System").tag("system")
                    }.labelsHidden().frame(width: 130)
                }
            }
        }
        .onAppear { devices = AudioDevices.inputs() }
        .onDisappear { model.stopMicTest() }
    }
}

struct SystemSettings: View {
    let dockChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    var body: some View {
        @Bindable var s = model.settings
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "App settings") {
                ToggleRow(title: "Launch app at login", isOn: $loginItem)
                ToggleRow(title: "Show Flow Bar at all times", isOn: $s.p.flowBar)
                ToggleRow(title: "Show app in dock", isOn: $s.p.showInDock)
            }
            SettingsGroup(title: "Sound") {
                ToggleRow(title: "Dictation and notification sounds", isOn: $s.p.sounds)
                ToggleRow(title: "Mute all audio while dictating", isOn: $s.p.muteAudio)
            }
            SettingsGroup(title: "Dictation") {
                ToggleRow(title: "Whisper mode", detail: "Picks up very quiet speech, for libraries and open offices.", isOn: $s.p.whisperMode)
            }
        }
        .onChange(of: loginItem) {
            do { if loginItem { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { loginItem = SMAppService.mainApp.status == .enabled }
        }
        .onChange(of: s.p.flowBar) { model.bar.idle() }
        .onChange(of: s.p.showInDock) { dockChanged() }
    }
}

struct ExperimentalSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var s = model.settings
        SettingsGroup {
            ToggleRow(title: "Command Mode", detail: "Hold \(s.p.shortcuts["command"]?.display ?? "fn ⌃") and say what to do with the selected text, or what to write.", isOn: $s.p.commandMode)
            ToggleRow(title: "“Press enter” voice command", detail: "End a dictation with “press enter” (or “aperta enter”) to send it.", isOn: $s.p.pressEnter)
        }
        .onChange(of: s.p.commandMode) { model.updateBindings() }
    }
}

struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var message: String?
    var body: some View {
        @Bindable var s = model.settings
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Privacy") {
                ToggleRow(title: "Context awareness", detail: "Reads the app, site and nearby text, on this Mac, to format and spell better.", isOn: $s.p.contextAware)
                ToggleRow(title: "Auto-add to dictionary", detail: "Learn names and terms you correct after dictating.", isOn: $s.p.autoLearn)
            }
            SettingsGroup(title: "Your data") {
                SettingRow(title: "Keep history", detail: "Audio is kept 14 days for retries; stats are always kept.") {
                    Picker("", selection: $s.p.keepHistory) {
                        Text("Forever").tag(Retention.forever); Text("30 days").tag(Retention.month); Text("Never store").tag(Retention.never)
                    }.labelsHidden().frame(width: 140)
                }
                SettingRow(title: "Export history", detail: "Save all your dictations as JSON.") { SoftButton("Export") { export() } }
                if WisprImport.available {
                    SettingRow(title: "Import from Wispr Flow", detail: message ?? "Dictations, dictionary and snippets. Duplicates are skipped.") { SoftButton("Import") { importWispr() } }
                }
                SettingRow(title: "Data folder", detail: "Everything LocalFlow stores lives here.") { SoftButton("Open") { NSWorkspace.shared.open(support) } }
                SettingRow(title: "Delete all history", detail: "Can't be undone.") { SoftButton("Delete", destructive: true) { confirmDelete = true } }
            }
        }
        .confirmationDialog("Delete all history? This can't be undone.", isPresented: $confirmDelete) {
            Button("Delete all", role: .destructive) { model.history.deleteAll() }
        }
    }

    func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "LocalFlow history.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        try? model.history.exportJSON().write(to: url)
    }

    func importWispr() {
        guard let r = WisprImport.read() else { message = "Couldn't read Wispr Flow's data."; return }
        let n = model.history.merge(r.entries)
        var w = 0
        for x in r.words where model.dict.saveWord(x) == nil { w += 1 }
        for x in r.snippets where model.dict.saveSnippet(x) == nil { w += 1 }
        message = "Imported \(n) dictations and \(w) dictionary entries."
    }
}

struct ShortcutsDialog: View {
    let close: () -> Void
    @Environment(AppModel.self) private var model
    static let rows: [(String, String, String)] = [
        ("ptt", "Push to talk", "Hold to say something short"),
        ("handsFree", "Hands-free mode", "Press to start and stop dictating"),
        ("command", "Command Mode", "Hold and say what to do with selected text"),
        ("pasteLast", "Paste last transcript", "Paste your most recent dictation"),
        ("copyLast", "Copy last transcript", "Copy it without pasting"),
        ("scratchpad", "Open Scratchpad", "Floating notepad you can dictate into"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Shortcuts").font(.ui(20, .semibold))
                Spacer()
                IconButton(icon: "xmark", help: "Close", action: close)
            }
            Text("Choose your preferred shortcuts for using LocalFlow.").font(.ui(14.5)).foregroundStyle(T.text2).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Self.rows.filter { $0.0 != "command" || model.settings.p.commandMode }, id: \.0) { id, title, detail in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title).font(.ui(15, .medium))
                                Text(detail).font(.ui(13)).foregroundStyle(T.text2)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 8) {
                                if id == "handsFree" {
                                    HStack(spacing: 6) { Text("Double tap").font(.ui(13)).foregroundStyle(T.text2); Keycap(text: "fn") }
                                        .padding(.horizontal, 10).frame(width: 200, height: 38, alignment: .leading)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(T.card))
                                }
                                ShortcutField(id: id)
                            }
                        }
                        .padding(16).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.tile))
                    }
                    HStack {
                        Text("Cancel").font(.ui(15, .medium))
                        Spacer()
                        Keycap(text: "Esc").padding(.trailing, 8)
                    }.padding(16).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.tile))
                }
            }
            HStack {
                SoftButton("Reset to default") { model.settings.p.shortcuts = Shortcut.defaults; model.updateBindings() }
                Spacer()
                InkButton("Done", action: close)
            }.padding(.top, 16)
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(T.panel))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
    }
}

struct MicTestRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 10) {
            LevelMeter(level: model.micLevel).frame(height: 6)
            SoftButton(model.micTesting ? "Stop" : "Test") { model.micTesting ? model.stopMicTest() : model.startMicTest() }
        }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(T.empty)
                Capsule().fill(T.teal).frame(width: g.size.width * CGFloat(min(1, sqrt(Double(level)) * 3.5)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}

// MARK: Onboarding

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var tryText = ""
    @FocusState private var tryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack { Logo(); Spacer() }.padding(.horizontal, 30).padding(.top, 52)
            Spacer()
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: micTest
                default: tryIt
                }
            }
            .frame(maxWidth: 580)
            .id(step)
            .transition(.opacity)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in Capsule().fill(i <= step ? T.ink : T.empty).frame(width: i == step ? 22 : 8, height: 6) }
            }.padding(.bottom, 34).animation(.snappy, value: step)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.bg)
    }

    func next() { withAnimation(.easeInOut(duration: 0.18)) { step += 1 } }

    var welcome: some View {
        VStack(spacing: 18) {
            Text("Speak naturally, \(Text("write").font(.serif(46, italic: true))) perfectly").font(.serif(46)).multilineTextAlignment(.center)
            Text("LocalFlow turns your voice into clean, well-written text in any app. Speech recognition and AI editing run entirely on this Mac.")
                .font(.ui(17)).multilineTextAlignment(.center).foregroundStyle(T.text2)
            InkButton("Get started", action: next).padding(.top, 10)
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Two permissions").font(.serif(36))
            Text("macOS asks you to approve these yourself.").font(.ui(15)).foregroundStyle(T.text2).padding(.bottom, 6)
            PermissionRow(ok: model.micOK, title: "Microphone", detail: "To hear you while you hold the key.") { Permissions.open(.microphone) }
            PermissionRow(ok: model.axOK, title: "Accessibility", detail: "To notice the fn key and type into the app you're using.") { Permissions.open(.accessibility) }
            PermissionRow(ok: false, title: "Globe (fn) key", detail: "Keyboard → “Press 🌐 key to” → Do Nothing, so fn doesn't open emoji.", action: { Permissions.open(.keyboard) }, optional: true)
            HStack { Spacer(); InkButton(model.micOK && model.axOK ? "Continue" : "Skip for now", action: next) }.padding(.top, 6)
        }
    }

    var micTest: some View {
        @Bindable var s = model.settings
        return VStack(alignment: .leading, spacing: 16) {
            Text("Check your microphone").font(.serif(36))
            Text("Say something. The bar should move with your voice.").font(.ui(15)).foregroundStyle(T.text2)
            Picker("Microphone", selection: $s.p.micUID) {
                Text("Automatic (system default)").tag(String?.none)
                ForEach(AudioDevices.inputs(), id: \.uid) { Text($0.name).tag(String?.some($0.uid)) }
            }.onChange(of: s.p.micUID) { model.stopMicTest(); model.startMicTest() }
            LevelMeter(level: model.micLevel).frame(height: 10)
            HStack { Spacer(); InkButton("Sounds good") { model.stopMicTest(); next() } }
        }
        .onAppear { model.startMicTest() }
        .onDisappear { model.stopMicTest() }
    }

    var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try it").font(.serif(36))
            Text("Click in the box, hold \(Text("fn").font(.ui(15, .semibold))), say “Hi, this is my first dictation, no wait, my first test”, then let go.")
                .font(.ui(15)).foregroundStyle(T.text2)
            TextEditor(text: $tryText).font(.ui(16)).focused($tryFocused).frame(height: 120).scrollContentBackground(.hidden)
                .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(T.card)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(T.line))
            VStack(alignment: .leading, spacing: 8) {
                tip(["fn", "fn"], "Double-tap for hands-free. Tap fn again to finish.")
                tip(["fn", "⌃ Ctrl"], "Hold for Command Mode: “make this shorter”, “translate to English”.")
                tip(["⌃ Ctrl", "⌘ Cmd", "V"], "Paste your last transcript. Esc cancels.")
            }
            HStack { Spacer(); InkButton("Finish") { model.settings.p.onboarded = true } }
        }
        .onAppear { tryFocused = true }
    }

    func tip(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) { ForEach(Array(keys.enumerated()), id: \.offset) { Keycap(text: $0.element) } }.frame(width: 150, alignment: .leading)
            Text(text).font(.ui(14)).foregroundStyle(T.text2)
        }
    }
}

struct PermissionRow: View {
    let ok: Bool, title: String, detail: String
    let action: () -> Void
    var optional = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : (optional ? "info.circle" : "circle")).font(.system(size: 20))
                .foregroundStyle(ok ? T.teal : T.text3)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.ui(15, .semibold)); Text(detail).font(.ui(13.5)).foregroundStyle(T.text2) }
            Spacer()
            if !ok { SoftButton(optional ? "Open" : "Allow", action: action) }
        }
        .padding(16).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.tile))
    }
}
