#!/usr/bin/env python3
"""把云端产出的 2 个切片打成可直接安装的 rootless deb。

用法（在仓库根目录）：
    python3 scripts/package.py --slices out --out dist

步骤：
  1. 每个 thin slice 单独 ldid -S 签名
  2. 两个切片拼成 FAT（0xcafebabe，对齐 0x4000）
  3. 整包再签一次，然后把 FAT 第二项 cputype 改回 0x0200000c（arm64e 标记，
     ldid 会把它写回 0x0100000c，不改的话 arm64e 机器会按 arm64 加载）
  4. filter plist 拷进载荷，最后打 deb（优先 dpkg-deb，没有就用内置 ar+tar）

依赖：ldid（PATH 里或 --ldid 指定）；dpkg-deb 可选。
"""
import argparse
import gzip
import io
import os
import shutil
import struct
import subprocess
import tarfile
import tempfile

PACKAGE = "cn.qwq.wxnotify"
TWEAK = "WxNotify"
FAT_ALIGN = 0x4000
CPU_TYPE_ARM64E_FAT = 0x0200000C


def align_up(v, a):
    return (v + a - 1) & ~(a - 1)


def build_fat(a, b, out):
    da, db = open(a, "rb").read(), open(b, "rb").read()
    off_a = align_up(8 + 2 * 20, FAT_ALIGN)
    off_b = align_up(off_a + len(da), FAT_ALIGN)
    hdr = struct.pack(">II", 0xCAFEBABE, 2)
    hdr += struct.pack(">5I", 0x0100000C, 0, off_a, len(da), FAT_ALIGN.bit_length() - 1)
    hdr += struct.pack(">5I", CPU_TYPE_ARM64E_FAT, 0, off_b, len(db), FAT_ALIGN.bit_length() - 1)
    buf = bytearray(off_b + len(db))
    buf[:len(hdr)] = hdr
    buf[off_a:off_a + len(da)] = da
    buf[off_b:off_b + len(db)] = db
    open(out, "wb").write(buf)


def fix_arm64e_marker(path):
    b = bytearray(open(path, "rb").read())
    if struct.unpack(">I", b[0:4])[0] != 0xCAFEBABE:
        raise SystemExit("不是 FAT: " + path)
    b[28:32] = struct.pack(">I", CPU_TYPE_ARM64E_FAT)
    open(path, "wb").write(b)


def sign(ldid, path):
    subprocess.check_call([ldid, "-S", path])


# ---------- 内置 deb 写出（没有 dpkg-deb 时用） ----------

def _tar_gz(entries):
    """entries: [(name, bytes, mode, is_dir)]"""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for name, data, mode, is_dir in entries:
            ti = tarfile.TarInfo(name)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = 0
            ti.mode = mode
            if is_dir:
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            else:
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    return gzip.compress(raw.getvalue(), mtime=0)


def _ar(members):
    out = bytearray(b"!<arch>\n")
    for name, data in members:
        hdr = "%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, 0, 0, 0, "100644", len(data))
        out += hdr.encode("ascii")
        out += data
        if len(data) % 2:
            out += b"\n"
    return bytes(out)


def write_deb(root, out):
    control_dir = os.path.join(root, "DEBIAN")
    entries = [("./", b"", 0o755, True)]
    for base, _dirs, files in os.walk(os.path.join(root, "var")):
        rel = os.path.relpath(base, root)
        entries.append(("./" + rel + "/", b"", 0o755, True))
        for f in sorted(files):
            p = os.path.join(base, f)
            entries.append(("./" + os.path.join(rel, f), open(p, "rb").read(), 0o644, False))
    data_tar = _tar_gz(entries)

    centries = [("./", b"", 0o755, True)]
    for f in sorted(os.listdir(control_dir)):
        p = os.path.join(control_dir, f)
        mode = 0o755 if os.access(p, os.X_OK) else 0o644
        centries.append(("./" + f, open(p, "rb").read(), mode, False))
    control_tar = _tar_gz(centries)

    blob = _ar([("debian-binary/", b"2.0\n"),
                ("control.tar.gz/", control_tar),
                ("data.tar.gz/", data_tar)])
    open(out, "wb").write(blob)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slices", default="out", help="存放 WxNotify-arm64/-arm64e.dylib 的目录")
    ap.add_argument("--root", default="build", help="deb 目录树（含 DEBIAN/ 与载荷）")
    ap.add_argument("--out", default="dist", help="输出目录")
    ap.add_argument("--version", default=None, help="覆盖 control 里的 Version")
    ap.add_argument("--ldid", default=shutil.which("ldid") or "ldid")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    libdir = os.path.join(args.root, "var/jb/Library/MobileSubstrate/DynamicLibraries")
    os.makedirs(libdir, exist_ok=True)

    # filter plist 只有一份源文件，打包时拷进载荷
    plist_src = os.path.join("src", TWEAK + ".plist")
    if os.path.exists(plist_src):
        shutil.copy(plist_src, os.path.join(libdir, TWEAK + ".plist"))
    elif not os.path.exists(os.path.join(libdir, TWEAK + ".plist")):
        raise SystemExit("找不到 filter plist: " + plist_src)

    with tempfile.TemporaryDirectory() as tmp:
        a = os.path.join(args.slices, TWEAK + "-arm64.dylib")
        b = os.path.join(args.slices, TWEAK + "-arm64e.dylib")
        for p in (a, b):
            if not os.path.exists(p):
                raise SystemExit("缺少切片: " + p)
        sa = os.path.join(tmp, "a.dylib")
        sb = os.path.join(tmp, "b.dylib")
        shutil.copy(a, sa)
        shutil.copy(b, sb)
        sign(args.ldid, sa)
        sign(args.ldid, sb)
        fat = os.path.join(tmp, "fat.dylib")
        build_fat(sa, sb, fat)
        sign(args.ldid, fat)
        fix_arm64e_marker(fat)
        dst = os.path.join(libdir, TWEAK + ".dylib")
        shutil.copy(fat, dst)
        os.chmod(dst, 0o644)
        print("packed", TWEAK, os.path.getsize(dst))

    control = os.path.join(args.root, "DEBIAN/control")
    if args.version:
        lines = open(control).read().splitlines()
        lines = [("Version: " + args.version) if l.startswith("Version:") else l for l in lines]
        open(control, "w").write("\n".join(lines) + "\n")

    ver = "0"
    for l in open(control):
        if l.startswith("Version:"):
            ver = l.split(":", 1)[1].strip()
    out = os.path.join(args.out, "%s_%s_iphoneos-arm64.deb" % (PACKAGE, ver))

    if shutil.which("dpkg-deb"):
        subprocess.check_call(["dpkg-deb", "--build", "--root-owner-group", args.root, out])
    else:
        write_deb(args.root, out)
    print("deb", out, os.path.getsize(out))


if __name__ == "__main__":
    main()
