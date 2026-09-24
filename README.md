# SampleChopper

A **sample pack from a song's stems** — on this machine. Given the four stems `stems` writes
(drums, bass, other, vocals), it finds the bars, cuts drum one-shots at their attacks and names
them by ear, names bass hits by note, chops the vocal into phrases, cuts tempo-exact loops from
every stem, and writes MIDI for the melodic parts with bar 1 on the first downbeat. Every file
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
| `<Stem>/Loops` | `Drums Loop 4 Bar - 130.4 BPM - Ebmin - 01.wav` | Bars from Beat This! downbeats on the drums; 1-, 2- and 4-bar windows where the stem is playing (within 9 dB of its loud bars); a repeat of the same sixteenth-note pattern counted once; length exactly `bars × beats × 60 / bpm` samples, rounded once. |
| `<Stem>/MIDI` | `Bass - 130.4 BPM - Ebmin.mid` | MuScriptor on bass, other and vocals; notes shifted so bar 1 is the first downbeat; the pack's tempo. |
| `manifest.json` | every item's bar, beat, start, length, label, note, cents, confidence | |

Tempo is the median beat gap of Beat This!, rounded to a whole number when within 0.15 of one;
key is `MusicAnalysis` on the other stem. Nothing is time-stretched or re-pitched: the pack is
the song, cut.

## Measured

On a 3 min 20 s dance track's RoFormer stems (48 kHz stereo), M3 Max, debug build:

- Bar grid 130.4 BPM, 113 bars, E♭ minor. The twelve bass notes CREPE named all sit in E♭ minor.
- 880 drum onsets became 42 distinct hits, 23 kept: 2 kicks, 3 snares, 1 clap, 8 hats, 8 open hats, 1 effect. Pre-roll before the attack 0.1–2.3 ms on every one-shot.
- 46 loops, every one exactly the tempo-exact sample count; 24 vocal chops from 0.6 s to 8 s.
- 74 s without MIDI, 250 s with MuScriptor medium on three stems (472, 3,662 and 129 notes).

## Models

Installed by the other tools, found in their folders: Beat This! (`scribe`), CLAP (`crate`),
CREPE (`tune`), MuScriptor (`scribe`). `PackOptions` takes explicit URLs instead.

## Requirements

- macOS 27+ (Core AI), Apple silicon
- Swift 6

## License

MIT — see [LICENSE](LICENSE).
