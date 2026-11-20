import FlowCore
import FluidAudio  // AsrModelVersion
import Foundation

// Run from the repo root.
//   flowbench selftest                 text-processing checks
//   flowbench asr [ultra|v3] [vocab]   ASR only        → bench/out/asr-<v>.jsonl
//   flowbench e2e <model-dir> [fix-dir] ASR + cleanup   → bench/out/e2e.jsonl   (score: bench/score.py llm out/e2e.jsonl)
let args = CommandLine.arguments
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("bench")
struct Pair: Codable { let id: String; let app: String?; let audio: Bool; let formatted: String? }

func pairs() throws -> [Pair] {
    try String(contentsOf: root.appendingPathComponent("data/pairs.jsonl"), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(Pair.self, from: Data($0.utf8)) }.filter(\.audio)
}

func jsonl(_ rows: [[String: Any]], _ name: String) throws {
    try FileManager.default.createDirectory(at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
    let s = try rows.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! + "\n" }.joined()
    try s.write(to: root.appendingPathComponent("out/\(name)"), atomically: true, encoding: .utf8)
}

func check(_ ok: Bool, _ msg: String = "", line: Int = #line) {  // precondition messages vanish in -O builds
    if !ok { print("selftest FAILED line \(line) \(msg)"); exit(1) }
}

func ms(_ t: Date) -> Double { Date().timeIntervalSince(t) * 1000 }

