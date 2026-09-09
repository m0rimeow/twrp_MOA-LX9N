#
# Product makefile for HUAWEI Honor 9A (MOA-LX9N) TWRP
#

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base.mk)

# TWRP common
$(call inherit-product, vendor/twrp/config/common.mk)

PRODUCT_DEVICE := MOA-LX9N
PRODUCT_NAME := twrp_MOA-LX9N
PRODUCT_BRAND := HUAWEI
PRODUCT_MODEL := Honor 9A
PRODUCT_MANUFACTURER := huawei

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/prebuilt/Image.gz:kernel

PRODUCT_PROPERTY_OVERRIDES += \
    ro.hardware.keystore=androidsoft
