#!/bin/bash
# APatch 改包名脚本（修正版）
# 用法: NEW_PKG=com.abc.manager NEW_NAME=ABC bash build_abc.sh
#
# ⚠ 包名不要带保留前缀：com.android.* / com.google.* / android.* / com.example.*
#   默认值已经是 com.abc.manager，一般直接用默认即可
set -e

OLD_PKG="me.bmax.apatch"
OLD_PKG_SLASH="me/bmax/apatch"
OLD_PKG_UNDER="me_bmax_apatch"      # JNI 符号形态（老版本 apjni 会出现）
OLD_NAME="APatch"

# ⚠️ 不要用 com.android.* / com.google.* / android.* / com.example.*
# 这些是保留前缀。原来用的 com.android.abc 必须换掉。
NEW_PKG="${NEW_PKG:-com.abc.manager}"
NEW_PKG_SLASH="${NEW_PKG//.//}"
NEW_PKG_UNDER="${NEW_PKG//./_}"
NEW_NAME="${NEW_NAME:-ABC}"

# 只处理这些目录，避免污染 docs / fastlane / .git / 二进制产物
TARGETS=(app apd kernel scripts build.gradle.kts settings.gradle.kts)
# 只处理文本文件（grep -I 会跳过二进制，防止 sed 破坏 jar/so/png）
SKIP_DIRS=(-e "/build/" -e "/.git/" -e "/.cargo/" -e "Cargo.lock")

echo "=========================================="
echo " $OLD_PKG -> $NEW_PKG"
echo " $OLD_PKG_SLASH -> $NEW_PKG_SLASH"
echo " $OLD_PKG_UNDER -> $NEW_PKG_UNDER"
echo "=========================================="

# ---------- 1. 三种形态的字符串替换 ----------
echo "[1/7] 替换包名字符串（点号 / 斜杠 / 下划线）..."
files=$(grep -rIl "$OLD_PKG\|$OLD_PKG_SLASH\|$OLD_PKG_UNDER" "${TARGETS[@]}" 2>/dev/null \
        | grep -v "${SKIP_DIRS[@]}" | grep -v "build_abc" || true)
for file in $files; do
    sed -i -e "s|$OLD_PKG_UNDER|$NEW_PKG_UNDER|g" \
           -e "s|$OLD_PKG_SLASH|$NEW_PKG_SLASH|g" \
           -e "s|$OLD_PKG|$NEW_PKG|g" "$file"
done
echo "  处理 $(echo "$files" | grep -c . ) 个文件"

# ---------- 2. 迁移 Kotlin/Java 目录 ----------
echo "[2/7] 迁移源码目录..."
for kind in java kotlin; do
    src="app/src/main/$kind/me/bmax/apatch"
    if [ -d "$src" ]; then
        mkdir -p "app/src/main/$kind/$(dirname "$NEW_PKG_SLASH")"
        mv "$src" "app/src/main/$kind/$NEW_PKG_SLASH"
        rmdir -p "app/src/main/$kind/me/bmax" 2>/dev/null || true
        echo "  $kind 目录已迁移 -> app/src/main/$kind/$NEW_PKG_SLASH"
    fi
done

# ---------- 3. 迁移 AIDL 目录 ----------
echo "[3/7] 迁移 AIDL 目录..."
src="app/src/main/aidl/me/bmax/apatch"
if [ -d "$src" ]; then
    mkdir -p "app/src/main/aidl/$(dirname "$NEW_PKG_SLASH")"
    mv "$src" "app/src/main/aidl/$NEW_PKG_SLASH"
    rmdir -p "app/src/main/aidl/me/bmax" 2>/dev/null || true
    echo "  aidl 目录已迁移 -> app/src/main/aidl/$NEW_PKG_SLASH"
fi

# ---------- 4. Gradle: applicationId + namespace ----------
echo "[4/7] 修改 Gradle 配置..."
for f in app/build.gradle.kts build.gradle.kts; do
    [ -f "$f" ] || continue
    sed -i -e "s|\(applicationId\s*=\s*\"\)[^\"]*\"|\1$NEW_PKG\"|" \
           -e "s|\(namespace\s*=\s*\"\)[^\"]*\"|\1$NEW_PKG\"|" "$f"
done
[ -f settings.gradle.kts ] && \
    sed -i "s|\(rootProject.name\s*=\s*\"\)[^\"]*\"|\1$NEW_NAME\"|" settings.gradle.kts

# ---------- 5. 应用名：strings.xml + AndroidManifest 的 android:label ----------
echo "[5/7] 修改应用名..."
find app/src/main/res -name "strings.xml" 2>/dev/null | while read -r f; do
    sed -i "s|\(<string name=\"app_name\"[^>]*>\)[^<]*</string>|\1$NEW_NAME</string>|" "$f"
