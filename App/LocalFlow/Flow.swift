import AppKit
import AVFoundation
import FlowCore
import Observation
import os

let logger = Logger(subsystem: "local.flow", category: "app")

/// Everything that happens between a key press and text landing in the app you're using.
@Observable @MainActor final class AppModel {
    enum Phase { case idle, recording, processing, transforming }
    enum Mode { case dictation, command }

    let settings = Settings.shared
    let history = HistoryStore()
    let dict = DictionaryStore()
    let notes = NotesStore()
    @ObservationIgnored let asr = Transcriber()
    @ObservationIgnored let cleaner = Cleaner()
    @ObservationIgnored let assistant = Assistant(directory: support.appendingPathComponent("models/assistant"))
    @ObservationIgnored let recorder = Recorder()
    @ObservationIgnored let bar = FlowBar()
    @ObservationIgnored var engine: HotkeyEngine?
    @ObservationIgnored var onScratchpad: () -> Void = {}

    var modelStatus = "Loading models…"
    var asrReady = false
    var downloadProgress: Double?
    var micOK = false
    var axOK = false
    var phase = Phase.idle
    var mode = Mode.dictation
    var handsFree = false
    var lastText = ""
    var scratchNote: UUID?            // note the floating Scratchpad should show
    var micLevel: Float = 0           // for the mic test meter
    var micTesting = false

    @ObservationIgnored private var pressAt = Date.distantPast
    @ObservationIgnored private var lastTap = Date.distantPast
    @ObservationIgnored private var startedAt = Date.distantPast
    @ObservationIgnored private var context: Task<AppInfo, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var levelTimer: Timer?
    @ObservationIgnored private var capTimer: Timer?
    @ObservationIgnored private var mutedByUs = false
    @ObservationIgnored private var lastLLM = false

    var status: String {
        if !micOK { return "Needs Microphone access" }
        if !axOK { return "Needs Accessibility access" }
        return modelStatus
    }

    init() {
        bar.onClick = { [weak self] in self?.barClicked() }
        bar.onCancel = { [weak self] in self?.cancel() }
        bar.idle()
    }

    // MARK: startup

    func loadModels() async {
        do {
            modelStatus = "Loading speech model…"
            try await asr.load()   // FluidAudio downloads Parakeet on first launch
            asrReady = true
            do {   // dictation already works without these; cleanup and Command Mode follow once they're in
                for m in [ModelDownload.cleaner, .cleanerFix] where !m.installed(in: support) { try await download(m, "cleanup model") }
            } catch { modelStatus = "Couldn't download the cleanup model (\(error.localizedDescription)). Dictation works without it." }
            let llm = support.appendingPathComponent("models/cleaner")
            if FileManager.default.fileExists(atPath: llm.path) {
                modelStatus = "Loading cleanup model…"
                try await cleaner.load(directory: llm, fixDirectory: support.appendingPathComponent("models/cleaner-fix"))
                _ = try? await cleaner.clean("warm up", category: "other")  // compile kernels before first use
            }
            if cleaner.isLoaded || !modelStatus.hasPrefix("Couldn't") { modelStatus = cleaner.isLoaded ? "Ready — hold fn to dictate" : "Ready (no cleanup model)" }
            if !ModelDownload.assistant.installed(in: support) {   // Command Mode / Transforms model, in the background
                let ready = modelStatus
                try? await download(.assistant, "assistant model")
                modelStatus = ready
            }
        } catch { modelStatus = "Model error: \(error.localizedDescription)" }
    }

    /// Downloads one model, showing progress in the status line and on Home.
    private func download(_ m: ModelDownload, _ label: String) async throws {
        modelStatus = "Downloading \(label)…"; downloadProgress = 0
        defer { downloadProgress = nil }
        try await m.fetch(into: support) { p in
            Task { @MainActor [weak self] in self?.downloadProgress = p; self?.modelStatus = "Downloading \(label)… \(Int(p * 100))%" }
        }
    }

    /// Permissions can change while we run; the key tap only works once Accessibility is on.
    func refreshPermissions() {
        micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let trusted = AXIsProcessTrusted()
        if trusted && (engine == nil || !axOK) { makeEngine() }
        axOK = trusted
    }

