#!/bin/bash
# APatch UI 定制脚本
#
# 必须放在 build_abc.sh 之后运行（那时源码目录已经迁到新包名下了）。
# 用法: bash ui_customize.sh
#
# 做的几件事：
#   1. 底部导航只留 主页 / 超级用户 / KPM，顺序固定，去掉 APM 模块系统
#   2. 设置从底部挪到主页右上角「溢出菜单（⋮）」
#   3. 关于从溢出菜单挪到设置页最下方
#   4. 关掉三项：反馈和建议、WebView 调试、发送日志
#   5. 语言列表只留简体中文，并让 App 启动时就锁中文（不跟随系统语言）
#   6. 剔除改完后失效的 import / 变量 / 字符串 / 其它语言资源
#
# 脚本是幂等的：重复执行不会叠加破坏，第二次跑只会提示"已定制过，跳过"。
#
# 上游更新后的行为：
#   默认【严格模式】——任何一项没命中，脚本最后以退出码 1 结束，CI 这一步会变红。
#   宁可构建失败让人看见，也不要静默漏改、打出一个没定制的 APK。
#   确认某项确实可以跳过时，用 ALLOW_MISS=1 bash ui_customize.sh 放行。
#
# 定位方式：不用整块精确字符串，改用「语义锚点 + 括号配对」找代码块，
#   上游改缩进、加换行、调参数顺序都不会失效；只有标识符本身被改名才会失败
#   （那种情况会明确报错，不会静默通过）。
set -e

echo "=========================================="
echo " UI 定制：底栏 3 项 / 设置进溢出菜单 / 关反馈、Web调试、日志 / 只留中文"
echo "=========================================="

ALLOW_MISS="${ALLOW_MISS:-0}"

python3 - "$ALLOW_MISS" <<'PY'
import glob, os, re, sys

APP = "app/src/main"
ALLOW_MISS = sys.argv[1] == "1"
FAILS = []


SKIP = "SKIP"   # 已定制过，属正常跳过，不算失败


def edit(rel, fn, label, required=True, group=False):
    """fn 返回值：文本=已改写；SKIP=已定制过不用再动；None=锚点没对上，算失败

    group=True 时（匹配到很多同名的文件，比如 43 份 strings.xml）把日志合并成
    一行，避免刷屏；失败的文件仍会逐个列出来。
    """
    hits = glob.glob(rel, recursive=True)
    if not hits:
        print(f"  ✗ 没找到文件 {rel}")
        if required:
            FAILS.append(f"{rel}（文件不存在）")
        return False

    # group=True 时把 fn 自己 print 的明细（"删掉死字符串: ..."）接管下来，
    # 只在最后回显前几条，避免 44 个文件刷出 44 行一模一样的日志。
    import contextlib, io as _io
    seen = []

    def run(s):
        if not group:
            return fn(s), None
        buf = _io.StringIO()
        with contextlib.redirect_stdout(buf):
            out = fn(s)
        return out, buf.getvalue()

    done = skipped = failed = 0
    for p in hits:
        s = open(p).read()
        out, logged = run(s)
        if out is SKIP:
            skipped += 1
        elif out is None:
            failed += 1
            seen.append(f"  ✗ {os.path.basename(p)}: 锚点没对上，{label} 未生效")
            if required:
                FAILS.append(f"{os.path.basename(p)}: {label}")
        else:
            open(p, "w").write(out)
            done += 1
            if logged and logged not in seen:
                seen.append(logged)

    if group:
        name = os.path.basename(hits[0])
        parts = []
        if done:
            parts.append(f"改了 {done} 个")
        if skipped:
            parts.append(f"跳过 {skipped} 个")
        if failed:
            parts.append(f"失败 {failed} 个")
        print(f"  ✓ {name} × {len(hits)}: {label}（{'，'.join(parts)}）")
        for l in seen[:3]:
            print(l.rstrip("\n"))
    elif skipped and not done and not failed:
        # 具体原因（已定制过 / 上游已无此功能）由各函数自己打印过了
        print(f"  · {os.path.basename(hits[0])}: 无需改动，跳过")
    return done > 0


# ---------------------------------------------------------------- 括号配对工具
# 上游改缩进/加换行/调参数顺序都不影响，只有标识符被改名才会失败。
PAIRS = {"(": ")", "{": "}"}


def match_paren(s, i):
    """s[i] 必须是 '(' 或 '{'，返回匹配的闭括号下标；配不上返回 -1。

    必须跳过字符串字面量和注释里的括号——Kotlin 源码里注释中的 '(...)'
    会让朴素计数提前失衡，导致文件后半部分的块全部定位失败。
    """
    stack = [PAIRS[s[i]]]
    j, n = i + 1, len(s)
    while j < n and stack:
        c = s[j]
        if c == '"':                                  # 字符串（含 """ 三引号）
            if s.startswith('"""', j):
                k = s.find('"""', j + 3)
                j = n if k < 0 else k + 3
            else:
                j += 1
                while j < n:
                    if s[j] == "\\":
                        j += 2
                        continue
                    if s[j] == '"':
                        j += 1
                        break
                    j += 1
            continue
        if c == "/" and j + 1 < n and s[j + 1] == "/":   # 行注释
            k = s.find("\n", j)
            j = n if k < 0 else k
            continue
        if c == "/" and j + 1 < n and s[j + 1] == "*":   # 块注释
            k = s.find("*/", j + 2)
            j = n if k < 0 else k + 2
            continue
        if c in PAIRS:
            stack.append(PAIRS[c])
        elif c in ")}":
            if stack and c == stack[-1]:
                stack.pop()
        j += 1
    return j - 1 if not stack else -1


