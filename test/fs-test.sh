#!/bin/bash
# Reformat the Ventoy data partition with another filesystem, copy a VM's
# vdisk back and boot it through Ventoy (BIOS + UEFI).  Needs sudo.
#   fs-test.sh NAME exfat|ntfs|udf|xfs|btrfs|ext2|ext3|ext4|vfat
# Restores nothing: run with exfat to go back (mkfs.exfat from exfatprogs).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "${VMS}"
name=${1:?usage: $0 NAME exfat|ntfs|udf|xfs|btrfs|ext2|ext3|ext4|vfat}
fs=${2:?usage: $0 NAME exfat|ntfs|udf|xfs|btrfs|ext2|ext3|ext4|vfat}
loop=$(sudo losetup -fP --show "${VMS}/ventoy.img")
case ${fs} in
  exfat) sudo mkfs.exfat -q -L Ventoy "${loop}p1" ;;
  ntfs) sudo mkfs.ntfs -Q -q -L Ventoy "${loop}p1" ;;
  ext2 | ext3 | ext4) sudo "mkfs.${fs}" -q -F -L Ventoy "${loop}p1" ;;
  udf)
    sudo mkfs.udf --media-type=hd --udfrev=0x0201 -l Ventoy \
      "${loop}p1" >/dev/null
    ;;
  xfs) sudo mkfs.xfs -q -f -L Ventoy "${loop}p1" ;;
  # single profile, no compression: Ventoy needs both
  btrfs) sudo mkfs.btrfs -q -f -L Ventoy "${loop}p1" ;;
  vfat) sudo mkfs.vfat -n VENTOY "${loop}p1" >/dev/null ;;
  *)
    sudo losetup -d "${loop}"
    echo "$0: unknown filesystem ${fs}" >&2
    exit 1
    ;;
esac
sudo losetup -d "${loop}"
echo "== ${name}: Ventoy partition formatted ${fs}"
ONLY_VENTOY=1 "${TEST}/run-matrix.sh" "${name}"
