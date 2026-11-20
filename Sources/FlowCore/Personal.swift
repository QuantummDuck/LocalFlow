import Foundation

// MARK: dictionary & snippets

public struct WordEntry: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var word: String
    public var misspelling: String?        // "Correct a misspelling": misspelling → word
    public var starred = false
    public var learned = false             // auto-added from an edit you made after a paste
    public var heard: String?              // what was transcribed before you corrected it
    public var uses = 0
    public var added = Date()
    public init(word: String, misspelling: String? = nil, learned: Bool = false, heard: String? = nil) {
        self.word = word; self.misspelling = misspelling; self.learned = learned; self.heard = heard
    }
}

public struct Snippet: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var trigger: String
    public var expansion: String
    public var uses = 0
    public var added = Date()
    public init(trigger: String, expansion: String) { self.trigger = trigger; self.expansion = expansion }
}

/// The matcher built from your dictionary and snippets.
public struct UserDictionary {
    public var words: [WordEntry] = [], snippets: [Snippet] = []

    public init(words: [WordEntry] = [], snippets: [Snippet] = []) { self.words = words; self.snippets = snippets }

    /// Legacy dictionary.txt: one term per line; "a -> b" replacement; "trigger => expansion" snippet; "#" comments.
    public init(contents: String) {
        for line in contents.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
        where !line.isEmpty && !line.hasPrefix("#") {
            if let r = line.range(of: "=>") {
                snippets.append(Snippet(trigger: line[..<r.lowerBound].trimmingCharacters(in: .whitespaces),
                                        expansion: line[r.upperBound...].trimmingCharacters(in: .whitespaces)))
            } else if let r = line.range(of: "->") {
                words.append(WordEntry(word: line[r.upperBound...].trimmingCharacters(in: .whitespaces),
                                       misspelling: line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)))
            } else { words.append(WordEntry(word: line)) }
        }
    }

    /// Terms the cleanup model should spell this way (starred first).
    public var terms: [String] { words.filter { $0.misspelling == nil }.sorted { $0.starred && !$1.starred }.map(\.word) }

    static func key(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The whole utterance is a snippet trigger → its expansion, verbatim.
    public func snippet(for text: String) -> Snippet? {
        let k = Self.key(text)
        return k.isEmpty ? nil : snippets.last { Self.key($0.trigger) == k }
    }

    /// Whole-word, case-insensitive; never inside "n't" contractions; longest pattern first.
    /// Returns the new text and the ids of the entries that fired.
    static func replace(_ text: String, _ rules: [(UUID, String, String)]) -> (String, [UUID]) {
        var t = text, fired: [UUID] = []
        for (id, from, to) in rules.sorted(by: { $0.1.count > $1.1.count }) where !from.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}_])\(NSRegularExpression.escapedPattern(for: from))(?![\\p{L}\\p{N}_])(?!['’]t\\b)"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let r = NSRange(t.startIndex..., in: t)
            if re.firstMatch(in: t, range: r) != nil {
                t = re.stringByReplacingMatches(in: t, range: r, withTemplate: NSRegularExpression.escapedTemplate(for: to))
                fired.append(id)
            }
        }
        return (t, fired)
    }

    public func applyReplacements(_ text: String) -> (String, [UUID]) {
        Self.replace(text, words.compactMap { w in w.misspelling.map { (w.id, $0, w.word) } })
    }

    public func expandSnippets(_ text: String) -> (String, [UUID]) {
        Self.replace(text, snippets.map { ($0.id, $0.trigger.trimmingCharacters(in: .whitespacesAndNewlines), $0.expansion) })
    }
}

// MARK: styles

public enum Tone: String, Codable, CaseIterable, Identifiable {
    case formal, casual, veryCasual, excited
    public var id: String { rawValue }
}

public enum StyleCategory: String, Codable, CaseIterable, Identifiable {
    case personal, work, email, other
    public var id: String { rawValue }
    public var tones: [Tone] { self == .personal ? [.formal, .casual, .veryCasual] : [.formal, .casual, .excited] }
}

extension Text {
    static let sentenceEnd = try! NSRegularExpression(pattern: "[.!?…]+(?=\\s|$)")

