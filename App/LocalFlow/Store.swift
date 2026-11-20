import Foundation
import Observation
import FlowCore
import SQLite3

let support: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalFlow")
    try? FileManager.default.createDirectory(at: u.appendingPathComponent("audio"), withIntermediateDirectories: true)
    return u
}()

func wordCount(_ s: String) -> Int { s.split { $0.isWhitespace }.count }

// MARK: settings

enum CleanupLevel: String, Codable, CaseIterable, Identifiable { case none, light, medium; var id: String { rawValue } }
enum Retention: String, Codable, CaseIterable, Identifiable { case forever, month, never; var id: String { rawValue } }

struct Transform: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var prompt: String
    var shortcut: Shortcut?
}

struct Prefs: Codable {
    var cleanup = CleanupLevel.light
    var tones: [String: Tone] = [:]                 // StyleCategory.rawValue → tone (default formal)
    var shortcuts: [String: Shortcut] = Shortcut.defaults
    var micUID: String?                             // nil = system default
    var sounds = true
    var muteAudio = false
    var flowBar = true
    var showInDock = true
    var whisperMode = false
    var contextAware = true
    var autoLearn = true
    var pressEnter = false
    var commandMode = true
    var keepHistory = Retention.forever
    var polishRules = [true, true, true, true, true]
    var customRules: [String] = []
    var transforms: [Transform] = []
    var onboarded = false
    var theme = "light"                             // light / dark / system (Wispr defaults to light)
    var transformsOn = true                         // "Opt in" for transform shortcuts
    var autoApply = "polish"                        // transform run on every dictation when autoApplyOn
    var autoApplyOn = false
    var dismissed: [String] = []                    // hero banners / cards the user closed
}

@Observable @MainActor final class Settings {
    static let shared = Settings()
    var p: Prefs { didSet { save() } }

    private init() {
        p = Self.load()
        if UserDefaults.standard.object(forKey: "cleanup") as? Bool == false { p.cleanup = .none; UserDefaults.standard.removeObject(forKey: "cleanup") }
    }

    func tone(_ c: StyleCategory) -> Tone { p.tones[c.rawValue] ?? .formal }

    var polishPrompt: String {
        let rules = zip(Assistant.polishRules, p.polishRules).filter(\.1).map(\.0) + p.customRules
        return Assistant.polishPrompt(rules: rules)
    }

    /// Saved prefs merged over defaults, so new settings get their defaults instead of failing to decode.
    static func load() -> Prefs {
        guard let data = UserDefaults.standard.data(forKey: "prefs"),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = try? JSONEncoder().encode(Prefs()),
              var base = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return Prefs() }
        base.merge(saved) { $1 }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return Prefs() }
        return (try? JSONDecoder().decode(Prefs.self, from: merged)) ?? Prefs()
    }

    private func save() { if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: "prefs") } }
}

// MARK: history

struct Entry: Codable, Identifiable, Hashable {
    var id = UUID()
    var time = Date()
    var app = ""                 // bundle id
    var appName: String?
    var url: String?
    var seconds = 0.0
    var raw = ""
    var text = ""                // what was pasted
    var words = 0
    var mode: String?            // nil = dictation, "command", "transform"
    var instruction: String?     // command / transform name
    var before: String?          // text a command or transform rewrote
    var fixes = 0                // words changed by cleanup
    var dictFixes = 0            // dictionary + snippet substitutions
    var audio: String?
    var asrMs: Int?
    var totalMs: Int?
    var imported = false

    enum CodingKeys: String, CodingKey {
        case id, time, app, appName, url, seconds, raw, text, words, mode, instruction, before, fixes, dictFixes, audio, imported
        case asrMs = "asr_ms", totalMs = "total_ms"
    }

    init() {}

    init(from dec: Decoder) throws {  // tolerant: older lines lack most fields
        let c = try dec.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: k) }
        id = v(.id) ?? UUID(); time = v(.time) ?? Date(); app = v(.app) ?? ""; appName = v(.appName); url = v(.url)
        seconds = v(.seconds) ?? 0; raw = v(.raw) ?? ""; text = v(.text) ?? ""; mode = v(.mode); instruction = v(.instruction)
        before = v(.before); fixes = v(.fixes) ?? 0; dictFixes = v(.dictFixes) ?? 0; audio = v(.audio)
        asrMs = v(.asrMs); totalMs = v(.totalMs); imported = v(.imported) ?? false
        words = v(.words) ?? wordCount(text)
    }

    var key: String { "\(app) \(appName ?? "") \(url ?? "")" }
    var audioURL: URL? { audio.map { support.appendingPathComponent("audio/\($0)") } }
}

