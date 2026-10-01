#!/usr/bin/env python3
"""Rebuild super_empty.img with every partition marked readonly (needed for fastboot's
one-step super flashing). Everything else (sizes, groups, slots, flags) is copied."""
import re, subprocess, sys

HOST = sys.argv[1]          # out/host/linux-x86/bin
SRC, DST = sys.argv[2], sys.argv[3]

def dump(path):
    return subprocess.run([f"{HOST}/lpdump", path], capture_output=True, text=True, check=True).stdout

def parse(txt):
    g = lambda pat: (re.search(pat, txt, re.M) or sys.exit(f"lpdump: '{pat}' not found")).group(1)
    info = {
        "version": g(r"^Metadata version: (\S+)"),
        "msize": g(r"^Metadata max size: (\d+) bytes"),
        "slots": g(r"^Metadata slot count: (\d+)"),
        "hflags": (re.search(r"^Header flags: (.*)$", txt, re.M) or [None, "none"])[1].strip(),
    }
    part_tbl = txt.split("Partition table:", 1)[1].split("Super partition layout:", 1)[0]
    blk_tbl = txt.split("Block device table:", 1)[1].split("Group table:", 1)[0]
    grp_tbl = txt.split("Group table:", 1)[1]
    info["parts"] = re.findall(r"Name: (\S+)\n\s+Group: (\S+)\n\s+Attributes: ([^\n]*)", part_tbl)
    info["blocks"] = re.findall(r"Partition name: (\S+)\n\s+First sector: (\d+)\n\s+Size: (\d+) bytes", blk_tbl)
    info["groups"] = re.findall(r"Name: (\S+)\n\s+Maximum size: (\d+) bytes", grp_tbl)
    return info

src = parse(dump(SRC))
if len(src["blocks"]) != 1:
    sys.exit(f"expected one super block device, got {src['blocks']}")
bname, _, bsize = src["blocks"][0]
cmd = [f"{HOST}/lpmake", "--metadata-size", src["msize"], "--metadata-slots", src["slots"],
       "--device", f"{bname}:{bsize}", "--super-name", bname, "--output", DST]
if "virtual_ab" in src["hflags"]:
    cmd.append("--virtual-ab")
for name, size in src["groups"]:
    if name != "default":
        cmd += ["--group", f"{name}:{size}"]
for name, group, _ in src["parts"]:
    cmd += ["--partition", f"{name}:readonly:0:{group}"]
print("partitions:", " ".join(p[0] for p in src["parts"]))
subprocess.run(cmd, check=True)

new = parse(dump(DST))
bad = [p for p in new["parts"] if "readonly" not in p[2]]
same = (src["version"], src["msize"], src["slots"], src["hflags"], src["blocks"][0][2], src["groups"],
        [(n, g) for n, g, _ in src["parts"]]) == \
       (new["version"], new["msize"], new["slots"], new["hflags"], new["blocks"][0][2], new["groups"],
        [(n, g) for n, g, _ in new["parts"]])
if bad or not same:
    sys.exit(f"CHECK FAILED: not readonly={bad} layout_identical={same}\nold={src}\nnew={new}")
print(f"OK: {len(new['parts'])} partitions readonly; layout identical (super {bsize} bytes, "
      f"metadata {src['msize']}x{src['slots']}, flags: {src['hflags']})")