def enclosing_call(s, marker, name):
    """找包住 marker 的 `name(...)` 调用，返回 (标识符开头下标, 右括号下标)。

    取「右括号刚好越过 marker、且是最小的那个」——也就是最紧凑的那一个。
    取最大下标会挑到后面同名的兄弟块，取最小下标会挑到前面根本没包住 marker 的块。
    marker 在块内部、或刚好落在块开头的参数里（比如 SwitchItem 前面那句
    prefs.getBoolean），这两种情况都能覆盖。
    """
    mi = s.find(marker)
    if mi < 0:
        return None
    best = None
    for m in re.finditer(r"\b" + re.escape(name) + r"\s*\(", s):
        lb = m.end() - 1                      # 指向 '('
        rb = match_paren(s, lb)
        if rb < 0 or rb <= mi:                # 没配平，或压根没包住 marker
            continue
        if best is None or rb < best[1]:      # 右括号最小 = 包得最紧
            best = (m.start(), rb)
    return best


def with_trailing_lambda(s, span):
    """Compose 的 SwitchItem(...) { ... } 这种尾随 lambda 在括号外面，
    只删括号部分会留下半截代码。右括号后面紧跟 `{` 就把它一起纳入删除范围。
    中间只允许空白，遇到任何标识符/符号就不认，避免误吃下一个 if 块。
    """
    a, b = span
    j = b + 1
    gap = 0
    while j < len(s) and s[j] in " \t\r\n":
        j += 1
        gap += 1
    if gap > 200 or j >= len(s) or s[j] != "{":
        return span
    rb = match_paren(s, j)
    return (a, rb) if rb > 0 else span


def drop_empty_if(s):
    """删掉内容为空的 if (...) { } 空壳，连同它上面紧挨着的注释行
    （开关删掉后常常只剩 // WebView Debug 加一个空壳）"""
    pat = re.compile(r"(?:[ \t]*//[^\n]*\n)*[ \t]*if \([^\n]*\) \{[ \t\r\n]*\}\n")
    s, n = pat.subn("", s)
    return s, n


def delete_block(s, span, eat_comment=True):
    """删掉 span 覆盖的块：往前吃掉紧邻的注释行，往后吃掉多余空行"""
    a, b = span
    if eat_comment:
        ls = s.rfind("\n", 0, a) + 1          # 块起始所在行的行首
        prev = s[:ls].rstrip("\n")
        pls = prev.rfind("\n") + 1
        if prev[pls:].strip().startswith("//"):
            a = pls                            # 上一行是注释，一起吃掉
    ls = s.rfind("\n", 0, a) + 1
    if not s[ls:a].strip():
        a = ls                                 # 块本身从行首开始，整行吃掉
    e = b + 1
    while e < len(s) and s[e] in " \t":
        e += 1
    if e < len(s) and s[e] == "\n":
        e += 1                                 # 吃掉行尾换行，不留空行
    return s[:a] + s[e:]


def reindent(block, indent):
    """把多行代码块整体平移到指定缩进（首行顶格，其余保持相对层级）"""
    lines = block.split("\n")
    base = min((len(l) - len(l.lstrip()) for l in lines if l.strip()), default=0)
    out = []
    for i, l in enumerate(lines):
        out.append(indent + l[base:] if l.strip() else l)
    return "\n".join(out)


def eat_line(s, needle):
    """删掉包含 needle 的那一整行（带后缀逗号/分号的也兼容）"""
    i = s.find(needle)
    if i < 0:
        return None
    ls = s.rfind("\n", 0, i) + 1
    le = s.find("\n", i)
    if le < 0:
        le = len(s)
    return s[:ls] + s[le + 1:]


def drop_import(s, imp):
    if imp not in s:
        return s
    name = imp.rstrip("\n").split(".")[-1]
    body = "\n".join(l for l in s.splitlines() if not l.startswith("import "))
    return s.replace(imp, "") if name not in body else s


# Kotlin 的 `val x by remember()` 委托靠隐式扩展函数实现，正文里看不到名字，
# 但删了一定编译不过；通配符 import 同理，一律不动。
IMPORT_KEEP = {"getValue", "setValue", "*"}


def prune_imports(s):
    lines = s.splitlines()
    body = "\n".join(l for l in lines if not l.startswith("import "))
    out, dropped = [], 0
    for l in lines:
        if l.startswith("import "):
            name = l.strip().split(".")[-1]
            if name in IMPORT_KEEP:
                out.append(l)
                continue
            if name and not re.search(r"\b" + re.escape(name) + r"\b", body):
                dropped += 1
                continue
        out.append(l)
    return "\n".join(out) + "\n", dropped