    /// Wispr's styles are capitalization/punctuation rules applied on top of the cleaned text:
    /// formal = as is; casual = no final period (≤ 10 sentences), no comma after a greeting;
    /// very casual = casual + lowercase sentence starts; excited = final "." becomes "!".
    public static func styled(_ s: String, tone: Tone, keep: Set<String> = []) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, tone != .formal else { return t }
        if tone == .excited {
            if t.hasSuffix("."), !t.hasSuffix("..") { t.removeLast(); t += "!" }
            return t
        }
        let sentences = sentenceEnd.numberOfMatches(in: t, range: NSRange(t.startIndex..., in: t))
        if sentences <= 10 || tone == .veryCasual { while t.hasSuffix(".") || t.hasSuffix("…") { t.removeLast() } }
        t = t.replacingOccurrences(of: "^(?i)(hey|hi|hello|hiya|yo|oi|olá|ola|e aí|thanks|valeu|obrigad[oa]),", with: "$1",
                                   options: .regularExpression)
        guard tone == .veryCasual else { return t }
        // lowercase the first word of each sentence/line, and "I", unless it's a name you keep capitalized or an acronym
        let keepLower = Set(keep.map { $0.lowercased() })
        let re = try! NSRegularExpression(pattern: "(^|[.!?…]\\s+|\\n\\s*)(\\p{Lu}[\\p{L}'’]*)|\\b(I)(?=['’]|\\b)")
        var out = t
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
            let g = m.range(at: 2).location != NSNotFound ? 2 : 3
            guard let r = Range(m.range(at: g), in: t) else { continue }
            let w = String(t[r])
            let acronym = w.count > 1 && w == w.uppercased()
            if g == 2, acronym || keepLower.contains(w.lowercased()) { continue }
            out.replaceSubrange(Range(m.range(at: g), in: out)!, with: w.lowercased())
        }
        return out
    }

    static func table(_ s: String, _ rows: [(String, [String])], _ fallback: String) -> String {
        let a = s.lowercased()
        return rows.first { $0.1.contains(where: a.contains) }?.0 ?? fallback
    }

    /// Which style applies: personal / work / email / other (from bundle id, app name and site).
    public static func styleCategory(_ s: String) -> StyleCategory {
        StyleCategory(rawValue: table(s, [
            ("email", ["mail", "outlook", "spark", "superhuman", "airmail", "mimestream", "missive", "proton.me", "fastmail"]),
            ("work", ["slack", "teams", "linkedin", "chat.google", "mattermost", "lark", "zoom"]),
            ("personal", ["whatsapp", "mobilesms", "messages", "telegram", "signal", "discord", "instagram", "messenger",
                          "facebook", "wechat", "line.naver"]),
        ], "other")) ?? .other
    }

    /// Insights usage buckets (Wispr's six).
    public static func usageCategory(_ s: String) -> String {
        let style = styleCategory(s)
        if style != .other { return ["personal": "Personal messages", "work": "Work messages", "email": "Emails"][style.rawValue]! }
        return table(s, [
            ("AI prompts", ["claude", "chatgpt", "openai", "perplexity", "gemini", "codex", "cursor", "warp", "ghostty"]),
            ("Documents", ["notes", "notion", "pages", "word", "obsidian", "textedit", "docs.google", "bear", "craft"]),
        ], "Other")
    }
}

// MARK: learning from your edits

public enum Learner {
    static func words(_ s: String) -> [String] {
        s.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "-") }.map(String.init)
    }

    /// One-word substitutions you made to text we pasted: `inserted` is what we pasted, `now` is the text
    /// around the same spot a little later. Only near-spellings or capitalization fixes count
    /// (so a rewrite like "good" → "great" is not learned).
    public static func corrections(inserted: String, now: String) -> [(heard: String, word: String)] {
        let a = words(inserted), b = words(now)
        guard !a.isEmpty, !b.isEmpty, a.count <= 400, b.count <= 1200 else { return [] }
        // LCS table
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        guard dp[0][0] * 2 >= a.count else { return [] }  // the pasted text isn't really there any more
        // walk the alignment, collecting gaps between matches
        var out: [(String, String)] = [], i = 0, j = 0, gapA: [String] = [], gapB: [String] = [], started = false
        func flush() {
            if started, gapA.count == 1, gapB.count == 1 { out.append((gapA[0], gapB[0])) }
            gapA.removeAll(); gapB.removeAll()
        }
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                if !started, gapA.count == 1, j > 0 { out.append((gapA[0], b[j - 1])) }  // first word was fixed
                flush(); started = true; i += 1; j += 1
            }
            else if dp[i + 1][j] >= dp[i][j + 1] { gapA.append(a[i]); i += 1 }
            else { if started { gapB.append(b[j]) }; j += 1 }
        }
        let restA = gapA + a[i...], restB = gapB + b[j...]  // last word fixed
        if started, restA.count == 1, let w = restB.first { out.append((restA[0], w)) }
        return out.filter { heard, word in
            guard heard != word, word.count >= 2, word.contains(where: \.isLetter) else { return false }
            if heard.lowercased() == word.lowercased() { return word.first!.isUppercase || word.dropFirst().contains(where: \.isUppercase) }
            return Text.distance(heard.lowercased(), word.lowercased()) <= max(2, word.count / 3)
        }.map { (heard: $0.0, word: $0.1) }
    }
}
