#!/bin/sh
# Expose the Ventoy vdisk this system was booted from as a block device: a
# loop device on Linux (run from the initramfs: dracut / mkinitcpio /
# initramfs-tools), a gnop over the USB disk on FreeBSD (run from the
# mfsroot). Does nothing when the machine was not booted through Ventoy.

set -u

os=$(uname -s)
# Linux: real mount point; /run/ventoy is a symlink to it (see the mount below)
mnt=/run/vtoyboot-ng/ventoy
vtoy_guid=77772020-2e77-6576-6e74-6f792e6e6574
case ${os} in
  FreeBSD) param=/tmp/ventoy-os-param ;;
  *) param=/run/ventoy-os-param ;;
esac

log() { echo "ventoy-map: $*" >&2; }
# unmount, or the mount guard below would make the next attempt exit early
fail() {
  log "$*"
  [ "${os}" = Linux ] && umount "${mnt}" 2>/dev/null
  exit 1
}

# rd TYPE OFFSET LEN: field of ventoy_os_param (offsets from vtoydump.h)
rd() { od -An -v -t "$1" -j "$((skip + $2))" -N "$3" "${src}" | tr -d ' \n'; }
# mem ADDR LEN: bytes of physical memory
mem() { dd if=/dev/mem bs=1 skip="$1" count="$2" 2>/dev/null; }

# VENTOY_GUID little-endian, then the checksum (all 512 bytes sum to 0), the
# same two tests vtoy_check_os_param() does
valid_param() {
  guid=$(rd x1 0 16)
  [ "${guid}" = 20207777772e76656e746f792e6e6574 ] || return 1
  sum=0
  for b in $(od -An -v -t u1 -j "${skip}" -N 512 "${src}"); do
    sum=$((sum + b))
  done
  [ $((sum & 255)) -eq 0 ]
}

# ----------------------------------------------------- parameter block --
# ventoy_os_param: 512 bytes, from the VTOY ACPI table (BIOS, UEFI+SecureBoot)
# or from an EFI variable (UEFI without SecureBoot). Both leave it in ${src}
# at offset ${skip}.

linux_acquire() {
  grep -qs " ${mnt} " /proc/mounts && exit 0
  acpi=/sys/firmware/acpi/tables/VTOY
  efivar=/sys/firmware/efi/efivars/VentoyOsParam-${vtoy_guid}
  if [ -e "${acpi}" ]; then
    src=${acpi} skip=36
  else
    [ -d /sys/firmware/efi/efivars ] || {
      mem_acquire
      return
    }
    grep -qs ' /sys/firmware/efi/efivars ' /proc/mounts || {
      modprobe -q efivarfs 2>/dev/null
      mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null
    }
    [ -e "${efivar}" ] || exit 0
    src=${efivar} skip=4
  fi
  # efivarfs/sysfs files are not seekable: work on a plain copy
  (
    umask 077
    cat "${src}" >"${param}"
  )
}

# BIOS boot without a VTOY table (seen with SeaBIOS on coreboot, where the
# RSDP grub rewrites does not reach the kernel): Ventoy's iPXE also copies the
# block, 16-byte aligned, into the base memory it hides from the OS as
# reserved, which /dev/mem may read. Scan all of it for the GUID, as vtoydump
# does; zero-filled System RAM pages cannot match.
mem_acquire() {
  [ -e /dev/mem ] || return 0
  src=${param} skip=0
  dd if=/dev/mem bs=4096 skip=1 count=159 2>/dev/null | od -An -v -t x1 \
    | grep -n '^ 20 20 77 77 77 2e 76 65 6e 74 6f 79 2e 6e 65 74$' \
    | (
      umask 077
      while IFS=: read -r l _; do
        mem $((4096 + (l - 1) * 16)) 512 >"${param}"
        valid_param && exit 0
      done
      rm -f "${param}"
    )
}

# No sysfs: the table is found through the XSDT (8-byte entries) or the RSDT
# (4-byte entries) the loader passed on (acpi.* since 14, hint.acpi.0.*
# before), and read from /dev/mem. The ACPI table carries the image location
# list inline after the 512 bytes; the EFI variable passes its address
# instead (fetched in bsd_map, once validated).
bsd_acquire() {
  [ -e /dev/vtoy.nop ] || [ -e /dev/concat/vtoy ] && exit 0
  skip=0
  w=8 sdt=$(kenv -q acpi.xsdt 2>/dev/null \
    || kenv -q hint.acpi.0.xsdt 2>/dev/null)
  [ $((${sdt:-0})) -ne 0 ] || w=4 sdt=$(kenv -q acpi.rsdt 2>/dev/null \
    || kenv -q hint.acpi.0.rsdt 2>/dev/null)
  if [ $((${sdt:-0})) -ne 0 ]; then
    sdt=$((sdt))
    len=$(mem $((sdt + 4)) 4 | od -An -v -t u4 | tr -d ' \n')
    i=36
    while [ "${i}" -lt "${len:-0}" ]; do
      a=$(mem $((sdt + i)) "${w}" | od -An -v -t "u${w}" | tr -d ' \n')
      i=$((i + w))
      sig=$(mem "${a}" 4)
      [ "${sig}" = VTOY ] || continue
      len=$(mem $((a + 4)) 4 | od -An -v -t u4 | tr -d ' \n')
      mem $((a + 36)) $((len - 36)) >"${param}"
      return 0
    done
  fi
  [ -e /dev/efi ] || exit 0
  efivar -pbN -n "${vtoy_guid}-VentoyOsParam" >"${param}" 2>/dev/null || exit 0
}