    func makeEngine() {
        engine = HotkeyEngine()
        engine?.onPress = { [weak self] id in MainActor.assumeIsolated { self?.pressed(id) } }
        engine?.onRelease = { [weak self] id in MainActor.assumeIsolated { self?.released(id) } }
        engine?.onOtherKey = { [weak self] in MainActor.assumeIsolated { self?.otherKey() } }
        engine?.onEscape = { [weak self] in MainActor.assumeIsolated { self?.escape() ?? false } }
        updateBindings()
        logger.notice("hotkeys armed: \(self.engine != nil)")
    }

    func updateBindings() {
        var b = settings.p.shortcuts.map { ($0.value, $0.key) }
        if !settings.p.commandMode { b.removeAll { $0.1 == "command" } }
        if settings.p.transformsOn { b += settings.p.transforms.compactMap { t in t.shortcut.map { ($0, "t:\(t.id)") } } }
        else { b.removeAll { $0.1 == "polish" || $0.1 == "promptEngineer" } }
        engine?.bindings = b
    }

    func shortcutOwner(_ s: Shortcut) -> String? {
        if let k = settings.p.shortcuts.first(where: { $0.value == s })?.key { return Shortcut.titles.first { $0.0 == k }?.1 ?? k }
        return settings.p.transforms.first { $0.shortcut == s }?.name
    }

    func setShortcut(_ id: String, _ s: Shortcut?) {
        if id.hasPrefix("t:") {
            if let i = settings.p.transforms.firstIndex(where: { "t:\($0.id)" == id }) { settings.p.transforms[i].shortcut = s }
        } else { settings.p.shortcuts[id] = s }
        updateBindings()
    }

    // MARK: keys

    func pressed(_ id: String) {
        switch id {
        case "ptt": pttDown()
        case "command": commandDown()
        case "handsFree": toggleHandsFree()
        case "pasteLast": pasteLast()
        case "copyLast": copyLast()
        case "scratchpad": onScratchpad()
        default:
            if let t = transformPrompt(id.hasPrefix("t:") ? String(id.dropFirst(2)) : id) { transform(t.name, t.prompt) }
        }
    }

    /// "polish", "promptEngineer" or a custom transform's id → (name, system prompt).
    func transformPrompt(_ id: String) -> (name: String, prompt: String)? {
        switch id {
        case "polish": return ("Polish", settings.polishPrompt)
        case "promptEngineer": return ("Prompt Engineer", Assistant.promptEngineer)
        default:
            guard let t = settings.p.transforms.first(where: { $0.id.uuidString == id }), !t.prompt.isEmpty else { return nil }
            return (t.name, t.prompt + "\nKeep the original language unless told otherwise. Output only the resulting text, no commentary.")
        }
    }

    func released(_ id: String) {
        guard id == "ptt" || id == "command", phase == .recording, !handsFree else { return }
        let held = Date().timeIntervalSince(pressAt)
        if held >= 0.3 { stop(); return }
        if mode == .dictation, Date().timeIntervalSince(lastTap) < 0.45 {   // double-tap: lock into hands-free
            handsFree = true; bar.show(.handsFree); return
        }
        lastTap = Date()
        cancel()  // a quick tap isn't a dictation
    }

    private func pttDown() {
        if phase == .recording, handsFree { stop(); return }
        guard phase == .idle else { return }
        pressAt = Date()
        start(.dictation)
    }

    private func commandDown() {
        guard settings.p.commandMode else { return }
        if phase == .recording, mode == .dictation, !handsFree { mode = .command; bar.show(.command); return }  // fn, then ⌃
        guard phase == .idle else { return }
        pressAt = Date()
        start(.command)
    }

    private func toggleHandsFree() {
        if phase == .recording {
            if handsFree { Date().timeIntervalSince(startedAt) < 0.5 ? cancel() : stop() }
            else { handsFree = true; bar.show(.handsFree) }
        } else if phase == .idle {
            start(.dictation); handsFree = true; bar.show(.handsFree)
        }
    }

    private func barClicked() {
        if phase == .recording && handsFree { Date().timeIntervalSince(startedAt) < 0.5 ? cancel() : stop() }
        else if phase == .idle { toggleHandsFree() }
    }

