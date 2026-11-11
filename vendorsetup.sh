#
# vendorsetup.sh —— ardbeg 的 lunch 入口 + 本机编译环境
#
# build/envsetup.sh 会自动 source 本文件（见 build/envsetup.sh 第 1698 行，
# 它按 device/*/*/vendorsetup.sh 扫描，最大深度 4 层）。所以这里做两件事：
#   一、注册 lunch 目标
#   二、把本机特有的工具链塞进 PATH —— 全部改动收敛在设备树里，
#       源码树（build/、prebuilts/、external/ …）一个字节都不动。
#
# 用法：
#     cd <源码树根>
#     . build/envsetup.sh
#     lunch cm_ardbeg-eng
#     make -j16
#

# =============================================================================
# 一、lunch 目标
# =============================================================================
# add_lunch_combo 只是往菜单里加一行，真正解析产品靠 AndroidProducts.mk 里的
# PRODUCT_MAKEFILES。两处不一致时"能选但选完报错"：
#     Cannot locate config makefile for product "..."
add_lunch_combo cm_ardbeg-eng
add_lunch_combo cm_ardbeg-userdebug
add_lunch_combo cm_ardbeg-user
add_lunch_combo cm_ardbeg_tv-eng

# =============================================================================
# 二、本机编译环境
# =============================================================================
# 下面这些路径属于「这台开发机」，不是设备树的一部分，换机器要跟着改。
# 写在这里而不是让使用者手工 export，是因为漏掉任何一条都会在编译中途
# 以很难懂的方式失败，而报错现场和真正的原因往往隔着几十个目标：
#
#   java 8        Android 7.1 只认 OpenJDK 8，系统默认 JDK 11+ 会在
#                 jack/desugar 阶段报 "Unsupported class file major version"。
#   python2       7.1 的 build/tools/*.py 全是 python2 语法，系统里若
#                 没有 python/python2，第一次调用就 SyntaxError。
#   flex          见 tools/hostbin/flex 头部注释：预编译 flex 2.5.39
#                 在 UTF-8 locale 下必崩，这里用包装脚本顶替。
#   m4 / bison    prebuilts 里的 bison 是 32 位 ELF（需要 /lib/ld-linux.so.2），
#                 本机没有 32 位加载器，只能转调宿主自编的 bison。
#   ncurses5      部分老预编译 host 工具链依赖 libncurses.so.5 / libtinfo.so.5，
#                 系统只有 .so.6，靠 LD_LIBRARY_PATH 补。
#
# 允许用环境变量覆盖：
#   ARDBEG_TOOLCHAIN      宿主自编工具链目录（默认 /home/dy/ardbeg-tc）
#   ARDBEG_COMPAT_LIBS    兼容库目录（默认 /home/dy/tc-libs）
#   JAVA_HOME             JDK 8 路径（默认 /usr/lib/jvm/java-8-openjdk-amd64）

ARDBEG_TOOLCHAIN=${ARDBEG_TOOLCHAIN:-/home/dy/ardbeg-tc}
ARDBEG_COMPAT_LIBS=${ARDBEG_COMPAT_LIBS:-/home/dy/tc-libs}
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}
export ARDBEG_TOOLCHAIN ARDBEG_COMPAT_LIBS JAVA_HOME

# 本文件所在目录（= device/nvidia/ardbeg），envsetup.sh 保证 cwd 是源码树根
_ARDBEG_DEVICE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# PATH 顺序：设备树自带 host 工具 > 宿主工具链 > JDK > 系统
export PATH="$_ARDBEG_DEVICE_DIR/tools/hostbin:$ARDBEG_TOOLCHAIN/bin:$JAVA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$ARDBEG_COMPAT_LIBS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# AOSP 的 external/bison 用 $(M4) 生成 skeleton，指定成宿主 m4 免得落到别的版本
export M4="$ARDBEG_TOOLCHAIN/bin/m4"

# ---- jack：不走常驻 server，直接起 JVM 跑编译器 ----
#   prebuilts/sdk/tools/jack 第 74 行留了"无 server 模式"：
#       if [ "$JACK_SERVER" != "true" ]; then
#           exec $JACK_MAIN_COMMAND -jar $JACK_REPOSITORY/jack-$JACK_VERSION.jar "$@"
#   置 JACK_SERVER=false 后，编译器在**当前进程**里跑完，全程不监听、不连接
#   任何 socket，于是绕开了 jack server 1.3-a8 与本机 JDK 的 TLS 协商失败
#   （服务端日志 "No available cipher suite for TLS13/TLS12"，详见
#   BoardConfig.mk 第十五节）。
#
#   JACK_REPOSITORY 指向存放 jack-<版本>.jar 的目录。prebuilts/sdk/tools/jacks
#   下有三个版本，其中 jack-3.36.CANDIDATE.jar 正好等于 jack_versions.mk 里的
#   JACK_DOGFOOD_VERSION，也就是整包构建默认用的那个。
#
#   JACK_EXTRA_CURL_OPTIONS 是给 jack-admin 用 curl 访问 server 时跳过证书
#   校验的。server 模式已经不走了，这条留着只是万一有人把 JACK_SERVER 改回
#   true 时能少一层报错——但注意 -k 并不能真正解决问题。
export JACK_SERVER=false
export JACK_REPOSITORY="$(cd "$_ARDBEG_DEVICE_DIR/../../.." && pwd)/prebuilts/sdk/tools/jacks"
export JACK_EXTRA_CURL_OPTIONS="-k"