# ---------------------------------------------------------------- 1. 底部导航
NEW_BOTTOM_BAR = '''enum class BottomBarDestination(
    val direction: DirectionDestinationSpec,
    @param:StringRes val label: Int,
    val iconSelected: ImageVector,
    val iconNotSelected: ImageVector,
    val kPatchRequired: Boolean,
    val aPatchRequired: Boolean,
) {
    Home(
        HomeScreenDestination,
        R.string.home,
        Icons.Filled.Home,
        Icons.Outlined.Home,
        false,
        false
    ),
    SuperUser(
        SuperUserScreenDestination,
        R.string.su_title,
        Icons.Filled.Security,
        Icons.Outlined.Security,
        true,
        false
    ),
    KModule(
        KPModuleScreenDestination,
        R.string.kpm,
        Icons.Filled.Settings,
        Icons.Outlined.Settings,
        true,
        false
    )
}
'''


def bottom_bar(s):
    # 已定制过的特征：APM 项没了，且枚举项恰好 3 个
    if "AModule(" not in s and s.count("ScreenDestination,") == 3:
        return SKIP
    i = s.find("enum class BottomBarDestination(")
    if i < 0:
        print("      ⚠ 找不到 enum class BottomBarDestination，上游结构可能变了")
        return None
    s = s[:i] + NEW_BOTTOM_BAR
    for imp in [
        "import androidx.compose.material.icons.filled.Apps\n",
        "import androidx.compose.material.icons.filled.Build\n",
        "import androidx.compose.material.icons.outlined.Apps\n",
        "import androidx.compose.material.icons.outlined.Build\n",
        "import com.ramcosta.composedestinations.generated.destinations.APModuleScreenDestination\n",
        "import com.ramcosta.composedestinations.generated.destinations.SettingScreenDestination\n",
    ]:
        s = drop_import(s, imp)
    s, _ = prune_imports(s)
    return s


edit(f"{APP}/java/**/ui/screen/BottomBarDestination.kt", bottom_bar, "底栏改为 主页/超级用户/KPM")


# ---------------------------------------------------------------- 2. 主页溢出菜单
SETTINGS_MENU_ITEM = '''                        DropdownMenuItem(text = {
                            Text(stringResource(R.string.settings))
                        }, onClick = {
                            navigator.navigate(SettingScreenDestination)
                            showDropdownMoreOptions = false
                        })'''


def insert_into_overflow(s, menu_state_var):
    """上游把菜单项全删了时的兜底：往溢出菜单容器里插一条「设置」。

    找 `DropdownMenu(expanded = <menu_state_var> ...) { ... }` 这个容器，
    在它内容的开头插入 SETTINGS_MENU_ITEM。返回新文本，插不进去返回 None。

    锚点必须是 `DropdownMenu(expanded = xxx` 这个完整写法——只搜变量名会命中
    IconButton 里那句 `showDropdownMoreOptions = true`，进而挑错菜单（比如重启菜单）。
    """
    mi = s.find("DropdownMenu(expanded = " + menu_state_var)
    if mi < 0:
        return None
    cont = enclosing_call(s, "DropdownMenu(expanded = " + menu_state_var, "DropdownMenu")
    if not cont:
        return None
    a, b = cont
    # 容器本身的 { 在 DropdownMenu(...) 右括号【之后】。
    # 从 a 开始找会命中 onDismissRequest = { 那个 lambda，插错地方。
    lb = s.find("{", b)
    if lb < 0:
        return None
    rb = match_paren(s, lb)
    if rb < 0:
        return None
    # 花括号后第一行就是菜单项该待的地方，照它的缩进对齐
    nl = s.find("\n", lb)
    if nl < 0 or nl > rb:
        return None
    next_line = s[nl + 1:rb]
    m = re.match(r"[ \t]*", next_line)
    indent = m.group(0) if m else " " * 24
    if not next_line.strip():
        # 容器是空的（rb 指向闭合括号本身，切片里看不到它），
        # 这时取到的是闭合括号的缩进，菜单项要再深一级
        indent += "    "
    item = reindent(SETTINGS_MENU_ITEM, indent)
    return s[:nl + 1] + item + "\n" + s[nl + 1:]


def home(s):
    if "SettingScreenDestination" in s:
        return SKIP
    changed = False

    # 2.1 删掉「反馈和建议」菜单项（靠 R.string 名定位，不靠缩进）
    if "home_more_menu_feedback_or_suggestion" in s:
        blk = enclosing_call(s, "home_more_menu_feedback_or_suggestion", "DropdownMenuItem")
        if blk:
            s = delete_block(s, blk)
            changed = True
        else:
            print("      ⚠ 「反馈和建议」还在，但块没定位到（上游可能改了写法）")
    else:
        print("      · 上游已无「反馈和建议」，跳过")

    # 2.2 「关于」菜单项就地换成「设置」（按原块缩进重新对齐）
    if "home_more_menu_about" in s:
        blk = enclosing_call(s, "home_more_menu_about", "DropdownMenuItem")
        if blk:
            ls = s.rfind("\n", 0, blk[0]) + 1
            indent = s[ls:blk[0]]
            if indent.strip():
                indent = ""
            # 从行首开始替换：blk[0] 指向标识符，前面的缩进要一并换掉，否则会叠加两次
            s = s[:ls] + reindent(SETTINGS_MENU_ITEM, indent) + s[blk[1] + 1:]
            changed = True
        else:
            print("      ⚠ 「关于」还在，但块没定位到（上游可能改了写法）")
    else:
        print("      · 上游已无「关于」菜单项，改成直接往溢出菜单里插设置项")
        ins = insert_into_overflow(s, "showDropdownMoreOptions")
        if ins:
            s, changed = ins, True
        else:
            print("      ⚠ 找不到溢出菜单容器，设置入口插不进去")

    # 2.3 关于页不再从主页直达，换成设置页
    s = s.replace(
        "import com.ramcosta.composedestinations.generated.destinations.AboutScreenDestination",
        "import com.ramcosta.composedestinations.generated.destinations.SettingScreenDestination",
    )
    # 2.4 TopBar 里的 uriHandler 只服务于「反馈和建议」。
    #     全文还有别的 uriHandler（更新检查等），所以不能按全文计数判断，
    #     只删 TopBar 里紧挨着 showDropdownMoreOptions 声明的那一行。
    s2 = re.sub(
        r"[ \t]*val uriHandler = LocalUriHandler\.current\n(\s*var showDropdownMoreOptions)",
        r"\1", s)
    if s2 != s:
        s = s2
    else:
        print("      ⚠ TopBar 里的 uriHandler 声明没找到（不影响功能，只是多个未用变量）")

    # 2.5 自检：光有 import 不算数，必须是真的有一句 navigate 调用
    if "navigate(SettingScreenDestination" not in s:
        print("      ⚠ 设置入口没能进溢出菜单（终态校验会拦下这种情况）")
    s, _ = prune_imports(s)
    return s