case ${os} in
  Linux) linux_acquire ;;
  FreeBSD) bsd_acquire ;;
  *) exit 0 ;;
esac
[ -s "${param}" ] || exit 0
src=${param}
trap 'rm -f "${param}"' EXIT

# The block comes from the firmware: check it is really one before acting on
# it.
valid_param || exit 0

disk_guid=$(rd x1 17 16)
part_id=$(rd u2 41 2)
fs_type=$(rd u2 43 2)
img_size=$(rd u8 429 8)
disk_sig=$(rd x1 481 4)
img_path=$(tail -c +$((skip + 46)) "${src}" | head -c 384 | tr -d '\0')
# the path is used under /run/ventoy: it must stay there
case ${img_path} in
  /*) ;;
  *) fail "image path is not absolute" ;;
esac
case ${img_path} in
  *..*) fail "image path contains .." ;;
  *) ;;
esac

log "image ${img_path} (${img_size} bytes) on partition ${part_id}"

# ---------------------------------------------------------- Ventoy disk --

# candidate disk names, without /dev/
disks() {
  if [ "${os}" = FreeBSD ]; then
    sysctl -n kern.disks
    return
  fi
  for d in /sys/block/*; do
    n=${d##*/}
    case ${n} in
      loop* | ram* | dm-* | sr* | zram* | nbd* | fd* | md*) continue ;;
      *) ;;
    esac
    [ -e "/dev/${n}" ] && echo "${n}"
  done
}

# dev_hex NAME OFFSET LEN: hex bytes of the first sector of /dev/NAME, empty
# when unreadable (FreeBSD disks only take sector-aligned reads)
dev_hex() {
  dd if="/dev/$1" bs=512 count=1 2>/dev/null \
    | od -An -v -t x1 -j "$2" -N "$3" 2>/dev/null | tr -d ' \n'
}

# echo the matching disk, return 2 when several match: a cloned GUID would
# otherwise decide by enumeration order which image the machine boots
find_disk() {
  found=
  for n in $(disks); do
    dev_guid=$(dev_hex "${n}" 384 16)
    [ "${dev_guid}" = "${disk_guid}" ] || continue
    dev_sig=$(dev_hex "${n}" 440 4)
    [ "${dev_sig}" = "${disk_sig}" ] || continue
    found="${found} ${n}"
  done
  # shellcheck disable=SC2086
  set -- ${found}
  [ $# -eq 0 ] && return 1
  [ $# -gt 1 ] && return 2
  echo "$1"
}

i=0
until disk=$(find_disk); do
  [ $? = 2 ] && fail "several disks match the Ventoy disk GUID"
  i=$((i + 1))
  if [ "${i}" -gt 30 ]; then
    log "Ventoy disk not found"
    exit 1
  fi
  # settle returns as soon as the queue is momentarily empty, which happens
  # before the USB disk is enumerated: wait a real second every round
  udevadm settle -t 2 2>/dev/null || :
  sleep 1
done

# -------------------------------------------------------------- mapping --

linux_map() {
  opts=
  case ${fs_type} in
    0) fs=exfat ;;
    1) fs=ntfs3 opts=force ;;
    2) fs=ext4 ;;
    3) fs=xfs ;;
    4) fs=udf ;;
    5) fs=vfat ;;
    6) fs=btrfs ;;
    *) fs= ;;
  esac
  # shellcheck disable=SC2086,SC2248  # a deliberately split module list
  modprobe -qa loop ${fs:-exfat ntfs3 ext4 xfs udf vfat btrfs} 2>/dev/null

  part=
  for p in "/sys/block/${disk}/${disk}"*; do
    [ -f "${p}/partition" ] || continue
    read -r pn <"${p}/partition"
    [ "${pn}" = "${part_id}" ] && {
      part=${p##*/}
      break
    }
  done
  if [ -z "${part}" ]; then
    log "partition ${part_id} of ${disk} not found"
    exit 1
  fi

  # The partition is untrusted removable media and the image file on it is a
  # byte-for-byte copy of this system's root filesystem, readable by anyone
  # who can reach it. Mount it under a root-only directory: that works
  # whatever the filesystem is, unlike umask= (only for the ones without unix
  # permissions) or a chmod, which would alter the stick itself. /run/ventoy
  # stays as the documented path.
  mkdir -p "${mnt}"
  chmod 0700 /run/vtoyboot-ng
  # a real directory there would turn the symlink into /run/ventoy/ventoy, and
  # an existing symlink would do the same: busybox ln has no -n, so remove it
  rm -f /run/ventoy 2>/dev/null || :
  rmdir /run/ventoy 2>/dev/null || :
  ln -s "${mnt}" /run/ventoy
  # shellcheck disable=SC2086
  if ! mount ${fs:+-t ${fs}} -o "noatime,nosuid,nodev,noexec${opts:+,${opts}}" \
    "/dev/${part}" "${mnt}"; then
    log "cannot mount /dev/${part}"
    exit 1
  fi

  img=${mnt}${img_path}
  [ -f "${img}" ] || fail "${img} not found"

  # raw: offset 0; fixed VHD: 512-byte footer; VDI: data offset from the
  # header (2 MiB for VirtualBox images, which is what Ventoy itself assumes).
  set -- -P -f --show
  vhd_tag=$(tail -c 512 "${img}" | head -c 8)
  vdi_tag=$(od -An -v -t x1 -j 64 -N 4 "${img}" | tr -d ' \n')
  if [ "${vhd_tag}" = conectix ]; then
    set -- "$@" --sizelimit $((img_size - 512))
  elif [ "${vdi_tag}" = 7f10dabe ]; then
    vdi_off=$(od -An -v -t u4 -j 344 -N 4 "${img}" | tr -d ' \n')
    set -- "$@" --offset "${vdi_off}"
  fi

  loop=$(losetup --direct-io=on "$@" "${img}" 2>/dev/null) \
    || loop=$(losetup "$@" "${img}") \
    || fail "losetup failed"
  # never punch holes into the image: Ventoy needs it contiguous
  echo 0 >"/sys/block/${loop#/dev/}/queue/discard_max_bytes" 2>/dev/null
  udevadm settle -t 10 2>/dev/null
  log "${img} mapped to ${loop}"
}

