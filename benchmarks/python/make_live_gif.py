"""Animated GIF of a live LivePTV run: the overlay frames `ace-probe usb --gif-every S` saved during the run (the
analysis as it happened, faces already blurred with --blur-faces), plus a bar with the metrics recorded with each
frame (hud.csv). usage: make_live_gif.py RUN_DIR OUT.gif [--from S] [--to S] [--width PX] [--fps F] [--label TEXT]"""
from __future__ import annotations

import argparse
import csv
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/Helvetica.ttc"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("out")
    ap.add_argument("--from", dest="t0", type=float, default=0)
    ap.add_argument("--to", dest="t1", type=float, default=1e9)
    ap.add_argument("--width", type=int, default=720)
    ap.add_argument("--fps", type=float, default=10)
    ap.add_argument("--label", default="")
    ap.add_argument("--vector-seconds", type=float, default=0.25, help="what the run used (--vector-seconds)")
    ap.add_argument("--colors", type=int, default=160)
    a = ap.parse_args()
    rows = [r for r in csv.DictReader(open(os.path.join(a.run, "hud.csv"))) if a.t0 <= float(r["t_s"]) <= a.t1]
    big = ImageFont.truetype(FONT, 17)
    small = ImageFont.truetype(FONT, 14)
    with tempfile.TemporaryDirectory() as td:
        for i, r in enumerate(rows):
            im = Image.open(os.path.join(a.run, "gif", r["file"])).convert("RGB")
            h = round(im.height * a.width / im.width)
            im = im.resize((a.width, h), Image.LANCZOS)
            bar = 46
            canvas = Image.new("RGB", (a.width, h + bar), (14, 14, 16))
            canvas.paste(im, (0, 0))
            d = ImageDraw.Draw(canvas)
            if a.label:
                d.rectangle((0, 0, d.textlength(a.label, font=small) + 16, 24), fill=(14, 14, 16))
                d.text((8, 4), a.label, font=small, fill=(235, 235, 235))
            line1 = (f"LIVE  camera {float(r['camera_fps']):.1f} fps  ·  analysed {float(r['analysed_fps']):.1f} fps  ·  "
                     f"{float(r['analyse_ms']):.0f} ms/frame  ·  {int(r['valid_cells']):,} vectors")
            d.text((10, h + 6), line1, font=big, fill=(255, 255, 255))
            d.text((10, h + 27), f"t = {float(r['t_s']):5.1f} s   ·   arrows: displacement over {a.vector_seconds:g} s, colour = speed",
                   font=small, fill=(170, 170, 175))
            canvas.save(os.path.join(td, f"f{i:05d}.png"))
        pal = os.path.join(td, "pal.png")
        subprocess.run(["ffmpeg", "-v", "error", "-framerate", str(a.fps), "-i", os.path.join(td, "f%05d.png"),
                        "-vf", f"palettegen=max_colors={a.colors}:stats_mode=diff", "-y", pal], check=True)
        subprocess.run(["ffmpeg", "-v", "error", "-framerate", str(a.fps), "-i", os.path.join(td, "f%05d.png"), "-i", pal,
                        "-lavfi", "paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle", "-loop", "0", "-y", a.out], check=True)
    print(a.out, f"{os.path.getsize(a.out) / 1e6:.1f} MB, {len(rows)} frames")


if __name__ == "__main__":
    main()
