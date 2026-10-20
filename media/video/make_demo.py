#!/usr/bin/env python3
"""Make Mochi's 30-second demo video: the app's own screens, a title and an end card, with original music.

    python3 media/video/make_demo.py

Needs numpy, Pillow and ffmpeg (with libx264 and aac). Writes media/video/mochi-demo-30s.mp4.
The music is synthesised by this script, so it is original and needs no licence. The screens are the
images in media/screenshots and media/video/walk, so run media/snapshots.sh first if the app has changed.
"""
import functools
import math
import pathlib
import shutil
import subprocess
import tempfile
import wave

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
MEDIA = ROOT / "media"
OUT = MEDIA / "video" / "mochi-demo-30s.mp4"

W, H, FPS = 1280, 720, 30
DURATION = 30.0
SR = 44100
XFADE = 0.35  # seconds of cross-fade between scenes

INK = (59, 42, 32)
ORANGE = (244, 162, 89)
TOP, BOTTOM = (255, 247, 236), (255, 226, 190)
HELVETICA = "/System/Library/Fonts/Helvetica.ttc"  # index 0 regular, index 1 bold
LANCZOS = Image.Resampling.LANCZOS


def font(size, bold=False):
    return ImageFont.truetype(HELVETICA, size, index=1 if bold else 0)


def ease(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def build_background():
    img = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        draw.line([(0, y), (W, y)], fill=tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)))
    return img


BG = build_background()


def fit(img, max_w, max_h):
    scale = min(max_w / img.width, max_h / img.height)
    return img.resize((round(img.width * scale), round(img.height * scale)), LANCZOS)


def shadowed(base, box, radius=22, offset=12, blur=18):
    """Adds a soft shadow under a rectangle of the base image (RGBA in, RGBA out)."""
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(layer).rounded_rectangle([x0, y0 + offset, x1, y1 + offset], radius=radius, fill=(90, 60, 40, 110))
    return Image.alpha_composite(base, layer.filter(ImageFilter.GaussianBlur(blur)))


def caption(img, text, y=646):
    """A short line under the picture, with a small orange accent above it."""
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([(W - 60) // 2, y - 42, (W + 60) // 2, y - 36], radius=3, fill=ORANGE)
    draw.text((W / 2, y), text, font=font(40, bold=True), fill=INK, anchor="mm")


def zoom(base, u):
    """A slow push-in: from the whole picture at u=0 to 4% closer at u=1."""
    z = 1.0 + 0.04 * min(1.0, max(0.0, u))
    w, h = W / z, H / z
    x0, y0 = (W - w) / 2, (H - h) / 2
    return base.resize((W, H), Image.Resampling.BILINEAR, box=(x0, y0, x0 + w, y0 + h))


@functools.cache
def framed(path, max_w, max_h, center_y, text):
    """A screenshot, centred, with a shadow and a caption, drawn once and then zoomed."""
    shot = fit(Image.open(MEDIA / path).convert("RGBA"), max_w, max_h)
    x, y = (W - shot.width) // 2, center_y - shot.height // 2
    base = shadowed(BG.convert("RGBA"), (x, y, x + shot.width, y + shot.height))
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.width - 1, shot.height - 1], radius=22, fill=255)
    shot.putalpha(ImageChops.multiply(shot.getchannel("A"), mask))
    base.alpha_composite(shot, (x, y))
    out = base.convert("RGB")
    caption(out, text)
    return out


@functools.cache
def walk_frames():
    """Mochi trotting, one PNG per frame, drawn by the app's own view on a transparent background."""
    raw = [Image.open(path).convert("RGBA") for path in sorted((MEDIA / "video" / "walk").glob("walk-*.png"))]
    # Crop every frame to the same box, the union of all of them, so she stays in place while she trots
    boxes = [frame.getchannel("A").getbbox() for frame in raw]
    box = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
    crop = [frame.crop(box) for frame in raw]
    scale = 470 / crop[0].height
    return [frame.resize((round(frame.width * scale), 470), LANCZOS) for frame in crop]


@functools.cache
def chat_list_scroll():
    """The tall chat list, scaled to a window, with its shadow and caption already drawn."""
    shot = Image.open(MEDIA / "screenshots" / "06-chat-list.png").convert("RGBA")
    shot = shot.resize((760, round(shot.height * 760 / shot.width)), LANCZOS)
    box = (260, 60, 1020, 590)
    base = shadowed(BG.convert("RGBA"), box).convert("RGB")
    caption(base, "Every chat in one list, by what needs you.")
    mask = Image.new("L", (760, 530), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, 759, 529], radius=22, fill=255)
    return shot, base, mask


@functools.cache
def title_logo():
    return Image.open(MEDIA / "logo" / "mochi-logo-1024.png").convert("RGBA")


