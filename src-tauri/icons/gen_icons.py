#!/usr/bin/env python3
"""Generate simple placeholder PNG icons for the Tauri app using only the stdlib.

Draws a rounded teal square with a white "tunnel" ring. Run with: python3 gen_icons.py
Replace later with real art via `cargo tauri icon <source.png>` if desired.
"""
import struct, zlib, os, math

def png(width, height, pixels):
    def chunk(typ, data):
        c = typ + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0
        for x in range(width):
            raw += bytes(pixels[y * width + x])
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")

def render(size):
    bg = (15, 23, 42, 255)        # slate background (transparent corners)
    teal = (20, 184, 166, 255)    # teal square
    white = (240, 253, 250, 255)
    transparent = (0, 0, 0, 0)
    pixels = []
    cx = cy = size / 2
    radius_corner = size * 0.22
    ring_outer = size * 0.34
    ring_inner = size * 0.20
    pad = size * 0.08
    for y in range(size):
        for x in range(size):
            # rounded-rect mask for the teal tile
            dx = max(pad + radius_corner - x, x - (size - pad - radius_corner), 0)
            dy = max(pad + radius_corner - y, y - (size - pad - radius_corner), 0)
            inside_tile = (x >= pad and x <= size - pad and y >= pad and y <= size - pad
                           and math.hypot(dx, dy) <= radius_corner)
            if not inside_tile:
                pixels.append(transparent)
                continue
            r = math.hypot(x - cx, y - cy)
            if ring_inner <= r <= ring_outer:
                pixels.append(white)
            elif r < ring_inner:
                pixels.append(bg)
            else:
                pixels.append(teal)
    return pixels

def write(name, size):
    data = png(size, size, render(size))
    path = os.path.join(os.path.dirname(__file__), name)
    with open(path, "wb") as f:
        f.write(data)
    print("wrote", path, len(data), "bytes")

if __name__ == "__main__":
    write("32x32.png", 32)
    write("128x128.png", 128)
    write("128x128@2x.png", 256)
    write("icon.png", 512)
    write("tray.png", 64)
