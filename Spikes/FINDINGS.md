# Spike findings

## Spike a — Core Audio tap capture (PASS, 2026-07-10)

- Swift initializer confirmed: `CATapDescription(monoGlobalTapButExcludeProcesses: [])` (also stereo variant). macOS 26 SDK.
- Tap native format: 48 kHz, 1 ch (mono global tap), Float32.
- Aggregate device with output as main sub-device + tap in `kAudioAggregateDeviceTapListKey` works; adding the default input device as a sub-device (`kAudioSubDeviceDriftCompensationKey: 1`) delivers **two clock-aligned mono streams in one IOProc**: observed order stream0 = mic, stream1 = tap. Do NOT hardcode this order — identify streams via the aggregate's stream/device topology in Phase 1.
- **TCC gotcha:** the audio-capture prompt/grant only engages when the app is launched via LaunchServices (`open app.app`). Exec'ing the bundle binary directly from a shell produces silent (all-zero) buffers with no tccd interaction at all. Real app usage is unaffected; dev/test scripts must use `open`.
- **Swift 6 gotcha:** top-level `main.swift` code is implicitly `@MainActor`; an IOProc block formed there inherits that isolation and crashes with `dispatch_assert_queue_fail` when the HAL invokes it. Capture/IO code must live in `nonisolated` context.
- Buffers arrive as 2048-byte (512-frame) mono Float32 per stream.
- File I/O inside the IOProc worked for the spike but stays banned in the real app (ring buffer + drain queue per plan).

## Spike b — encoding (DECIDED: AAC-LC, 2026-07-10)

- **Chosen: AAC-LC (`kAudioFormatMPEG4AAC`), 16 kHz mono, `AVEncoderBitRateKey: 32000`, `.m4a`** → ~27 kbps effective, **11.7 MB/h**. Rereads via AVAudioFile, plays natively in QuickTime/Quick Look. 16 kHz matches whisper input for the re-check decode path.
- Opus via AVAudioFile: `.opus`/`.ogg` containers fail at open ('fmt?' 1885563711); `.caf` writes+rereads but **ignores AVEncoderBitRateKey** (~218 kbps, 92 MB/h — 8× target). Hitting 24 kbps Opus would require manual AVAudioConverter + packet-level AudioFile plumbing for ~1 MB/h savings over AAC — not worth it.
- **kill -9 mid-write:** unfinalized `.m4a` is completely unreadable (no moov atom); unfinalized Opus-CAF has data but reports 0 duration. Confirms the closed-chunks-only artifact rule; a crash forfeits the in-flight chunk (≤5 min). AVAudioFile finalizes on deinit — writers must be dropped/scoped to close chunks.

## Spike c — whisper.cpp (PASS, 2026-07-10)

- xcframework v1.9.1 as local SwiftPM `binaryTarget` — ships its own modulemap, so `import whisper` works directly; **no C shim target needed**.
- base.en on M4 (Metal): model load 7.1 s (one-time — keep context resident), transcription ~28× realtime (14.2 s audio in 0.50 s). Perfect transcript of the spike-a system-audio capture.
- Confidence API works as planned: mean `whisper_full_get_token_p` + `whisper_full_get_segment_no_speech_prob`; segment t0/t1 are centiseconds (×10 → ms).
- Standalone VAD works: `whisper_vad_init_from_file_with_params` (ggml-silero-v6.2.0) + `whisper_vad_segments_from_samples` → t0/t1 in centiseconds. `use_gpu = false` fine for VAD.
- `whisper_full_params.language` needs a stable C string for the call duration (`withCString` scope).
- AVFoundation needs `@preconcurrency import` under Swift 6 for AVAudioConverter closures.

## Spike d — LSUIElement shell (PASS, 2026-07-10)

- `MenuBarExtra` + `Window(id:)` + `.defaultLaunchBehavior(.suppressed)` works in a SwiftPM-bundled LSUIElement app: launch shows menu item only (policy=accessory, 0 windows).
- 5× open/close cycles clean: `openWindow` + `setActivationPolicy(.regular)` + `activate()` on open; `NSWindow.willCloseNotification` observer flips back to `.accessory` when the last main window closes. No zombie windows, no stuck dock icon.
- Driver/housekeeping tasks can live in the MenuBarExtra *label* view (`.task {}`) — it is instantiated at launch, unlike the menu content.
- Swift 6: notification-center closures need values extracted before `MainActor.assumeIsolated` (sending `note` across risks data-race error).

## Spike: FluidAudio diarization (PASS, 2026-07-11)

- SwiftPM `from: "0.15.5"`. `DiarizerModels.downloadIfNeeded()` auto-fetches ~13 CoreML files to `~/Library/Application Support/FluidAudio/Models/` (fast, one-time; compiles wespeaker + pyannote in ~1s). Runs on ANE.
- `DiarizerManager().initialize(models:)` then `try performCompleteDiarization(_ audio: RandomAccessCollection<Float>)` — takes our exact 16 kHz mono `[Float]`; **throws** (not in my research). ~3.4s for 18s audio.
- `DiarizationResult.segments: [TimedSpeakerSegment {speakerId: String, startTimeSeconds, endTimeSeconds}]`. `speakerDatabase` was nil — embeddings come from `diarizer.speakerManager` instead.
- **Verified within-session grouping**: 3-voice sequence (Daniel/Samantha/Daniel) → 2 speakers, Daniel's two non-adjacent utterances both labeled "1". 
- **Cross-session embeddings**: `diarizer.speakerManager.getSpeakerList() -> [Speaker {id, name, currentEmbedding: [Float], duration}]`; `currentEmbedding` is **256-d, L2-normalized**. `initializeKnownSpeakers([Speaker])` seeds enrolled profiles (so diarization auto-assigns known IDs); `findSpeaker(with:speakerThreshold:) -> (id?, distance)` for matching. Config: `DiarizerConfig(clusteringThreshold: 0.7)` default (NOT 0.65).
- Plan: per-session batch diarization; seed enrolled `VoiceProfile`s as known speakers; persist `getSpeakerList()` embeddings; cross-session match via cosine + margin rule (0.55/0.06).