edit(f"{APP}/java/**/ui/screen/Home.kt", home, "溢出菜单：删反馈/关于，只留设置")


# ---------------------------------------------------------------- 3. 设置页
ABOUT_ITEM = '''            // about
            ListItem(
                leadingContent = {
                    Icon(
                        Icons.Filled.Info, stringResource(id = R.string.home_more_menu_about)
                    )
                },
                headlineContent = { Text(stringResource(id = R.string.home_more_menu_about)) },
                modifier = Modifier.clickable {
                    navigator.navigate(AboutScreenDestination)
                })

'''


def settings(s):
    if "navigator.navigate(AboutScreenDestination)" in s:
        return SKIP

    # 3.1 入口改成带 navigator（composedestinations 会自动注入）
    if "fun SettingScreen() {" not in s:
        print("      ⚠ 找不到 fun SettingScreen()，上游签名可能变了")
        return None
    s = s.replace("fun SettingScreen() {", "fun SettingScreen(navigator: DestinationsNavigator) {")

    # 3.2 设置页现在是二级页面，顶栏补一个返回箭头
    old_bar = '''            TopAppBar(
                title = { Text(stringResource(R.string.settings)) },
            )
'''
    new_bar = '''            TopAppBar(
                title = { Text(stringResource(R.string.settings)) },
                navigationIcon = {
                    IconButton(onClick = { navigator.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null)
                    }
                },
            )
'''
    if old_bar in s:
        s = s.replace(old_bar, new_bar)
        if "import androidx.compose.material3.IconButton" not in s:
            s = s.replace(
                "import androidx.compose.material3.Icon\n",
                "import androidx.compose.material3.Icon\nimport androidx.compose.material3.IconButton\n",
            )
        if "import androidx.compose.material.icons.automirrored.filled.ArrowBack" not in s:
            s = s.replace(
                "import androidx.compose.material.icons.filled.ColorLens\n",
                "import androidx.compose.material.icons.automirrored.filled.ArrowBack\n"
                "import androidx.compose.material.icons.filled.ColorLens\n",
            )
    else:
        print("      ⚠ 顶栏结构变了，返回箭头没加上（不影响其它改动）")

    # 3.3 删掉 WebView 调试开关：先删 SwitchItem 本体，再删它前面那句变量声明
    if "enable_web_debugging" in s:
        blk = enclosing_call(s, "R.string.enable_web_debugging", "SwitchItem")
        if blk:
            s = delete_block(s, with_trailing_lambda(s, blk))
        else:
            print("      ⚠ WebView 调试还在，但块没定位到（上游可能改了写法）")
    else:
        print("      · 上游已无 WebView 调试功能，跳过")
    s = re.sub(
        r"[ \t]*var enableWebDebugging by rememberSaveable \{.*?\}\n",
        "", s, flags=re.S)

    # 3.4 删掉加载对话框
    s = eat_line(s, "val loadingDialog = rememberLoadingDialog()") or s

    # 3.5 删掉日志相关变量和导出 launcher
    for needle in [
        "var showLogBottomSheet by remember",
        "val saveLog = stringResource",
        "val logSavedMessage = stringResource",
    ]:
        s = eat_line(s, needle) or s
    i = s.find("val exportBugreportLauncher = rememberLauncherForActivityResult(")
    if i >= 0:
        lb = s.find("(", i + len("val exportBugreportLauncher = rememberLauncherForActivityResult"))
        rb = match_paren(s, lb)
        if rb > 0:
            # 同样有尾随 lambda（{ uri: Uri? -> ... }），不留会剩半截 bugreport 逻辑
            s = delete_block(s, with_trailing_lambda(s, (i, rb)), eat_comment=False)

    # 3.6 删掉「发送日志」ListItem
    # 判「功能还在不在」只看代码里的实际引用，不看 import（import 可能只是残留）。
    # 万一上游是把标识符改了名，这里会误判成"已删除"——但终态校验会兜住这种情况。
    if "R.string.send_log" in s or "showLogBottomSheet" in s:
        blk = enclosing_call(s, "R.string.send_log", "ListItem")
        if blk:
            s = delete_block(s, with_trailing_lambda(s, blk))
        else:
            print("      ⚠ 「发送日志」还在，但 ListItem 块没定位到（上游可能改了写法）")
    else:
        print("      · 上游已无「发送日志」功能，跳过")

    # 3.7 删掉点它弹出来的那个 BottomSheet（整段 if 块）
    i = s.find("if (showLogBottomSheet)")
    if i >= 0:
        lb = s.find("{", i)
        rb = match_paren(s, lb)
        if rb > 0:
            ls = s.rfind("\n", 0, i) + 1
            s = s[:ls] + s[rb + 1:].lstrip("\n")

    # 3.8 「关于」插到语言项后面（语言项是保留项里最靠下的，插它后面=页面最下方）
    lang = enclosing_call(s, "R.string.settings_app_language", "ListItem")
    if lang:
        s = s[:lang[1] + 1] + "\n\n" + ABOUT_ITEM.rstrip("\n") + "\n" + s[lang[1] + 1:]
    else:
        print("      ⚠ 没找到语言项，「关于」改成插到页面末尾")
        s = s.rstrip()
        i = s.rfind("}")
        s = s[:i] + "\n" + ABOUT_ITEM.rstrip("\n") + "\n" + s[i:]

    # 3.9 语言列表只剩中文后，index==0 不再代表「跟随系统」，改成按值判断
    s = s.replace(
        "if (index == 0) {",
        'if (languagesValues[index] == "default") {',
    )

    # 3.10 日志块删掉后，Column 里那个 context 没人用了
    s = s.replace(
        "            val context = LocalContext.current\n"
        "            val scope = rememberCoroutineScope()\n",
        "            val scope = rememberCoroutineScope()\n",
    )

    # 3.11 补 import
    if "import androidx.compose.material.icons.filled.Info" not in s:
        s = s.replace(
            "import androidx.compose.material.icons.filled.InvertColors",
            "import androidx.compose.material.icons.filled.Info\n"
            "import androidx.compose.material.icons.filled.InvertColors",
        )
    if "AboutScreenDestination" not in s.split("fun SettingScreen")[0]:
        s = s.replace(
            "import com.ramcosta.composedestinations.annotation.Destination",
            "import com.ramcosta.composedestinations.generated.destinations.AboutScreenDestination\n"
            "import com.ramcosta.composedestinations.navigation.DestinationsNavigator\n"
            "import com.ramcosta.composedestinations.annotation.Destination",
        )

    # 3.12 开关删掉后可能留下 if (xxx) { } 空壳，一并清掉
    s, n_if = drop_empty_if(s)
    if n_if:
        print(f"      · 清掉 {n_if} 个 if 空壳")

    s, n = prune_imports(s)
    if n:
        print(f"      · 顺带清掉 {n} 个失效 import")
    return s


