#
# AndroidProducts.mk — 把 ardbeg 的产品入口注册给 build 系统
#
# 【7.1 与 cm-11 的区别（这一处不改，lunch 直接失败）】
#   cm-11 里可以写 `cm_ardbeg:$(LOCAL_DIR)/lineage.mk` 这种"名字:路径"形式，
#   7.1 的 build/core/product_config.mk **不支持**它：它把 PRODUCT_MAKEFILES
#   的每一项都当文件路径直接 include，带冒号就变成不存在的文件名，报
#       Cannot locate config makefile for product "cm_ardbeg:..."
#   所以这里只列路径，产品名由各 .mk 里的 PRODUCT_NAME 决定。
#
# 两个产品：
#   lineage.mk    -> cm_ardbeg      平板/盒子形态（eng 默认）
#   lineage_tv.mk -> cm_ardbeg_tv   Android TV 形态
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/lineage.mk \
    $(LOCAL_DIR)/lineage_tv.mk
