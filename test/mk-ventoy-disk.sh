#!/bin/bash
# Create a 40 GB sparse raw Ventoy disk for the VM tests (needs root).
#   mk-ventoy-disk.sh [VENTOY_DIR]
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"
mkdir -p "${VMS}"
VENTOY=${1:?ventoy dir}
IMG=${VMS}/ventoy.img

[[ -e ${IMG} ]] && {
  echo "${IMG} exists"
  exit 0
}
truncate -s 40G "${IMG}"
loop=$(losetup -f --show "${IMG}")
trap 'losetup -d "$loop"' EXIT
(cd "${VENTOY}" && printf 'y\ny\n' | sh Ventoy2Disk.sh -i "${loop}")
echo "Ventoy disk: ${IMG}"
