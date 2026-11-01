#!/usr/bin/env python3
"""Extract the map page (page 1) of each Lantmäteriet PDF in maps/ to images/ at native scan resolution.

Remaining PDF pages are the survey protocols and are not extracted. PNG/JPEG files in maps/ are copied as-is.
Requires Ghostscript (`brew install ghostscript`).

Usage: scripts/extract_maps.py [maps_dir] [images_dir]
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path


def native_dpi(pdf: Path) -> int:
    """DPI that renders page 1 at the pixel width of its embedded scan."""
    data = pdf.read_bytes()
    width_px = None
    for m in re.finditer(rb"/Subtype\s*/Image(.{0,400})", data, re.S):
        w = re.search(rb"/Width\s+(\d+)", m.group(0))
        if w:
            width_px = int(w.group(1))
            break
    box = re.search(rb"/MediaBox\s*\[\s*([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s*\]", data)
    if not width_px or not box:
        return 300
    width_pt = float(box.group(3)) - float(box.group(1))
    return max(72, round(width_px / (width_pt / 72)))


def main() -> None:
    maps_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "maps")
    out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else "images")
    out_dir.mkdir(exist_ok=True)
    for src in sorted(maps_dir.iterdir()):
        suffix = src.suffix.lower()
        if suffix == ".pdf":
            dst = out_dir / (src.stem + ".jpg")
            if dst.exists():
                print(f"skip  {dst.name}")
                continue
            dpi = native_dpi(src)
            subprocess.run(
                ["gs", "-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=jpeg", "-dJPEGQ=92",
                 f"-r{dpi}", "-dFirstPage=1", "-dLastPage=1", f"-sOutputFile={dst}", str(src)],
                check=True,
            )
            print(f"pdf   {dst.name} @ {dpi} dpi")
        elif suffix in (".png", ".jpg", ".jpeg"):
            dst = out_dir / src.name
            if not dst.exists():
                shutil.copy2(src, dst)
                print(f"copy  {dst.name}")


if __name__ == "__main__":
    main()
