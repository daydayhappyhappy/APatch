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
#
# 脚本是幂等的：重复执行不会出现叠加破坏，第二次跑只会提示"已定制过，跳过"。
set -e

echo "=========================================="
echo " UI 定制：底栏 3 项 / 设置进溢出菜单 / 关反馈、Web调试、日志 / 只留中文"
echo "=========================================="

python3 - <<'PY'
import glob, os, re

APP = "app/src/main"

def edit(rel, fn, label):
    """对匹配 rel 的文件执行 fn；fn 返回 None 表示没匹配到（通常=已定制过）"""
    hits = glob.glob(rel, recursive=True)
    if not hits:
        print(f"  ⚠ 没找到 {rel}")
        return False
    ok = False
    for p in hits:
        s = open(p).read()
        out = fn(s)
        if out is None:
            print(f"  ⚠ {os.path.basename(p)}: 没匹配到（可能已定制过），跳过")
            continue
        open(p, "w").write(out)
        print(f"  ✓ {os.path.basename(p)}: {label}")
        ok = True
    return ok


def drop_import(s, imp):
    """只在文件正文（去掉所有 import 行之后）不再出现该标识符时才删，避免删坏编译"""
    if imp not in s:
        return s
    name = imp.rstrip("\n").split(".")[-1]
    body = "\n".join(l for l in s.splitlines() if not l.startswith("import "))
    return s.replace(imp, "") if name not in body else s


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
        Icons.Filled.Build,
        Icons.Outlined.Build,
        true,
        false
    )
}
'''

def bottom_bar(s):
    if "AModule(" not in s and "    Settings(" not in s:
        return None
    i = s.find("enum class BottomBarDestination(")
    if i < 0:
        return None
    s = s[:i] + NEW_BOTTOM_BAR
    for imp in [
        "import androidx.compose.material.icons.filled.Apps\n",
        "import androidx.compose.material.icons.filled.Settings\n",
        "import androidx.compose.material.icons.outlined.Apps\n",
        "import androidx.compose.material.icons.outlined.Settings\n",
        "import com.ramcosta.composedestinations.generated.destinations.APModuleScreenDestination\n",
        "import com.ramcosta.composedestinations.generated.destinations.SettingScreenDestination\n",
    ]:
        s = drop_import(s, imp)
    return s

edit(f"{APP}/java/**/ui/screen/BottomBarDestination.kt", bottom_bar, "底栏改为 主页/超级用户/KPM")


# ---------------------------------------------------------------- 2. 主页溢出菜单
OLD_MORE_MENU = '''                        DropdownMenuItem(text = {
                            Text(stringResource(R.string.home_more_menu_feedback_or_suggestion))
                        }, onClick = {
                            showDropdownMoreOptions = false
                            uriHandler.openUri("https://github.com/bmax121/APatch/issues/new/choose")
                        })
                        DropdownMenuItem(text = {
                            Text(stringResource(R.string.home_more_menu_about))
                        }, onClick = {
                            navigator.navigate(AboutScreenDestination)
                            showDropdownMoreOptions = false
                        })
'''
NEW_MORE_MENU = '''                        DropdownMenuItem(text = {
                            Text(stringResource(R.string.settings))
                        }, onClick = {
                            navigator.navigate(SettingScreenDestination)
                            showDropdownMoreOptions = false
                        })
