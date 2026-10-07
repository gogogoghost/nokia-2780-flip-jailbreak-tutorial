#!/usr/bin/env python3
"""Build the patched dtbo image from the stock eMMC dump.

The keypad device tree sets `debounce-delay-ms = 10`, which is just below the
contact chatter this hardware produces: a single physical press of one key was
measured producing a second, spurious press/release pair only 10.4 ms long,
which the kernel then reports as a second key press. Raising the debounce to
30 ms leaves a 3x margin over that chatter and is still well below the shortest
real key press measured on the device (~59 ms).

The value lives in the overlays of the `dtbo` partition, in three of them (the
board variants that carry the keypad node). The firmware's DTBs do not follow
the standard FDT layout - the header offsets are stale, so the strings table is
not where `off_dt_strings` claims - which is why the property is located by
walking back from the `input-name = "matrix_keypad"` value instead of parsing
the tree:

  1. the `input-name` value gives the property's nameoff (the u32 before it)
  2. the matching `input-name` string in the same DTB gives the strings base
  3. the `debounce-delay-ms` nameoff follows, and its value is the 4 bytes after
     a `len=4 | nameoff` header in the struct block

Usage: make-dtbo.py <emmc.img> <output.img>
"""

import struct
import sys
from pathlib import Path

OLD_DEBOUNCE_MS = 10
NEW_DEBOUNCE_MS = 30

FDT_MAGIC = b"\xd0\x0d\xfe\xed"
KEYPAD_VALUE = b"matrix_keypad\x00"
INPUT_NAME = b"input-name\x00"
DEBOUNCE = b"debounce-delay-ms\x00"
MAX_DTB_SIZE = 400000


def find_all(buf, needle):
    out, i = [], buf.find(needle)
    while i != -1:
        out.append(i)
        i = buf.find(needle, i + 1)
    return out


def gpt_partitions(image):
    """Yield (name, file offset, size) for every named GPT partition."""
    with open(image, "rb") as f:
        f.seek(512)
        header = f.read(128)
        if header[:8] != b"EFI PART":
            sys.exit("make-dtbo: no GPT found in %s" % image)
        entries_lba = struct.unpack("<Q", header[72:80])[0]
        count = struct.unpack("<I", header[80:84])[0]
        entry_size = struct.unpack("<I", header[84:88])[0]
        f.seek(entries_lba * 512)
        entries = f.read(count * entry_size)

    for i in range(count):
        entry = entries[i * entry_size:(i + 1) * entry_size]
        if entry[:16] == b"\x00" * 16:
            continue
        first, last = struct.unpack("<QQ", entry[32:48])
        name = entry[56:128].decode("utf-16-le").rstrip("\x00")
        if name.strip():
            yield name, first * 512, (last - first + 1) * 512


def dtb_ranges(data):
    """File ranges of the DTBs inside the dtbo image."""
    ranges = []
    for start in find_all(data, FDT_MAGIC):
        totalsize = struct.unpack(">I", data[start + 4:start + 8])[0]
        if 40 < totalsize < MAX_DTB_SIZE and start + totalsize <= len(data):
            ranges.append((start, start + totalsize))
    return ranges


def find_debounce_values(data):
    """File offsets of the keypad debounce-delay-ms values in the dtbo image."""
    ranges = dtb_ranges(data)
    anchors = [a for a in find_all(data, KEYPAD_VALUE)
               if struct.unpack(">I", data[a - 8:a - 4])[0] == len(KEYPAD_VALUE)]
    input_names = find_all(data, INPUT_NAME)
    debounce_names = find_all(data, DEBOUNCE)

    def owner(offset):
        for low, high in ranges:
            if low <= offset < high:
                return low, high
        return None, None

    targets = []
    for anchor in anchors:
        nameoff = struct.unpack(">I", data[anchor - 4:anchor])[0]
        low, high = owner(anchor)
        if low is None:
            continue
        for string in input_names:
            if not (low <= string < high):
                continue
            base = string - nameoff
            if base < 0:
                continue
            for name in debounce_names:
                if not (low <= name < high):
                    continue
                pattern = b"\x00\x00\x00\x04" + struct.pack(">I", name - base)
                found = data.find(pattern)
                if found == -1 or not (low <= found < high):
                    continue
                targets.append(found + 8)
                break
            else:
                continue
            break
    return sorted(set(targets))


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: make-dtbo.py <emmc.img> <output.img>")
    image, output = sys.argv[1], sys.argv[2]

    partition = None
    for name, offset, size in gpt_partitions(image):
        if name == "dtbo":
            partition = (offset, size)
            break
    if partition is None:
        sys.exit("make-dtbo: no dtbo partition in %s" % image)

    with open(image, "rb") as f:
        f.seek(partition[0])
        blob = bytearray(f.read(partition[1]))

    targets = find_debounce_values(blob)
    if not targets:
        sys.exit("make-dtbo: no keypad debounce-delay-ms found in the dtbo partition")

    for offset in targets:
        current = struct.unpack(">I", blob[offset:offset + 4])[0]
        if current != OLD_DEBOUNCE_MS:
            sys.exit("make-dtbo: unexpected debounce value %d at offset %d (expected %d)"
                     % (current, offset, OLD_DEBOUNCE_MS))
        blob[offset:offset + 4] = struct.pack(">I", NEW_DEBOUNCE_MS)

    Path(output).write_bytes(bytes(blob))
    print("  %s: debounce-delay-ms %d -> %d ms in %d overlay(s)"
          % (output, OLD_DEBOUNCE_MS, NEW_DEBOUNCE_MS, len(targets)))


if __name__ == "__main__":
    main()