edit(f"{APP}/java/**/ui/screen/Settings.kt", settings, "设置页：删 Web 调试/日志，底部加关于")


# ---------------------------------------------------------------- 3.5 WebView 调试彻底关掉
def webui(s):
    old = 'WebView.setWebContentsDebuggingEnabled(prefs.getBoolean("enable_web_debugging", false))'
    if old in s:
        return s.replace(old, "WebView.setWebContentsDebuggingEnabled(false)")
    if "setWebContentsDebuggingEnabled(false)" in s:
        return SKIP
    if "setWebContentsDebuggingEnabled" in s:
        print("      ⚠ WebView 调试开关还在，但写法变了（上游可能改了签名）")
        return None
    print("      · 上游已无 WebView 调试开关，跳过")
    return SKIP


edit(f"{APP}/java/**/ui/WebUIActivity.kt", webui, "WebView 调试强制关闭")


# ---------------------------------------------------------------- 4. 清掉失效字符串
DEAD_STRINGS = [
    "home_more_menu_feedback_or_suggestion",   # 反馈和建议（菜单项已删）
    "enable_web_debugging",                    # WebView 调试（开关已删）
    "enable_web_debugging_summary",
    "send_log",                                # 发送日志（整块已删）
    "save_log",
    "log_saved",                               # 只被删掉的那句 logSavedMessage 用过
]

# 注：源码里另外还有 30 来条上游自己的孤儿字符串（kpm_version、apm_version 等），
# 那是上游遗留，跟本次改动无关，不动它们——批量删风险大于收益。


def build_reference_corpus():
    """把所有可能引用 @string / R.string 的地方拼在一起。

    必须扫整个 res/ 而不只是 res/xml：字符串还可能被 drawable、mipmap 快捷方式、
    menu、以及其它 values 文件（<item>@string/x</item>）引用。
    漏扫 = 删掉还在被引用的字符串 = 构建直接挂，宁可多扫。
    """
    corpus = ""
    for p in glob.glob(f"{APP}/java/**/*.kt", recursive=True):
        corpus += open(p).read()
    for p in glob.glob(f"{APP}/res/**/*.xml", recursive=True):
        corpus += open(p).read()
    for p in glob.glob(f"{APP}/AndroidManifest.xml"):
        corpus += open(p).read()
    return corpus


_REFERENCES = None


def is_referenced(name):
    global _REFERENCES
    if _REFERENCES is None:
        _REFERENCES = build_reference_corpus()
    return (re.search(r"R\.string\." + name + r"\b", _REFERENCES) is not None
            or re.search(r"@string/" + name + r"\b", _REFERENCES) is not None)


