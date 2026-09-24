# CLAUDE.md — swift-sample-chopper

Sample packs from stems: `PackBuilder` over `BarGrid` (Beat This!),
`OnsetDetector` (spectral flux + attack refinement), `HitCutter`/`HitNamer`
(CLAP), `NoteNamer` (CREPE), `PhraseCutter`, `LoopCutter`, MIDI via
MuScriptor. Module `SampleChopper`; the verb is `aud pack` in
`../swift-aud-cli`. Added 2026-09-25.

## Build & test
```bash
swift build && swift test --filter CutterTests             # synthetic signals, no models
CHOP_STEMS=<folder of *-drums/-bass/-other/-vocals> CHOP_OUT=<dir> swift test --filter PackTests   # a whole pack, all models
```
Depends on tagged siblings by URL (music-transcriber, sample-search,
pitch-tracker, music-analysis) — a path dep on music-analysis conflicts with
music-transcriber's URL dep on it ("conflicting identity").

## Traps (measured)
- **Frame-start onset times are up to 43 ms early** with a 2048 window;
  centre the frames AND refine each onset to the attack (first 1 ms window
  reaching 20% of the local peak) — pre-roll went from tens of ms to ≤ 2 ms.
- **Round the loop length once**: `round(bars × barSeconds × sr)`, not
  `bars × round(barSeconds × sr)`; the latter was 1–2 samples long.
- Ghost hits (−43 dBFS) pass the onset detector; drop hits more than 24 dB
  under the stem's 95th-percentile hit peak before naming.
- `MusicTranscriber.transcribe(url, tempo: .off)` for MIDI, then shift notes
  by the first downbeat and assemble with `BeatGrid.fixed(bpm:)` — bar 1 is
  the pack's bar 1.
- One Core AI job on the GPU at a time; the builder runs its models one after
  another.
