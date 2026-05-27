#!/usr/bin/env python3
"""Unpack Wallpaper Engine scene.pkg files."""

import struct
import os
import sys

def unpack_scene_pkg(pkg_path, output_dir):
    with open(pkg_path, 'rb') as f:
        data = f.read()

    o = 0
    # Read signature string length
    slen = struct.unpack_from('<I', data, o)[0]
    o += 4
    # Read signature string
    sig = data[o:o+slen].decode('utf-8')
    o += slen
    print(f"Signature: {sig}")

    # Read number of files
    nfiles = struct.unpack_from('<I', data, o)[0]
    o += 4
    print(f"Number of files: {nfiles}")

    entries = []
    for i in range(nfiles):
        # Read name length
        ns = struct.unpack_from('<I', data, o)[0]
        o += 4
        # Read name
        name = data[o:o+ns].decode('utf-8')
        o += ns
        # Read offset and length
        file_off = struct.unpack_from('<I', data, o)[0]
        o += 4
        file_len = struct.unpack_from('<I', data, o)[0]
        o += 4
        entries.append((name, file_off, file_len))
        print(f"  [{i}] {name} (offset={file_off}, length={file_len})")

    base = o
    print(f"\nBase offset: {base}")

    for name, file_off, file_len in entries:
        start = base + file_off
        end = start + file_len
        file_data = data[start:end]

        # Create output path
        out_path = os.path.join(output_dir, name)
        os.makedirs(os.path.dirname(out_path), exist_ok=True)

        with open(out_path, 'wb') as f:
            f.write(file_data)
        size_kb = file_len / 1024
        print(f"  Extracted: {name} ({size_kb:.1f} KB)")

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python unpack_scene_pkg.py <scene.pkg> <output_dir>")
        sys.exit(1)

    pkg_path = sys.argv[1]
    output_dir = sys.argv[2]

    if not os.path.exists(pkg_path):
        print(f"Error: {pkg_path} not found")
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)
    unpack_scene_pkg(pkg_path, output_dir)
    print(f"\nDone! Extracted to: {output_dir}")