def dead_strings(s):
    removed = []
    for name in DEAD_STRINGS:
        if is_referenced(name):
            continue
        pat = re.compile(r"[ \t]*<string name=\"" + name + r"\".*?</string>\n", re.S)
        s, cnt = pat.subn("", s)
        if cnt:
            removed.append(name)
    if not removed:
        # 一条都不剩 = 已经清过了
        return SKIP if not any(f'name="{n}"' in s for n in DEAD_STRINGS) else None
    print(f"      · 删掉死字符串: {', '.join(removed)}")
    return s


# 所有语言的 strings.xml 都清一遍：App 锁的是 zh-CN，实际显示用的是
# values-zh-rCN 那份，只清默认的 values 会留下看不出、但确实存在的死资源。
edit(f"{APP}/res/values*/strings.xml", dead_strings,
     "清理已关功能遗留的字符串（含其它语言）", required=False, group=True)


# ---------------------------------------------------------------- 5. 语言只留中文
def arrays(s):
    out = re.sub(
        r'<string-array name="languages">.*?</string-array>',
        '<string-array name="languages">\n        <item>简体中文</item>\n    </string-array>',
        s, flags=re.S)
    out = re.sub(
        r'<string-array name="languages_values">.*?</string-array>',
        '<string-array name="languages_values">\n        <item>zh-CN</item>\n    </string-array>',
        out, flags=re.S)
    if out == s:
        return SKIP if 'zh-CN' in s and '简体中文' in s else None
    return out


edit(f"{APP}/res/values/arrays.xml", arrays, "语言列表只留简体中文")


# ---------------------------------------------------------------- 5.5 其它语言的资源目录直接删掉
# 光改 arrays.xml 只是改了「选择器里列几项」。仓库里那 40 多个 values-xx/strings.xml
# 还在，它们会：
#   · 被 generateLocaleConfig 收进 locale_config.xml -> 系统「应用语言」页仍列出一堆语言
#   · 让 APK 白胖一大圈
# 所以这里直接物理删除，不依赖 localeFilters 那条 DSL 是否被 AGP 认。
# 只保留：values（默认）、values-night（深色主题，非语言）、values-zh-rCN（简体中文）
# 注意：这步只删 CI 运行机工作区里的文件，不动你 git 仓库里的东西。
KEEP_RES = {"values", "values-night", "values-zh-rCN"}


def strip_locales(res_dir):
    import shutil
    removed = []
    for d in sorted(os.listdir(res_dir)):
        p = os.path.join(res_dir, d)
        if not os.path.isdir(p) or not d.startswith("values-"):
            continue
        if d in KEEP_RES:
            continue
        shutil.rmtree(p)
        removed.append(d)
    return removed


_removed = strip_locales(f"{APP}/res")
if _removed:
    print(f"  ✓ res/: 删掉 {len(_removed)} 个其它语言目录（保留 values / values-night / values-zh-rCN）")
    print(f"      · {', '.join(_removed)}")
else:
    print("  ✓ res/: 其它语言目录已清理过，跳过")


# ---------------------------------------------------------------- 5.6 系统「应用语言」页只列中文
# 上面改的 arrays.xml 只管 App 内部那个语言选择器。
# 手机系统设置里「应用 → 该应用 → 语言」那一页是另一套机制：它列的是
# APK 支持的 locale，由 AGP 的 generateLocaleConfig 自动扫描 res 生成，
# 不受 arrays.xml 影响 —— 所以光删目录，那一页还是会列出英文等。
# 要让它也只剩中文，必须显式给一份 locale_config.xml 并在 manifest 里引用。
LOCALE_CONFIG = '''<?xml version="1.0" encoding="utf-8"?>
<locale-config xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- 定制：只支持简体中文，系统「应用语言」页就只列出这一项 -->
    <locale android:name="zh-CN"/>
</locale-config>
'''

_xml_dir = f"{APP}/res/xml"
os.makedirs(_xml_dir, exist_ok=True)
_lp = os.path.join(_xml_dir, "locale_config.xml")
if os.path.exists(_lp) and "zh-CN" in open(_lp).read():
    print("  · locale_config.xml: 已存在且正确，跳过")
else:
    open(_lp, "w").write(LOCALE_CONFIG)
    print("  ✓ locale_config.xml: 系统「应用语言」页只列简体中文")


def add_locale_config_attr(s):
    if "android:localeConfig" in s:
        return SKIP
    m = re.search(r"<application\b", s)
    if not m:
        return None
    return (s[:m.end()] + '\n        android:localeConfig="@xml/locale_config"'
            + s[m.end():])


edit(f"{APP}/AndroidManifest.xml", add_locale_config_attr, "manifest 引用 locale_config")


def disable_auto_locale_config(s):
    """关掉 AGP 自动扫描生成：它会把扫描结果也写进 APK，跟上面那份打架"""
    if "generateLocaleConfig = false" in s:
        return SKIP
    if "generateLocaleConfig" not in s:
        return None
    return s.replace("generateLocaleConfig = true", "generateLocaleConfig = false")


edit("app/build.gradle.kts", disable_auto_locale_config,
     "关闭 AGP 自动生成 locale_config", required=False)


