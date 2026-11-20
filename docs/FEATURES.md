# LocalFlow vs Wispr Flow: feature parity spec

Sources:
- Wispr's help center (shortcuts, hands-free, Styles, Usage/Insights, Context Awareness, Command Mode, Transforms, Snippets, Dictionary, Smart Formatting & Backtrack) and its changelog through Nov 2026.
- The preference defaults inside the Wispr Flow app installed on this Mac (`this.user = {…}` in its main bundle).

Desktop (Mac) features only. "Local" means the model runs on this Mac instead of Wispr's cloud.

## Hub window

| Wispr | How Wispr does it | LocalFlow |
|---|---|---|
| **Home** | Greeting, weekly stats, *Recent activity* grouped by day. Hovering a row shows Copy. The "…" menu has Undo/Redo AI edit, Retry transcript (needs saved audio, kept 14 days), Play audio, Delete. | Same. Audio is kept 14 days as 16 kHz WAV. |
| **Insights** | WPM (speech time), total words, "Fixes made by Flow" (words corrected + dictionary fixes), desktop usage by 6 categories (word share), activity heatmap with current and longest streak. | Same, computed from local history. No leaderboard or percentile, since there are no other users. |
| **Dictionary** | Add a word, or a *Correct a misspelling* pair (whole word, case-insensitive, output keeps saved casing, longest match wins). Star key terms, sort by usage, search, import (CSV/JSON, 1,000 items). **Auto-add** learns words from your edits after a paste (`shouldAutoLearnWords`, on by default). | Same, including auto-add from edits. Entries are kept in `dictionary.txt` so they stay hand-editable. |
| **Snippets** | Trigger (≤60 chars) → expansion (≤4,000). Works said alone *or inside a sentence*, case-insensitive, longest trigger wins, whole words only. Search, edit, delete, import. | Same (plain text; no rich text). |
| **Style** | Categories: Personal messages, Work messages, Email, Other. Personal offers Formal / Casual / very casual; the others offer Formal / Casual / Excited!. Default is Formal. Formal = caps + punctuation; Casual = caps + less punctuation (drops the final period for ≤10 sentences); very casual = no caps + less punctuation; Excited = more "!". An **Auto Cleanup** tab has None / Light (default) / Medium (clarity + concision). | Same. Styles are applied deterministically after cleanup. Medium = Light + a light tidy pass by the 4B model; its output is discarded if a question lost its "?" or under 80% of the speaker's words survive (so it can never answer the dictation). |
| **Transforms** | Select text and press a shortcut. **Polish** (⌥1) has 5 rule toggles plus custom rules; **Prompt Engineer** (⌥2) turns rambling into a structured AI prompt; up to 8 custom transforms (name + prompt + shortcut). Limit 3,000 words; with no selection it uses the field's text. Esc cancels. | Same, run by a local instruct model (Qwen3-4B-Instruct). |
| **Scratchpad** (replaced Flow Notes) | ⌥S opens a floating notepad with a notes sidebar; you dictate into it. | Notes page in the Hub plus a floating Scratchpad on ⌥S (plain text). |
| **Settings** | General: Shortcuts, Microphone (auto-ranked, or pick one), Languages. System: launch at login, Flow Bar, show in Dock, sounds, mute audio while dictating. Data & Privacy: context awareness, history storage, export. Experimental: Command Mode, "press enter". | Same set (no account, billing or cloud sync, because nothing leaves the Mac). |

## Dictation engine

| Wispr | LocalFlow |
|---|---|
| Push-to-talk **fn**. Hands-free **fn+Space**, or double-tap fn; stop with the same shortcut or a Flow Bar click; a second press within 0.5 s cancels. **Esc** cancels. Sessions are capped at 20 min (warning at 19). | Same. A system-wide key tap swallows our shortcuts so they don't type characters. |
| **Command Mode** fn+Ctrl: speak an instruction. A selection is replaced; otherwise text is inserted at the cursor. "Search …" opens a web search. | Same, with the local instruct model. Holding fn and then adding Ctrl turns the recording into a command. |
| **Paste last transcript** ⌃⌘V, **Copy last transcript**. | Same. |
| Flow Bar: an idle bubble at the bottom centre. Click it for hands-free. It shows white level bars while listening, and Stop / Cancel buttons in hands-free mode. | Same. Can be hidden in Settings. |
| Start "ping" sound; mute or pause audio while dictating. | Start/stop sounds; mute system output while recording (restored afterwards). Pausing media isn't possible because macOS locks MediaRemote. |
| Whisper mode for very quiet speech. | Auto-gain on quiet audio plus a lower speech gate. |
| Context awareness: app category (from the browser's site too), on-screen names for spelling, matching spacing and capitals to the text around the cursor. | App + browser URL category; names and identifiers near the cursor are fed to the model as extra dictionary terms; leading space and capitals match the character before the cursor. |
| Backtrack, fillers, lists, spoken punctuation, numbers. | Fine-tuned local cleanup models (`cleaner` + `cleaner-fix`). |
| "Press enter" voice command (experimental). | Same, in English and Portuguese ("press enter", "aperta enter"). |
| Onboarding: permissions, mic test, hotkey test, try it. | Same. |

## Not included (and why)

- **Notetaker / meetings / calendar / tasks / extensions / "Ask Wispr" chat:** a separate product (system-audio capture, diarization, summaries). A candidate for a later phase.
- **Accounts, billing, teams, sharing, cloud sync, leaderboard, mobile apps:** cloud features.
- **Mouse-button shortcuts, up to 4 bindings per action, rich-text snippets, Hub localization, sound packs:** small extras, easy to add later if you want them.
