#!/bin/bash
# Create a test VM disk from a cloud image: root password "vtoy", ssh key,
# repo copied to /root/vtoyboot-ng, cloud-init disabled. FreeBSD images
# (freebsd* names) are left alone: libguestfs cannot write UFS, so a NoCloud
# seed ISO (vms/NAME.seed.iso, attached by vm.sh) does the same on first boot.
#   mk-vm.sh NAME [IMAGE]      (IMAGE defaults to vms/images/NAME.*)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "${VMS}"
name=${1:?usage: $0 NAME [IMAGE]}
img=${2:-}
if [[ -z ${img} ]]; then
  imgs=("${VMS}/images/${name}".*)
  img=${imgs[0]}
fi
[[ -e ${img} ]] || {
  echo "$0: no image for ${name} in ${VMS}/images" >&2
  exit 1
}
if [[ ${img} == *.xz ]]; then
  [[ -e ${img%.xz} ]] || xz -dk "${img}"
  img=${img%.xz}
fi
disk=${VMS}/${name}.qcow2
[[ -e ${disk} ]] && {
  echo "${disk} exists"
  exit 0
}
qemu-img convert -O qcow2 "${img}" "${disk}"
if [[ ${name} == freebsd* ]]; then
  seed=$(mktemp -d)
  printf 'instance-id: %s\nlocal-hostname: %s\n' "${name}" "${name}" \
    >"${seed}/meta-data"
  # nuageinit runs a user-data that is not #cloud-config as a script, once
  # sshd is up; root gets sh so the matrix commands parse
  cat >"${seed}/user-data" <<EOT
#!/bin/sh
mkdir -p /root/.ssh /root/vtoyboot-ng
echo '$(<"${HOME}/.ssh/id_ed25519.pub")' >/root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
pw usermod root -s /bin/sh
echo 'PermitRootLogin prohibit-password' >>/etc/ssh/sshd_config
service sshd restart
EOT
  chmod +x "${seed}/user-data"
  genisoimage -quiet -V CIDATA -J -r -o "${VMS}/${name}.seed.iso" "${seed}"
  rm -rf "${seed}"
  # the image is nearly full and its first boot runs freebsd-update: give
  # growfs room, and take that slow boot here rather than in the matrix
  qemu-img resize -q "${disk}" +8G
  "${TEST}/vm.sh" "${name}" uefi >/dev/null
  for i in $(seq 120); do
    # shellcheck disable=SC2310  # polling: failure is the expected case
    if vm_ssh "${name}" true 2>/dev/null; then break; fi
    ((i < 120)) || {
      echo "$0: ${name} did not come up with the ssh key" >&2
      exit 1
    }
    sleep 10
  done
  vm_off "${name}"
  echo "${disk}"
  exit 0
fi
virt-customize -a "${disk}" \
  --hostname "${name}" \
  --root-password password:vtoy \
  --ssh-inject root:file:"${HOME}/.ssh/id_ed25519.pub" \
  --run-command 'touch /etc/cloud/cloud-init.disabled; ssh-keygen -A;
    rm -f /var/lib/YaST2/reconfig_system' \
  --upload "${TEST}/dhcp.network:/etc/systemd/network/80-vtoy-dhcp.network" \
  --run-command 'systemctl is-enabled NetworkManager 2>/dev/null ||
    systemctl enable systemd-networkd' \
  --copy-in "${REPO}:/root" \
  --run-command "[ -d /root/vtoyboot-ng ] ||
    mv '/root/$(basename "${REPO}")' /root/vtoyboot-ng"
echo "${disk}"