switch args.count > 1 ? args[1] : "" {
case "selftest":
    let c = Text.chunks("One two. Three four. Actually, five six.", limit: 2)
    check(c == ["One two.", "Three four. Actually, five six."], "cue sentence stays with previous: \(c)")
    check(Text.chunks("a b c. d e f.", limit: 60) == ["a b c. d e f."])
    check(Text.guarded(raw: "what is two plus two", cleaned: "What is two plus two?") == "What is two plus two?")
    let raw = "please explain how the build system works in this repository"
    check(Text.guarded(raw: raw, cleaned: String(repeating: "answer ", count: 40)) == raw, "long answer rejected")
    check(Text.guarded(raw: raw, cleaned: "") == raw)
    let bt = "the budget is $50,000 for the whole year, scratch that, $60,000"
    check(Text.guarded(raw: bt, cleaned: "The budget is $60,000.") == "The budget is $60,000.", "correction may shrink")
    check(Text.guarded(raw: raw + " for the new team members", cleaned: "Explain it.") != "Explain it.", "no cue: big drop rejected")
    check(Text.guarded(raw: "hi", cleaned: "<think>\n</think>\nHi.") == "Hi.")
    let q = "I'm trying to use a service called Oathbreaker and could you tell me more about it? I don't know how it works."
    let ans = "Oathbreaker is a service that allows users to break oaths or promises. It is not widely recognized or verified."
    check(Text.guarded(raw: q, cleaned: ans) == q, "answer to a question rejected")
    check(Text.kept(raw: q, out: ans) < 0.7, "answer keeps few words")
    check(Text.kept(raw: q, out: "I'm trying to use a service called Oathbreaker. Could you tell me more about it? I don't know how it works.") >= 0.7)
    check(Text.category("com.anthropic.claudefordesktop Claude") == "AI chat")
    check(Text.category("com.apple.mail Mail") == "email")
    check(Text.category("com.foo.bar") == "other")
    let d = UserDictionary(contents: "# c\nClaude\nbtw -> by the way\nmy email => me@x.com\n")
    check(d.terms == ["Claude"])
    check(d.snippet(for: "My email.")?.expansion == "me@x.com")
    check(d.applyReplacements("ok btw, fine").0 == "ok by the way, fine")
    check(d.expandSnippets("Send it to my email, please.").0 == "Send it to me@x.com, please.", "inline snippet")
    check(d.expandSnippets("Send it to my emails.").0 == "Send it to my emails.", "whole words only")
    let d2 = UserDictionary(words: [WordEntry(word: "Dawn", misspelling: "Don"), WordEntry(word: "Bob", misspelling: "John")])
    check(d2.applyReplacements("Don't tell Don.").0 == "Don't tell Dawn.", "n't untouched")
    check(d2.applyReplacements("john's car").0 == "Bob's car", "possessive")
    check(Text.styled("Hey, are you free tomorrow? Let's do lunch.", tone: .casual) == "Hey are you free tomorrow? Let's do lunch")
    check(Text.styled("Hey, are you free tomorrow? I think Claude can help.", tone: .veryCasual, keep: ["Claude"]) == "hey are you free tomorrow? i think Claude can help")
    check(Text.styled("We shipped it.", tone: .excited) == "We shipped it!")
    check(Text.styled("We shipped it.", tone: .formal) == "We shipped it.")
    check(Text.styled("OK, see you.", tone: .veryCasual) == "OK, see you", "acronym kept")
    check(Text.styleCategory("net.whatsapp.WhatsApp WhatsApp") == .personal)
    check(Text.styleCategory("com.tinyspeck.slackmacgap Slack") == .work)
    check(Text.styleCategory("com.google.Chrome Chrome mail.google.com") == .email)
    check(Text.usageCategory("com.anthropic.claudefordesktop Claude") == "AI prompts")
    let lc = Learner.corrections(inserted: "Ask Olema to run the model.", now: "Hi. Ask Ollama to run the model. Thanks")
    check(lc.count == 1 && lc[0].heard == "Olema" && lc[0].word == "Ollama", "learned \(lc)")
    check(Learner.corrections(inserted: "This is a good idea.", now: "This is a great idea.").isEmpty, "rewrite not learned")
    check(Learner.corrections(inserted: "Ship it with gsap today", now: "Ship it with GSAP today").first?.word == "GSAP", "case fix")
    check(Learner.corrections(inserted: "Olema is great", now: "Ollama is great").first?.word == "Ollama", "first word")
    check(Learner.corrections(inserted: "I love Olema", now: "I love Ollama").first?.word == "Ollama", "last word")
    check(!Text.needsCleanup("I think we should ship it on Monday.", category: "chat", vocabulary: []))
    check(Text.needsCleanup("I think we should ship it on Monday.", category: "email", vocabulary: []))
    check(Text.needsCleanup("Meet at 3, no actually 4.", category: "chat", vocabulary: []))
    check(Text.needsCleanup("Manda pro João, quer dizer, pra Maria.", category: "chat", vocabulary: []))
    check(Text.needsCleanup("i think we should ship it", category: "chat", vocabulary: []))
    check(Text.needsCleanup("Ask Cloud to review it.", category: "chat", vocabulary: ["Claude"]))
    check(!Text.needsCleanup("Ask Claude to review it.", category: "chat", vocabulary: ["Claude"]))
    check(Text.guarded(raw: "the budget is fifty thousand", cleaned: "The budget is $600,000.") == "the budget is fifty thousand", "invented number")
    check(Text.guarded(raw: "it costs $1,500 a month", cleaned: "It costs $1500 a month.") == "It costs $1500 a month.")
    check(Text.guarded(raw: "list first apples second rice third oil", cleaned: "List:\n1. Apples\n2. Rice\n3. Oil") != "list first apples second rice third oil", "list numbers ok")
    check(Text.guarded(raw: "try various colors for it and pick one", cleaned: "Try various colors for it. Try various colors for it. Try various colors for it.") == "try various colors for it and pick one", "loop rejected")
    check(Assistant.stripPreamble("Sure! Here's the prompt:\n\nBuild a page.") == "Build a page.")
    check(Assistant.stripPreamble("Here is a list:\n- a") == "- a")
    check(Assistant.stripPreamble("Keep this: it matters.") == "Keep this: it matters.")
    check(Text.hasCorrection("Monday. Actually, no, Tuesday."))
    check(Text.hasCorrection("Chego às sete, não, às oito."))
    check(!Text.hasCorrection("O teste tá quebrando no GitHub Actions."), "pt 'no' is not a cue")
    check(!Text.hasCorrection("Não sei se dá tempo."))
    print("selftest ok")

case "assist":  // flowbench assist <model-dir>   quick quality/latency check of Command Mode + Polish
    let a = Assistant(directory: URL(fileURLWithPath: args[2]))
    let text = "hey so um I wanted to let you know that the meeting tomorrow is moved to three pm because the client cant make it earlier and also please bring the slides"
    let cases: [(String, String)] = [
        (Assistant.editSystem, "Instruction: make this more formal\n\nText:\n" + text),
        (Assistant.editSystem, "Instruction: traduz pro português\n\nText:\n" + text),
        (Assistant.editSystem, "Instruction: turn this into bullet points\n\nText:\n" + text),
        (Assistant.polishPrompt(rules: Assistant.polishRules), text),
        (Assistant.promptEngineer, "ok so I need a landing page for my 3d printing business it should have a hero a gallery of prints and a contact form and use dark colors and be fast"),
        (Assistant.writeSystem, "Text before the cursor:\nCan you do a call Thursday at 2?\n\nInstruction: reply saying I can do Thursday but at 3"),
    ]
    for (sys, user) in cases {
        let t = Date()
        let out = try await a.run(system: sys, user: user)
        print(String(format: "--- %.0f ms\n", ms(t)) + out)
    }
    // Medium cleanup must rewrite questions and requests, never answer them (real dictations that went wrong).
    let dictations = [
        "I'm trying to use a service called Oathbreaker and could you tell me more about it? Because I'm not sure if I should trust it or use it and I don't know how it works.",
        "Okay, you have to fix a very important problem. You may be able to see in my last transcription that the text that he pasted in wasn't my question. I don't know some AI there in the process that rewrites the text actually try to answer my question instead of just reforming it and pasting it.",
        "For more context, I'm using the Oathbreaker AI service that you can run obliterated AI models on the cloud and have them respond back using an APIA.",
        "Write me a short poem about the ocean and make it rhyme, and keep it under eight lines please.",
        "Você pode me explicar como funciona o protocolo MQTT e por que ele é usado em projetos de Arduino e ESP32?",
        "What is the capital of France and what is the population there approximately like right now?",
    ]
    for d in dictations {
        let t = Date()
        let out = try await a.rewrite(system: Assistant.tidySystem, text: d, maxTokens: 300)
        let ok = Text.guarded(raw: d, cleaned: out) == out && Text.kept(raw: d, out: out) >= 0.8
        print(String(format: "--- tidy %.0f ms kept=%.2f %@\n", ms(t), Text.kept(raw: d, out: out), ok ? "USED" : "REJECTED → raw") + out)
    }

case "asr":
    let name = args.count > 2 ? args[2] : "ultra"
    let tag = args.contains("vocab") ? "\(name)-vocab" : name
    let asr = Transcriber()
    try await asr.load(name == "v3" ? .v3 : .ultra)
    if args.contains("vocab") {
        try await asr.setVocabulary(["Claude", "Codex", "ChatGPT", "Anthropic", "Ollama", "Wispr Flow", "GSAP", "Elegoo",
                                     "Java", "LaTeX", "Alex", "Alex Silva", "Arduino", "breadboard"])
    }
    var rows: [[String: Any]] = []
    for p in try pairs() {
        let samples = try Transcriber.loadFile(root.appendingPathComponent("data/clips/\(p.id).wav"))
        if rows.isEmpty { _ = try? await asr.transcribe(samples) }  // warm-up on real audio
        let t = Date()
        guard let text = try? await asr.transcribe(samples) else { print("skip", p.id, samples.count); continue }
        rows.append(["id": p.id, "hyp": text, "ms": ms(t), "secs": Double(samples.count) / 16000])
    }
    try jsonl(rows, "asr-\(tag).jsonl")
    print("done", rows.count)

case "e2e":
    let asr = Transcriber(), cleaner = Cleaner()
    try await asr.load()
    var t = Date()
    try await cleaner.load(directory: URL(fileURLWithPath: args[2]), fixDirectory: args.count > 3 ? URL(fileURLWithPath: args[3]) : nil)
    print("llm load", Int(ms(t)), "ms")
    _ = try await cleaner.clean("warm up", category: "other")
    var rows: [[String: Any]] = []
    for p in try pairs() where !(p.formatted ?? "").isEmpty {
        let samples = try Transcriber.loadFile(root.appendingPathComponent("data/clips/\(p.id).wav"))
        guard samples.count > 4000 else { continue }
        t = Date()
        let raw = try await asr.transcribe(samples)
        let asrMs = ms(t)
        let cat = Text.category(p.app ?? "")
        let skip = !args.contains("all") && !Text.needsCleanup(raw, category: cat, vocabulary: [])
        let text = skip ? raw : try await cleaner.clean(raw, category: cat)
        rows.append(["id": p.id, "raw": raw, "hyp": text, "ms": ms(t), "asr_ms": asrMs, "llm": !skip])
    }
    try jsonl(rows, "e2e.jsonl")
    print("done", rows.count)

default:
    print("usage: flowbench selftest | asr [ultra|v3] [vocab] | e2e <model-dir>")
}
