# shellcheck shell=bash
set -o pipefail
# shared by the test scripts
# CDPATH= keeps a cd that would echo its target out of $TEST
# shellcheck disable=SC1007
TEST=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(dirname "${TEST}")
# $VMS is not created here: sourcing a library must not touch the disk.
# The scripts that write into it create it themselves.
VMS=${VMS:-$(dirname "${REPO}")/vms}
# shellcheck disable=SC2034
OVMF=${OVMF:-${VMS}/ovmf40/usr/share/OVMF}
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes)

# a stable per-VM ssh port
vm_port() {
  local sum
  sum=$(printf %s "$1" | cksum | cut -d' ' -f1)
  echo $((2200 + sum % 200))
}
vm_ssh() {
  local name=$1 port
  shift
  port=$(vm_port "${name}")
  ssh "${SSH_OPTS[@]}" -p "${port}" root@localhost "$@"
}
vm_scp() {
  local name=$1 port
  shift
  port=$(vm_port "${name}")
  scp -q "${SSH_OPTS[@]}" -P "${port}" "$@"
}

# vm_boot NAME bios|uefi [ventoy]: start the VM and wait for ssh, pressing
# Enter for the Ventoy menu while it is still booting
vm_boot() {
  local i
  rm -f "${VMS}/$1.vars.fd"
  "${TEST}/vm.sh" "$@" >/dev/null || return 1
  for i in $(seq 48); do
    vm_ssh "$1" true 2>/dev/null && return 0
    [[ ${3:-} == ventoy ]] && ((i <= 6)) && "${TEST}/vm.sh" "$1" key ret
    sleep 5
  done
  echo "   (no ssh, serial tail:)"
  strings "${VMS}/$1.serial" | tail -5 | sed 's/^/   /'
  return 1
}

# vm_off NAME [TAG]: power off and wait for qemu to exit, keeping the serial
# log under TAG when given
vm_off() {
  if [[ -n ${2:-} ]]; then cp "${VMS}/$1.serial" "${VMS}/$1.serial.$2"; fi
  vm_ssh "$1" poweroff 2>/dev/null
  local qemu_pid
  for _ in $(seq 60); do
    qemu_pid=$(cat "${VMS}/$1.pid" 2>/dev/null) || return 0
    kill -0 "${qemu_pid}" 2>/dev/null || return 0
    sleep 1
  done
  "${TEST}/vm.sh" "$1" stop
  # the kill is asynchronous and the next start needs the image lock
  for _ in $(seq 30); do
    kill -0 "${qemu_pid}" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "${qemu_pid}" 2>/dev/null || :
}