# ---------------------------------------------------------------- 6. 启动即中文
LOCALE_CODE = '''    // 定制：不跟随系统语言，启动即锁定简体中文。
    // 想恢复「跟随系统」，把整个 attachBaseContext + withChineseLocale 删掉即可。
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(withChineseLocale(base))
    }

    private fun withChineseLocale(context: Context): Context {
        val locale = Locale.SIMPLIFIED_CHINESE
        Locale.setDefault(locale)
        val config = Configuration(context.resources.configuration)
        config.setLocale(locale)
        return context.createConfigurationContext(config)
    }

'''


def applocale(s):
    if "withChineseLocale" in s:
        return SKIP
    anchor = "    override fun onCreate() {"
    if anchor not in s:
        return None
    s = s.replace(anchor, LOCALE_CODE + anchor)
    if "import android.content.res.Configuration" not in s:
        s = s.replace(
            "import android.content.Context",
            "import android.content.Context\nimport android.content.res.Configuration",
        )
    return s


edit(f"{APP}/java/**/APatchApp.kt", applocale, "App 启动锁定简体中文")


# ---------------------------------------------------------------- 7. 只打中文资源
# ⚠ 别用 localeFilters 这条 DSL：实测 AGP 9.3.1 会把它原样喂给 aapt2 的 -c 参数，
#   而 -c 只认老式资源限定符（zh / zh-rCN），传 BCP-47 的 "zh-CN" 会直接构建失败：
#     error: invalid config 'zh-CN' for -c option.
#   Execution failed for task ':app:generateReleaseLocaleConfig'
# 语言目录在上面第 5.5 步已经物理删掉了，localeFilters 属于多余，不加。
# 这里只做一件事：万一之前有人手动加过，把它清掉，避免再次踩坑。
def drop_locale_filters(s):
    if "localeFilters" not in s:
        return SKIP
    # 连带吃掉它上面紧邻的注释行；闭合括号那行的缩进原样保留
    out = re.sub(r"(?:[ \t]*//[^\n]*\n)*[ \t]*localeFilters[^\n]*\n", "", s)
    print("      · 清掉手动加的 localeFilters（会破坏构建）")
    return out


edit("app/build.gradle.kts", drop_locale_filters, "清理会破坏构建的 localeFilters", required=False)


# ---------------------------------------------------------------- 8. 终态校验
# 过程不重要，只看「最终状态达没达成」。
# 上游把某个功能删了 -> 终态自然达成，脚本自己认，不需要人工改脚本。
# 上游把标识符改名了 -> 终态达不到，下面会明确列出是哪一项。
def read_one(pattern):
    hits = glob.glob(pattern, recursive=True)
    return open(hits[0]).read() if hits else None


def final_check():
    bad = []

    def need(ok, msg):
        if not ok:
            bad.append(msg)

    bb = read_one(f"{APP}/java/**/ui/screen/BottomBarDestination.kt")
    if bb is None:
        bad.append("找不到 BottomBarDestination.kt")
    else:
        need(bb.count("ScreenDestination,") == 3, "底栏不是 3 项")
        i = bb.find("enum class BottomBarDestination(")
        j = bb.find(") {", i) if i >= 0 else -1
        order = re.findall(r"^\s+([A-Za-z]+)\($", bb[j + 3:], re.M) if j >= 0 else []
        need(order == ["Home", "SuperUser", "KModule"], f"底栏顺序不是 主页→超级用户→KPM，实际 {order}")
        need("Icons.Filled.Settings" in bb and "Icons.Outlined.Settings" in bb,
             "KPM 图标不是齿轮")

    home = read_one(f"{APP}/java/**/ui/screen/Home.kt")
    # 必须是真的有一句 navigate 调用，光有 import 不算（否则会假阳性）
    need(home is None or "navigate(SettingScreenDestination" in home,
         "主页溢出菜单里没有「设置」导航入口")

    st = read_one(f"{APP}/java/**/ui/screen/Settings.kt")
    if st is None:
        bad.append("找不到 Settings.kt")
    else:
        need("navigate(AboutScreenDestination" in st, "设置页底部没有「关于」导航入口")
        need("fun SettingScreen(navigator" in st,
             "SettingScreen 没有加 navigator 参数（关于入口跳不过去）")
        for k in ("enable_web_debugging", "send_log", "showLogBottomSheet"):
            need(k not in st, f"设置页仍残留 {k}")
        # 兜底扫描：只要日志导出功能还在（不管上游把它改叫什么名），
        # 这两个痕迹基本跑不掉。上游真删了功能则两者皆无，不会误报。
        for k in ("getBugreportFile", "BugReport"):
            need(k not in st, f"设置页仍有日志导出痕迹 {k}（上游可能改了名，需人工确认）")

    web = read_one(f"{APP}/java/**/ui/WebUIActivity.kt")
    if web is not None:
        need("getBoolean(\"enable_web_debugging\"" not in web,
             "WebUIActivity 仍在读 WebView 调试开关")

    arr = read_one(f"{APP}/res/values/arrays.xml")
    if arr is not None:
        need(arr.count("<item>") == 2, "语言数组不是只剩简体中文一项")

    if os.path.isdir(f"{APP}/res"):
        left = [d for d in os.listdir(f"{APP}/res")
                if os.path.isdir(os.path.join(f"{APP}/res", d))
                and d.startswith("values-") and d not in KEEP_RES]
        need(not left, f"仍有其它语言资源目录: {left}")

    app = read_one(f"{APP}/java/**/APatchApp.kt")
    need(app is None or "withChineseLocale" in app, "App 没有锁定简体中文")

    mf = read_one(f"{APP}/AndroidManifest.xml")
    need(mf is None or "android:localeConfig" in mf,
         "manifest 没有引用 locale_config（系统「应用语言」页不会只列中文）")
    lc = read_one(f"{APP}/res/xml/locale_config.xml")
    # 注意：不能用 "<locale" 计数，它会连 <locale-config> 根标签一起数进去
    need(lc is not None and "zh-CN" in lc
         and lc.count("<locale android:name") == 1,
         "locale_config.xml 不是只含 zh-CN 一项")
    ag = read_one("app/build.gradle.kts")
    if ag is not None and "generateLocaleConfig" in ag:
        need("generateLocaleConfig = false" in ag,
             "AGP 自动生成 locale_config 没关掉（会跟上面那份打架）")

    return bad