done
[ -f app/src/main/AndroidManifest.xml ] && \
    sed -i "s|android:label=\"[^\"]*\"|android:label=\"$NEW_NAME\"|" app/src/main/AndroidManifest.xml

# ---------- 6. 签名 ----------
# 不要在 gradle 这一步纠结签名方案：内核要求是「只有 v2，且 v2 有效」，
#   apk_matches_trusted_signature() 里 有 v1 -> 拒 / 有 v3、v3.1 -> 拒
# AGP 默认会签 v1+v2(+v3)，怎么调注入参数都不干净。
# 正确做法：gradle 照常出包，之后统一用官方的 sign_v2_only.sh
# （zipalign + apksigner --v1 false --v2 true --v3 false --v4 false）重签并自检。
echo "[6/7] 签名交给 sign_v2_only.sh，gradle 阶段不处理"

# ---------- 7. 关掉官方更新检查 ----------
# Downloader.kt:57 硬编码 https://api.github.com/repos/bmax121/APatch/releases/latest
# 这个 URL 不含包名，上面的替换碰不到它。官方版装上来会提示升级、覆盖成官方 APK。
# 设置里的开关默认 true，且存在 SharedPreferences 里（重装会重置），所以直接改源码默认值。
echo "[7/8] 关闭并隐藏官方更新检查 / KPM 只保留「加载」..."
# 注意：第 2 步已把源码目录迁到新包名下，这里必须用 find 现找
python3 - <<'PY'
import re, glob, os

def edit(rel, fn):
    hits = glob.glob(rel, recursive=True)
    if not hits:
        print(f"  ⚠ 没找到 {rel}")
        return
    for p in hits:
        s = open(p).read()
        n = fn(s)
        if n is None:
            print(f"  ⚠ {os.path.basename(p)}: 没匹配到，跳过")
            continue
        open(p, "w").write(n)
        print(f"  ✓ {os.path.basename(p)}")

# --- 1) 更新检查：默认关 ---
def off_update(s):
    return s.replace('getBoolean("check_update", true)', 'getBoolean("check_update", false)') \
            .replace('getBoolean(key, true)', 'getBoolean(key, false)')
edit("app/src/main/java/**/ui/screen/Home.kt", off_update)
edit("app/src/main/java/**/ui/screen/Settings.kt", off_update)

# --- 2) 隐藏设置里的 Check Update 开关 ---
def drop_switch(s):
    i = s.find("// Check Update")
    if i < 0:
        return None
    j = s.find("checkUpdate = it", i)
    if j < 0:
        return None
    k = s.find("\n", j)
    end = s.find("}", k)
    if end < 0:
        return None
    # 吃掉结尾换行，不留空行
    e = s.find("\n", end)
    return s[:i] + s[e + 1:]
edit("app/src/main/java/**/ui/screen/Settings.kt", drop_switch)

# --- 3) KPM 添加方式只留「加载」，隐藏镶嵌与安装 ---
def kpm_only_load(s):
    old = "val options = listOf(moduleEmbed, moduleInstall, moduleLoad)"
    if old not in s:
        return None
    return s.replace(old, "val options = listOf(moduleLoad)")
edit("app/src/main/java/**/ui/screen/KPM.kt", kpm_only_load)
PY

# ---------- 8. 验证 ----------
echo "[8/8] 验证..."
set +e
for pat in "$OLD_PKG" "$OLD_PKG_SLASH" "$OLD_PKG_UNDER"; do
    n=$(grep -rIl "$pat" "${TARGETS[@]}" 2>/dev/null | grep -v "${SKIP_DIRS[@]}" | wc -l)
    echo "  残留 [$pat]: $n"
done
grep -q "$OLD_PKG\|$OLD_PKG_SLASH" app/src/main/cpp/apjni.cpp && echo "  ⚠️ apjni.cpp 仍有残留" || echo "  apjni.cpp OK"
set -e
echo "=========================================="
echo " 完成。下一步："
echo " 1) 用固定 keystore 签名（不要每次 keytool 新建）"
echo " 2) keytool -list -v -keystore xxx.keystore 取证书 SHA-256"
echo " 3) 把该 SHA-256 填进 KernelPatch kernel/patch/android/userd.c 的 trusted_managers[]"
echo " 4) 自己编译 KernelPatch（APatch 默认下载的是官方预编译 kpimg，里面写死官方包名+摘要）"
echo
echo " 已顺手关掉官方更新检查（Home.kt / Settings.kt 默认 false）"
echo "=========================================="
