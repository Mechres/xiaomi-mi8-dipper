#!/usr/bin/env python3
"""Merge a split Qualcomm PIL image (foo.mdt + foo.bNN) into one ELF (.mbn).

Each program header i whose data is not inside the .mdt itself comes from
foo.b<i:02d> and is written at its p_offset. Same idea as pil-squasher.
usage: pil-squash.py foo.mdt out.mbn
"""
import struct, sys, os

mdt_path, out_path = sys.argv[1], sys.argv[2]
mdt = open(mdt_path, 'rb').read()
assert mdt[:4] == b'\x7fELF', "not an ELF .mdt"
is64 = mdt[4] == 2
if is64:
    phoff, = struct.unpack_from('<Q', mdt, 32)
    phentsize, phnum = struct.unpack_from('<HH', mdt, 54)
    fmt = '<IIQQQQQQ'
else:
    phoff, = struct.unpack_from('<I', mdt, 28)
    phentsize, phnum = struct.unpack_from('<HH', mdt, 42)
    fmt = '<IIIIIIII'

segs = []
for i in range(phnum):
    f = struct.unpack_from(fmt, mdt, phoff + i * phentsize)
    if is64:
        p_type, p_flags, off, vaddr, paddr, filesz, memsz, align = f
    else:
        p_type, off, vaddr, paddr, filesz, memsz, p_flags, align = f
    segs.append((i, off, filesz))

# Only the ELF header and program headers come from the .mdt; it packs the
# hash segment right behind them, not at that segment's p_offset.
hdrlen = phoff + phnum * phentsize
size = max([hdrlen] + [off + fsz for _, off, fsz in segs])
out = bytearray(size)
out[:hdrlen] = mdt[:hdrlen]
base = os.path.splitext(mdt_path)[0]
for i, off, fsz in segs:
    if fsz == 0:
        continue
    bpath = f"{base}.b{i:02d}"
    if os.path.exists(bpath):
        data = open(bpath, 'rb').read()
        assert len(data) == fsz, f"{bpath}: size {len(data)} != p_filesz {fsz}"
        out[off:off + fsz] = data
    elif off + fsz <= hdrlen:
        pass  # segment is the ELF/program header itself
    else:
        sys.exit(f"missing {bpath} for segment {i}")
open(out_path, 'wb').write(out)
print(f"{out_path}: {len(out)} bytes, {phnum} segments")