# ---------------------------------------------------------------- 收尾
print()
_bad = final_check()
if _bad:
    print(" ✗ 终态校验没通过，下面这几项目标状态没达成：")
    for b in _bad:
        print(f"   · {b}")
else:
    print(" ✔ 终态校验通过：底栏/设置入口/关于入口/三项关闭/中文 全部达成")

if not ALLOW_MISS and (_bad or FAILS):
    print()
    print(" 上游代码可能变了。以上列出的是「没达成的目标」，照着改对应文件即可；")
    print(" 若确认某一项这次确实可以跳过，用 ALLOW_MISS=1 bash ui_customize.sh 放行。")
    sys.exit(1)
if ALLOW_MISS and (_bad or FAILS):
    print(" （ALLOW_MISS=1，放行继续）")
PY

echo "------------------------------------------"
echo " 验证："
set +e   # 下面全是计数类命令，grep 数到 0 会返回 1，不能让它中断脚本

BB=$(find app/src/main/java -name 'BottomBarDestination.kt' 2>/dev/null | head -1)
echo -n " 底栏项(应为3): "; grep -c 'ScreenDestination,' "$BB" 2>/dev/null
echo -n " 底栏顺序(应为 主页→超级用户→KPM): "
awk '/^\) \{/{f=1;next} f' "$BB" 2>/dev/null | grep -oE '^\s+[A-Za-z]+\(' | tr -d ' (' | tr '\n' ' '; echo
echo -n " KPM 图标(应为 Settings): "; grep -A4 '    KModule(' "$BB" 2>/dev/null | grep -oE 'Icons\.(Filled|Outlined)\.[A-Za-z]+' | tr '\n' ' '; echo
echo -n " 语言项(应为2): "; grep -c '<item>' app/src/main/res/values/arrays.xml 2>/dev/null
echo -n " 剩余语言目录(应为0，只留 values/night/zh-rCN): "
ls -d app/src/main/res/values-* 2>/dev/null | grep -vE 'values-night$|values-zh-rCN$' | wc -l
echo -n " manifest引用locale_config(应为1): "; grep -c 'android:localeConfig' app/src/main/AndroidManifest.xml 2>/dev/null
echo -n " AGP自动生成locale_config(应为0): "; grep -c 'generateLocaleConfig = true' app/build.gradle.kts 2>/dev/null
echo -n " localeFilters残留(应为0，它会让构建失败): "; grep -c 'localeFilters' app/build.gradle.kts 2>/dev/null
echo -n " WebView调试残留(应为0): "; grep -rl 'getBoolean("enable_web_debugging"' app/src/main/java 2>/dev/null | wc -l
echo -n " 反馈入口残留(应为0): "; grep -rl 'home_more_menu_feedback_or_suggestion' app/src/main/java 2>/dev/null | wc -l
echo -n " 发送日志残留(应为0): "; grep -rl 'showLogBottomSheet' app/src/main/java 2>/dev/null | wc -l
echo -n " 死字符串残留(应为0): "; grep -c 'home_more_menu_feedback_or_suggestion\|enable_web_debugging\|send_log\|save_log' app/src/main/res/values/strings.xml 2>/dev/null
echo
echo " 各文件失效 import 复查："
for f in $(find app/src/main/java -name 'BottomBarDestination.kt' -o -name 'Home.kt' -o -name 'Settings.kt' -o -name 'APatchApp.kt' -o -name 'WebUIActivity.kt' 2>/dev/null); do
    n=$(python3 - "$f" <<'PYEOF'
import sys, re
lines = open(sys.argv[1]).read().splitlines()
body = "\n".join(l for l in lines if not l.startswith("import "))
c = 0
for l in lines:
    if l.startswith("import "):
        nm = l.strip().split(".")[-1]
        if nm in ("getValue", "setValue", "*"):
            continue
        if nm and not re.search(r"\b" + re.escape(nm) + r"\b", body):
            c += 1
print(c)
PYEOF
)
    printf "  %-26s %s\n" "$(basename "$f")" "$([ "$n" = "0" ] && echo '干净' || echo "还有 $n 个")"
done
echo "=========================================="
echo " UI 定制完成。"
echo " 底栏：主页 - 超级用户 - KPM模块系统（KPM 用齿轮图标）"
echo " 设置：主页右上角 ⋮ 菜单"
echo " 关于：设置页最下方"
echo " 已关：反馈和建议 / WebView 调试 / 发送日志"
echo " 语言：只留简体中文，不跟随系统"
echo "=========================================="
