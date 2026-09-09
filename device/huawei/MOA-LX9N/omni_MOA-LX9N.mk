#
# Product makefile for HUAWEI Honor 9A (MOA-LX9N) TWRP
#

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base.mk)

# TWRP common (omni tree)
$(call inherit-product, vendor/omni/config/common.mk)

PRODUCT_DEVICE := MOA-LX9N
PRODUCT_NAME := omni_MOA-LX9N
PRODUCT_BRAND := HUAWEI
PRODUCT_MODEL := Honor 9A
PRODUCT_MANUFACTURER := huawei