@Observable @MainActor final class HistoryStore {
    private(set) var entries: [Entry] = []        // newest first
    let url = support.appendingPathComponent("history.jsonl")
    static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init() {
        let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n")
        entries = lines.compactMap { try? Self.dec.decode(Entry.self, from: Data($0.utf8)) }.sorted { $0.time > $1.time }
        prune()
    }

    func add(_ e: Entry) {
        var e = e
        if Settings.shared.p.keepHistory == .never { e.raw = ""; e.text = ""; e.before = nil; e.audio = nil }
        entries.insert(e, at: 0)
        guard let d = try? Self.enc.encode(e) else { return }
        let line = Data((String(data: d, encoding: .utf8)! + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    func update(_ e: Entry) { if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i] = e; rewrite() } }

    func delete(_ ids: Set<UUID>) {
        for e in entries where ids.contains(e.id) { if let a = e.audioURL { try? FileManager.default.removeItem(at: a) } }
        entries.removeAll { ids.contains($0.id) }
        rewrite()
    }

    func deleteAll() { delete(Set(entries.map(\.id))) }

    func merge(_ new: [Entry]) -> Int {
        let have = Set(entries.map(\.id))
        let add = new.filter { !have.contains($0.id) }
        entries = (entries + add).sorted { $0.time > $1.time }
        rewrite()
        return add.count
    }

    private func rewrite() {
        let s = entries.reversed().compactMap { try? Self.enc.encode($0) }.map { String(data: $0, encoding: .utf8)! + "\n" }.joined()
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Audio is kept 14 days (for retry and playback); text per the history setting.
    private func prune() {
        let audioCutoff = Date().addingTimeInterval(-14 * 86400)
        var changed = false
        for i in entries.indices where entries[i].audio != nil && entries[i].time < audioCutoff {
            if let a = entries[i].audioURL { try? FileManager.default.removeItem(at: a) }
            entries[i].audio = nil; changed = true
        }
        if Settings.shared.p.keepHistory == .month {
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            for i in entries.indices where entries[i].time < cutoff && !entries[i].text.isEmpty {
                entries[i].raw = ""; entries[i].text = ""; entries[i].before = nil; changed = true
            }
        }
        if changed { rewrite() }
    }

    func exportJSON() -> Data { (try? Self.enc.encode(entries)) ?? Data() }
}

// MARK: stats (Insights)

struct Stats {
    var totalWords = 0, wpm = 0, fixes = 0, dictFixes = 0, weekWords = 0, streak = 0, longest = 0, apps = 0
    var monthWords = 0, lastMonthWords = 0
    var categories: [(String, Int)] = []
    var counts: [String: Int] = [:]                 // dictations per usage category
    var daily: [Date: Int] = [:]

    init(_ entries: [Entry]) {
        let cal = Calendar.current
        var speech = 0.0, speechWords = 0, cats: [String: Int] = [:], appSet = Set<String>()
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let monthStart = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        let lastMonthStart = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let lastMonthCutoff = lastMonthStart.addingTimeInterval(Date().timeIntervalSince(monthStart))
        for e in entries where e.mode == nil {
            totalWords += e.words; fixes += e.fixes; dictFixes += e.dictFixes
            if e.seconds > 1, e.words > 0 { speech += e.seconds; speechWords += e.words }
            if e.time >= weekStart { weekWords += e.words }
            daily[cal.startOfDay(for: e.time), default: 0] += e.words
            let cat = Text.usageCategory(e.key)
            cats[cat, default: 0] += e.words; counts[cat, default: 0] += 1
            // month-to-date vs the same stretch of last month
            if e.time >= monthStart { monthWords += e.words } else if e.time >= lastMonthStart && e.time < lastMonthCutoff { lastMonthWords += e.words }
            appSet.insert(e.app)
        }
        apps = appSet.count
        wpm = speech > 0 ? Int((Double(speechWords) / speech * 60).rounded()) : 0
        let names = ["Personal messages", "Work messages", "Emails", "AI prompts", "Documents", "Other"]
        categories = names.map { ($0, cats[$0] ?? 0) }.sorted { $0.1 > $1.1 }
        // streaks: consecutive days with words; current streak ends at the last active day (yesterday counts)
        let days = Set(daily.filter { $0.value > 0 }.keys)
        var run = 0, prev: Date?
        for d in days.sorted() {
            run = prev.map { cal.dateComponents([.day], from: $0, to: d).day == 1 } == true ? run + 1 : 1
            longest = max(longest, run); prev = d
        }
        if let last = days.max(), cal.dateComponents([.day], from: last, to: cal.startOfDay(for: Date())).day ?? 9 <= 1 {
            var d = last; streak = 0
            while days.contains(d) { streak += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        }
    }
}

// MARK: dictionary

struct DictFile: Codable { var words: [WordEntry] = []; var snippets: [Snippet] = [] }

@Observable @MainActor final class DictionaryStore {
    private(set) var file = DictFile()
    var matcher: UserDictionary { UserDictionary(words: file.words, snippets: file.snippets) }
    let url = support.appendingPathComponent("dictionary.json")

    init() {
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(DictFile.self, from: d) { file = f; return }
        // first run of this version: migrate dictionary.txt
        let txt = support.appendingPathComponent("dictionary.txt")
        if let s = try? String(contentsOf: txt, encoding: .utf8) {
            let m = UserDictionary(contents: s)
            file = DictFile(words: m.words, snippets: m.snippets)
            try? FileManager.default.moveItem(at: txt, to: support.appendingPathComponent("dictionary.txt.migrated"))
        } else {
            file.words = ["Claude", "Claude Code", "Codex", "ChatGPT", "Anthropic"].map { WordEntry(word: $0) }
        }
        save()
    }

    func save() { if let d = try? JSONEncoder().encode(file) { try? d.write(to: url, options: .atomic) } }

    static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func exists(_ s: String, except: UUID? = nil) -> Bool {
        let k = s.lowercased()
        return file.words.contains { $0.id != except && ($0.word.lowercased() == k || $0.misspelling?.lowercased() == k) }
            || file.snippets.contains { $0.id != except && $0.trigger.lowercased() == k }
    }

    /// Returns an error message, or nil when saved.
    func saveWord(_ w: WordEntry) -> String? {
        var w = w
        w.word = Self.clean(w.word); w.misspelling = w.misspelling.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
        guard w.word.contains(where: { $0.isLetter || $0.isNumber }) else { return "Enter a word" }
        guard w.word.count <= 60, (w.misspelling?.count ?? 0) <= 60 else { return "Max 60 characters" }
        if exists(w.word, except: w.id) || (w.misspelling.map { exists($0, except: w.id) } ?? false) { return "“\(w.word)” is already in your dictionary" }
        if let i = file.words.firstIndex(where: { $0.id == w.id }) { file.words[i] = w } else { file.words.insert(w, at: 0) }
        save(); return nil
    }

    func saveSnippet(_ s: Snippet) -> String? {
        var s = s
        s.trigger = Self.clean(s.trigger); s.expansion = Self.clean(s.expansion)
        guard s.trigger.contains(where: { $0.isLetter || $0.isNumber }), !s.expansion.isEmpty else { return "Enter a snippet and its expansion" }
        guard s.trigger.count <= 60 else { return "Snippet is too long (max 60 characters)" }
        guard s.expansion.count <= 4000 else { return "This expansion is too long (max 4,000 characters)" }
        if exists(s.trigger, except: s.id) { return "“\(s.trigger)” already exists" }
        if let i = file.snippets.firstIndex(where: { $0.id == s.id }) { file.snippets[i] = s } else { file.snippets.insert(s, at: 0) }
        save(); return nil
    }

    func deleteWords(_ ids: Set<UUID>) { file.words.removeAll { ids.contains($0.id) }; save() }
    func deleteSnippets(_ ids: Set<UUID>) { file.snippets.removeAll { ids.contains($0.id) }; save() }
    func toggleStar(_ id: UUID) { if let i = file.words.firstIndex(where: { $0.id == id }) { file.words[i].starred.toggle(); save() } }

    func bump(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for i in file.words.indices where ids.contains(file.words[i].id) { file.words[i].uses += 1 }
        for i in file.snippets.indices where ids.contains(file.snippets[i].id) { file.snippets[i].uses += 1 }
        save()
    }

    func contains(_ word: String) -> Bool { exists(word) }

    /// Import .json (our export, or a plain array of strings) or .txt/.csv (one entry per line, "a -> b", "x => y").
    func importFile(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        var incoming = DictFile()
        if let f = try? JSONDecoder().decode(DictFile.self, from: data) { incoming = f }
        else if let a = try? JSONDecoder().decode([String].self, from: data) { incoming.words = a.map { WordEntry(word: $0) } }
        else if let s = String(data: data, encoding: .utf8) {
            let m = UserDictionary(contents: s.replacingOccurrences(of: "\"", with: ""))
            incoming = DictFile(words: m.words, snippets: m.snippets)
        }
        var n = 0
        for w in incoming.words.prefix(1000) where saveWord(WordEntry(word: w.word, misspelling: w.misspelling)) == nil { n += 1 }
        for s in incoming.snippets.prefix(1000) where saveSnippet(Snippet(trigger: s.trigger, expansion: s.expansion)) == nil { n += 1 }
        return n
    }

    func exportJSON() -> Data { (try? JSONEncoder().encode(file)) ?? Data() }
}

// MARK: notes (Scratchpad)

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var text = ""
    var updated = Date()
    var title: String {
        let t = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? "New note" : String(t.prefix(60))
    }
}

@Observable @MainActor final class NotesStore {
    var notes: [Note] = []
    let url = support.appendingPathComponent("notes.json")

    init() {
        if let d = try? Data(contentsOf: url), let n = try? JSONDecoder().decode([Note].self, from: d) { notes = n }
    }

    func save() { if let d = try? JSONEncoder().encode(notes) { try? d.write(to: url, options: .atomic) } }

    @discardableResult func new() -> UUID {
        if let first = notes.first, first.text.isEmpty { return first.id }
        let n = Note(); notes.insert(n, at: 0); save(); return n.id
    }

    func set(_ id: UUID, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text; notes[i].updated = Date()
        save()
    }

    func delete(_ id: UUID) { notes.removeAll { $0.id == id }; save() }
}

// MARK: audio files

enum WAV {
    /// 16 kHz mono 16-bit PCM.
    static func write(_ samples: [Float], to url: URL) {
        var d = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        try? d.write(to: url)
    }
}

// MARK: import from Wispr Flow (read-only copy of its local database)

enum WisprImport {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wispr Flow")
    static var available: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("flow.sqlite").path) }

