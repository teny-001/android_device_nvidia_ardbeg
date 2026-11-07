#!/bin/bash
# =============================================================================
# build.sh —— 用手工工具链打包 ArdbegIME.apk
#
# 为什么不用 `m LatinIME` / `mm`：
#   7.1 的构建系统要先 lunch、再编一整套 host 工具（ckati / aapt / jack ...），
#   而且本机 out/ 目录是空的。为了"让设备能打字"去跑一遍完整构建不值得。
#   这个 APK 只用四个预编译工具就能出来，全程几十秒：
#
#       aapt      打资源 + AndroidManifest      prebuilts/sdk/tools/linux/bin/aapt
#       javac     编 Java（JDK 8，-source 1.7）
#       dx        转 dex                       prebuilts/sdk/tools/lib/dx.jar
#       signapk   用平台证书签名                prebuilts/sdk/tools/lib/signapk.jar
#
# 必须用 -source 1.7 -target 1.7：
#   dx.jar 这一版只认到 class file 51（Java 7）。用 1.8 编出来的 class 52
#   会报 "PARSE ERROR: unsupported class file version 52.0"。
#   本项目的代码没有用 lambda / default method，降到 1.7 无损失。
#
# 必须在宿主机执行（容器里没有 java）：
#   flatpak-spawn --host bash "/home/dy/WorkBuddy AI/ardbeg-cm-14.1/mini-ime/build.sh"
# =============================================================================
set -e

SRC_TREE="/home/dy/WorkBuddy AI/2026-10-23-16-34-21/aosp-src"
# 脚本自己所在的目录（设备树里的 ime/）。这样把整个 ime/ 目录搬走也能编。
HERE="$(cd "$(dirname "$0")" && pwd)"

AAPT="$SRC_TREE/prebuilts/sdk/tools/linux/bin/aapt"
DX_JAR="$SRC_TREE/prebuilts/sdk/tools/lib/dx.jar"
SIGNAPK_JAR="$SRC_TREE/prebuilts/sdk/tools/lib/signapk.jar"
SIGNAPK_JNI="$SRC_TREE/prebuilts/sdk/tools/linux/lib64"
ANDROID_JAR="$SRC_TREE/prebuilts/sdk/25/android.jar"
KEY_PEM="$SRC_TREE/build/target/product/security/platform.x509.pem"
KEY_PK8="$SRC_TREE/build/target/product/security/platform.pk8"

JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}"
JAVA="$JAVA_HOME/bin/java"
JAVAC="$JAVA_HOME/bin/javac"

OUT="$HERE/out"
rm -rf "$OUT"
mkdir -p "$OUT/classes"

echo "== 1/5 检查工具 =="
for f in "$AAPT" "$DX_JAR" "$SIGNAPK_JAR" "$ANDROID_JAR" "$KEY_PEM" "$KEY_PK8"; do
    [ -f "$f" ] || { echo "缺少: $f"; exit 1; }
    echo "   OK  $f"
done

echo "== 2/5 aapt 打资源（生成不含 dex 的 APK） =="
"$AAPT" package -f \
    -M "$HERE/AndroidManifest.xml" \
    -S "$HERE/res" \
    -I "$ANDROID_JAR" \
    -F "$OUT/base.apk"

echo "== 3/5 javac 编 Java（-source 1.7 -target 1.7） =="
# 【必须给每行加引号】源码树路径里有空格（/home/dy/WorkBuddy AI/...），
# 而 javac 的 @argfile 是按空白切分参数的，不加引号会被拆成
#   javac: 无效的标记: /home/dy/WorkBuddy
# 用 -printf '"%p"\n' 让每行变成 "带空格路径"，javac 能正确识别。
find "$HERE/src" -name '*.java' -printf '"%p"\n' > "$OUT/sources.txt"
cat "$OUT/sources.txt"
"$JAVAC" -source 1.7 -target 1.7 -encoding UTF-8 \
    -bootclasspath "$ANDROID_JAR" \
    -classpath "$ANDROID_JAR" \
    -d "$OUT/classes" \
    @"$OUT/sources.txt"

echo "== 4/5 dx 转 dex 并塞进 APK =="
"$JAVA" -Xmx1g -jar "$DX_JAR" --dex --output="$OUT/classes.dex" "$OUT/classes"
ls -l "$OUT/classes.dex"
# aapt add 要在 classes.dex 所在目录执行，且参数用相对路径
( cd "$OUT" && "$AAPT" add base.apk classes.dex )

echo "== 5/5 用平台证书签名 =="
"$JAVA" -Xmx1g \
    -Djava.library.path="$SIGNAPK_JNI" \
    -jar "$SIGNAPK_JAR" \
    "$KEY_PEM" "$KEY_PK8" \
    "$OUT/base.apk" "$OUT/ArdbegIME.apk"

echo
echo "== 产物 =="
ls -l "$OUT/ArdbegIME.apk"
# 直接覆盖设备树里那份预编译 APK，避免手工拷贝时漏掉
cp -f "$OUT/ArdbegIME.apk" "$HERE/ArdbegIME.apk"
echo "已更新: $HERE/ArdbegIME.apk"
echo
echo "内容清单："
"$AAPT" list "$OUT/ArdbegIME.apk"