#   jack 走无 server 模式后，每个 Java 模块都要**冷启一个 JVM**，而 JVM 的默认
#   最大堆是物理内存的 1/4（本机 22 GiB → 单个 5.5 GiB）。-j12 时十几个 JVM
#   同时展开，直接触发内核 OOM killer，现象是 make 只打印一行
#       make: *** [build/core/ninja.mk:152: ninja_wrapper] 已终止
#   看不出任何原因（journalctl --user -u <unit> 里才写 oom-kill）。
#   这里显式限死单 JVM 堆，配合 -j8 左右即可稳定。
export JACK_MAIN_COMMAND="java -Xmx3g -Xms256m -Djava.io.tmpdir=/tmp -Dfile.encoding=UTF-8 -XX:+TieredCompilation"

# ---- 给 ninja 限并发 ----
#   build/core/ninja.mk 第 152 行用 $(NINJA_MAKEPARALLEL) 起 ninja，而
#   makeparallel 实测**不会**把 make 的 -j 传下去（ps 里看到的是光秃秃的
#   `ninja -C . -f out/build-cm_ardbeg.ninja`，没有 -j），ninja 于是退回默认值
#   nproc+2。本机 16 核 → 18 路并行，jack 无 server 模式下瞬间起十几个 JVM，
#   内存直接打爆；内核 OOM killer 把整个 make SIGTERM 掉，日志里只留一行
#   "已终止"，看不出任何原因（原因只在 journalctl --user -u <unit> 里）。
#
#   ninja.mk 里 NINJA_ARGS 只用 += 追加，所以从环境传进来的值会被保留。
#   6 路并行在 16 核上够用，也能把 jack 的 JVM 数量压住。
export NINJA_ARGS="-j6"

# ---- 手动 `make` 不编测试模块 ----
#   build/core/main.mk 第 1090 行附近有一段：
#
#       ifneq ($(ANDROID_NO_TEST_CHECK),true)
#       ...
#       droidcore : target-tests host-tests
#
#   也就是在 eng / userdebug 变体下，全量 `make`（默认目标 droid_targets）
#   会把树里所有 tests 标签的模块都编一遍：cts/ 各测试包、external/deqp、
#   external/skia 的 skia_dm、frameworks/base 下的 FrameworksCoreTests /
#   FrameworksServicesTests …
#
#   而 LineageOS 14.1 的测试目录长期跟着 AOSP 打补丁，很多测试代码来自
#   Android 8+，用到的类 / API 在 7.1 里并不存在。实测两例：
#
#     FrameworksCoreTests      import android.platform.test.annotations.AsbSecurityTest
#                              注解类全树没有（上游漏 backport）
#     FrameworksServicesTests  AccountManagerServiceTestFixtures 全树没有；
#                              String.join(CharSequence, Iterable) 是 API 26 才有的
#
#   这些模块上游本来就编不过，而且**不进 ROM**：它们装的是测试 APK，
#   `make otapackage` 从不编它们。所以直接关掉，省掉几十分钟无效编译，
#   也让「手动 make」这条路径可用。
#
#   需要编测试时（注意等号后面留空，把 true 覆盖掉）：
#       ANDROID_NO_TEST_CHECK= make tests
#   或者点名编某个测试模块：
#       make FrameworksCoreTests
export ANDROID_NO_TEST_CHECK=true

unset _ARDBEG_DEVICE_DIR

# ---- 自检：缺什么当场说清楚，别等编译到一半才炸 ----
_ardbeg_env_check() {
    if [ ! -x "$JAVA_HOME/bin/java" ]; then
        echo "vendorsetup: JAVA_HOME 无效: $JAVA_HOME" >&2
    fi

    if ! command -v python >/dev/null 2>&1 && ! command -v python2 >/dev/null 2>&1; then
        echo "vendorsetup: PATH 里没有 python2，7.1 的构建脚本会全部失败" >&2
    fi

    if [ ! -x "$ARDBEG_TOOLCHAIN/bin/bison" ]; then
        echo "vendorsetup: 缺少宿主 bison: $ARDBEG_TOOLCHAIN/bin/bison" >&2
    fi

    # JACK_SERVER 不是 true 时 jack 走无 server 模式，必须能直接找到编译器 jar，
    # 否则每个 Java 模块都会在 "Building with Jack" 这一步报 jar 不可读。
    if [ "${JACK_SERVER:-true}" != "true" ]; then
        _have_jar=0
        for _j in "$JACK_REPOSITORY"/jack-*.jar; do
            [ -r "$_j" ] && _have_jar=1 && break
        done
        if [ "$_have_jar" -eq 0 ]; then
            echo "vendorsetup: JACK_REPOSITORY 下没有可读的 jack-*.jar: $JACK_REPOSITORY" >&2
            echo "             JACK_SERVER=$JACK_SERVER 时 jack 必须直接跑 jar，见 BoardConfig.mk 第十五节" >&2
        fi
        unset _have_jar _j
    fi

    return 0
}
_ardbeg_env_check
unset -f _ardbeg_env_check
