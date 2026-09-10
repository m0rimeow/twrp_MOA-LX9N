#!/usr/bin/env bash
# Build TWRP for Honor 9A (MOA-LX9N) inside an amd64 Ubuntu container.
# Target host: Apple Silicon Mac (M4 Pro) running Docker Desktop or OrbStack
# with Rosetta enabled, e.g.:
#   docker run --rm -it --platform linux/amd64 \
#     -v /path/to/twrp_MOA-LX9N:/tree -v twrp-src:/twrp -v twrp-ccache:/ccache \
#     -w /tree ubuntu:22.04 bash tools/build_in_container.sh
set -e

JOBS=${JOBS:-$(nproc)}
TWRP_DIR=${TWRP_DIR:-/twrp}
CCACHE_DIR=${CCACHE_DIR:-/ccache}
BRANCH=twrp-9.0
DEVICE_PATH=device/huawei/MOA-LX9N
LUNCH=omni_MOA-LX9N-eng

if [ ! -f /twrp/.deps-done ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git-core gnupg flex bison build-essential zip \
    curl zlib1g-dev gcc-multilib g++-multilib libc6-dev-i386 libncurses5 \
    lib32ncurses-dev x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev \
    libxml2-utils xsltproc unzip fontconfig python3 ccache bc \
    python2 libpython2-stdlib libtinfo5 perl \
    libssl-dev lz4 libncurses-dev gperf pngcrush schedtool rsync repo
  ln -sf /usr/bin/python2 /usr/bin/python || true
  mkdir -p "$TWRP_DIR" "$CCACHE_DIR"
  touch /twrp/.deps-done
fi

export USE_CCACHE=1 CCACHE_DIR
ccache -M 20G || true

cd "$TWRP_DIR"
if [ ! -d .repo ]; then
  repo init -u https://github.com/minimal-manifest-twrp/platform_manifest_twrp_omni.git -b "$BRANCH" --depth=1
fi
repo sync -c -j"$JOBS" --no-tags --no-clone-bundle

mkdir -p "$DEVICE_PATH"
rsync -a --delete /tree/$DEVICE_PATH/ "$DEVICE_PATH/"

export ALLOW_MISSING_DEPENDENCIES=true
source build/envsetup.sh
lunch "$LUNCH"
mka recoveryimage -j"$JOBS"

OUT=out/target/product/MOA-LX9N
mkdir -p /tree/out

bash /tree/tools/unpack_img.sh "$OUT/recovery.img" /tmp/repack
K=/tmp/repack/Image.gz; [ -f "$K" ] || K=/tree/$DEVICE_PATH/prebuilt/Image.gz
R=/tmp/repack/ramdisk.cpio.gz; [ -f "$R" ] || R=/tmp/repack/ramdisk.cpio.bin
perl /tree/tools/repack_img.pl /tree/out/twrp-3.x-MOA-LX9N.img "$K" "$R" \
  /tree/$DEVICE_PATH/prebuilt/dtb.img \
  "bootopt=64S3,32N2,64N2 androidboot.selinux=permissive androidboot.hardware=mt6765 unmovable_isolate1=2:256M,3:312M,4:348M buildvariant=user" \
  0x40078000 2048 0x8000 0x11a88000 0xf88000 0x7808000 0x7808000
ls -la /tree/out/
echo "DONE: /tree/out/twrp-3.x-MOA-LX9N.img"
