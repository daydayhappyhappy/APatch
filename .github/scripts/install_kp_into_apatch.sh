#!/usr/bin/env bash
# 把自编译的 KernelPatch 产物接进 APatch，并关掉 gradle 对应的下载任务。
#
# 必须关掉下载的原因：registerDownloadTask 的判断是
#     if (!destFile.exists() || isFileUpdated(url, destFile))
# 即使提前放好文件，只要远端 Last-Modified 更新，它照样下官方产物覆盖掉你，
# 改的包名就白改了。
#
# 只关掉「我们确实提供了产物」的那几项；没提供的继续用官方的，避免版本错配。
#   改包名只需要替换 kpimg —— kptools / kpatch 里没有包名，用官方同版本即可。
#
# 用法: ./install_kp_into_apatch.sh <APatch源码根> <kp-out目录>
set -euo pipefail

APATCH_DIR="${1:?用法: $0 <APatch源码根> <kp-out目录>}"
OUT_DIR="${2:?用法: $0 <APatch源码根> <kp-out目录>}"

APP="$APATCH_DIR/app"
GRADLE="$APP/build.gradle.kts"

# 产物文件名 -> gradle 下载任务名
declare -A MAP=(
  [kpimg]=downloadKpimg
  [libkptools.so]=downloadKptools
  [libkpatch.so]=downloadCompatKpatch
)

echo "=========================================="
echo " APatch:   $APATCH_DIR"
echo " 产物目录: $OUT_DIR"
echo "=========================================="

# ---------- 1. 拷贝产物 ----------
echo "[1/2] 拷贝产物..."
copied=()

if [[ -f "$OUT_DIR/kpimg" ]]; then
  mkdir -p "$APP/src/main/assets"
  cp -f "$OUT_DIR/kpimg" "$APP/src/main/assets/kpimg"
  copied+=(kpimg)
  echo "  kpimg -> app/src/main/assets/kpimg"
fi

for f in libkptools.so libkpatch.so; do
  if [[ -f "$OUT_DIR/$f" ]]; then
    mkdir -p "$APP/libs/arm64-v8a"
    cp -f "$OUT_DIR/$f" "$APP/libs/arm64-v8a/$f"
    copied+=("$f")
    echo "  $f -> app/libs/arm64-v8a/$f"
  fi
done

shopt -s nullglob
for ko in "$OUT_DIR"/*_kernelpatch.ko; do
  mkdir -p "$APP/src/main/assets"
  cp -f "$ko" "$APP/src/main/assets/$(basename "$ko")"
  echo "  $(basename "$ko") -> app/src/main/assets/"
done
if compgen -G "$OUT_DIR/*_kernelpatch.ko" >/dev/null; then
  copied+=(ko)
fi

[[ ${#copied[@]} -gt 0 ]] || { echo "✘ kp-out 里没有任何产物"; exit 1; }

# ---------- 2. 关掉对应下载任务 ----------
echo "[2/2] 从 preBuild 依赖里移除对应下载任务..."
python3 - "$GRADLE" "${copied[@]}" <<'PY'
import re, sys
path, items = sys.argv[1], sys.argv[2:]
all_map = {"kpimg": "downloadKpimg",
           "libkptools.so": "downloadKptools",
           "libkpatch.so": "downloadCompatKpatch"}
# .ko 是逐个 KMI 下载的，整体由 downloadJailbreakKo 负责
if "ko" in items:
    all_map["ko"] = "downloadJailbreakKo"
# 只移除「本次确实提供了产物」的那几项
todo = [all_map[i] for i in items if i in all_map]
s = open(path).read()
before = s
for task in todo:
    s = re.sub(r'\n\s*"' + task + '",', '', s)
if s == before:
    print("  (没有可移除的下载任务，可能已经处理过)")
else:
    open(path, "w").write(s)
    print("  已移除: " + ", ".join(todo))
PY

echo
echo "核对 preBuild（不应再出现已替换产物的 download*）："
grep -A7 'getByName("preBuild")' "$GRADLE" || true
echo "=========================================="
