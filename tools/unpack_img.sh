#!/usr/bin/env bash
# Unpack an Android boot/recovery image (v0/v1/v2 header).
# Usage: tools/unpack_img.sh <image> [outdir]
set -e

IMG="$1"
OUT="${2:-unpacked}"
mkdir -p "$OUT"

[ "$(head -c8 "$IMG")" = "ANDROID!" ] || { echo "Not an ANDROID! boot image"; exit 1; }

u32() { # offset -> little-endian uint32
  od -An -tu4 -j "$1" -N4 "$IMG" | tr -d ' '
}

KS=$(u32 8);  KA=$(u32 12)
RS=$(u32 16); RA=$(u32 20)
SS=$(u32 24); SA=$(u32 28)
TAGS=$(u32 32)
PAGE=$(u32 36)
HV=$(u32 40)
# offset 44 is os_version. DT(DTB) sizes live in v1/v2 header extensions:
# v1: recovery_dtbo_size @ 1632; v2: dtb_size @ 1648
DTS=0
if [ "$HV" = "2" ]; then DTS=$(u32 1648); fi

BASE=$(printf '0x%08x' $((KA - 0x8000)))
CMDLINE=$(dd if="$IMG" bs=1 skip=64 count=512 2>/dev/null | tr -d '\0')

echo "page_size         = $PAGE"
echo "kernel_size       = $KS  addr = $(printf '0x%08x' "$KA")"
echo "ramdisk_size      = $RS  addr = $(printf '0x%08x' "$RA")"
echo "second_size       = $SS  addr = $(printf '0x%08x' "$SA")"
echo "tags_addr         = $(printf '0x%08x' "$TAGS")"
echo "dtb_size          = $DTS"
echo "header_version    = $HV"
echo "BOARD_KERNEL_BASE := $BASE"
echo "cmdline           = $CMDLINE"

palign() { echo $(( ($1 + PAGE - 1) / PAGE * PAGE )); }

OFF=$PAGE
dd if="$IMG" of="$OUT/kernel.bin" bs=1M iflag=skip_bytes,count_bytes skip=$OFF count=$KS 2>/dev/null
OFF=$(( OFF + $(palign $KS) ))
dd if="$IMG" of="$OUT/ramdisk.cpio.bin" bs=1M iflag=skip_bytes,count_bytes skip=$OFF count=$RS 2>/dev/null
OFF=$(( OFF + $(palign $RS) ))
if [ "$SS" -gt 0 ]; then
  dd if="$IMG" of="$OUT/second.bin" bs=1M iflag=skip_bytes,count_bytes skip=$OFF count=$SS 2>/dev/null
fi
OFF=$(( OFF + $(palign $SS) ))
if [ "$HV" = "1" ] || [ "$HV" = "2" ]; then
  DTBO=$(u32 1632)
  OFF=$(( OFF + $(palign $DTBO) ))
fi
if [ "$DTS" -gt 0 ]; then
  dd if="$IMG" of="$OUT/dtb.img" bs=1M iflag=skip_bytes,count_bytes skip=$OFF count=$DTS 2>/dev/null || true
fi

# identify kernel format by magic
KMAGIC=$(od -An -tx1 -N8 "$OUT/kernel.bin" | tr -d ' \n')
case "$KMAGIC" in
  1f8b*)            mv "$OUT/kernel.bin" "$OUT/Image.gz";   echo "kernel: gzip (Image.gz)";;
  0221*)            mv "$OUT/kernel.bin" "$OUT/Image.lz4";  echo "kernel: lz4 (Image.lz4)";;
  894c5a4f*)        mv "$OUT/kernel.bin" "$OUT/Image.lzo";  echo "kernel: lzo (Image.lzo)";;
  4d5a*)            mv "$OUT/kernel.bin" "$OUT/Image";      echo "kernel: uncompressed Image";;
  *)                echo "kernel: unknown magic $KMAGIC (kept as kernel.bin)";;
esac

RMAGIC=$(od -An -tx1 -N2 "$OUT/ramdisk.cpio.bin" | tr -d ' \n')
if [ "$RMAGIC" = "1f8b" ]; then
  mv "$OUT/ramdisk.cpio.bin" "$OUT/ramdisk.cpio.gz"
  echo "ramdisk: gzip cpio -> extract with:  mkdir ramdisk && cd ramdisk && gzip -dc ../ramdisk.cpio.gz | cpio -i"
else
  echo "ramdisk: not gzip (magic $RMAGIC)"
fi
echo "Done -> $OUT"