@functools.cache
def end_lineup():
    return fit(Image.open(MEDIA / "images" / "skins-lineup.png").convert("RGBA"), 900, 340)


# MARK: - Scenes. Each takes its own local time in seconds and returns an RGB frame.

def scene_title(lt):
    k = ease(lt / 0.9)
    size = int(320 * (0.8 + 0.2 * k))
    canvas = BG.convert("RGBA")
    logo = title_logo().resize((size, size), LANCZOS)
    canvas.alpha_composite(logo, (220 + (320 - size) // 2, 200 + (320 - size) // 2 + round((1 - k) * 40)))

    fade = ease((lt - 0.5) / 0.7)
    text = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(text)
    draw.text((600, 300), "Mochi", font=font(120, bold=True), fill=INK + (255,), anchor="lm")
    draw.text((604, 392), "A pixel-art companion for", font=font(38), fill=INK + (255,), anchor="lm")
    draw.text((604, 438), "Claude Code on macOS", font=font(38), fill=INK + (255,), anchor="lm")
    text.putalpha(text.getchannel("A").point(lambda a: int(a * fade)))
    canvas.alpha_composite(text)
    return canvas.convert("RGB")


def scene_working(lt):
    frames = walk_frames()
    frame = frames[int(lt * 12) % len(frames)]  # 12 frames a second: a two-second trot, looped
    canvas = BG.convert("RGBA")
    canvas.alpha_composite(frame, ((W - frame.width) // 2, 60))
    out = canvas.convert("RGB")
    caption(out, "She shows what each chat is doing.")
    return out


def scene_states(lt):
    return zoom(framed("screenshots/01-status.png", 1000, 300, 330, "Working, waiting for you, ready, or blocked."), lt / 4.0)


def scene_approval(lt):
    return zoom(framed("screenshots/04-approval-card.png", 820, 430, 320, "Allow or deny from her card."), lt / 4.0)


def scene_list(lt):
    shot, base, mask = chat_list_scroll()
    u = ease(lt / 4.5)
    top = round(u * (shot.height - 530))
    canvas = base.copy()
    canvas.paste(shot.crop((0, top, 760, top + 530)).convert("RGB"), (260, 60), mask)
    return canvas


def scene_usage(lt):
    return zoom(framed("screenshots/02-mood-and-countdown.png", 1000, 400, 320, "Keep an eye on your limits."), lt / 3.5)


def scene_week(lt):
    return zoom(framed("screenshots/08-this-week.png", 1000, 540, 320, "Your week, day by day."), lt / 3.0)


def scene_end(lt):
    canvas = BG.convert("RGBA")
    lineup = end_lineup()
    canvas.alpha_composite(lineup, ((W - lineup.width) // 2, 50))
    out = canvas.convert("RGB")
    draw = ImageDraw.Draw(out)
    draw.text((W / 2, 460), "github.com/EmmaNguyen/mod-pet", font=font(46, bold=True), fill=INK, anchor="mm")
    draw.text((W / 2, 520), "Open source · MIT licence · macOS 13 or later", font=font(30), fill=INK, anchor="mm")
    caption(out, "Try Mochi on GitHub.")
    return out


# (start, end, scene). Scenes are back to back; a cross-fade is centred on each join.
SCENES = [
    (0.0, 3.0, scene_title),
    (3.0, 7.5, scene_working),
    (7.5, 11.5, scene_states),
    (11.5, 15.5, scene_approval),
    (15.5, 20.0, scene_list),
    (20.0, 23.5, scene_usage),
    (23.5, 26.5, scene_week),
    (26.5, 30.0, scene_end),
]


def scene_frame(i, t):
    start, end, scene = SCENES[i]
    return scene(min(max(t - start, 0.0), end - start))


def frame_at(t):
    for k in range(len(SCENES) - 1):
        join = SCENES[k][1]
        if abs(t - join) < XFADE / 2:
            mix = ease((t - (join - XFADE / 2)) / XFADE)
            return Image.blend(scene_frame(k, t), scene_frame(k + 1, t), mix)
    for i, (start, end, _) in enumerate(SCENES):
        if start <= t < end:
            return scene_frame(i, t)
    return scene_frame(len(SCENES) - 1, t)


# MARK: - Music: a slow loop in C major, 96 beats a minute, twelve bars (30 seconds)

PROGRESSION = [(60, 64, 67), (57, 60, 64), (53, 57, 60), (55, 59, 62)] * 3  # C, Am, F, G
MELODY = [(76, 79, 84, 79), (76, 81, 84, 81), (77, 81, 84, 81), (74, 79, 83, 79)] * 3


def midi_hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def tone(t, freq, kind="sine"):
    phase = 2 * np.pi * freq * t
    if kind == "triangle":
        return 2 / np.pi * np.arcsin(np.sin(phase))
    return np.sin(phase)


def add(buf, start, signal, pan=0.0):
    """Mixes a mono note into the stereo buffer at a time, from left (-1) to right (+1)."""
    i = int(start * SR)
    if i >= buf.shape[1]:
        return
    n = min(len(signal), buf.shape[1] - i)
    buf[0, i:i + n] += signal[:n] * math.sqrt((1 - pan) / 2)
    buf[1, i:i + n] += signal[:n] * math.sqrt((1 + pan) / 2)


def pad(buf, start, chord, bar):
    n = int((bar + 0.8) * SR)
    t = np.arange(n) / SR
    env = np.minimum(1, t / 0.6) * np.clip((bar + 0.8 - t) / 0.8, 0, 1)
    for m in chord:
        f = midi_hz(m - 12)
        add(buf, start, (0.5 * tone(t, f) + 0.25 * tone(t, f * 1.004) + 0.12 * tone(t, 2 * f)) * env * 0.07)


def arpeggio(buf, start, chord, beat):
    order = [0, 1, 2, 1, 0, 2, 1, 2]  # up and down through the chord, in eighth notes
    t = np.arange(int(0.9 * SR)) / SR
    env = np.exp(-t / 0.22)
    for k, idx in enumerate(order):
        sig = tone(t, midi_hz(chord[idx] + 12), "triangle") * env * 0.10
        add(buf, start + k * beat / 2, sig, pan=-0.5 if k % 2 == 0 else 0.5)


def melody(buf, start, notes, beat):
    t = np.arange(int(1.6 * beat * SR)) / SR
    env = np.minimum(1, t / 0.03) * np.exp(-t / 0.45)
    for k, m in enumerate(notes):
        sig = (0.7 * tone(t, midi_hz(m)) + 0.3 * tone(t, midi_hz(m) * 2)) * env * 0.09
        add(buf, start + k * beat, sig, pan=0.15)


def bass(buf, start, chord, beat):
    t = np.arange(int(1.2 * SR)) / SR
    sig = tone(t, midi_hz(chord[0] - 24)) * np.exp(-t / 0.55) * 0.22
    for k in (0, 2):
        add(buf, start + k * beat, sig)


def hats(buf, start, beat, rng):
    t = np.arange(int(0.08 * SR)) / SR
    env = np.exp(-t / 0.02)
    for k in (1, 3, 5, 7):  # the off-beat eighths
        noise = np.diff(rng.standard_normal(len(t)), prepend=0.0)  # a little high-passed
        add(buf, start + k * beat / 2, noise * env * 0.035, pan=0.3)


def reverb(buf, rng):
    n_ir = int(1.8 * SR)
    t = np.arange(n_ir) / SR
    size = buf.shape[1] + n_ir
    wet = np.zeros_like(buf)
    for ch in range(2):
        ir = rng.standard_normal(n_ir) * np.exp(-t / 0.45)
        ir /= np.sqrt(np.sum(ir ** 2)) + 1e-9
        wet[ch] = np.fft.irfft(np.fft.rfft(buf[ch], size) * np.fft.rfft(ir, size), size)[: buf.shape[1]]
    return buf + 0.35 * wet


def make_music(rng):
    n = int(DURATION * SR)
    buf = np.zeros((2, n))
    beat = 60 / 96
    bar = 4 * beat
    for b, chord in enumerate(PROGRESSION):
        start = b * bar
        pad(buf, start, chord, bar)
        arpeggio(buf, start, chord, beat)
        bass(buf, start, chord, beat)
        hats(buf, start, beat, rng)
        melody(buf, start, MELODY[b], beat)
    buf = reverb(buf, rng)
    t = np.arange(n) / SR
    buf *= np.minimum(1, t / 1.0) * np.clip((DURATION - t) / 2.5, 0, 1)  # fade in, then fade out
    return buf / np.max(np.abs(buf)) * 0.8


def write_wav(path, buf):
    data = (np.clip(buf.T, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(SR)
        out.writeframes(data.tobytes())


def main():
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise SystemExit("ffmpeg is needed: brew install ffmpeg")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        wav = pathlib.Path(tmp) / "music.wav"
        write_wav(wav, make_music(np.random.default_rng(7)))
        cmd = [
            ffmpeg, "-y", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
            "-i", str(wav),
            "-map", "0:v", "-map", "1:a",
            "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart",
            str(OUT),
        ]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
        for n in range(round(DURATION * FPS)):
            proc.stdin.write(frame_at(n / FPS).tobytes())
        proc.stdin.close()
        if proc.wait() != 0:
            raise SystemExit("ffmpeg failed")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
