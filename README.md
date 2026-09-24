# SampleChopper

A **sample pack from a song's stems** — on this machine. Given the four stems `stems` writes
(drums, bass, other, vocals), it finds the bars, cuts drum one-shots at their attacks and names
them by ear, names bass hits by note, chops the vocal into phrases, cuts tempo-exact loops from
every stem, and writes a MIDI file for every melodic loop, transcribed from that loop alone. Every file
comes with where it came from.

```swift
import SampleChopper

let stems = try PackBuilder.stems(in: stemsFolder)                 // *-drums, *-bass, *-other, *-vocals
let builder = PackBuilder(stems: stems, options: PackOptions(name: "Not Alone"))
let pack = try await builder.build(into: packsFolder)              // packsFolder/Not Alone/…
pack.bpm, pack.key, pack.items                                     // 130.4, "Ebmin", 108 items with bar, beat, label, note…
```

## What it cuts

| Folder | What | How |
|---|---|---|
| `Drums/One-shots` | `Kick - 01.wav`, `Snare - …`, `Hat`, `Open-hat`, `Clap`, `Tom`, `Crash`, `Ride`, `Perc`, `Fx` | Spectral-flux onsets refined to the attack; each hit cut to where it decays (−48 dB) or the next hit starts; ghosts under the loud hits dropped; near-identical hits (24-band attack fingerprint) counted once; named by CLAP zero-shot over drum phrases; the cleanest per label kept; peak-normalised to −1 dBFS. |
| `Bass/One-shots` | `Bass D#2 - 01.wav` | The same cut on the bass stem, named by CREPE (median of the confident frames), two per note. |
| `Vocals/Chops` | `Vocal Chop - 01.wav` | Stretches above −42 dBFS, gaps under 250 ms bridged, under 300 ms dropped, 30 ms of air, the longest 24. |
| `<Stem>/Loops` | `Drums Loop 4 Bar - 130.4 BPM - Ebmin - 01.wav` | Bars from Beat This! downbeats on the drums; windows of 4 and 2 bars for bass, other and vocals and 4, 2 and 1 for drums (`bars` overrides) where the stem is playing (within 9 dB of its loud bars); a repeat of the same sixteenth-note pattern counted once; length exactly `bars × beats × 60 / bpm` samples, rounded once. |
| `<Stem>/Phrases` | `Other Phrase 8 Bar - 130.4 BPM - Ebmin - 01.wav` | Whole musical units from bass, other, vocals and a **Music** stem (the three summed, so a melody the separation scattered comes back together): every bar is described by its chroma at each sixteenth, and a span of 4, 8 or 16 bars is a phrase when the span after it is the same again — the smallest span that repeats is the phrase length. Ranked by how many times the song returns to them (`repeats` in the manifest): the most-repeated is the main part. Each phrase gets its MIDI, transcribed from the cut alone. |
| `Drums/MIDI` | `Drums Loop 4 Bar - … - 01.mid` | Every drum loop as a drum pattern: each hit inside it at its beat on the General MIDI note of its label (kick 36, snare 38, clap 39, hat 42, open hat 46, tom 45, crash 49, ride 51, perc 37), velocity from its peak, channel 10. |
| `Drums/Layers` | `… (Dry).wav`, `… (FX).wav` | With `drumLayers`: a median-filter harmonic/percussive split at margin 3, reproduced from librosa to 154–162 dB; FX is what neither the steady-tone nor the transient mask claims — noise sweeps, washes, tails — and Dry is the loop without it. |
| `<Stem>/MIDI` | `Bass Loop 4 Bar - 130.4 BPM - Ebmin - 01.mid` | One MIDI file per bass, other and vocal loop, transcribed by MuScriptor from that loop alone — bar 1 at the loop's start, the pack's tempo — so every loop has its notes beside it. `midiFull` adds one file per stem over the whole song. |
| `manifest.json` | every item's bar, beat, start, length, label, note, cents, confidence | |

Tempo is the median beat gap of Beat This!, rounded to a whole number when within 0.15 of one;
key is `MusicAnalysis` on the other stem. Nothing is time-stretched or re-pitched: the pack is
the song, cut.

## Measured

On a 3 min 20 s dance track's RoFormer stems (48 kHz stereo), M3 Max, debug build:

- Bar grid 130.4 BPM, 113 bars, E♭ minor. The twelve bass notes CREPE named all sit in E♭ minor.
- Phrases on the track: 13 found — the other stem's main part is a 4-bar span the song returns to 21 times, bass phrases return 2–6 times, the Music stem (bass + other + vocals summed) gives four 4-bar phrases and one 8-bar phrase that repeats 9 times, and the vocal gets one; 12 of them carry MIDI. Repeat scores at 4 bars sit above those at 8 and 16 almost everywhere on this track: it is built from 4-bar loops, and the finder says so rather than inventing longer ones.
- 880 drum onsets became 42 distinct hits, 23 kept: 2 kicks, 3 snares, 1 clap, 8 hats, 8 open hats, 1 effect. Pre-roll before the attack 0.1–2.3 ms on every one-shot.
- 35 loops (4 and 2 bars for the melodic stems, 4, 2 and 1 for drums), every one exactly the tempo-exact sample count; 24 vocal chops from 0.6 s to 8 s.
- Phrases: on a synthetic chord sequence (A B C D ×3, then E F ×4) the finder returns the 4-bar phrase with 2 repeats and the 2-bar phrase with 3; magnitude chroma puts identical bars at 1.00 and different chords at 0.10–0.75.
- The FX layer: on a synthetic mix of drums with a white-noise riser and a low wash, the noise lands in FX at 11 dB SDR (margin 3; 7 dB at margin 2, nothing at margin 1). On the track's one FX-heavy drum loop 42% of the energy went to FX, on ordinary ones far less. It is a layer split, not a model: a cymbal wash and a riser are both "FX" to it.
- 26 s without MIDI in a release build; 113 s with MuScriptor medium on the 35 melodic loops (a one-bar bass loop came out as six notes, B1–C#2). Whole-stem MIDI, when asked for, adds about 3 minutes (472, 3,662 and 129 notes).

## Models

Installed by the other tools, found in their folders: Beat This! (`scribe`), CLAP (`crate`),
CREPE (`tune`), MuScriptor (`scribe`). `PackOptions` takes explicit URLs instead.

## Requirements

- macOS 27+ (Core AI), Apple silicon
- Swift 6

## License

MIT — see [LICENSE](LICENSE).
