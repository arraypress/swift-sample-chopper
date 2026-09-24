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
- MIDI is PER LOOP (the user: "generated on the clean samples"): transcribe
  the written loop file with `tempo: .off`, clamp notes to the loop, assemble
  with `BeatGrid.fixed(bpm:)` so bar 1 is the loop's start. `midiFull` (off)
  does the whole stem shifted to the first downbeat.
- `HPSS` is librosa's `effects.hpss` exactly (centre zero-pad, periodic Hann,
  scipy 'reflect' medians, softmask power 2, iSTFT over window-sum-square):
  154–162 dB on a real loop at margins 1 and 3. Margin 1 leaves NO residual
  (masks sum to 1); noise/FX only appears as the residual at margin > 1.
  A white-noise riser splits 50/50 at margin 1 — measure before claiming.
- `PhraseFinder`: chroma per sixteenth, MAGNITUDE not log-compressed —
  `log(1 + 100·energy)` flattened leakage into a floor that made every bar
  look alike (A vs B 0.8+); with magnitudes identical bars score 1.00 and
  different chords 0.10–0.75 at the 0.8 repeat threshold. A phrase is the
  SMALLEST span whose next span repeats it, unless a longer span repeats
  better by `longerWinsBy` (0.02) — a melody that changes over a repeating
  chord loop scores higher at its own length. Measured on the test track
  (`PhraseDiagnostics`, CHOP_STEMS): "other" repeats at 4 bars (r4 0.86–0.97
  above r8/r16) almost everywhere — the song IS 4-bar loops — with r8 > r4
  only at a few starts (bass bar 32: 0.88 vs 0.76). Chroma baselines on
  pad-heavy stems sit at 0.8+, so 16-bar structure is rarely evidenced.
- `PackOptions.chops` are the vocal-chop options; `phrases` is the Bool for
  musical phrases (the two names collided once).
- Drum-pattern MIDI needs every hit's label, not just the group leaders':
  `labelled` maps each hit in a group to its leader's CLAP label.
- One Core AI job on the GPU at a time; the builder runs its models one after
  another.
