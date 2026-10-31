"""Builds the fighter voices in assets/audio/voice/fighters/ from three free voice packs.

Every fighter has their own voice actor (no pitch-shifted copies) and five kinds of takes:
  attack   short efforts on strong normal attacks ("hup", "hah")
  special  a sharper shout on special moves
  super    the longest, loudest shout, on the super flash
  hurt     a pain grunt when a solid hit lands on them
  ko       the cry when they are knocked out
FightFx decides when each kind plays (scripts/fx/fight_fx.gd); Audio.shout picks a take.

Each take is cut from the pack, trimmed to the voice, high-passed, de-noised when the
recording is noisy, gently compressed, brought to one loudness (LOUD_DBFS, the loud part
of the take), held under PEAK with a soft knee (no clipping), faded in and out, and
encoded mono Ogg Vorbis. The packs are downloaded once into --cache and read from there.

Needs ffmpeg on PATH, numpy and soundfile. After a run, refresh the mouth envelopes and the import:
    uv run --no-project --with numpy --with soundfile python tools/build_fighter_voices.py [--cache DIR]
    python tools/build_voice_envelopes.py
    godot --headless --path . --import
"""

import argparse
import io
import pathlib
import subprocess
import urllib.request
import zipfile

import numpy as np
import soundfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "audio" / "voice" / "fighters"
SR = 44100
LOUD_DBFS = -11.0  # the 95th-percentile 20 ms RMS of every take
PEAK = 0.84  # -1.5 dBFS
KNEE = 0.6  # the soft limiter starts here
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 Chrome/126 Safari/537.36"

# Packs: file name in the cache -> URL. Licences and authors are in assets/CREDITS.md.
PACKS = {
    "yelling sounds.zip": "https://opengameart.org/sites/default/files/yelling%20sounds.zip",  # HaelDB, CC0
    "RPG Voice Starter Pack.zip": "https://opengameart.org/sites/default/files/RPG%20Voice%20Starter%20Pack.zip",  # cicifyre, CC0
    "FEMALE_Gruntwork_1.mp3": "https://opengameart.org/sites/default/files/FEMALE_Gruntwork_1.mp3",  # PlumpDev, CC BY-SA 4.0
}

# A take: "yell:<file stem>" (HaelDB; 1yell* is one vocalist, 3* another, plain yell* a
# third), "rpg<type>:<file stem>" (cicifyre; type 1 bright, 2 medium, 3 mature), or
# "grunt:<n>" (the n-th take of the Gruntwork recording, split at its pauses). A list of
# takes is one clip, played back to back with GAP between them.
GAP = 0.07
CAST = {
    # Jin, Tae Kwon Do kicker: vocalist 1, short sharp yells.
    "jin": {
        "attack": ["yell:1yell2", "yell:1yell9", "yell:1yell13", "yell:1yell14", "yell:1yell15"],
        "special": ["yell:1yell4", "yell:1yell10", "yell:1yell5"],
        "super": ["yell:1yell3", "yell:1yell11"],
        "hurt": ["yell:1yell8", "yell:1yell6", "yell:1yell7"],
        "ko": ["yell:1yell12"],
    },
    # Kenji, all-rounder: vocalist 3, the widest range.
    "kenji": {
        "attack": ["yell:3yell3", "yell:3yell4", "yell:3grunt5", "yell:3grunt1", "yell:3grunt4"],
        "special": ["yell:3yell8", "yell:3yell14", "yell:3yell12"],
        "super": ["yell:3yell6", "yell:3yell9"],
        "hurt": ["yell:3grunt3", "yell:3yell5", "yell:3grunt2"],
        "ko": ["yell:3yell1", "yell:3yell2"],
    },
    # Brutus, heavy hitter: the lowest male voice.
    "brutus": {
        "attack": ["yell:yell7", "yell:yell12", "yell:yell13"],
        "special": ["yell:yell3", "yell:yell4", "yell:yell8"],
        "super": ["yell:yell10", "yell:yell11"],
        "hurt": ["yell:yell6", "yell:yell8"],
        "ko": ["yell:yell5", "yell:yell2", "yell:yell1"],
    },
    # Rhea, lightning-fast rushdown: the bright voice.
    "rhea": {
        "attack": ["rpg1:attack1", "rpg1:attack2", "rpg1:attack3", "rpg1:jump1", "rpg1:jump2", "rpg1:jump3"],
        "special": ["rpg1:attack1", "rpg1:attack2", "rpg1:attack3"],
        "super": [["rpg1:attack1", "rpg1:attack3"], ["rpg1:attack3", "rpg1:attack2"]],
        "hurt": ["rpg1:damaged1", "rpg1:damaged2", "rpg1:damaged3"],
        "ko": [["rpg1:damaged1", "rpg1:damaged2"], ["rpg1:damaged3", "rpg1:damaged2"]],
    },
    # Mira, street brawler: the medium voice.
    "mira": {
        "attack": ["rpg2:attack1", "rpg2:attack2", "rpg2:attack3", "rpg2:jump1"],
        "special": ["rpg2:attack1", "rpg2:attack2", "rpg2:attack3"],
        "super": [["rpg2:attack2", "rpg2:attack1"], ["rpg2:attack3", "rpg2:attack2"]],
        "hurt": ["rpg2:damaged1", "rpg2:damaged2", "rpg2:damaged3"],
        "ko": [["rpg2:damaged1", "rpg2:damaged3"], ["rpg2:damaged2", "rpg2:damaged3"]],
    },
    # Lian, Wing Chun master: the mature voice.
    "lian": {
        "attack": ["rpg3:attack1", "rpg3:attack2", "rpg3:attack3", "rpg3:jump2", "rpg3:jump3"],
        "special": ["rpg3:attack1", "rpg3:attack2", "rpg3:attack3"],
        "super": [["rpg3:attack1", "rpg3:attack3"], ["rpg3:attack2", "rpg3:attack3"]],
        "hurt": ["rpg3:damaged1", "rpg3:damaged2", "rpg3:damaged3"],
        "ko": [["rpg3:damaged2", "rpg3:damaged1"], ["rpg3:damaged3", "rpg3:damaged1"]],
    },
    # Valka, towering wrestler: the low female voice.
    "valka": {
        "attack": ["grunt:0", "grunt:4", "grunt:23", "grunt:26", "grunt:24", "grunt:22"],
        "special": ["grunt:7", "grunt:14", "grunt:13", "grunt:15", "grunt:2"],
        "super": ["grunt:9", "grunt:20"],
        "hurt": ["grunt:1", "grunt:3", "grunt:16", "grunt:6"],
        "ko": ["grunt:19", "grunt:21"],
    },
}


