#!/bin/bash
# Convert a VM disk to a vdisk inside the Ventoy partition and make it the
# auto-booted default (needs root).
#   add-vdisk.sh NAME [raw|vhd|vdi]
# VDISK_FRAG=1 lays the file out in two extents (the FreeBSD gconcat path).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "${VMS}"
name=${1:?usage: $0 NAME}
fmt=${2:-raw}
loop=$(losetup -fP --show "${VMS}/ventoy.img")
trap 'umount "$VMS/mnt" 2>/dev/null; losetup -d "$loop"' EXIT
mkdir -p "${VMS}/mnt"
mount "${loop}p1" "${VMS}/mnt"
mkdir -p "${VMS}/mnt/images" "${VMS}/mnt/ventoy"
img=${VMS}/mnt/images/${name}.vtoy
rm -f "${img}" "${VMS}/mnt/images/.spacer"
# written before the image: a json file allocated right behind it would
# split the next, slightly larger copy (a VHD) into two extents, and the
# default run is meant to be the single-extent case
cat >"${VMS}/mnt/ventoy/ventoy.json" <<EOT
{
  "control": [
    { "VTOY_MENU_TIMEOUT": "3" },
    { "VTOY_DEFAULT_IMAGE": "/images/${name}.vtoy" }
  ]
}
EOT
out=${img}
[[ -z ${VDISK_FRAG:-} ]] || out=${VMS}/${name}.vtoy.tmp
case ${fmt} in
  raw)
    qemu-img convert -O raw -S 0 "${VMS}/${name}.qcow2" "${out}"
    ;;
  # fixed VHD: raw data plus a 512-byte footer
  vhd)
    qemu-img convert -O vpc -o subformat=fixed,force_size=on \
      "${VMS}/${name}.qcow2" "${out}"
    ;;
  # Ventoy only accepts VirtualBox's own header text and assumes its
  # 2 MiB data offset, so rewrite szFileInfo and push the data out
  vdi)
    qemu-img convert -O vdi -o static=on "${VMS}/${name}.qcow2" \
      "${VMS}/${name}.vdi.tmp"
    off=$(od -An -v -t u4 -j 344 -N 4 "${VMS}/${name}.vdi.tmp" | tr -d ' \n')
    {
      head -c "${off}" "${VMS}/${name}.vdi.tmp"
      head -c $((2097152 - off)) /dev/zero
      tail -c "+$((off + 1))" "${VMS}/${name}.vdi.tmp"
    } >"${out}"
    rm -f "${VMS}/${name}.vdi.tmp"
    printf '\000\000\040\000' | dd of="${out}" bs=1 seek=344 conv=notrunc \
      status=none
    head -c 64 /dev/zero | dd of="${out}" bs=1 conv=notrunc status=none
    printf '<<< Oracle VM VirtualBox Disk Image >>>\n' \
      | dd of="${out}" bs=1 conv=notrunc status=none
    ;;
  *)
    echo "$0: unknown format ${fmt}" >&2
    exit 1
    ;;
esac
if [[ ${out} != "${img}" ]]; then
  # first half, a one-byte spacer that takes the next cluster, second half
  half=$(($(stat -c %s "${out}") / 2))
  head -c "${half}" "${out}" >"${img}"
  echo >"${VMS}/mnt/images/.spacer"
  tail -c "+$((half + 1))" "${out}" >>"${img}"
  rm -f "${out}"
fi
sync
ls -la "${VMS}/mnt/images"
