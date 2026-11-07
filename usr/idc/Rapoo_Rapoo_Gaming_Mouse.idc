# ardbeg: Rapoo 游戏鼠标（复合 HID 设备）
#
# 它的第二个接口声明支持 scancode 16，被 Generic.kl 映射成 KEY_Q，
# 导致 EventHub 把它判成字母键盘 -> config.keyboard=qwerty ->
# LatinIME.onEvaluateInputViewShown() 返回 false -> 软键盘永远弹不出来。
#
# 换成不含字母映射的空键表。鼠标按键/滚轮不依赖键表，不受影响。
keyboard.layout = ardbeg-nokeyboard
