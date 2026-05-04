#!/usr/bin/env python3
"""
Generate netmon.icns — a dark shield with a lightning bolt.
Requires: pip install Pillow
Output:   MenuBar/Assets/netmon.icns  (committed to repo, used by CI)
"""
import math
import struct
import zlib
from pathlib import Path


def draw_icon(size: int) -> bytes:
    """Return raw RGBA bytes for the icon at `size`x`size`."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        raise SystemExit("pip install Pillow")

    img  = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    s    = size

    # ── Background circle ────────────────────────────────────────────────────
    pad = int(s * 0.04)
    draw.ellipse([pad, pad, s - pad, s - pad], fill=(15, 17, 23, 255))

    # ── Shield shape ─────────────────────────────────────────────────────────
    def pt(rx, ry):
        return (int(s * rx), int(s * ry))

    shield = [
        pt(0.22, 0.14), pt(0.78, 0.14),
        pt(0.78, 0.58),
        pt(0.50, 0.86),
        pt(0.22, 0.58),
    ]
    draw.polygon(shield, fill=(99, 102, 241, 255))   # indigo-500

    # ── Lightning bolt ───────────────────────────────────────────────────────
    bolt = [
        pt(0.54, 0.21),
        pt(0.38, 0.50),
        pt(0.50, 0.50),
        pt(0.46, 0.76),
        pt(0.63, 0.44),
        pt(0.50, 0.44),
    ]
    draw.polygon(bolt, fill=(250, 204, 21, 255))     # yellow-400

    # ── Thin border ring ─────────────────────────────────────────────────────
    bw = max(1, int(s * 0.025))
    draw.ellipse([pad, pad, s - pad, s - pad], outline=(99, 102, 241, 180), width=bw)

    return img.tobytes("raw", "RGBA")


# ── Minimal PNG writer (no external dep for writing) ────────────────────────

def _png_chunk(tag: bytes, data: bytes) -> bytes:
    c = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", c)


def rgba_to_png(rgba: bytes, size: int) -> bytes:
    sig  = b"\x89PNG\r\n\x1a\n"
    ihdr = _png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    rows = b""
    row_len = size * 4
    for y in range(size):
        rows += b"\x00" + rgba[y * row_len:(y + 1) * row_len]
    idat = _png_chunk(b"IDAT", zlib.compress(rows, 9))
    iend = _png_chunk(b"IEND", b"")
    return sig + ihdr + idat + iend


def _write_png(path: Path, size: int):
    raw = draw_icon(size)
    path.write_bytes(rgba_to_png(raw, size))
    print(f"  {size:4}×{size:<4}  {path.name}")


# ── icns builder ─────────────────────────────────────────────────────────────

ICNS_TYPES = {
    16:   b"icp4",
    32:   b"icp5",
    64:   b"icp6",
    128:  b"ic07",
    256:  b"ic08",
    512:  b"ic09",
    1024: b"ic10",
}


def build_icns(out: Path):
    chunks = b""
    for size, tag in ICNS_TYPES.items():
        raw  = draw_icon(size)
        png  = rgba_to_png(raw, size)
        blen = 8 + len(png)
        chunks += tag + struct.pack(">I", blen) + png

    header = b"icns" + struct.pack(">I", 8 + len(chunks))
    out.write_bytes(header + chunks)
    print(f"\n✓ {out}  ({len(header + chunks) // 1024} KB)")


if __name__ == "__main__":
    assets = Path(__file__).parent.parent / "MenuBar" / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    print("Generating icon sizes...")
    build_icns(assets / "netmon.icns")
