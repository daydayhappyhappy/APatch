#!/usr/bin/env bash
# 编译 KernelPatch —— 改包名后只需要重新编译 kpimg
#
# 为什么只编 kpimg：
#   内核里写死「管理器包名 + 证书 SHA-256」的表 trusted_managers[] 在
#   kernel/patch/android/userd.c，它只被编译进 kpimg。
#   kptools（libkptools.so）只是读 kpimg、打 boot 补丁的工具，里面没有包名，
#   用官方同版本预编译产物即可，不必自己编。
#
# 工具链：官方 CI 用的是 ARM 裸机工具链 aarch64-none-elf（不是 aarch64-linux-gnu）
#
# 用法:
#   ./build_kp.sh                                    # 只编 kpimg（推荐）
#   ./build_kp.sh --ko --kdir /path/to/kernel --kmi android14-6.1   # 额外编 .ko（免刷机 jailbreak）
#
set -euo pipefail

KP_DIR="${KP_DIR:-$(pwd)/KernelPatch}"
OUT_DIR="${OUT_DIR:-$(pwd)/kp-out}"
TC_DIR="${TC_DIR:-$(pwd)/arm-toolchain}"

DO_KO=0
KDIR=""
KMI=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kp-dir) KP_DIR="$2";   shift 2;;
    --out)    OUT_DIR="$2";  shift 2;;
    --ko)     DO_KO=1;       shift;;
    --kdir)   KDIR="$2";     shift 2;;
    --kmi)    KMI="$2";      shift 2;;
    *) echo "未知参数: $1" >&2; exit 1;;
  esac
done

mkdir -p "$OUT_DIR"
export ANDROID=1

echo "=========================================="
echo " KernelPatch 源码: $KP_DIR"
echo " 输出目录:        $OUT_DIR"
echo "=========================================="

# ---------- 0. 交叉编译器 ----------
# 官方 CI 用的是 ARM 官方裸机工具链；拿不到就退回系统包
TARGET_COMPILE="${TARGET_COMPILE:-}"
if [[ -z "$TARGET_COMPILE" ]]; then
  TC_VER="12.2.rel1"
  TC_TAR="arm-gnu-toolchain-${TC_VER}-x86_64-aarch64-none-elf.tar.xz"
  TC_URL="https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/${TC_VER}/binrel/${TC_TAR}"
  if command -v aarch64-none-elf-gcc >/dev/null 2>&1; then
    TARGET_COMPILE="aarch64-none-elf-"
    echo "[0/3] 用系统已有的 aarch64-none-elf-"
  else
    echo "[0/3] 下载 ARM 官方工具链 ${TC_VER}..."
    mkdir -p "$TC_DIR"
    curl -sSL --retry 3 -o "$TC_DIR/$TC_TAR" "$TC_URL"
    tar -Jxf "$TC_DIR/$TC_TAR" -C "$TC_DIR"
    TARGET_COMPILE="$TC_DIR/arm-gnu-toolchain-${TC_VER}-x86_64-aarch64-none-elf/bin/aarch64-none-elf-"
  fi
fi
[[ -x "${TARGET_COMPILE}gcc" ]] || { echo "找不到交叉编译器: ${TARGET_COMPILE}gcc" >&2; exit 1; }
echo "     编译器: ${TARGET_COMPILE}gcc"

# ---------- 1. kpimg ----------
echo "[1/3] 编译 kpimg（含 trusted_managers[]，改包名后必须自己编）..."
# make hdr 会把 include/preset.h 拷到 tools/，kptools 依赖它
( cd "$KP_DIR/kernel" && TARGET_COMPILE="$TARGET_COMPILE" ANDROID=1 make hdr kpimg )
cp -f "$KP_DIR/kernel/kpimg" "$OUT_DIR/kpimg"
ls -la "$OUT_DIR/kpimg"

# ---------- 2. 自检：包名确实编进去了 ----------
echo "[2/3] 自检 kpimg 里是否含新包名..."
if grep -qa "com.example.apatch" "$OUT_DIR/kpimg"; then
  echo "  ⚠ kpimg 里还是 com.example.apatch —— 说明 patch_kp_trusted_manager.py 没跑成功"
else
  echo "  ✔ 占位包名已被替换"
fi

# ---------- 3. .ko（可选）----------
if [[ "$DO_KO" -eq 1 ]]; then
  echo "[3/3] 编译 kernelpatch.ko..."
  if [[ -z "$KDIR" || -z "$KMI" ]]; then
    echo "  ⚠ 需要 --kdir <内核源码树> --kmi <如 android14-6.1>，跳过"
  else
    ( cd "$KP_DIR/lkm" && CONFIG_KP_LKM=m make KDIR="$KDIR" )
    cp -f "$KP_DIR/lkm/kernelpatch.ko" "$OUT_DIR/${KMI}_kernelpatch.ko"
    echo "  -> $OUT_DIR/${KMI}_kernelpatch.ko"
  fi
else
  echo "[3/3] 跳过 .ko（未加 --ko；只走刷 boot 路线的话不需要）"
fi

echo "=========================================="
echo " 产物："
ls -la "$OUT_DIR"
echo "=========================================="