    private func otherKey() {
        // fn+arrow, ⌥+letter…: that wasn't a dictation
        if phase == .recording, !handsFree, Date().timeIntervalSince(startedAt) < 1 { cancel() }
    }

    private func escape() -> Bool {
        switch phase {
        case .recording: cancel(); return true
        case .processing, .transforming: work?.cancel(); bar.notice("Cancelled"); return true
        case .idle: return false
        }
    }

    // MARK: recording

    func start(_ mode: Mode) {
        guard asrReady, phase == .idle, !micTesting else {
            if !asrReady { bar.notice("Still loading the speech model…") }
            return
        }
        do { try recorder.start(deviceUID: settings.p.micUID) } catch {
            logger.error("mic: \(error.localizedDescription, privacy: .public)")
            bar.notice("Microphone unavailable"); return
        }
        phase = .recording; self.mode = mode; handsFree = false; startedAt = Date()
        logger.notice("recording \(mode == .command ? "command" : "dictation", privacy: .public)")
        Sounds.play("Tink")
        if settings.p.muteAudio { mutedByUs = AudioDevices.setOutputMuted(true) }
        let deep = settings.p.contextAware
        context = Task.detached { Context.capture(deep: deep) }  // AX reads can be slow; never on the key path
        bar.show(mode == .command ? .command : .recording)
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.bar.push(level: self.recorder.level) }
        }
        capTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                let m = Date().timeIntervalSince(self.startedAt) / 60
                if m >= 20 { self.stop() } else if m >= 19 { self.bar.notice("1 minute left (20-minute limit)") }
            }
        }
    }

    private func endRecording() -> [Float] {
        levelTimer?.invalidate(); capTimer?.invalidate()
        let s = recorder.stop()
        if mutedByUs { _ = AudioDevices.setOutputMuted(false); mutedByUs = false }
        return s
    }

    func cancel() {
        guard phase == .recording else { return }
        logger.notice("cancelled")
        _ = endRecording()
        phase = .idle; handsFree = false
        bar.idle()
    }

    func stop() {
        guard phase == .recording else { return }
        let samples = endRecording()
        Sounds.play("Pop")
        phase = .processing; handsFree = false
        bar.show(.processing)
        let mode = self.mode
        work = Task { await process(samples, mode: mode); phase = .idle; bar.idle() }
    }

    // MARK: pipeline

    struct Formatted { var text: String; var fixes: Int; var dictFixes: Int; var enter: Bool }

    private func process(_ samples: [Float], mode: Mode) async {
        let t0 = Date()
        let info = await context?.value ?? AppInfo()
        let level = Recorder.rms(samples)
        guard samples.count > 16000 / 4, level > (settings.p.whisperMode ? 0.0012 : 0.004) else {
            logger.notice("skipped: \(samples.count) samples, rms \(level)"); return
        }
        var audio = level < 0.03 ? Recorder.normalized(samples) : samples
        if audio.count < 16000 { audio += [Float](repeating: 0, count: 16000 - audio.count) }
        do {
            let raw = try await asr.transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
            let tAsr = Date()
            guard !Task.isCancelled else { return }
            guard !raw.isEmpty else { bar.notice("No speech detected"); return }
            if mode == .command { await command(raw, info: info, samples: samples); return }
            var f = try await format(raw, info: info)
            if settings.p.autoApplyOn, assistant.isAvailable, wordCount(f.text) >= 4, let t = transformPrompt(settings.p.autoApply),
               let out = try? await assistant.rewrite(system: t.prompt, text: f.text, maxTokens: min(4000, wordCount(f.text) * 3 + 200)), !out.isEmpty {
                f.text = Inserter.spaced(out, after: info.charBefore)   // Transforms → Auto Apply After Dictation
            }
            let tFmt = Date()
            guard !Task.isCancelled else { return }
            await Inserter.paste(f.text)
            logger.notice("timing asr=\(Int(tAsr.timeIntervalSince(t0) * 1000)) format=\(Int(tFmt.timeIntervalSince(tAsr) * 1000)) paste=\(Int(Date().timeIntervalSince(tFmt) * 1000)) llm=\(self.lastLLM)")
            if f.enter { try? await Task.sleep(for: .milliseconds(250)); Inserter.key(36) }
            lastText = f.text
            var e = Entry()
            e.app = info.bundleID; e.appName = info.name; e.url = info.url; e.seconds = Double(samples.count) / 16000
            e.raw = raw; e.text = f.text.trimmingCharacters(in: .whitespaces); e.words = wordCount(e.text)
            e.fixes = f.fixes; e.dictFixes = f.dictFixes
            e.asrMs = Int(tAsr.timeIntervalSince(t0) * 1000); e.totalMs = Int(Date().timeIntervalSince(t0) * 1000)
            saveAudio(samples, &e)
            history.add(e)
            logger.notice("dictation \(e.totalMs ?? 0)ms app=\(info.bundleID, privacy: .public)")
            watchEdits(info, inserted: f.text)
        } catch { logger.error("pipeline: \(error.localizedDescription, privacy: .public)"); bar.notice("Something went wrong") }
    }

    func saveAudio(_ samples: [Float], _ e: inout Entry) {
        guard settings.p.keepHistory != .never else { return }
        e.audio = "\(e.id).wav"
        WAV.write(samples, to: support.appendingPathComponent("audio/\(e.id).wav"))
    }

    /// Raw transcript → the text to paste (cleanup, snippets, dictionary, style, spacing).
    func format(_ raw: String, info: AppInfo) async throws -> Formatted {
        var raw = raw, enter = false
        if settings.p.pressEnter,
           let r = raw.range(of: "[,.]?\\s*\\b(press|hit|aperta|aperte|pressiona) (enter|return|o enter)[.!]?$", options: [.regularExpression, .caseInsensitive]) {
            raw = String(raw[..<r.lowerBound]); enter = true
        }
        let m = dict.matcher
        if let s = m.snippet(for: raw) { dict.bump([s.id]); return Formatted(text: Inserter.spaced(s.expansion, after: info.charBefore), fixes: 0, dictFixes: 1, enter: enter) }
        let category = Text.category(info.key), vocab = m.terms + info.names.filter { !m.terms.contains($0) }
        var text = raw
        lastLLM = false
        if settings.p.cleanup != .none, cleaner.isLoaded, Text.needsCleanup(raw, category: category, vocabulary: vocab) {
            text = try await cleaner.clean(raw, category: category, vocabulary: vocab)
            lastLLM = true
        }
        if settings.p.cleanup == .medium, assistant.isAvailable, wordCount(text) > 12 {
            let p = try await assistant.rewrite(system: Assistant.tidySystem, text: text, maxTokens: wordCount(text) * 3 + 100)
            // same safety checks as cleanup, plus: most of the speaker's words survive (an answer or a free rewrite doesn't)
            if !p.isEmpty, Text.guarded(raw: text, cleaned: p) == p, Text.kept(raw: text, out: p) >= 0.8 { text = p }
        }
        let (t1, sn) = m.expandSnippets(text)
        let (t2, rp) = m.applyReplacements(t1)
        dict.bump(sn + rp)
        var out = t2
        if settings.p.cleanup != .none { out = Text.styled(out, tone: settings.tone(Text.styleCategory(info.key)), keep: Set(m.terms)) }
        out = Inserter.matchCase(out, before: info.textBefore, keep: Set(m.terms))
        return Formatted(text: Inserter.spaced(out, after: info.charBefore), fixes: Self.wordDiff(raw, text),
                         dictFixes: sn.count + rp.count, enter: enter)
    }

    /// Words changed between two versions (word-level edit distance).
    static func wordDiff(_ a: String, _ b: String) -> Int {
        let x = a.lowercased().split { !$0.isLetter && !$0.isNumber }, y = b.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard !x.isEmpty, !y.isEmpty, x.count < 2000, y.count < 2000 else { return 0 }
        var d = Array(0...y.count)
        for i in 1...x.count {
            var prev = d[0]; d[0] = i
            for j in 1...y.count { let cur = d[j]; d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1)); prev = cur }
        }
        return d[y.count]
    }

    // MARK: command mode & transforms

    static let searchIntent = try! NSRegularExpression(pattern: "^(search( the web)?( for)?|google|look up|pesquis[ae]r?( por)?|procur[ae]r?( por)?|busc[ae]r?( por)?)\\s+", options: .caseInsensitive)

    private func command(_ instruction: String, info: AppInfo, samples: [Float]) async {
        phase = .transforming; bar.show(.transforming)
        var e = Entry()
        e.app = info.bundleID; e.appName = info.name; e.url = info.url; e.seconds = Double(samples.count) / 16000
        e.mode = "command"; e.instruction = instruction; e.raw = instruction
        if let m = Self.searchIntent.firstMatch(in: instruction, range: NSRange(instruction.startIndex..., in: instruction)),
           let r = Range(m.range, in: instruction) {
            let q = (String(instruction[r.upperBound...]) + " " + info.selected).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            if let u = c.url { NSWorkspace.shared.open(u) }
            e.text = q; history.add(e); return
        }
        guard assistant.isAvailable else { bar.notice("Command Mode model is missing"); return }
        var selected = info.selected
        if selected.isEmpty, !info.selectionKnown { selected = await Inserter.copySelection() ?? "" }
        do {
            let out: String
            if !selected.isEmpty {
                out = try await assistant.run(system: Assistant.editSystem, user: "Instruction: \(instruction)\n\nText:\n\(selected)",
                                              maxTokens: min(4000, wordCount(selected) * 3 + 300))
            } else {
                let ctx = String(info.textBefore.suffix(2000))
                out = try await assistant.run(system: Assistant.writeSystem,
                                              user: (ctx.isEmpty ? "" : "Text before the cursor:\n\(ctx)\n\n") + "Instruction: \(instruction)")
            }
            guard !Task.isCancelled, !out.isEmpty else { return }
            await Inserter.paste(selected.isEmpty ? Inserter.spaced(out, after: info.charBefore) : out)
            lastText = out
            e.before = selected.isEmpty ? nil : selected; e.text = out; e.words = wordCount(out)
            history.add(e)
        } catch { if !Task.isCancelled { bar.notice("Command failed") } }
    }

    func transform(_ name: String, _ system: String) {
        guard phase == .idle else { return }
        guard assistant.isAvailable else { bar.notice("Transforms model is missing"); return }
        phase = .transforming; bar.show(.transforming)
        work = Task {
            defer { phase = .idle; bar.idle() }
            let info = await Task.detached { Context.capture(deep: false) }.value
            var text = info.selected
            if text.isEmpty, !info.selectionKnown { text = await Inserter.copySelection() ?? "" }
            if text.isEmpty, let el = info.element { text = Inserter.selectAll(el) ?? "" }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { bar.notice("Select text to apply a transform"); return }
            guard wordCount(text) <= 3000 else { bar.notice("Too long to transform (max 3,000 words)"); return }
            do {
                let out = try await assistant.rewrite(system: system, text: text, maxTokens: min(4000, wordCount(text) * 3 + 200))
                guard !Task.isCancelled, !out.isEmpty else { return }
                if out == text.trimmingCharacters(in: .whitespacesAndNewlines) { bar.notice("Your text looks good!"); return }
                await Inserter.paste(out)
                lastText = out
                var e = Entry()
                e.app = info.bundleID; e.appName = info.name; e.mode = "transform"; e.instruction = name
                e.before = text; e.text = out; e.words = wordCount(out)
                history.add(e)
            } catch { if !Task.isCancelled { bar.notice("Transform failed") } }
        }
    }

    // MARK: last transcript, retry

    func pasteLast() {
        guard !lastText.isEmpty || history.entries.first != nil else { bar.notice("Nothing dictated yet"); return }
        let t = lastText.isEmpty ? history.entries.first!.text : lastText
        work?.cancel()
        Task { await Inserter.paste(t) }
    }

    func copyLast() {
        let t = lastText.isEmpty ? (history.entries.first?.text ?? "") : lastText
        guard !t.isEmpty else { bar.notice("Nothing dictated yet"); return }
        copy(t)
        bar.notice("Copied last transcript")
    }

    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    /// Re-transcribe and re-format a saved recording (the result replaces the entry; nothing is pasted).
    func retry(_ entry: Entry) async {
        guard let url = entry.audioURL, let samples = try? Transcriber.loadFile(url) else { bar.notice("No saved audio for this one"); return }
        do {
            var audio = Recorder.rms(samples) < 0.03 ? Recorder.normalized(samples) : samples
            if audio.count < 16000 { audio += [Float](repeating: 0, count: 16000 - audio.count) }
            let raw = try await asr.transcribe(audio)
            var info = AppInfo(); info.bundleID = entry.app; info.name = entry.appName ?? ""; info.url = entry.url
            let f = try await format(raw, info: info)
            var e = entry
            e.raw = raw; e.text = f.text.trimmingCharacters(in: .whitespaces); e.words = wordCount(e.text); e.fixes = f.fixes; e.dictFixes = f.dictFixes
            history.update(e)
            lastText = e.text
            bar.notice("Transcript retried")
        } catch { bar.notice("Retry failed") }
    }

    // MARK: learning from your edits

    /// After a paste, look at the same text field again later; words you corrected (near-spellings, capitalization)
    /// go into the dictionary, and the before/after pair is kept for retraining.
    private func watchEdits(_ info: AppInfo, inserted: String) {
        guard settings.p.autoLearn, let el = info.element, let loc = info.location, wordCount(inserted) >= 2 else { return }
        for delay in [12.0, 40.0, 90.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.checkEdits(el, loc, inserted, info) }
        }
    }

    @ObservationIgnored private var logged = Set<String>()

    private func checkEdits(_ el: AXUIElement, _ loc: Int, _ inserted: String, _ info: AppInfo) {
        guard let value = Context.attr(el, kAXValueAttribute) as? String else { return }
        let u = Array(value.utf16)
        let now = Context.slice(u, loc - 200, loc + inserted.utf16.count + 200)
        guard !now.contains(inserted.trimmingCharacters(in: .whitespaces)) else { return }  // untouched
        for c in Learner.corrections(inserted: inserted, now: now) where !dict.contains(c.word) && Self.distinctive(c.word, heard: c.heard) {
            if dict.saveWord(WordEntry(word: c.word, learned: true, heard: c.heard)) == nil {
                bar.notice("Added “\(c.word)” to your dictionary")
                logger.notice("learned \(c.word, privacy: .public)")
            }
        }
        let key = inserted + "|" + now
        guard !logged.contains(key) else { return }
        logged.insert(key)
        let row: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "app": info.bundleID, "inserted": inserted, "edited": now]
        if let d = try? JSONSerialization.data(withJSONObject: row), let h = try? FileHandle(forWritingTo: support.appendingPathComponent("edits.jsonl")) {
            h.seekToEndOfFile(); h.write(d + Data("\n".utf8)); try? h.close()
        } else if let d = try? JSONSerialization.data(withJSONObject: row) {
            try? (d + Data("\n".utf8)).write(to: support.appendingPathComponent("edits.jsonl"))
        }
    }

    /// Names, jargon and brand spellings, not everyday words (those are typo fixes, not vocabulary).
    static func distinctive(_ word: String, heard: String) -> Bool {
        if word.dropFirst().contains(where: \.isUppercase) || word.contains(where: \.isNumber) { return true }   // GSAP, ChatGPT, L298N
        let known = ["en", "pt_BR"].contains { lang in
            NSSpellChecker.shared.checkSpelling(of: word.lowercased(), startingAt: 0, language: lang, wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        if !known { return true }
        return heard.lowercased() == word.lowercased() && word.first!.isUppercase && heard.first!.isLowercase  // "maria" → "Maria"
    }

    /// Test hook: run the dictation pipeline on a WAV file as if it had just been recorded.
    func testFile(_ path: String, mode: Mode = .dictation) {
        guard phase == .idle, let samples = try? Transcriber.loadFile(URL(fileURLWithPath: path)) else { return }
        logger.notice("test file \(path, privacy: .public)")
        let deep = settings.p.contextAware
        context = Task.detached { Context.capture(deep: deep) }
        phase = .processing; bar.show(.processing)
        work = Task { await process(samples, mode: mode); phase = .idle; bar.idle() }
    }

    // MARK: mic test

    func startMicTest() {
        guard phase == .idle, !micTesting else { return }
        guard (try? recorder.start(deviceUID: settings.p.micUID)) != nil else { return }
        micTesting = true
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.micLevel = self.recorder.level }
        }
    }

    func stopMicTest() {
        guard micTesting else { return }
        levelTimer?.invalidate(); _ = recorder.stop(); micTesting = false; micLevel = 0
    }
}