def fetch(cache: pathlib.Path, name: str) -> bytes:
    path = cache / name
    if not path.exists():
        cache.mkdir(parents=True, exist_ok=True)
        req = urllib.request.Request(PACKS[name], headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=120) as res:
            path.write_bytes(res.read())
    return path.read_bytes()


def decode(data: bytes, filters: str = "") -> np.ndarray:
    args = ["ffmpeg", "-v", "error", "-i", "pipe:0"]
    if filters:
        args += ["-af", filters]
    args += ["-f", "f32le", "-ac", "1", "-ar", str(SR), "pipe:1"]
    return np.frombuffer(subprocess.run(args, input=data, capture_output=True, check=True).stdout, np.float32).copy()


def encode(samples: np.ndarray, fmt: str = "ogg") -> bytes:
    """Ogg Vorbis (libsndfile's encoder: not every ffmpeg build has one) or float WAV."""
    out = io.BytesIO()
    if fmt == "ogg":
        soundfile.write(out, samples.astype(np.float32), SR, format="OGG", subtype="VORBIS")
    else:
        soundfile.write(out, samples.astype(np.float32), SR, format="WAV", subtype="FLOAT")
    return out.getvalue()


def frames_rms(a: np.ndarray, size: float = 0.01) -> np.ndarray:
    n = int(SR * size)
    count = max(1, len(a) // n)
    padded = np.zeros(count * n, np.float32)
    padded[: min(len(a), count * n)] = a[: count * n]
    return np.sqrt(np.mean(padded.reshape(count, n) ** 2, axis=1))


def split_takes(a: np.ndarray, gap: float = 0.18, floor_db: float = -38.0, shortest: float = 0.12) -> list[np.ndarray]:
    """Takes in one long recording, separated by at least `gap` s of near silence."""
    env = frames_rms(a, 0.02)
    on = env > env.max() * 10 ** (floor_db / 20)
    takes, start, quiet = [], None, 0
    for i, loud in enumerate(on):
        if loud:
            start = i if start is None else start
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet * 0.02 >= gap:
                takes.append((start, i - quiet + 1))
                start, quiet = None, 0
    if start is not None:
        takes.append((start, len(on)))
    n = int(0.02 * SR)
    return [a[max(0, s * n - int(0.03 * SR)): min(len(a), e * n + int(0.08 * SR))]
            for s, e in takes if (e - s) * 0.02 >= shortest]


class Library:
    """Raw takes by name, decoded on demand."""

    def __init__(self, cache: pathlib.Path):
        self.cache = cache
        self._zips: dict[str, zipfile.ZipFile] = {}
        self._grunts: list[np.ndarray] | None = None

    def _zip(self, name: str) -> zipfile.ZipFile:
        if name not in self._zips:
            self._zips[name] = zipfile.ZipFile(io.BytesIO(fetch(self.cache, name)))
        return self._zips[name]

    def _member(self, archive: str, suffix: str) -> bytes:
        z = self._zip(archive)
        hits = [m for m in z.namelist() if m.endswith(suffix) and "__MACOSX" not in m]
        if len(hits) != 1:
            raise KeyError(f"{suffix} in {archive}: {hits}")
        return z.read(hits[0])

    def raw(self, take: str) -> np.ndarray:
        pack, key = take.split(":", 1)
        if pack == "yell":
            return decode(self._member("yelling sounds.zip", f"/{key}.wav"))
        if pack.startswith("rpg"):
            return decode(self._member("RPG Voice Starter Pack.zip", f"Type {pack[3:]}/{key}.wav"))
        if pack == "grunt":
            if self._grunts is None:
                self._grunts = split_takes(decode(fetch(self.cache, "FEMALE_Gruntwork_1.mp3")))
            return self._grunts[int(key)]
        raise KeyError(take)


def trim(a: np.ndarray, floor_db: float = -32.0) -> np.ndarray:
    env = frames_rms(a)
    on = np.where(env > env.max() * 10 ** (floor_db / 20))[0]
    if len(on) == 0:
        return a
    n = int(0.01 * SR)
    return a[max(0, on[0] * n - int(0.015 * SR)): min(len(a), (on[-1] + 1) * n + int(0.08 * SR))]


def snr_db(a: np.ndarray) -> float:
    env = frames_rms(a, 0.02)
    loud = env[env > env.max() * 0.1]
    return float(20 * np.log10((np.median(loud) + 1e-9) / (np.percentile(env, 10) + 1e-9)))


def clean(a: np.ndarray, male: bool) -> np.ndarray:
    """One take, trimmed, filtered, compressed, levelled and faded."""
    noisy = snr_db(a) < 30.0
    a = trim(a)
    chain = [f"highpass=f={80 if male else 110}:poles=2", "lowpass=f=15000"]
    if noisy:
        chain.append("afftdn=nr=12:nf=-42")
    chain.append("acompressor=threshold=0.1:ratio=3:attack=4:release=90:knee=4")
    a = decode(encode(a, fmt="wav"), ",".join(chain))
    return a


def level(a: np.ndarray) -> np.ndarray:
    env = frames_rms(a, 0.02)
    loud = np.percentile(env, 95)
    a = a * (10 ** (LOUD_DBFS / 20) / max(loud, 1e-6))
    # Soft knee: untouched below KNEE, eased into PEAK above it.
    mag = np.abs(a)
    over = mag > KNEE
    a[over] = np.sign(a[over]) * (KNEE + (PEAK - KNEE) * np.tanh((mag[over] - KNEE) / (PEAK - KNEE)))
    fade_in = int(0.004 * SR)
    fade_out = min(int(0.06 * SR), len(a) // 3)
    a[:fade_in] *= np.linspace(0.0, 1.0, fade_in)
    a[len(a) - fade_out:] *= 0.5 + 0.5 * np.cos(np.linspace(0.0, np.pi, fade_out))
    return a


def build(lib: Library, fighter: str, takes, male: bool) -> np.ndarray:
    parts = takes if isinstance(takes, list) else [takes]
    pieces = []
    for i, take in enumerate(parts):
        if i:
            pieces.append(np.zeros(int(GAP * SR), np.float32))
        pieces.append(clean(lib.raw(take), male))
    return level(np.concatenate(pieces))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--cache", type=pathlib.Path, default=pathlib.Path.home() / ".cache" / "ringside-voices")
    args = parser.parse_args()
    lib = Library(args.cache)
    written = set()
    for fighter, kinds in CAST.items():
        male = fighter in ("jin", "kenji", "brutus")
        for kind, takes in kinds.items():
            for n, take in enumerate(takes, 1):
                a = build(lib, fighter, take, male)
                path = OUT / f"{fighter}_{kind}_{n}.ogg"
                path.write_bytes(encode(a))
                written.add(path.name)
                print(f"{path.name:22s} {len(a) / SR:4.2f} s  peak {20 * np.log10(np.abs(a).max()):5.1f} dBFS")
    # Takes from an earlier cast that this one no longer has.
    for old in OUT.glob("*.ogg"):
        if old.name not in written:
            old.unlink()
            imported = old.with_name(old.name + ".import")
            if imported.exists():
                imported.unlink()
            print(f"removed {old.name}")
    print(f"{len(written)} takes -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
