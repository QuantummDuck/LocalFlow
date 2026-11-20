# Rebuilding Wispr Flow locally: research report

*2026-11-19 · target machine: MacBook Air M4, 16 GB RAM, macOS 27*

Evidence is tagged by how sure we are:

- **[APP]**: read directly from the Wispr Flow 1.6.1337 bundle installed on this Mac (database migrations, main-process JS, Swift helper strings).
- **[DATA]**: measured from your own local Wispr history database (a read-only copy; nothing was sent anywhere).
- **[OFFICIAL]**: Wispr's or a vendor partner's own pages.
- **[3P]**: third-party blogs and reviews, some written by competitors.
- **[TEST]**: something I ran on this Mac today.

---

## 1. TL;DR

1. **Wispr Flow is not magic. It is a well-tuned five-stage pipeline:** streaming audio → their own ASR model (Canto) → a fine-tuned small LLM that rewrites the text using **context read through the macOS Accessibility API** → paste into the focused field → **watch what you edit afterwards and learn from it**. Every stage can be rebuilt locally.
2. **The "it understands when I change my mind" behavior comes from the LLM rewrite stage, not the speech model.** The LLM gets the raw transcript plus context and is trained to keep only the final version of a self-correction. Your own history shows this happening, e.g. *"…connect the logic pin. Actually, just say where to connect all the pins…"* → *"Just say where to connect all the pins…"*.
3. **"Screen context" is mostly Accessibility text, not screenshots.** The request payload has: app, URL, the text before and after your cursor, the selected text, nearby visible text, and an HTML rendering of the field with a `<USER INSERTING TEXT HERE>` marker. A screenshot field still exists in the payload but is currently sent empty [APP].
4. **Your Handy is clanky partly because its LLM cleanup is switched off** (`post_process_enabled: false` in your settings). Handy only does raw ASR + paste today.
5. **Local models are good enough now.** Parakeet TDT v3 transcribes in ~0.1–0.2 s on the Neural Engine. A 2–4B local LLM can do the rewrite in ~0.5 s. Wispr's own measured average on your machine is **681 ms** end to end [DATA], so matching or beating its speed locally is realistic.
6. **We have a ready-made benchmark:** 1,217 of your dictations with Wispr's raw ASR and its final cleaned output, and **267 of them with the original audio** [DATA]. We can replay your real voice through our pipeline and compare it with Wispr's output, side by side.
7. **My recommendation:** a native Swift menu-bar app (not Electron, not a Handy fork) using FluidAudio/Parakeet for ASR, MLX for a small local LLM (Apple Foundation Models as a zero-download fallback), the Accessibility API for context and insertion, and an edit-observation loop for learning. Details are in §7.

---

## 2. How Wispr Flow actually works

### 2.1 App architecture [APP]

- **Electron app** (`com.electron.wispr-flow`, React renderer windows: `hub`, `overlay`, `status`, `scratchpad`, `contextMenu`, `meeting_recorder`…) plus a **native Swift helper app** that does all the macOS-specific work: Accessibility, keystroke tracking, pasteboard, media control (`MediaRemoteAdapter.framework` pauses your music while you dictate).
- **Local SQLite DB** (`~/Library/Application Support/Wispr Flow/flow.sqlite`, Sequelize migrations) with tables `History`, `Dictionary`, `Notes`, `Polish`, `Meetings`, `Todos`, `CalendarEvents`, `InstructHistory`, `UserContext`, `UserVoicePreferences`, `Automations`, `TranscriptCorrections`…
- **Cloud backend:** `api.wisprflow.ai` over WebSocket, with a protobuf API (`flow_api.v1.*`). Audio is **encoded to Opus incrementally while you speak** (`incrementalOpusEncoder.worker.js`) and streamed in packets, so most of the upload is already done when you release the key.
- **Multi-provider fallback.** The code references Baseten (primary, 150+ mentions), OpenAI, Groq, Gemini, Cerebras and Anthropic. The History table records `defaultAsrText` vs `fallbackAsrText`, `usedFallbackAsr`, `usedFallbackFormatting`, `fallbackLevel`, and divergence scores between the main and fallback outputs.

### 2.2 The pipeline, stage by stage

