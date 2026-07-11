# autowhisper design system — decisions & tokens

Reference for the v2 UI. Source: the "Converge" handoff (`AutoWhisper-UX-screens.html`
in this folder — open in a browser to view all 7 screens).

## Adoption decisions (2026-07-11)

- **Scope: incremental.** Build the *speaker* surfaces (transcript speaker
  treatment, speaker rail, Voices library, threshold slider) in this visual
  language as part of Phase 7 — that's what the design depicts. Re-theme the
  non-speaker screens (session history, settings, menu bar) in a later pass
  once the look is proven on real diarized data. Do **not** stop feature work
  for a full reskin.
- **Transcript layout: dense rows + speaker color, NOT chat bubbles.** Keep the
  current compact timestamped `SegmentRow` layout (better for long ambient
  sessions, scanning, and search), and add per-speaker color coding + a name
  chip. The hero screen's chat-bubble treatment is not adopted; the speaker
  *color system* and matched/low-confidence states are.
- **Storage stays JSON** (`speakers.json`), not Core Data/SQLite as the handoff
  README suggests — matches the codebase's file-per-store pattern.
- **Copy fix:** footer "whisper large-v3" in the mock is wrong for us — the
  fast pass is `base.en`; large-v3-turbo is the re-check only. Label
  accordingly ("base.en · re-checking with large-v3-turbo").

## Tokens (adopt as a `Theme` enum/asset when the terminal look is applied)

**Type:** monospace-forward. Space Mono 700 for display/wordmark/big numbers;
JetBrains Mono 400–700 for UI/data/transcript. 13px base, tabular numerals,
ligatures off. (Incremental scope: apply to speaker surfaces first.)

**Color — surfaces:** void `#06080c` · bg0 `#0a0e14` · bg1 `#0e131b` · bg2
`#131923` (card) · bg3 `#1a2230` (input/hover) · bg4 `#232d3d` (active).
**Lines:** `#161d27` / `#232d3a` / `#33404f`. **Text:** `#e7eef5` / `#b3c0cd`
/ `#7d8b9a` / `#515f6e`.

**Accent — brand green** `#3fb950` (bright `#56d364`, dim `#2ea043`, faint
`#13361c`, line `#1f5a2c`). Green **glow** `0 0 8px rgba(63,185,80,.5)` is
reserved for the *matched/converged speaker* state only.

**Status:** red `#f85149` (recording), amber `#d29922` (low-confidence),
info blue `#58a6ff`.

**Speaker color coding (load-bearing — this is the concrete Phase-7 win):**
- Speaker 1 / unmatched-A: blue `#58a6ff` (faint `#11253f`, line `#1f3f66`)
- Speaker 2 / unmatched-B: orange `#f0883e` (faint `#3a2410`)
- Matched named speaker ("Ben"): green `#3fb950` + glow
- Unknown/unassigned: `--fg-3` `#515f6e`
- Assign additional speakers by hashing into a fixed palette; matched-named
  always overrides to green.

**Shape/spacing:** 4px grid, dense. Control heights sm/md/lg = 24/30/36px.
Radii: controls/cards 4px, chips/cells 2px, pills 999px, windows 9–10px.
Hairline 1px borders; structure from lines not shadows. Cards = bg2 + 1px
line1 + 4px radius, no rest shadow. Elevation shadow only on real windows.

**Motion:** fast 120ms, ease-out `cubic-bezier(.2,0,0,1)`, no bounce. Only two
loops: recording StatusDot pulse and transcript cursor blink (1s). Both pause
under `prefers-reduced-motion`.

**Copy voice:** lowercase system-log cadence; UPPERCASE tracked eyebrows
(`SPEAKERS · THIS SESSION`); short verb buttons (`Start capture`, `Stop`,
`Tag`); numbers with units; no emoji, no exclamation marks — status is a
colored dot.

## Screen inventory (build order within Phase 7 / later theming)

Phase 7 (speaker-driven): 04 live session speaker rail + colored transcript,
05 Voices library, 07 settings "diarization & matching" section (0.55 slider,
margin implied). Later theming pass: 01 onboarding, 02/03 menu-bar popovers,
06 session history, remaining settings.
