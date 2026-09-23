#!/usr/bin/env python3
"""
把自定义管理器的「包名 + 签名证书 SHA-256」写进 KernelPatch 的受信任管理器表。

内核里那张表是 APatch 改包名后能不能拿到 root 的唯一开关：
  - kernel/patch/android/userd.c      -> trusted_managers[]      (kpimg / 刷 boot 路线)
  - lkm/manager/apk_sign.c            -> kp_trusted_managers[]   (.ko / 免刷机 jailbreak 路线)

摘要 = SHA256(签名证书的 DER)，也就是 `keytool -list -v` 里那行 SHA256 指纹。
两个文件都改，免得以后切路线时还得回头补。

用法:
  python3 patch_kp_trusted_manager.py \
      --kp-dir /path/to/KernelPatch \
      --package com.abc.manager \
      --keystore abc.jks --alias abc --storepass xxx \
      [--replace me.bmax.apatch]     # 连官方条目一起换掉（默认只换 com.example.apatch 占位）
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

TARGETS = [
    ("kernel/patch/android/userd.c", "trusted_managers"),
    ("lkm/manager/apk_sign.c", "kp_trusted_managers"),
]


def cert_sha256(keystore: str, alias: str, storepass: str) -> bytes:
    out = subprocess.run(
        ["keytool", "-list", "-v", "-keystore", keystore, "-alias", alias,
         "-storepass", storepass],
        capture_output=True, text=True, check=True,
    ).stdout
    m = re.search(r"^\s*SHA256:\s*([0-9A-Fa-f:]{95})$", out, re.M)
    if not m:
        sys.exit("keytool 输出里没找到 SHA256 指纹，检查别名/密码")
    digest = bytes.fromhex(m.group(1).replace(":", ""))
    if len(digest) != 32:
        sys.exit(f"摘要长度异常: {len(digest)}")
    return digest


def format_userd(pkg: str, digest: bytes, indent: str) -> str:
    rows = []
    for i in range(0, 32, 8):
        rows.append(", ".join(f"0x{b:02x}" for b in digest[i:i + 8]))
    body = ",\n".join(f"{indent}    {r}" for r in rows)
    return f'{indent}{{\n{indent}    "{pkg}",\n{indent}    {{\n{body}\n{indent}    }}\n{indent}}},'


def format_lkm(pkg: str, digest: bytes, indent: str) -> str:
    rows = []
    for i in range(0, 32, 8):
        rows.append(", ".join(f"0x{b:02x}" for b in digest[i:i + 8]))
    body = ",\n".join(f"{indent}\t\t{r}" for r in rows)
    return (f'{indent}{{\n'
            f'{indent}\t.package = "{pkg}",\n'
            f'{indent}\t.digest = {{\n{body},\n'
            f'{indent}\t}},\n'
            f'{indent}}},')


def patch_file(path: Path, pkg: str, digest: bytes, replace_pkg: str, array_name: str) -> bool:
    src = path.read_text()
    is_lkm = array_name.startswith("kp_")

    # 定位待替换的条目：优先用户指定的包名，否则用官方留的 com.example.apatch 占位
    for target in ([replace_pkg] if replace_pkg else []) + ["com.example.apatch", "me.bmax.apatch"]:
        # 匹配 "com.example.apatch", { ... } 或 .package = "com.example.apatch", .digest = { ... }
        if is_lkm:
            pat = re.compile(
                r'(?P<ind>[\t ]*)\{\s*\n\s*\.package\s*=\s*"' + re.escape(target) + r'",\s*\n'
                r'\s*\.digest\s*=\s*\{.*?\},\s*\n(?P=ind)\},',
                re.S)
            fmt = format_lkm
        else:
            pat = re.compile(
                r'(?P<ind>[\t ]*)\{\s*\n\s*"' + re.escape(target) + r'",\s*\n'
                r'\s*\{.*?\}\s*\n(?P=ind)\},',
                re.S)
            fmt = format_userd

        m = pat.search(src)
        if m:
            src = src[:m.start()] + fmt(pkg, digest, m.group("ind")) + src[m.end():]
            path.write_text(src)
            print(f"  ✓ {path.name}: 替换条目 [{target}] -> [{pkg}]")
            return True

    print(f"  ⚠ {path.name}: 没找到可替换的条目，跳过")
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kp-dir", required=True, help="KernelPatch 源码根目录")
    ap.add_argument("--package", required=True, help="新的管理器包名")
    ap.add_argument("--keystore", required=True)
    ap.add_argument("--alias", required=True)
    ap.add_argument("--storepass", required=True)
    ap.add_argument("--replace", default=None,
                    help="要替换掉的包名条目；默认只动 com.example.apatch 占位条目")
    args = ap.parse_args()

    digest = cert_sha256(args.keystore, args.alias, args.storepass)
    print(f"证书 SHA-256: {digest.hex(':')}")
    print(f"包名:         {args.package}")

    for rel, array in TARGETS:
        p = Path(args.kp_dir) / rel
        if not p.exists():
            print(f"  ⚠ 找不到 {rel}，跳过")
            continue
        patch_file(p, args.package, digest, args.replace, array)

    print("\n改完了。核对一下两张表里现在都有你的包名，然后再编译。")


if __name__ == "__main__":
    main()
