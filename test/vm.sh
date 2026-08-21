#!/bin/bash
# Start/stop a test VM.
# shellcheck disable=SC2054
#   vm.sh NAME bios|uefi|secboot [ventoy]   start, daemonized
#                                           (serial log in vms/NAME.serial)
#   vm.sh NAME stop
#   vm.sh NAME ssh [CMD...]
#   vm.sh NAME key KEY...                  send keys via the qemu monitor
# "ventoy" boots from the Ventoy USB disk instead of the VM's own disk.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "${VMS}"
name=${1:?usage: $0 NAME bios|uefi|secboot|stop|ssh|key [ARG...]}
mode=${2:-}
pid=${VMS}/${name}.pid mon=${VMS}/${name}.mon

case ${mode} in
  stop)
    [[ -e ${pid} ]] && kill "$(<"${pid}")" 2>/dev/null
    rm -f "${pid}"
    exit 0
    ;;
  ssh)
    shift 2
    vm_ssh "${name}" "$@"
    exit $?
    ;;
  key)
    shift 2
    for k in "$@"; do
      echo "sendkey ${k}" | socat - "unix-connect:${mon}" >/dev/null
      sleep 0.3
    done
    exit 0
    ;;
  *) ;;
esac

[[ -e ${pid} ]] && kill -0 "$(<"${pid}")" 2>/dev/null && {
  echo "${name} already running"
  exit 1
}
mach=q35
[[ ${mode} == secboot ]] && mach=q35,smm=on
args=(-enable-kvm -machine "${mach}" -cpu host -m 2048 -smp 2 -display none
  -serial "file:${VMS}/${name}.serial" -monitor "unix:${mon},server,nowait"
  -pidfile "${pid}" -daemonize
  -netdev "user,id=n,hostfwd=tcp:127.0.0.1:$(vm_port "${name}")-:22"
  -device virtio-net-pci,netdev=n)
case ${mode} in
  bios) ;;
  uefi | secboot)
    code=${OVMF}/OVMF_CODE.fd vars=${OVMF}/OVMF_VARS.fd
    [[ ${mode} == secboot ]] \
      && code=${OVMF}/OVMF_CODE.secboot.fd vars=${OVMF}/OVMF_VARS.secboot.fd
    [[ -e ${VMS}/${name}.vars.fd ]] || cp "${vars}" "${VMS}/${name}.vars.fd"
    args+=(-drive "if=pflash,format=raw,readonly=on,file=${code}"
      -drive "if=pflash,format=raw,file=${VMS}/${name}.vars.fd")
    [[ ${mode} == secboot ]] \
      && args+=(-global driver=cfi.pflash01,property=secure,value=on
        -global ICH9-LPC.disable_s3=1)
    ;;
  *)
    echo "usage: $0 NAME bios|uefi|secboot [ventoy]" >&2
    exit 1
    ;;
esac
if [[ ${3:-} == ventoy ]]; then
  # qemu's xhci emulation and FreeBSD's umass do not get along (the probe
  # INQUIRY and reads over 128 KB fail with "CCB request completed with an
  # error"; real xhci hardware is fine): that guest gets a USB 2.0 port
  hc=qemu-xhci
  [[ ${name} == freebsd* ]] && hc=usb-ehci
  args+=(-device "${hc}"
    -drive "if=none,id=vt,file=${VMS}/ventoy.img,format=raw"
    -device usb-storage,drive=vt,removable=on)
else
  args+=(-drive "file=${VMS}/${name}.qcow2,if=virtio")
fi
# FreeBSD first-boot seed (mk-vm.sh); inert once /firstboot is gone
[[ -e ${VMS}/${name}.seed.iso ]] && args+=(-drive
  "file=${VMS}/${name}.seed.iso,media=cdrom,if=ide,readonly=on")
: >"${VMS}/${name}.serial"
qemu-system-x86_64 "${args[@]}"
port=$(vm_port "${name}")
echo "${name} started (${mode}${3:+ $3}), ssh port ${port}"