    static func read() -> (entries: [Entry], words: [WordEntry], snippets: [Snippet])? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wispr-import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.copyItem(at: dir.appendingPathComponent("flow.sqlite\(ext)"), to: tmp.appendingPathComponent("flow.sqlite\(ext)"))
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.appendingPathComponent("flow.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        func rows(_ sql: String, _ each: (OpaquePointer) -> Void) {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
            while sqlite3_step(st) == SQLITE_ROW { each(st) }
            sqlite3_finalize(st)
        }
        func str(_ st: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        var entries: [Entry] = []
        rows("""
            select transcriptEntityId, asrText, coalesce(pastedText, formattedText, asrText), timestamp, app, url,
                   coalesce(speechDuration, duration, 0), coalesce(numWords, 0), coalesce(numWordsCorrected, 0),
                   coalesce(numDictionaryReplacements, 0)
            from History where status in ('formatted', 'raw_transcript', '') and coalesce(isArchived, 0) = 0
            """) { st in
            var e = Entry()
            e.id = str(st, 0).flatMap(UUID.init(uuidString:)) ?? UUID()
            e.raw = str(st, 1) ?? ""; e.text = str(st, 2) ?? ""
            e.time = str(st, 3).flatMap { df.date(from: $0) } ?? Date()
            e.app = str(st, 4) ?? ""; e.url = str(st, 5).flatMap { $0 == "unknown" ? nil : $0 }
            e.seconds = sqlite3_column_double(st, 6)
            e.words = Int(sqlite3_column_int(st, 7)); if e.words == 0 { e.words = wordCount(e.text) }
            e.fixes = Int(sqlite3_column_int(st, 8)); e.dictFixes = Int(sqlite3_column_int(st, 9)); e.imported = true
            if !e.text.isEmpty { entries.append(e) }
        }
        var words: [WordEntry] = [], snippets: [Snippet] = []
        rows("select phrase, replacement, isSnippet, isStarred, frequencyUsed, observedSource, manualEntry from Dictionary where isDeleted = 0") { st in
            guard let phrase = str(st, 0) else { return }
            if sqlite3_column_int(st, 2) == 1, let exp = str(st, 1) { snippets.append(Snippet(trigger: phrase, expansion: exp)); return }
            var w = WordEntry(word: phrase, learned: sqlite3_column_int(st, 6) == 0 && str(st, 5) != nil, heard: str(st, 5))
            if let r = str(st, 1) { w = WordEntry(word: r, misspelling: phrase) }   // "phrase -> replacement"
            w.starred = sqlite3_column_int(st, 3) == 1; w.uses = Int(sqlite3_column_int(st, 4))
            words.append(w)
        }
        return (entries, words, snippets)
    }
}
