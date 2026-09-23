#!/usr/bin/env bash
# 生成 APatch 改包名专用的签名密钥（只需做一次，之后永久复用）
#
# 为什么必须固定：KernelPatch 内核里烧的是「签名证书的 SHA-256」。
# 每次构建新建 keystore → 摘要每次都变 → 内核永远对不上 → 卡闪屏。
#
# 用法:
#   bash make_keystore.sh                         # 默认 ./abc.jks / alias=abc
#   bash make_keystore.sh --out my.jks --alias mgr --dname-cn "MyMgr"
#
# 生成后你会拿到三样东西：
#   1. my.jks                —— 私钥，只留本地，绝对不要提交到 git
#   2. 证书 SHA-256          —— 填进 KernelPatch 的 trusted_managers[]
#   3. base64 单行           —— 存成 GitHub Secret: SIGNING_KEY
#
set -euo pipefail

OUT="abc.jks"
ALIAS="abc"
STOREPASS=""
KEYPASS=""
DNAME_CN="ABC"
VALIDITY=10950   # 30 年；自签名密钥过期后无法续期，宁可给长一点

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)      OUT="$2"; shift 2;;
    --alias)    ALIAS="$2"; shift 2;;
    --storepass) STOREPASS="$2"; shift 2;;
    --keypass)  KEYPASS="$2"; shift 2;;
    --dname-cn) DNAME_CN="$2"; shift 2;;
    *) echo "未知参数: $1" >&2; exit 1;;
  esac
done

if [[ -f "$OUT" ]]; then
  echo "⚠ $OUT 已存在。覆盖它会让之前烧进内核的摘要全部失效。"
  read -r -p "确认覆盖？输入 yes 继续: " ans
  [[ "$ans" == "yes" ]] || { echo "已取消"; exit 1; }
  rm -f "$OUT"
fi

# 没给密码就现场生成一个，避免大家图省事用 abc123456
if [[ -z "$STOREPASS" ]]; then
  STOREPASS="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 16)"
fi
[[ -n "$KEYPASS" ]] || KEYPASS="$STOREPASS"

echo "=========================================="
echo " 生成 keystore: $OUT (alias=$ALIAS)"
echo "=========================================="

keytool -genkeypair -v \
  -keystore "$OUT" \
  -storetype PKCS12 \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 \
  -validity "$VALIDITY" \
  -storepass "$STOREPASS" -keypass "$KEYPASS" \
  -dname "CN=$DNAME_CN, OU=$DNAME_CN, O=$DNAME_CN, L=$DNAME_CN, ST=$DNAME_CN, C=CN" \
  2>&1 | tail -4

chmod 600 "$OUT"

SHA256=$(keytool -list -v -keystore "$OUT" -alias "$ALIAS" -storepass "$STOREPASS" \
         | grep -E '^\s+SHA256:' | head -1 | sed 's/.*SHA256:\s*//')

echo
echo "=========================================="
echo " ① 证书 SHA-256（填内核用）"
echo "=========================================="
echo "$SHA256"
echo
echo "=========================================="
echo " ② 需要配置的 GitHub Secret（4 个）"
echo "=========================================="
echo "SIGNING_KEY          = $(base64 -w0 "$OUT")"
echo "KEY_STORE_PASSWORD   = $STOREPASS"
echo "KEY_ALIAS            = $ALIAS"
echo "KEY_PASSWORD         = $KEYPASS"
echo
echo "=========================================="
echo " ③ 别忘了"
echo "=========================================="
echo "  · 把 $(basename "$OUT") 加进 .gitignore，别提交私钥"
echo "  · 上面这组密码本地存好，丢了就只能用新密钥、重新烧内核"
echo "  · 下一步："
echo "      python3 patch_kp_trusted_manager.py \\"
echo "          --kp-dir KernelPatch --package com.abc.manager \\"
echo "          --keystore $OUT --alias $ALIAS --storepass '$STOREPASS'"
echo "=========================================="