# leave nothing behind, so a retry is not blocked by the nops of this one
nop_fail() {
  # shellcheck disable=SC2086
  [ -z "${nops}" ] || gnop destroy ${nops}
  fail "$@"
}

# The Ventoy partition is never mounted (reroot would kill an md over it).
# The ventoy_image_location list after the parameter block says where the
# file sits on the stick: guid[16], image sector size u32, disk sector size
# u32, region count u32, then {count u32, image start u32, disk start u64}.
# A contiguous file is one region, mapped straight onto the disk with gnop
# as /dev/vtoy.nop; a fragmented one gets a nop per region and a gconcat
# over them, /dev/concat/vtoy. g_part tastes either, so the p* partitions
# and the gpt/ labels appear.
bsd_map() {
  addr=$(rd u8 437 8)
  len=$(rd u4 445 4)
  [ "${addr}" -eq 0 ] || mem "${addr}" "${len}" >>"${src}"
  loc_guid=$(rd x1 512 16)
  [ "${loc_guid}" = 20207777772e76656e746f792e6e6574 ] \
    || fail "no image location list"
  img_ss=$(rd u4 528 4)
  disk_ss=$(rd u4 532 4)
  [ "${img_ss}" = 512 ] && [ "${disk_ss}" = 512 ] \
    || fail "only 512-byte sectors are supported"
  n=$(rd u4 536 4)
  [ "${n}" -ge 1 ] || fail "empty image location list"
  # Every nop passes the root's write-exclusive open down to the disk, and
  # g_access() refuses a second such opener on a provider. Bit 16 of
  # kern.geom.debugflags drops that check on rank-1 providers (the disks
  # themselves), nothing else; it must stay set, later opens run the check
  # again.
  [ "${n}" -eq 1 ] || {
    flags=$(sysctl -n kern.geom.debugflags)
    sysctl "kern.geom.debugflags=$((flags | 16))" >/dev/null \
      || fail "cannot set kern.geom.debugflags"
  }
  i=0 pos=0 nops=
  while [ "${i}" -lt "${n}" ]; do
    off=$((540 + i * 16))
    count=$(rd u4 "${off}" 4)
    img_start=$(rd u4 $((off + 4)) 4)
    start=$(rd u8 $((off + 8)) 8)
    [ "${img_start}" -eq "${pos}" ] || nop_fail "unexpected region order"
    pos=$((pos + count))
    size=$((count * 512))
    name=vtoy
    [ "${n}" -eq 1 ] || name=vtoy${i}
    i=$((i + 1))
    # fixed VHD: drop the footer, or the backup GPT header is misplaced
    # (a VDI header is already trimmed by Ventoy)
    if [ "${i}" -eq "${n}" ]; then
      vhd_tag=$(dd if="/dev/${disk}" bs=512 skip=$((start + count - 1)) \
        count=1 2>/dev/null | head -c 8)
      [ "${vhd_tag}" = conectix ] && size=$((size - 512))
    fi
    gnop create -Z "${name}" -o $((start * 512)) -s "${size}" "/dev/${disk}" \
      || nop_fail "gnop failed"
    nops="${nops} ${name}.nop"
  done
  dev=/dev/vtoy.nop
  [ "${n}" -eq 1 ] || {
    # shellcheck disable=SC2086
    gconcat create vtoy ${nops} || nop_fail "gconcat failed"
    dev=/dev/concat/vtoy
  }
  log "${img_path} mapped to ${dev} (${n} extents)"
}

case ${os} in
  Linux) linux_map ;;
  FreeBSD) bsd_map ;;
  *) ;;
esac
