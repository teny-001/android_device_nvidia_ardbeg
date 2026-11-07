#!/system/bin/sh
# =============================================================================
# mouse_helper.sh —— 通过 /dev/input/event1 注入真实鼠标事件（调试用）
#
# 用途：在没有物理鼠标 / 需要精确落点时，闭环地把指针移到指定坐标再点击。
#
#   mouse_helper.sh pos                 打印当前指针坐标
#   mouse_helper.sh move <x> <y>        闭环移动到 (x,y)
#   mouse_helper.sh click <x> <y>       移动到 (x,y) 后左键单击
#   mouse_helper.sh rclick <x> <y>      移动到 (x,y) 后右键单击
#   mouse_helper.sh wheel <n>           滚轮 n 格（正=下）
#
# 为什么要闭环：Android 7.1 的 CursorInputMapper 开了指针加速
# （PointerVelocityControlParameters: lowThreshold=500, highThreshold=3000,
# acceleration=3.0），一次注入大位移会被放大数倍，落点无法预测。
# 所以每步只走 12px（低于 lowThreshold，不触发加速），走完读回真实坐标再修正。
#
# 注意：Sprite 图层的 pos 是 (指针坐标 - hotspot)，hotspot 在图标左上角，
# 实测约 (0,0)，所以直接用即可。
# =============================================================================

D=/dev/input/event1

getpos() {
    dumpsys SurfaceFlinger 2>/dev/null \
        | grep -A 14 '(Sprite)' \
        | grep -o 'pos=([0-9.]*, *[0-9.]*)' \
        | head -1 \
        | sed 's/pos=(//; s/)//; s/,/ /'
}

emit() {
    sendevent $D $1 $2 $3
}

syn() {
    sendevent $D 0 0 0
}

case "$1" in
pos)
    getpos
    ;;
move|click|rclick)
    # ★ 必须先把动作名存下来：下面循环里的 `set -- $(getpos)` 会覆盖 $1/$2/$3
    act=$1
    tx=$2
    ty=$3
    i=0
    while [ $i -lt 80 ]; do
        set -- $(getpos)
        [ -z "$1" ] && break
        cx=${1%.*}
        cy=${2%.*}
        dx=$((tx - cx))
        dy=$((ty - cy))
        ax=${dx#-}
        ay=${dy#-}
        if [ "$ax" -le 8 ] && [ "$ay" -le 8 ]; then
            break
        fi
        sx=0; sy=0
        [ "$dx" -gt 8 ]  && sx=12
        [ "$dx" -lt -8 ] && sx=-12
        [ "$dy" -gt 8 ]  && sy=12
        [ "$dy" -lt -8 ] && sy=-12
        emit 2 0 $sx
        emit 2 1 $sy
        syn
        i=$((i+1))
    done
    echo "pos: $(getpos)  (steps=$i)"

    if [ "$act" = "click" ] || [ "$act" = "rclick" ]; then
        btn=272
        [ "$act" = "rclick" ] && btn=273
        emit 1 $btn 1; syn
        emit 1 $btn 0; syn
        echo "clicked btn=$btn"
    fi
    ;;
wheel)
    n=${2:-1}
    i=0
    while [ $i -lt ${n#-} ]; do
        if [ "${n#-}" = "$n" ]; then
            emit 2 8 -1     # REL_WHEEL 向上
        else
            emit 2 8 1      # REL_WHEEL 向下
        fi
        syn
        i=$((i+1))
    done
    echo "wheel $n done"
    ;;
*)
    echo "usage: $0 pos | move <x> <y> | click <x> <y> | rclick <x> <y> | wheel <n>"
    ;;
esac
