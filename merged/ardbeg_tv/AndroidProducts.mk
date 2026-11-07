# 仅在非 CM_BUILD 模式（例如 `make product-graph`）下才会用到。
# 正常情况下 lunch cm_ardbeg_tv-eng 走 CM_BUILD=ardbeg_tv 的 find 路径，
# 直接读同目录的 lineage.mk。
PRODUCT_MAKEFILES := $(LOCAL_DIR)/lineage.mk