The server pipeline enum is literally `transcribe → align → format → lowercase_sentences / slack_tagging / email_signature` [APP]. Per-dictation stats returned include `asr_time`, `llm_time`, `pasted_time`, `total_time`, `cursor_position`, `detected_language`, `average_log_prob`, `starts_with_proper_noun`, `generated_tokens`, `formatting_divergence` [APP].

| Stage | What Wispr does | Evidence |
|---|---|---|
| **Trigger** | Hold Fn = push-to-talk (`ptt`). Hands-free toggle (`popo`, press on / press off). `command` (Command Mode). `lens` (assistant). In your history: 929 ptt, 285 hands-free. | [APP][DATA] |
| **Capture** | Mic at 16 kHz, Opus-encoded in chunks, streamed live. Silence-trimmed `speechDuration` is used for WPM stats. "Whisper mode" works on very quiet speech. | [APP][OFFICIAL] |
| **ASR** | Since 17 Sep 2026: **Canto**, their own speech model (claimed 3.4% WER on their dictation set vs Google/OpenAI/AssemblyAI/Deepgram; ~2B params is unverified). Before that: external providers. The ASR is already fairly clean (punctuated). Your personal dictionary is sent as `vocabulary` to bias it. | [OFFICIAL][3P][APP] |
| **Context snapshot** | Taken at dictation time via Accessibility (details in §2.3). | [APP] |
| **Format (LLM)** | A **fine-tuned Llama** served on Baseten with TensorRT-LLM. Budget: 100+ tokens in <250 ms, whole pipeline <700 ms, optimized for p90/p99 latency per user. Does: filler removal, self-correction/backtracking, punctuation, lists, spoken punctuation ("open quote… close quote"), number/part-code normalization, proper-noun spelling from context, tone matching. | [OFFICIAL Baseten][APP][DATA] |
| **Post-format** | Per-app rules: all-lowercase mode, "casual messaging" (only capitalize proper nouns), Slack @-tagging, email signature, file tagging in Cursor/Windsurf. | [APP][OFFICIAL] |
| **Insert** | The Swift helper first tries to **set the field's AXValue directly**. If that "did not stick", it falls back to clipboard paste: save the pasteboard, write the text (plain + HTML), send ⌘V, restore the pasteboard (skipped if it holds content that can't be restored). Waits for modifier keys to be released. Uses per-app delays (longer for remote-desktop apps, Word and Outlook). | [APP][3P teardown] |
| **Learn** | After pasting, it **observes the text field** (`KeystrokeTraceRecorder`, `ObservationEndKeystrokeTracker`) to capture your edits (`editedText`, `editDistance`, `word_substitutions`, `word_deletions`). New words are auto-added to the dictionary (`observedSource`, `frequencySeen/Used`). It tracks `hasRevertedAI` when you undo the AI version. | [APP] |

### 2.3 What "context awareness" really sends [APP]

The context object built for every dictation (from the main bundle, field names verbatim):

```
{ app,                       // bundle id + URL (for browsers)
  vocabulary,                // your dictionary words
  textbox: { contents, beforeText, selectedText, afterText },
  contentText: nearestTexts, // visible text near the cursor, read via Accessibility
  contentHtml: axHTML,       // the field rendered as HTML with <USER INSERTING TEXT HERE> marker
  sessionDictationApps,      // other apps you dictated into recently
  screenshot: new Uint8Array // ← EMPTY in this version
}
```

- The Swift helper reads `AXFocusedApplication`, `AXFocusedUIElement`, `AXValue`, `AXSelectedTextRange(s)`, `AXSelectedTextMarkerRange`, and listens for `AXFocusedUIElementChanged` / `AXSelectedTextChanged`.
- **App type classification** drives the style: `email | ai | work | personal_messaging | document | other` (plus `terminal`). Each category gets a style: `formal | casual | veryCasual | excited` (plus `genz`, mapped to very casual) or a custom one.
- Formatting modes per app: "Apply AI formatting", "No AI formatting", "Casual messaging", "All lowercase". There's also an `autoCleanupLevel` (default `Light`).
- **Screenshots:** older versions captured the active window periodically, which caused a 2025 community backlash [3P]. This build has a `screenshot` field and `captureScreenshot` code (used by Flow Lens / Command Mode), but the dictation payload sends an empty array. **Conclusion: Accessibility text gets you ~90% of the context benefit without screenshots.**

