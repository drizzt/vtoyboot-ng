#!/bin/bash
# Check that ventoy-map.sh only acts on a real ventoy_os_param block, and
# rejects an image path that would escape the Ventoy mount.  No VM, no root:
# a user namespace bind-mounts a fake VTOY table over the real one.
#   param-test.sh
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

[[ -d /sys/firmware/acpi/tables ]] || {
  echo "SKIP: no ACPI tables on this host"
  exit 0
}
unshare -rm true 2>/dev/null || {
  echo "SKIP: no unprivileged user namespaces"
  exit 0
}

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# mkblock MODE PATH: a 512-byte ventoy_os_param on stdout.  MODE is ok,
# badguid or badsum.
mkblock() {
  python3 - "$1" "$2" <<-'PY'
		import struct, sys
		mode, path = sys.argv[1], sys.argv[2].encode()
		p = bytearray(512)
		# VENTOY_GUID, little-endian, reads as "  www.ventoy.net"
		p[0:16] = b"x" * 16 if mode == "badguid" else b"  www.ventoy.net"
		p[17:33] = bytes(range(16))          # disk guid
		struct.pack_into("<H", p, 41, 1)     # partition id
		struct.pack_into("<H", p, 43, 0)     # exfat
		p[45:45 + len(path)] = path
		struct.pack_into("<Q", p, 429, 1 << 20)
		p[481:485] = b"\xde\xad\xbe\xef"     # disk signature
		# checksum: all 512 bytes must sum to zero mod 256
		p[16] = ((-sum(p)) & 0xff) ^ (1 if mode == "badsum" else 0)
		sys.stdout.buffer.write(bytes(p))
	PY
}

# mkparam MODE PATH: the block behind a 36-byte ACPI header, as the firmware
# hands it over
mkparam() {
  {
    printf VTOY
    head -c 32 /dev/zero
    mkblock "$1" "$2"
  } >"${tmp}/tables/VTOY"
}

# mkmem PATH: conventional memory (0-0xA0000) with the block where iPXE leaves
# it: 16-byte aligned, here below the 0x80000 vtoydump starts scanning at
mkmem() {
  {
    head -c $((0x7E010)) /dev/zero
    mkblock ok "$1"
    head -c $((0xA0000 - 0x7E010 - 512)) /dev/zero
  } >"${tmp}/mem"
}

# run MODE PATH: run the hook against that block, echo its output
run() {
  mkdir -p "${tmp}/tables"
  mkparam "$1" "$2"
  # tmpfs over /run: the fake root cannot write the real one.  The timeout
  # bounds the disk search a valid block runs into, which cannot succeed here.
  # paths go in as arguments: a repo path with a quote in it would
  # otherwise break the command sh -c parses
  # shellcheck disable=SC2016  # expanded by the inner sh, not here
  timeout 10 unshare -rm sh -c '
		mount --bind "$1" /sys/firmware/acpi/tables &&
		mount -t tmpfs none /run &&
		sh "$2"' sh "${tmp}/tables" "${REPO}/hook/ventoy-map.sh" 2>&1
}

# run_mem PATH: no VTOY table, no efivars, the block only in /dev/mem
run_mem() {
  mkdir -p "${tmp}/empty"
  mkmem "$1"
  # shellcheck disable=SC2016
  timeout 10 unshare -rm sh -c '
		mount --bind "$1" /sys/firmware/acpi/tables &&
		{ ! [ -d /sys/firmware/efi ] || mount -t tmpfs none /sys/firmware/efi; } &&
		mount --bind "$2" /dev/mem &&
		mount -t tmpfs none /run &&
		sh "$3"' sh "${tmp}/empty" "${tmp}/mem" "${REPO}/hook/ventoy-map.sh" 2>&1
}

fail=0
check() { # check DESC EXPECTED_REGEX ACTUAL
  if printf '%s\n' "$3" | grep -qE "$2"; then echo "PASS $1"; else
    echo "FAIL $1: expected /$2/, got: ${3:-<no output>}"
    fail=1
  fi
}

out=$(run badguid /images/x.vtoy)
check "a block with the wrong GUID is ignored" '^$' "${out}"

out=$(run badsum /images/x.vtoy)
check "a block with a bad checksum is ignored" '^$' "${out}"

out=$(run ok 'images/x.vtoy')
check "a relative image path is rejected" 'not absolute' "${out}"

out=$(run ok '/images/../../etc/shadow')
check "a traversing image path is rejected" 'contains \.\.' "${out}"

# a valid block gets as far as looking for the disk, which is not there
out=$(run ok /images/x.vtoy)
check "a valid block is parsed and the disk searched" \
  'image /images/x.vtoy' "${out}"

if [[ -e /dev/mem ]]; then
  out=$(run_mem /images/x.vtoy)
  check "a block left in base memory is parsed" 'image /images/x.vtoy' "${out}"
else
  echo "SKIP a block left in base memory is parsed: no /dev/mem"
fi

exit "${fail}"
