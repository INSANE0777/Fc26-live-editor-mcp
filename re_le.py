#!/usr/bin/env python3
"""FCLiveEditor.dll reverse-engineering helper (task c).

Maps RTTI type descriptors -> Complete Object Locators -> vtables for
CareerModeManager@LE / DetoursManager@LE / TransferManager@LE, and locates
the InstallDX12Hooks function via string xrefs. Pure stdlib + capstone.

Usage: python le_rtti.py [path-to-FCLiveEditor.DLL]
"""
import struct
import sys
from pathlib import Path

try:
    from capstone import Cs, CS_ARCH_X86, CS_MODE_64
except ImportError:
    print("capstone required: pip install capstone")
    sys.exit(2)

PE = Path(sys.argv[1] if len(sys.argv) > 1 else "FCLiveEditor.DLL")
DATA = PE.read_bytes()


def va_to_off(va, image_base, secs):
    for name, vsz, va0, rs, ro in secs:
        if va0 <= va - image_base < va0 + vsz:
            return ro + (va - image_base - va0)
    return None


def off_to_va(off, image_base, secs):
    for name, vsz, va, rs, ro in secs:
        if ro <= off < ro + rs:
            return image_base + va + (off - ro)
    return None


def find_bytes(pat):
    out = []
    i = 0
    while True:
        i = DATA.find(pat, i)
        if i < 0:
            break
        out.append(i)
        i += 1
    return out


def read_cstr(off):
    end = DATA.index(b"\x00", off)
    return DATA[off:end].decode("ascii", "ignore")


# ---- PE headers -----------------------------------------------------------
e_lfanew = struct.unpack_from("<I", DATA, 0x3C)[0]
coff = e_lfanew + 4
machine, nsec = struct.unpack_from("<HH", DATA, coff)
opt = coff + 20
magic, = struct.unpack_from("<H", DATA, opt)
image_base = struct.unpack_from("<Q", DATA, opt + 24)[0]
sec_off = opt + (240 if magic == 0x20B else 224)
secs = []
for i in range(nsec):
    o = sec_off + i * 40
    name = DATA[o:o + 8].rstrip(b"\x00").decode()
    vsz, va, rs, ro = struct.unpack_from("<IIII", DATA, o + 8)
    secs.append((name, vsz, va, rs, ro))
TEXT = next(s for s in secs if s[0] == ".text")
RDATA = next(s for s in secs if s[0] == ".rdata")

md = Cs(CS_ARCH_X86, CS_MODE_64)
md.detail = False


def disas(va, count=30):
    off = va_to_off(va, image_base, secs)
    code = DATA[off:off + 256]
    out = []
    for ins in md.disasm(code, va):
        out.append(f"  0x{ins.address:X}  {ins.mnemonic} {ins.op_str}".rstrip())
        if len(out) >= count:
            break
    return out


# ---- RTTI walk ------------------------------------------------------------
CLASSES = ["CareerModeManager@LE", "DetoursManager@LE", "TransferManager@LE",
           "AdvancedFilter@LE", "EventMessageTypes@LE", "FCLiveEditor@LE"]


def resolve_va(va):  # noqa: unused
    return None


type_desc_offsets = {}
for pat in [b".?AV" + c.encode() + b"@@" for c in CLASSES]:
    offs = find_bytes(pat)
    if offs:
        type_desc_offsets[pat[4:-3].decode()] = offs

print("== RTTI type descriptors ==")
td_vas = {}
for cls, offs in type_desc_offsets.items():
    for off in offs:
        va = off_to_va(off)
        tdv = va - 0x10  # TypeDescriptor struct = 0x10 before name
        td_vas.setdefault(cls, []).append(tdv)
        print(f"  {cls}: name@0x{va:X} typeDescriptor@0x{tdv:X}")

# Complete Object Locators: scan .rdata for {int sig, int off, int cd, rva td, rva hier}
def rva_to_va(rva):
    return image_base + rva

cols = {}
print("\n=== Complete Object Locators -> vtables ===")
for cls, tds in td_vas.items():
    for tdv in tds:
        td_rva_lo = tdv & 0xFFFFFFFF
        # COL pTypeDescriptor (u32 RVA) stored little-endian
        tgt = struct.pack("<I", td_rva_lo)
        rdata_off, rdata_len = RDATA[4], RDATA[3]
        rdata_off = va_to_off(image_base + RDATA[2], image_base, secs)
        i = 0
        while True:
            i = DATA.find(tgt, rdata_off + i, rdata_off + rdata_len)
            if i < 0:
                break
            # candidate: 20-byte COL ending at this field -> sig at i-16, off i-12, cdOff i-8
            sig_off = i - 16
            if sig_off >= rdata_off:
                sig, obj_off, cd_off = struct.unpack_from("<III", DATA, sig_off)
                if sig == 0 and obj_off == 0 and cd_off == 0:
                    col = struct.unpack_from("<I", DATA, sig_off - 4)[0] or None  # not needed
                    col_va = off_to_va(sig_off)
                    # find vtables: scan .rdata for qword equal to col_va (absolute)
                    col_b = struct.pack("<Q", col_va)
                    j = rdata_off
                    while True:
                        j = DATA.find(col_b, j, rdata_off + rdata_len)
                        if j < 0:
                            break
                        vtable_va = off_to_va(j + 8)
                        entries = []
                        k = j + 8
                        while True:
                            slot, = struct.unpack_from("<Q", DATA, k)
                            so = va_to_off(slot, image_base, secs)
                            if slot == 0 or so is None or not (TEXT[3] <= so < TEXT[3] + TEXT[4]):
                                break
                            entries.append(slot)
                            k += 8
                        print(f"  {cls} COL=0x{col_va:X} vtable=0x{vtable_va:X} ({len(entries)} virtuals)")
                        for idx, e in enumerate(entries):
                            print(f"      vf[{idx:02d}] 0x{e:X}  {disas(e, 4)[0] if disas(e, 4) else ''}")
                        j += 8
            i += 4


# ---- string xrefs ---------------------------------------------------------
print("\n=== string refs: InstallDX / DirectX12 hooks ===")
for needle in [b"Setup DirectX12 Hooks", b"InstallDirectX12Hooks", b"Install DX12 hooks",
               b"InstallDX12Hooks", b"dxgi.dll", b"CreateDXGIFactory", b"IDXGISwapChain"]:
    o = DATA.find(needle)
    if o < 0:
        continue
    sva = off_to_va(o, image_base, secs)
    print(f"  '{needle.decode()}' at VA 0x{sva:X}")
    t_off, t_len = TEXT[3], TEXT[4]
    hits = []
    i = t_off
    while i < t_off + t_len - 8:
        # lea r*, [rip+disp32] = (REX) 8D modrm disp32, modrm in {05,0D,15,1D,25,2D,35,3D}
        base = i
        if DATA[i] in (0x48, 0x4C):
            base = i + 1
        if DATA[i] in (0x48, 0x4C) and DATA[base] == 0x8D and DATA[base + 1] in (0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D):
            disp = struct.unpack_from("<i", DATA, base + 2)[0]
            insn_len = 7
            tgt = off_to_va(i, image_base, secs) + insn_len + disp
            if tgt == sva:
                hits.append(i)
            i += insn_len
        else:
            i += 1
    for h in hits:
        # crude: back up 16 bytes for context, then disasm region
        print(f"    referenced from VA 0x{off_to_va(h, image_base, secs):X}")
        for d in disas(off_to_va(h, image_base, secs) - 16, 24):
            print("      " + d)
