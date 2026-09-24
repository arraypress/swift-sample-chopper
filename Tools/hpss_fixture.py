# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["numpy", "librosa", "soundfile"]
# ///
"""librosa's harmonic/percussive split as a fixture for the Swift port, and a measured synthetic test.

    uv run Tools/hpss_fixture.py <loop.wav> [--seconds 3] [--fixtures Tests/SampleChopperTests/Fixtures]

Writes hpss_input.f32 (mono, native rate), hpss_harmonic.f32, hpss_percussive.f32 from `librosa.effects.hpss`
(n_fft 2048, hop 512, kernel 31, margin 1, power 2). Then mixes synthetic drums with a noise riser and a
sustained noise wash and reports how much of each lands in which layer (SDR)."""
import argparse, json
from pathlib import Path
import numpy as np, soundfile as sf, librosa
HERE = Path(__file__).resolve().parent
ap = argparse.ArgumentParser(); ap.add_argument("loop"); ap.add_argument("--seconds", type=float, default=3.0)
ap.add_argument("--fixtures", default=str(HERE.parent / "Tests/SampleChopperTests/Fixtures")); args = ap.parse_args()
fx = Path(args.fixtures); fx.mkdir(parents=True, exist_ok=True)
y, sr = sf.read(args.loop, dtype="float32", always_2d=True); m = y.mean(1)[: int(args.seconds * sr)].astype(np.float32)
m.tofile(fx / "hpss_input.f32")
for margin in (1.0, 3.0):
    h, p = librosa.effects.hpss(m, margin=margin)
    tag = "" if margin == 1 else f"_m{int(margin)}"
    h.astype(np.float32).tofile(fx / f"hpss_harmonic{tag}.f32"); p.astype(np.float32).tofile(fx / f"hpss_percussive{tag}.f32")
    r = m - h - p
    print(f"fixture margin {margin:.0f}: {len(m)} samples at {sr} Hz; harmonic {100*(h**2).sum()/((m**2).sum()+1e-12):.0f}%, percussive {100*(p**2).sum()/((m**2).sum()+1e-12):.0f}%, residual {100*(r**2).sum()/((m**2).sum()+1e-12):.0f}% of the energy")
json.dump({"sampleRate": sr, "samples": len(m), "margins": [1, 3]}, open(fx / "hpss_manifest.json", "w"))

def sdr(ref, est): return 10 * np.log10((ref**2).sum() / (((ref - est)**2).sum() + 1e-12))
rng = np.random.default_rng(0); sr2 = 48000; T = 4.0; t = np.arange(int(T * sr2)) / sr2
drums = np.zeros_like(t)
for k in range(16):                                   # kicks and hats on a 16th grid at 120 bpm
    s = int(k * 0.125 * sr2); n = int(0.08 * sr2)
    drums[s:s+n] += np.sin(2*np.pi*55*t[:n]) * np.exp(-t[:n]/0.05) * 0.8
    if k % 2 == 1: drums[s:s+n//4] += rng.standard_normal(n//4) * np.exp(-t[:n//4]/0.01) * 0.3
riser = rng.standard_normal(len(t)) * (t / T) ** 2 * 0.3
riser = librosa.effects.preemphasis(riser)
wash = np.convolve(rng.standard_normal(len(t)), np.ones(400)/400, "same") * 0.15   # low, sustained
mix = (drums + riser + wash).astype(np.float32)
for margin in (1.0, 2.0, 3.0, 4.0):
    H, P = librosa.effects.hpss(mix, margin=margin); R = mix - H - P
    print(f"synthetic margin {margin:.0f}: drums→percussive SDR {sdr(drums, P):5.1f} dB | noise (riser+wash)→residual SDR {sdr(riser + wash, R):5.1f} dB | noise→harmonic {sdr(riser + wash, H):5.1f} dB | residual holds {100*(R**2).sum()/((mix**2).sum()):.0f}% of the mix")
# a tonal riser (pitch sweep) for comparison
tone = 0.3 * np.sin(2*np.pi*np.cumsum(200 + 3000*(t/T)**2)/sr2)
mix2 = (drums + tone).astype(np.float32); H, P = librosa.effects.hpss(mix2, margin=3.0); R = mix2 - H - P
print(f"synthetic tonal sweep, margin 3: sweep→harmonic SDR {sdr(tone, H):.1f} dB, drums→percussive {sdr(drums, P):.1f} dB")