### 2.4 Full feature inventory

**Core dictation (what we must match):**

- Hold-to-talk + hands-free toggle, works in any app, small floating "Flow bar" overlay with waveform.
- Filler removal, punctuation, capitalization, paragraphing, auto-lists.
- **Backtracking / self-correction** ("no actually 4", "scratch that", restated sentences).
- Spoken punctuation & formatting commands ("new line", "open quote", "comma").
- Number, date, unit and part-number normalization ("L two nine eight N" → "L298N").
- **Personal dictionary** (auto-learned + manual, starred, replacements "X → Y").
- **Snippets** (say a trigger phrase → expands to saved text).
- **Per-app styles / tone matching** (formal in email, casual in Slack…), email greeting/sign-off layout.
- Multilingual with auto-detect and code-switching (you use en + pt; 253 of your dictations are Portuguese) [DATA].
- Developer features: camelCase/snake_case, variable names visible in the editor, file tagging in Cursor/Windsurf chats.
- Whisper mode (very quiet speech), pauses media while dictating, mic selection.
- History with raw vs formatted, "undo AI formatting", stats (WPM, words, per-app).

**Editing & assistant:**

- **Command Mode:** select text, speak an instruction ("make this more formal", "turn into bullets"). Uses big models: the code lists `claude-haiku-4-5`, `claude-sonnet-4-5`, `claude-opus-4-6`, `gpt-5.5`, `gpt-realtime-2`, `gpt-oss-120b` (Cerebras) [APP].
- **Polish:** rewrites the whole current text box with a named prompt; tracks undo and feedback [APP].
- **Flow Lens:** an assistant chat with screenshot + AX text as context [APP].

**Scope creep we can ignore:** notes, meeting notetaker (with Granola import), calendar, todos, team dictionaries and sharing, automations, ChatGPT computer-use integration.

---

## 3. What users say

**Love** [3P]: "4× faster than typing"; the cleanup is the product (raw-ASR apps feel clanky by comparison); works in every app; backtracking feels magical; great for prompting AI tools (your top target app is the Claude desktop app with 519 dictations, then browsers) [DATA].

**Hate** [3P]:

- **Privacy:** everything goes to the cloud; the screenshot controversy; data used for training unless Privacy Mode is on.
- **Resource use:** ~800 MB RAM and ~8% CPU idle (Electron).
- **Reliability:** occasional freezes, slow startup, "works 60% of the time" post-trial claims, outages (no offline mode at all).
- **Price:** ~$15/mo; the free tier is capped at 2,000 words/week.
- **Over-editing:** visible in your data. One dictation, *"Could you look it up, uh, its datasheet."*, was **dropped entirely** from the output. This is the classic failure of an LLM rewrite step, and the thing our guardrails must prevent.

---

## 4. Your own data (what we'll benchmark against) [DATA]

| Metric | Value |
|---|---|
| Dictations in history | 1,442 (21 Jun → 29 Oct 2026) |
| With raw ASR + Wispr's final text | 1,217 |
| With original audio (WAV) | **267** |
| With text you edited afterwards | 509 |
| Languages | en, pt (253 pt) |
| Avg end-to-end latency | **681 ms** |
| Avg utterance | 21.6 s, 35 words |
| Top apps | Claude desktop 519, Arc 228, Safari 152, Codex 93, Zen 67 |

The transformations it performs on your speech (paraphrased examples):

- **Backtrack:** "*Friday at 3? No, actually 4*" → "*Friday at 4?*"
- **Email layout:** "*Hey Greg, um, hi Greg, let's connect soon…, best, Alex*" → greeting / body / sign-off on separate lines.
- **Spoken quotes in mixed languages:** "*we said open quote Então como que a gente colou close quotes*" → *we said, "Então como que a gente colou?"*
- **Spelled-out part code:** "*L two nine eight N N X…*" → "*L298N*".
- **Light punctuation** for Portuguese, keeping English loanwords (output, MD, LLM) intact.

This gives us an objective score: replay the 267 audio clips through our pipeline and compare against Wispr's output, then use the 1,217 text pairs to tune the LLM prompt or fine-tune.

