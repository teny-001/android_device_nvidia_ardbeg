#
# vendorsetup.sh — 把 ardbeg 的 lunch 目标注册进菜单
#
# 7.1 的 build/envsetup.sh 会遍历 device/*/*/vendorsetup.sh 并 source 它，
# 所以这里只需要 add_lunch_combo。
#
# 【必须同时有 PRODUCT_MAKEFILES 里对应的产品】
#   add_lunch_combo 只是往菜单里加一行，真正解析产品还是靠
#   AndroidProducts.mk -> PRODUCT_MAKEFILES。两处不一致时，
#   lunch 能选但选完报 "Cannot locate config makefile"。
#

add_lunch_combo cm_ardbeg-eng
add_lunch_combo cm_ardbeg-userdebug
add_lunch_combo cm_ardbeg-user
add_lunch_combo cm_ardbeg_tv-eng
