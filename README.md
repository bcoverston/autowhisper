# autowhisper

macOS menu-bar app that records the microphone + all system audio, transcribes
near-real-time with whisper.cpp (base.en), re-checks low-confidence spans with
large-v3-turbo, and has the local `claude` CLI arbitrate a corrected transcript.

## Build & run

```sh
Scripts/make-app.sh          # swift build -c release + bundle + codesign → dist/autowhisper.app
open dist/autowhisper.app    # must launch via LaunchServices, not by exec'ing the binary
```

First run: grant the microphone and system-audio-recording prompts. Ad-hoc
signing means TCC may re-prompt after rebuilds (no Apple Development cert on
this machine).

Requires the whisper xcframework at `.deps/build-apple/whisper.xcframework`
(v1.9.1 — `curl -L <github release zip> && unzip` into `.deps/`). Models
download to `~/Library/Application Support/autowhisper/models/` on first
recording if missing.

## Layout

- `Sources/Events` — event/segment types shared by pipeline and UI (leaf target)
- `Sources/autowhisper/{App,UI,Capture,Chunking,Whisper,Correction,Encoding,Storage,Settings}`
- `Spikes/` — Phase-0 throwaway spikes; `Spikes/FINDINGS.md` records the verified
  platform behavior (tap API, TCC gotchas, encoder decision, whisper API)
- Sessions land in `~/Library/Application Support/autowhisper/sessions/<id>/`:
  `audio/chunk-*.m4a` (AAC 16 kHz mono, 5-min rotation, 30-day retention),
  `draft.jsonl`, `recheck.jsonl`, `corrected.jsonl`, `transcript.md` (kept forever)

## Dev switches

- `open dist/autowhisper.app --args --autotest` — records ~25 s, stops, exits
  (used for E2E verification from a shell)
- `--flag-all` — flags every segment, forcing the re-check + correction path
