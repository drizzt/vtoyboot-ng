#!/bin/bash
# Full test sequence for one VM: install, vanilla boots (UEFI+BIOS), kernel
# update check, then boot the vdisk through Ventoy (BIOS+UEFI).
#   run-matrix.sh NAME [FIRMWARE...]   (default: uefi bios)
# Needs sudo for add-vdisk.sh. Prints PASS/FAIL per step.
# single-quoted commands below are expanded on the guest, not here
# shellcheck disable=SC2016
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "${VMS}"
name=${1:?usage: $0 NAME [FIRMWARE...]}
shift
modes=${*:-uefi bios}
step() {
  cur=$*
  printf '== %s: %s\n' "${name}" "$*"
}
res() {
  if (($1 == 0)); then
    echo "PASS ${name}: $2"
  else
    echo "FAIL ${name}: $2"
    fail=1
  fi
}
fail=0
boot() { vm_boot "${name}" "$@"; }
off() {
  local tag
  tag=$(echo "${cur}" | tr ' ' -)
  vm_off "${name}" "${tag}"
}

# per-OS guest commands; the Linux defaults are overridden below
pre=
vanilla='! findmnt /run/ventoy >/dev/null && [ -z "$(losetup -ln)" ]'
mods='loop exfat ntfs3 vfat ext4 xfs udf nls_cp437 nls_iso8859-1'
mods+=' usb_storage uas xhci_pci xhci_hcd sd_mod'
# ostree roots are overlay/composefs: the block device shows up on /sysroot
ventoy='findmnt -no SOURCE /run/ventoy &&
  { findmnt -no SOURCE /; findmnt -no SOURCE /sysroot; } 2>/dev/null |
  grep -q "^/dev/loop0p"'
hardened='findmnt -no OPTIONS /run/ventoy | grep -q nosuid,nodev,noexec &&
  [ "$(stat -c %a /run/vtoyboot-ng)" = 700 ] &&
  [ "$(readlink /run/ventoy)" = /run/vtoyboot-ng/ventoy ]'
case ${name} in
  debian* | ubuntu*)
    reinst='apt-get install -y --reinstall linux-image-$(uname -r) '
    reinst+='>/dev/null 2>&1; lsinitramfs /boot/initrd.img-$(uname -r)'
    ;;
  fedora*)
    reinst='dnf -y reinstall kernel-core >/dev/null 2>&1; '
    reinst+='lsinitrd /boot/initramfs-$(uname -r).img'
    ;;
  opensuse*)
    reinst='zypper -n in -f kernel-default >/dev/null 2>&1; '
    reinst+='lsinitrd /boot/initrd-$(uname -r)'
    ;;
  arch*)
    reinst='pacman -S --noconfirm linux >/dev/null 2>&1; '
    reinst+='lsinitcpio /boot/initramfs-linux.img'
    ;;
  silverblue*)
    reinst='lsinitrd "$(ls -t /boot/ostree/*/initramfs-$(uname -r).img'
    reinst+=' | head -n1)"'
    ;;
  freebsd*)
    pre='ASSUME_ALWAYS_YES=yes pkg install bash >/dev/null 2>&1; '
    # no kernel reinstall: list the mfsroot instead of an initramfs
    reinst='zcat /boot/vtoyboot-ng/mfsroot.gz >/tmp/m; u=$(mdconfig -f /tmp/m)'
    reinst+='; mount -o ro /dev/$u /mnt; find /mnt; umount /mnt; '
    reinst+='mdconfig -d -u $u'
    mods=
    vanilla='! [ -e /dev/vtoy.nop ] && ! [ -e /dev/concat/vtoy ]'
    # the root sits on vtoy.nopp5 or, for a fragmented image, concat/vtoyp5
    ventoy='glabel status -s | grep -q "gpt/rootfs .*vtoy"'
    [[ ${name} == *zfs* ]] && ventoy='zpool status | grep -q vtoy'
    hardened=
    ;;
  *) reinst='false' ;;
esac

if [[ -z ${ONLY_VENTOY:-} ]]; then
  step "install"
  boot uefi \
    && vm_scp "${name}" -r "${REPO}/vtoyboot-ng" "${REPO}/hook" \
      "root@localhost:/root/vtoyboot-ng/" \
    && vm_ssh "${name}" \
      "${pre}"'cd /root/vtoyboot-ng && ./vtoyboot-ng install 2>&1 | tail -15'
  res $? "install"
  off

  for m in ${modes}; do
    step "vanilla ${m}"
    boot "${m}" && vm_ssh "${name}" "${vanilla}"
    res $? "vanilla ${m} boots without Ventoy mapping"
    if [[ ${m} == uefi ]]; then
      vm_ssh "${name}" "${reinst}" 2>/dev/null >"${VMS}/${name}.initramfs.lst"
      grep ventoy-map "${VMS}/${name}.initramfs.lst" >/dev/null
      res $? "kernel reinstall keeps the hook in the initramfs"
    fi
    if [[ ${m} == uefi && -n ${mods} ]]; then
      missing=$(vm_ssh "${name}" \
        'cat /lib/modules/$(uname -r)/modules.builtin' 2>/dev/null \
        | awk -v mods="${mods}" '
          {
            n = split($0, a, "/"); f = a[n]
            sub(/\.ko.*/, "", f); gsub(/-/, "_", f)
            have[f] = 1
          }
          END {
            gsub(/-/, "_", mods)
            split(mods, m, " ")
            for (i in m) if (!(m[i] in have)) printf "%s ", m[i]
          }' - "${VMS}/${name}.initramfs.lst")
      [[ -z ${missing} ]]
      res $? "initramfs has needed modules${missing:+ (missing: ${missing})}"
    fi
    off
  done

fi

step "vdisk"
sudo VMS="${VMS}" VDISK_FRAG="${VDISK_FRAG:-}" "${TEST}/add-vdisk.sh" \
  "${name}" \
  "${VDISK_FORMAT:-raw}" >/dev/null
res $? "vdisk copied to the Ventoy disk"

for m in ${modes}; do
  step "ventoy ${m}"
  boot "${m}" ventoy && vm_ssh "${name}" "${ventoy}"
  res $? "ventoy ${m} boots from the vdisk"
  if [[ -n ${hardened} ]]; then
    vm_ssh "${name}" "${hardened}"
    res $? "the Ventoy mount is hardened and root-only"
  else
    echo "SKIP ${name}: no Ventoy mount on this OS"
  fi
  if [[ ${m} == uefi ]]; then
    vm_ssh "${name}" 'cd /root/vtoyboot-ng && ./vtoyboot-ng install 2>&1' \
      >"${VMS}/${name}.reinstall.log"
    res $? "install re-run from the Ventoy boot is idempotent"
  fi
  off
done
exit "${fail}"
