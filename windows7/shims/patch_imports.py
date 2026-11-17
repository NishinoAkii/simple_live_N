"""Rename DLL names in a PE file's import descriptors, in place.

Usage: python patch_imports.py <file.dll> <redirects.txt>
redirects.txt lines: OLDNAME.dll|newname.dll (new name not longer than old).
Only the import directory's DLL-name strings change; nothing else moves.
"""
import struct
import sys


def main(path, redirects_txt):
    redirects = {}
    for line in open(redirects_txt, encoding="utf-8"):
        line = line.strip()
        if line:
            old, new = line.split("|")
            assert len(new) <= len(old), (old, new)
            redirects[old.lower()] = new
    data = bytearray(open(path, "rb").read())
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe:pe + 4] == b"PE\0\0"
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    assert magic == 0x20B, "PE32+ only"
    dd = opt + 112  # data directories in PE32+
    imp_rva, imp_size = struct.unpack_from("<II", data, dd + 8)
    sections = []
    for i in range(nsec):
        s = opt + opt_size + 40 * i
        vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", data, s + 8)
        sections.append((va, max(vsize, rawsize), rawptr))

    def off(rva):
        for va, size, raw in sections:
            if va <= rva < va + size:
                return rva - va + raw
        raise ValueError(hex(rva))

    seen = {}
    pos = off(imp_rva)
    while True:
        desc = struct.unpack_from("<IIIII", data, pos)
        if desc == (0, 0, 0, 0, 0):
            break
        name_off = off(desc[3])
        end = data.index(b"\0", name_off)
        name = data[name_off:end].decode("ascii")
        new = redirects.get(name.lower())
        if new:
            data[name_off:end] = new.encode("ascii") + b"\0" * (end - name_off - len(new))
            seen[name] = new
        pos += 20
    missing = [k for k in redirects if k not in {n.lower() for n in seen}]
    if missing:
        sys.exit(f"not found in import table: {missing}")
    open(path, "wb").write(bytes(data))
    for old, new in seen.items():
        print(f"{path}: {old} -> {new}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