'''

def home(s):
    if "SettingScreenDestination" in s:
        return None
    if OLD_MORE_MENU not in s:
        return None
    s = s.replace(OLD_MORE_MENU, NEW_MORE_MENU)
    # TopBar 里的 uriHandler 只服务于「反馈和建议」，一并去掉
    s = s.replace(
        "    val uriHandler = LocalUriHandler.current\n    var showDropdownMoreOptions",
        "    var showDropdownMoreOptions",
    )
    # 主页不再直接跳关于页，换成设置页
    s = s.replace(
        "import com.ramcosta.composedestinations.generated.destinations.AboutScreenDestination",
        "import com.ramcosta.composedestinations.generated.destinations.SettingScreenDestination",
    )
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
        return None

    # 3.1 入口改成带 navigator（composedestinations 会自动注入）
    if "fun SettingScreen() {" not in s:
        return None
    s = s.replace(
        "fun SettingScreen() {",
        "fun SettingScreen(navigator: DestinationsNavigator) {",
    )

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

    # 3.3 删掉 WebView 调试开关
    i = s.find("            // WebView Debug")
    if i < 0:
        return None
    j = s.find("\n            }\n", i)
    s = s[:i] + s[j + len("\n            }\n"):]

    # 3.3 删掉加载对话框
    s = s.replace("        val loadingDialog = rememberLoadingDialog()\n\n", "")

    # 3.4 删掉日志相关变量 + 导出 launcher（showLogBottomSheet / saveLog /
    #     logSavedMessage / exportBugreportLauncher 都在这一段里）
    i = s.find("        var showLogBottomSheet by remember")
    if i < 0:
        return None
    j = s.find("        val exportBugreportLauncher = rememberLauncherForActivityResult(", i)
    if j < 0:
        return None
    k = s.find("\n        }\n", j)
    s = s[:i] + s[k + len("\n        }\n"):]

    # 3.5 删掉「发送日志」整块（ListItem + ModalBottomSheet），原位放「关于」
    i = s.find("            // log")
    if i < 0:
        return None
    j = s.find("NavigationBarsSpacer()", i)
    if j < 0:
        return None
    k = s.find("\n            }", j)
    s = s[:i] + ABOUT_ITEM + s[k + len("\n            }"):]

    # 3.6 语言列表只剩中文后，index==0 不再代表「跟随系统」，改成按值判断
    s = s.replace(
        "if (index == 0) {",
        'if (languagesValues[index] == "default") {',
    )

    # 3.7 补 import
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

    # 3.8 清掉随上面删除而失效的 import（正文里还用到的会自动保留）
    for imp in [
        "import android.content.Intent\n",
        "import android.net.Uri\n",
        "import androidx.core.content.FileProvider\n",
        "import me.bmax.apatch.ui.component.rememberLoadingDialog\n",
        "import me.bmax.apatch.util.getBugreportFile\n",
        "import me.bmax.apatch.util.outputStream\n",
        "import me.bmax.apatch.util.ui.NavigationBarsSpacer\n",
        "import androidx.compose.material.icons.filled.BugReport\n",
        "import androidx.compose.material.icons.filled.Save\n",
        "import androidx.compose.material.icons.filled.Share\n",
        "import androidx.compose.material.icons.filled.DeveloperMode\n",
        "import androidx.compose.material3.ModalBottomSheet\n",
        "import androidx.activity.compose.rememberLauncherForActivityResult\n",
        "import androidx.activity.result.contract.ActivityResultContracts\n",
        "import androidx.compose.foundation.layout.WindowInsets\n",
        "import java.time.LocalDateTime\n",
        "import java.time.format.DateTimeFormatter\n",
    ]:
        s = drop_import(s, imp)
    return s

edit(f"{APP}/java/**/ui/screen/Settings.kt", settings, "设置页：删 Web 调试/日志，底部加关于")


# ---------------------------------------------------------------- 3.5 WebView 调试彻底关掉
def webui(s):
    old = 'WebView.setWebContentsDebuggingEnabled(prefs.getBoolean("enable_web_debugging", false))'
    if old not in s:
        return None
    return s.replace(old, "WebView.setWebContentsDebuggingEnabled(false)")

edit(f"{APP}/java/**/ui/WebUIActivity.kt", webui, "WebView 调试强制关闭")


# ---------------------------------------------------------------- 4. 语言只留中文
def arrays(s):
    out = re.sub(
        r'<string-array name="languages">.*?</string-array>',
        '<string-array name="languages">\n        <item>简体中文</item>\n    </string-array>',
        s, flags=re.S)
    out = re.sub(
        r'<string-array name="languages_values">.*?</string-array>',
        '<string-array name="languages_values">\n        <item>zh-CN</item>\n    </string-array>',
        out, flags=re.S)
    return None if out == s else out

edit(f"{APP}/res/values/arrays.xml", arrays, "语言列表只留简体中文")


# ---------------------------------------------------------------- 5. 启动即中文
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
        return None
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
PY

# ---------------------------------------------------------------- 验证
echo "------------------------------------------"
echo " 验证："
for f in app/src/main/res/values/arrays.xml \
         $(find app/src/main/java -name 'BottomBarDestination.kt' -o -name 'Home.kt' -o -name 'Settings.kt' -o -name 'APatchApp.kt' 2>/dev/null); do
    printf "  %-28s %s 行\n" "$(basename "$f")" "$(wc -l < "$f")"
done
echo
echo " 底栏项: $(grep -c 'ScreenDestination,' $(find app/src/main/java -name 'BottomBarDestination.kt') 2>/dev/null)"
echo " 语言项: $(grep -c '<item>' app/src/main/res/values/arrays.xml 2>/dev/null) (应为 2：一个语言名 + 一个语言码)"
echo " WebView 调试残留: $(grep -rl 'getBoolean("enable_web_debugging"' app/src/main/java 2>/dev/null | wc -l) (应为 0)"
echo " 反馈入口残留:     $(grep -rl 'home_more_menu_feedback_or_suggestion' app/src/main/java 2>/dev/null | wc -l)"
echo " 发送日志残留:     $(grep -rl 'showLogBottomSheet' app/src/main/java 2>/dev/null | wc -l)"
echo "=========================================="
echo " UI 定制完成。"
echo " 底栏：主页 - 超级用户 - KPM模块系统"
echo " 设置：主页右上角 ⋮ 菜单"
echo " 关于：设置页最下方"
echo "=========================================="
