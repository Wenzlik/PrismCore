"""Marks one external symbol of a 64-bit Mach-O object as a weak definition (N_WEAK_DEF).

Neither `ld -r` nor `strip` can do it, and build-xcframework.sh needs `_rust_eh_personality`
weak so that it merges with the copy another Rust static library in the same app carries.

usage: python3 -I mark-weak.py OBJECT SYMBOL
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SYMTAB = 0x2
N_SECT_EXT = 0x0F  # defined in a section, external
N_WEAK_DEF = 0x0080

path, name = sys.argv[1], sys.argv[2].encode()
data = bytearray(open(path, "rb").read())
if struct.unpack_from("<I", data)[0] != MH_MAGIC_64:
    sys.exit(f"{path}: not a 64-bit Mach-O object")

marked = 0
offset = 32  # mach_header_64
for _ in range(struct.unpack_from("<I", data, 16)[0]):  # ncmds
    command, size = struct.unpack_from("<II", data, offset)
    if command == LC_SYMTAB:
        symoff, nsyms, stroff = struct.unpack_from("<III", data, offset + 8)
        for entry in range(symoff, symoff + 16 * nsyms, 16):  # nlist_64
            strx, kind, _sect, desc = struct.unpack_from("<IBBH", data, entry)
            start = stroff + strx
            if kind == N_SECT_EXT and data[start:data.index(0, start)] == name:
                struct.pack_into("<H", data, entry + 6, desc | N_WEAK_DEF)
                marked += 1
    offset += size

if marked != 1:
    sys.exit(f"{path}: {name.decode()} defined {marked} times, expected once")
open(path, "wb").write(data)