---

## 5. Open-source landscape

| Project | Stack | ASR | LLM cleanup | Context | Notes |
|---|---|---|---|---|---|
| **Handy** (cjpais) | Tauri/Rust, MIT, 39k★, v0.10.1 | transcribe-cpp (GGUF, Metal): Whisper S/M/Turbo/Large, Parakeet | Yes, OpenAI-compatible / Anthropic / Groq / **Apple Intelligence**. **Off in your settings** | None | Clipboard paste + restore (has a known race, #502); "transcription hook" script |
| **VoiceInk** | Swift native, GPL-3, 7.2k★ | whisper.cpp, FluidAudio Parakeet, SenseVoice | "Smart Modes" (AI) | "Context aware: understands screen", per-app/URL modes | Closest native reference; doesn't accept PRs |
| **OpenWhispr** | Electron, MIT, 11.9k★ | whisper.cpp, Parakeet (sherpa-onnx), cloud BYOK | Cloud LLMs + llama.cpp local | Opt-in screenshot for assistant | Feature-rich, but Electron |
| **FreeFlow** (zachlatta) | Swift, MIT, 3.1k★ | Groq / any OpenAI-compatible | Yes, context-aware default prompt; Edit Mode | `AppContextService` reads nearby app context | Cloud-first, but pointable at Ollama/LM Studio; a good source to study for prompts |
| **Hex** (kitlangton) | Swift/TCA, MIT, archived Oct 2026 | Parakeet via FluidAudio, WhisperKit | None | None | Clean Swift reference for hotkey + FluidAudio |
| **Phonon** (Elliot Arledge) | Rust + Metal | Parakeet | **LFM3-1.7B fine-tuned on DeepSeek-distilled data**; claims Wispr-level quality, 65 ms key-up latency on M4 Max | ? | Proof that a fine-tuned ~1.7B refiner is enough. Repo not confirmed yet |
| Muesli, Amical, LocalFlow, whisper-local | various | Parakeet/Whisper | Gemma 4 / Ollama | some | More data points |

**Takeaway:** nobody open-source has the full Wispr loop (AX context in the prompt + insertion + edit observation + auto-learning dictionary + per-app styles + guarded rewrite). The pieces exist separately; the integration is the product.

---

## 6. Local model options for this Mac (M4, 16 GB)

### 6.1 Speech-to-text

| Model | Speed on Apple Silicon | Accuracy | Languages | Verdict |
|---|---|---|---|---|
| **Parakeet TDT 0.6B v3** via FluidAudio (CoreML, Neural Engine) | ~0.1–0.2 s per utterance, ~20× realtime+ | ~6.3% Open ASR (EN), beats Whisper turbo on most sets | 25 European **incl. Portuguese**, auto-detect | **Primary choice** |
| Whisper large-v3-turbo via WhisperKit | ~0.7–1.2 s | ~7.8% Open ASR | 99 | Fallback for non-European languages |
| Apple SpeechAnalyzer (built in, macOS 26+) | Very fast (64× RT) | Good EN, weaker multilingual | ~22 languages | Zero-download option; worth testing for pt |
| Qwen3-ASR 1.7B (MLX) | ~30× RT | Very good | Many | Candidate if Parakeet's Portuguese disappoints |

Handy is currently running a Parakeet GGUF through Metal. FluidAudio's CoreML/ANE path is several times faster and frees the GPU for the LLM.

### 6.2 Cleanup LLM

| Option | Notes |
|---|---|
| **Apple Foundation Models** (on-device ~3B, built in) | **[TEST] Available on this Mac.** Cold 2.2 s, **warm ~0.5 s**. Zero-shot it *missed* "at 3, no actually 4". With two few-shot examples it handled English backtracks correctly. On Portuguese it **translated to English and reversed the correction** ("downloads, not documents" when the speaker meant documents). Fine as a fallback, not the main model. |
| **Qwen3.5 2B/4B, Gemma 4 E2B/E4B, LFM 2.5** via MLX | Others report ~0.5–1.3 s on 16 GB Macs. Good multilingual. A 4B model at 4-bit is ~2.5 GB RAM. |
| **Fine-tuned 1–2B refiner** (Phonon approach) | Fastest and most faithful. Training data comes from your 1,217 Wispr pairs + synthetic backtracking data generated by a big model. This is how Wispr got to <250 ms. |
| Big model for Command Mode | Local 4–8B, or optional bring-your-own-key cloud for heavy rewrites only. |

**Memory budget (16 GB):** Parakeet ~0.7 GB (ANE) + 4B LLM ~2.5 GB + app ~100 MB. That's comfortable; Wispr's Electron app alone uses ~800 MB.

---

## 7. Recommended approach

### 7.1 Build native Swift, from scratch (borrowing ideas, not code)

Why not fork Handy: it's a good cross-platform base, but everything that makes Wispr *Wispr* is macOS-native: Accessibility reads and writes, `CGEventTap` for the Fn key, the Neural Engine via CoreML (FluidAudio), Foundation Models, MLX-Swift, and pasteboard save/restore. In Tauri/Rust that's all `objc2` bridging. In Swift it's first-class, and the app stays ~50–100 MB of RAM. You only need it on this Mac, so cross-platform buys nothing. VoiceInk (GPL) and Hex (MIT) are the Swift references to study; FreeFlow (MIT) is the reference for context and prompt handling.

*Alternative if you'd rather ship faster at the cost of a ceiling:* fork Handy, turn on its post-processing, and add a context-capture hook. I don't recommend it, but it's a valid MVP path.

### 7.2 Target architecture

```
 Fn down ─┬─► AVAudioEngine 16 kHz ─► Silero VAD ─► Parakeet (streaming chunks, ANE)
          │
          └─► Context snapshot (parallel, ~20 ms):
               frontmost app + bundle id, browser URL, window title,
               focused field: before/selected/after text (AX),
               nearby visible text (AX tree walk, capped),
               OCR of focused window ONLY if AX gives nothing (Vision, opt-in)
 Fn up ──► finalize ASR tail (~100 ms)
        ─► deterministic pre-pass: snippets, replacements, spoken commands
           ("new line", "open quote"), number words
        ─► fast-path?  short + already clean + casual app → skip LLM
        ─► LLM rewrite (MLX, warm, ~300–500 ms)
              prompt = style for app type + dictionary + context excerpt
                       + few-shot (incl. backtracking, pt+en)
        ─► guardrail: if the output dropped content / answered the question /
           changed language / diverged too far from ASR → use the lightly
           cleaned ASR instead (this is the "dropped clause" bug fix)
        ─► insert: AX setValue at cursor → else pasteboard ⌘V with save/restore
        ─► observe the field for ~30 s: diff your edits → learn dictionary
           words and replacements, log a (raw, ours, your-final) triple
```

**Latency target:** <500 ms from key-up to text, beating Wispr's 681 ms average on your own clips.

### 7.3 Phased plan

| Phase | Deliverable | "Done" means |
|---|---|---|
| **0. Benchmark harness** | CLI that replays your 267 WAVs + 1,217 text pairs through any ASR/LLM combo and scores WER, faithfulness and latency vs Wispr | We can pick models with numbers, not vibes |
| **1. MVP dictation** | Menu-bar app: Fn hold/toggle, overlay, Parakeet, Apple FM or MLX cleanup, paste + restore, history | Daily-drivable; beats Handy |
| **2. Context** | AX context snapshot, app-type classification, per-app styles, dictionary in prompt | Names and terms spelled from screen; tone fits the app |
| **3. Quality** | Guardrails, backtracking eval set, spoken commands, snippets, dev mode (camelCase, file names) | ≥ Wispr on our benchmark |
| **4. Learning loop** | Edit observation → auto-dictionary; fine-tune a 1–2B refiner (LoRA via MLX) on your data | Gets better the more you use it |
| **5. Command Mode** | Select text + instruction; bigger model; optional cloud BYOK | Parity with Wispr's Command Mode |

---

## 8. Decisions I need from you

1. **Languages:** is it English + Portuguese, including mixing both in one sentence? This decides Parakeet vs Whisper/Qwen3-ASR, and which LLM.
2. **Strictly local, or local-first with optional cloud?** E.g. allow a bring-your-own-key cloud model only for Command Mode.
3. **Native Swift from scratch (my pick) vs forking Handy?**
4. **May the benchmark use your Wispr history?** It stays on this Mac; it's the single best quality signal we have.
5. **Must-haves for v1:** anything beyond dictation + context + dictionary + snippets? (Command Mode? Notes and meetings, which I'd skip?)

---

## Sources

- Installed app: `/Applications/Wispr Flow.app` (v1.6.1337): `Resources/migrations/*`, `app.asar` → `.webpack/main/index.js`, `swift-helper-app-dist` binary strings.
- [Baseten: Wispr Flow customer story (Llama, <700 ms, p99)](https://www.baseten.co/customers/wispr-flow/)
- [Wispr: Canto speech model / AI Lab](https://wisprflow.ai/lab) · [VKTR on $2B round + Canto](https://www.vktr.com/ai-platforms/wispr-hits-2b-valuation-launches-canto-voice-model/) · [Kompozy on Canto launch](https://kompozy.io/news/wispr-canto-speech-model-launch)
- [Wispr: Why Flow](https://wisprflow.ai/why-flow) · [Wispr features](https://wisprflow.ai/features) · [Wispr docs: Cursor/VS Code](https://docs.wisprflow.ai/articles/6434410694-use-flow-with-cursor-vs-code-and-other-ides) · [Vibe coding post](https://wisprflow.ai/post/vibe-coding-supercharged)
- [Fora Soft engineering walkthrough](https://www.forasoft.com/learn/ai-for-video-engineering/articles-ai/whisper-flow-app-engineering-walkthrough) · [wisprflowguide features](https://wisprflowguide.com/docs/guides/wispr-flow-features/) · [eesel overview](https://www.eesel.ai/blog/wispr-flow-overview)
- [az9713 Wispr teardown (paste rules)](https://github.com/az9713/wispr-flow-rea-teardown)
- Reviews and complaints: [Voibe review](https://www.getvoibe.com/resources/wispr-flow-review/) · [Voibe reliability log](https://www.getvoibe.com/resources/is-wispr-flow-reliable/) · [Vocai privacy](https://vocai.net/blog/wispr-flow-review-privacy-2026/) · [Mintavocado 90 days](https://mintavocado.com/en/wispr-flow-my-complete-review-after-3-months-of-daily-use-2026/) · [Superwhisper vs Wispr](https://www.getvoibe.com/resources/wispr-flow-vs-superwhisper/)
- Open source: [Handy](https://github.com/cjpais/Handy) · [VoiceInk](https://github.com/Beingpax/VoiceInk) · [OpenWhispr](https://github.com/OpenWhispr/openwhispr) · [FreeFlow](https://github.com/zachlatta/freeflow) · [Hex](https://github.com/kitlangton/Hex) · [LocalFlow](https://github.com/vmysla/LocalFlow) · [Muesli](https://github.com/Muesli-HQ/muesli) · [Elliot Arledge / Phonon](https://x.com/elliotarledge/status/2118386115170496855) · [whispr-bro design spec](https://github.com/Micaxes/whispr-bro/issues/1)
- Models: [Parakeet vs Whisper on Apple Silicon (dev.to)](https://dev.to/konrad_sierzputowski_c86a/how-i-benchmarked-on-device-speech-to-text-on-apple-silicon-whisper-vs-parakeet-dne) · [vocai benchmark](https://vocai.net/blog/parakeet-vs-whisper-mac-benchmark-2026/) · [FluidAudio SDK](https://macparakeet.com/blog/fluidaudio-speech-ai-sdk/) · [soniqo Qwen3-ASR benchmarks](https://soniqo.audio/benchmarks) · [on-device ASR benchmark incl. Apple SpeechTranscriber](https://github.com/founden-bot/on-device-asr-benchmark) · [Apple SpeechAnalyzer vs Whisper](https://www.developersdigest.tech/blog/apple-speechanalyzer-vs-whisper-benchmark) · [Show HN: local STT on Apple Silicon](https://news.ycombinator.com/item?id=46824361) · [sabbel local LLM cleanup issue](https://github.com/kenodressel/sabbel/issues/4) · [Stenox MLX docs](https://docs.stenox.app/providers/llm/mlx-local)
