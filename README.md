# vtoyboot-ng

Make a Linux or FreeBSD installation inside a vdisk file (raw, fixed VHD,
fixed VDI) bootable from [Ventoy](https://www.ventoy.net), without the workarounds of the
[original vtoyboot](https://github.com/ventoy/vtoyboot): no vendored binaries,
no device-mapper tricks, no patched kernel modules, no grub-probe wrappers,
no shim swapping.

## How it works

At boot Ventoy passes a 512-byte `ventoy_os_param` block to the guest (ACPI
table `VTOY` on BIOS and on UEFI with Secure Boot, EFI variable `VentoyOsParam`
on UEFI without Secure Boot). It contains the GUID/signature of the USB disk,
the partition number and the path of the vdisk file. On BIOS machines where
the `VTOY` table does not reach the kernel (seen with SeaBIOS on coreboot),
the block is read through `/dev/mem` from the base memory Ventoy's iPXE
leaves it in, as upstream `vtoydump` does.

`ventoy-map.sh`, run from the initramfs, reads that block, finds the USB disk,
mounts the Ventoy partition read-write at `/run/ventoy` and runs
`losetup -P` on the vdisk file. The kernel then exposes `/dev/loop0pN`, udev
creates the usual `by-uuid` / `by-partuuid` links and the rest of the boot
proceeds exactly as on real hardware: `root=UUID=...`, systemd device units,
LUKS, LVM and fstab all resolve unchanged. On a normal boot the script finds
no Ventoy data and exits immediately.

`/run` survives `switch-root`, so the Ventoy partition stays available at
`/run/ventoy` in the running system. The mount itself lives under a
root-only directory (`/run/vtoyboot-ng/`) that `/run/ventoy` points at, and
is made with `nosuid,nodev,noexec`: the vdisk file is a byte-for-byte image
of the root filesystem, so leaving it readable by every local user would hand
them `/etc/shadow` and every other protected file on the system. See
[Security](#security).

The installer also makes the disk bootable by both firmwares (Ventoy may boot
a vdisk from a BIOS or a UEFI machine regardless of how it was installed):

- **grub**: installs the i386-pc target on the disk (adding a BIOS boot
  partition to GPT disks when missing) and, on BIOS-only systems with an ESP,
  the removable x86_64-efi target. If the distro's `grub.cfg` uses
  `linuxefi`/`initrdefi`, a tiny `/etc/grub.d/01_vtoyboot_linuxefi` defines
  them for the BIOS build.
- **systemd-boot**: left untouched for UEFI; grub i386-pc is installed as the
  BIOS companion with a generated `grub.cfg`.
- **limine**: `limine bios-install`, and `BOOTX64.EFI` copied to the ESP if
  missing.
- **shim**: `BOOTX64.EFI` (shim) is kept so the Secure Boot chain stays
  intact. The distro's signed `grubx64.efi` is copied next to it and
  `fbx64.efi` is renamed, so shim loads grub directly instead of
  `fallback.efi`, which would create NVRAM entries and reboot in a loop.
  `--keep-fallback` skips this.

Nothing else in the grub configuration is touched.

### FreeBSD

There is no initramfs, the base system has no exFAT or NTFS driver, and
`reboot -r` (the only way to switch roots) unmounts everything, which would
take an `md` over a file on the Ventoy partition with it. So on FreeBSD the
Ventoy partition is never mounted. Along with `ventoy_os_param` Ventoy also
hands over the list of disk extents the vdisk file occupies on the stick,
whatever the filesystem. `gnop create -o OFFSET -s SIZE` maps a contiguous
file (one extent) straight onto the USB disk as `/dev/vtoy.nop`; a
fragmented one gets a nop per extent and `gconcat` glues them into
`/dev/concat/vtoy`. `g_part` tastes either and `/dev/vtoy.nopp5` (or
`/dev/concat/vtoyp5`), `/dev/gpt/rootfs` and the rest appear as they would
on any disk.

The script runs from a small UFS image (`/boot/vtoyboot-ng/mfsroot.gz`,
built from the system's own `sh`, `dd`, `od`, `kenv`, `geom`, `efivar`...
and their libraries) that the loader preloads as `md0`. The kernel only
falls back to it when the root named in `/etc/fstab` is missing, which is
what a Ventoy boot looks like before the mapping: its `/etc/rc` maps the
vdisk and `reboot -r`s onto the unchanged `vfs.root.mountfrom`. On a normal
boot the real root mounts first and the mfsroot is never entered.

What differs from Linux: there is no `/run/ventoy`; the stick's own
partitions (`da0p1`, `da0p2`) wither while the vdisk root is mounted
read-write, because GEOM gives the nop's writer exclusive access to `da0`
(they come back once it is unmounted); swap from the vdisk
(`/dev/gpt/swapfs` in the official images) lands on the stick, inside the
image file, as everything else does.

## Install

```sh
git clone https://github.com/drizzt/vtoyboot-ng
cd vtoyboot-ng
sudo ./vtoyboot-ng install            # or: install --keep-fallback
```

Then convert the disk to a raw image (`qemu-img convert -O raw -S 0`) and
copy it to the Ventoy partition, or run the installer directly inside the
system when it is already booted through Ventoy. FreeBSD needs
`pkg install bash` first.

Everything installed lives under `/etc` plus two files on the ESP, so it
works on read-only `/usr` (Silverblue, Kinoite, secureblue...) and is picked
up automatically by every future kernel update:

| initramfs generator | files |
|---|---|
| dracut | `/etc/dracut.conf.d/90-vtoyboot-ng.conf`, `/etc/systemd/system/ventoy-map.service` |
| mkinitcpio | `/etc/initcpio/{install,hooks}/ventoy`, `/etc/mkinitcpio.conf.d/vtoyboot-ng.conf` |
| initramfs-tools | `/etc/initramfs-tools/hooks/ventoy`, `/etc/initramfs-tools/scripts/local-block/ventoy` |
| FreeBSD (mfsroot) | `/boot/vtoyboot-ng/mfsroot.gz`, `/boot/loader.conf.d/vtoyboot-ng.conf` |

On rpm-ostree systems the installer enables `rpm-ostree initramfs` (client
side initramfs regeneration) and creates a new deployment; reboot into it.

`vtoyboot-ng refresh` re-applies what package updates can revert (the shim
fixup on the ESP and the systemd-boot companion `grub.cfg`). It is wired to
pacman, apt and `kernel-install`; on Fedora/openSUSE re-run it manually after
a shim update. On FreeBSD it rebuilds the mfsroot: its binaries and
`geom_nop.so`/`geom_concat.so` are frozen copies of the base system, so run
it after a major upgrade.

`vtoyboot-ng uninstall` removes all files and restores `fbx64.efi`. The BIOS
boot code and partition are left in place, they are harmless.

## Requirements

- `losetup` from util-linux (busybox's lacks `--sizelimit`), `od`, `udevadm`.
- The `exfat` kernel module (Ventoy's partition is exFAT). Ubuntu's cloud
  kernels ship it in `linux-modules-extra-$(uname -r)`; the installer stops
  and says so when it is missing. Trimmed kernels like openSUSE's
  `kernel-default-base` (Minimal-VM images) lack `ntfs3`, `udf` and `uas`:
  fine for an exFAT stick on a non-UAS port, otherwise install the full
  `kernel-default`. Missing modules are skipped per kernel at initramfs
  build time, so a later kernel that does have them picks them up on its
  own, without re-running the installer.
- grub i386-pc modules for BIOS boot: `grub-pc-bin` (Debian/Ubuntu),
  `grub2-pc-modules` (Fedora), `grub2-i386-pc` (openSUSE), `grub` (Arch).
  The installer tells you which package is missing.
- The vdisk file must end in `.vtoy`, whatever is inside it. Ventoy only
  routes that suffix to the vdisk boot path; it then sniffs the content and
  accepts raw, fixed VHD and fixed VDI. A `.vhd` goes to the Windows vhdboot
  path instead, and any other suffix is not listed in the menu at all. Ventoy
  recommends keeping the real format visible before it (`fedora.img.vtoy`,
  `arch.vhd.vtoy`); only the trailing `.vtoy` is matched, the rest is for you.
- FreeBSD 13.0 or newer with `bash` from ports, `/` mounted by label
  (`/dev/gpt/rootfs` as in the official VM images, or `ufs/`, `ufsid/`,
  `label/`): a Ventoy boot sees the disk as `vtoy.nop`, so a plain
  `/dev/ada0p2` in fstab cannot be found. The installer refuses such a root
  and says how to label it (`gpart modify -l rootfs -i N DISK`). The stick
  must have 512-byte sectors. ZFS roots go through the same path
  (`gptzfsboot`, the pool's disk is detected) but are untested.
- The vdisk must be fully allocated (Ventoy reads raw sectors). Use a raw
  image (`qemu-img convert -O raw -S 0`); fixed VHD and fixed VDI are the
  same bytes with a footer/header and only matter if VirtualBox or Hyper-V
  must open the file too. VDI files written by qemu do not boot in Ventoy at
  all: Ventoy only accepts VirtualBox's own header text
  (`<<< Oracle VM VirtualBox Disk Image >>>` or
  `<<< Oracle VirtualBox Disk Image >>>`, qemu writes its own) and hardcodes
  a 2 MiB data offset instead of reading the header, while qemu starts the
  data right after the block map. `test/add-vdisk.sh vdi` patches both.

## Out of scope

- dynamic VHD/VDI.
- dracut images without systemd (the hook is a systemd unit).
- Creating an ESP on a disk that has none.
- bootc images without rpm-ostree: add the `/etc` files from the table above
  to the Containerfile instead.
- systemd-boot with the `kernel-install` layout (`/boot/<machine-id>/...`):
  grub-mkconfig does not find those kernels, only `/boot/vmlinuz-*` layouts
  are covered (Fedora's BLS layout works through `blscfg`).
- On FreeBSD: MBR-scheme disks (no BIOS boot code installed), roots mounted
  by device name instead of label, DragonFly and the other BSDs.

## Notes

- Ventoy decides "this vdisk is BIOS-bootable" by scanning the GPT for a
  BIOS boot partition and stops at the first empty slot. Images whose BIOS
  boot partition has a high number (Debian cloud images use 14) get a
  "created in UEFI mode" warning on BIOS machines; press Enter, it boots.
  FreeBSD disks have a `freebsd-boot` partition instead, which Ventoy does
  not count: the installer adds an empty one-track `bios-boot` partition in
  gap before the first partition when the table has one (the official VM
  images start their `freebsd-boot` at sector 34 and have none), otherwise
  the same warning shows up and Enter boots it.
- A machine with FreeBSD on an internal disk and the same labels
  (`gpt/rootfs`) on the vdisk gets two providers for one label; glabel keeps
  the first one it saw and the Ventoy boot may end up on the wrong root.
  Relabel one of them.
- LUKS/LVM roots work unchanged: the vdisk partitions appear before the
  distro's own crypt/LVM handling runs (with mkinitcpio the `ventoy` hook is
  inserted right after `block`).
- Discards on the loop device are disabled so the image never gets holes
  punched into it; Ventoy needs the file contiguous.
- Files: `vtoyboot-ng` (installer, bash) and `hook/` (runtime script, POSIX
  sh, plus the per-generator glue). `test/` holds the qemu based test
  helpers; `test/param-test.sh` checks the parameter block parsing and
  validation on its own, with no VM and no root.
- The installer refuses to run when `/` spans more than one disk (md or LVM
  over several members): there is no way to tell which one the firmware
  boots, and writing BIOS boot code to an arbitrary member is worse than
  writing none. It also saves the partition table to
  `/etc/vtoyboot-ng/parttable.bak` before adding a BIOS boot partition.

## Security

- The vdisk is not authenticated. Secure Boot verifies shim, grub and, on
  distros that enforce it, the kernel; the initramfs (and therefore
  `ventoy-map.sh`) is not signed on any of the layouts here except UKIs, and
  the image file sits on a removable partition that anyone with physical
  access can modify offline. Treat a Ventoy-booted system as exposed to
  whoever holds the stick, and encrypt the root filesystem inside the vdisk
  if that matters.
- Installing a BIOS boot chain next to the UEFI one and booting through
  Ventoy changes the PCR values. TPM-sealed LUKS keys and remote attestation
  stop matching, and unsealing will need the recovery passphrase.
- The Ventoy partition is parsed by the kernel, for the whole session. The
  initramfs mounts it read-write (the loop file has to be writable) with the
  in-kernel exfat, ntfs3, ext4, xfs, btrfs or vfat driver, and the mount has
  to stay for as long as the loop device does, so every metadata update and
  every access to `/run/ventoy` keeps feeding that driver whatever is on the
  stick. This is not a physical-access risk: whoever can write to the
  partition can also patch Ventoy itself or the vdisk, which is your
  unauthenticated root filesystem, and Ventoy has already parsed the same
  filesystem in its own preboot environment before any of this runs. It
  matters when the boot chain is intact but the filesystem is not: a hostile
  image someone handed you, or plain corruption from a bad stick or a yanked
  write. Do not boot from media you would not mount.
- `ventoy-map.sh` acts only on a parameter block with a valid `VENTOY_GUID`
  and checksum, refuses an image path that is not absolute or contains `..`,
  and refuses to boot at all when two disks answer to the same Ventoy disk
  GUID and signature rather than picking one by enumeration order. The first
  two checks are what `test/param-test.sh` exercises. The original validates
  the same block and refuses the same ambiguous disk case; reimplementing it
  in shell loses none of that.
- On FreeBSD a fragmented vdisk needs several nops over the same USB disk,
  and GEOM normally refuses the second writer on a disk. The hook sets bit
  16 of `kern.geom.debugflags` (the "foot-shooting" flag) for that boot
  only when the image has more than one extent, and the flag has to stay
  for the session: every later open re-runs the check. Its only effect is in
  that check, on whole disks: root may then open a disk for writing while
  partitions on it are mounted, the guard that stops a stray `dd if=...
  of=/dev/da0`. Contiguous images never touch the flag.
- The shim fixup does not weaken Secure Boot: `BOOTX64.EFI` stays shim,
  `fbx64.efi` is only renamed, and `01_vtoyboot_linuxefi` is scoped to
  `$grub_platform = pc`, so the UEFI `linuxefi` verification path is
  untouched.

### Compared to the original vtoyboot

The threat model above is the same for both projects: neither authenticates
the vdisk, and both change the measured boot. What differs is the footprint
on the installed system.

- **Secure Boot.** The original renames the ESP's `bootx64.efi` (shim) to
  `bootx64.efi_VTBK` and puts `grubx64.efi` in its place, which takes shim
  and MOK verification out of the chain. vtoyboot-ng keeps shim as
  `BOOTX64.EFI` and only renames `fbx64.efi`; it also puts back a shim the
  original had replaced.
- **grub binaries.** The original moves the real `grub-probe` and
  `grub-editenv` aside and installs shell wrappers that replay cached output
  from `/etc/vtoyboot/probe/`, permanently. vtoyboot-ng leaves both alone.
- **Files under `/usr`.** The original installs `vtoydump`, `vtoypartx` and
  `vtoytool` into `/bin` or `/sbin` and its initramfs modules under
  `/usr/lib`. vtoyboot-ng writes only under `/etc` and on the ESP, and
  records every path in `/etc/vtoyboot-ng/created` so `uninstall` can replay
  it.
- **Configuration rewritten and never restored.** The original injects
  `exit 0` into `/etc/grub.d/30_os-prober`, forces
  `GRUB_ENABLE_BLSCFG=false` and edits `GRUB_TIMEOUT` in
  `/etc/default/grub`. vtoyboot-ng adds `01_vtoyboot_linuxefi` and nothing
  else.
- **Which disk gets written.** Three of the four `dd` writes that install the
  original's BIOS boot chain go to a hardcoded `/dev/sda`, whatever disk it
  resolved. vtoyboot-ng writes to the detected disk and refuses to run at all
  when `/` spans more than one.
- **The other direction**: the original never mounts the partition. It parses
  exFAT in userspace and maps the file's extents with device-mapper, so a
  malformed filesystem hits its own parser instead of a kernel driver, and
  nothing stays mounted afterwards. That parser also runs as root in the
  initramfs, so the difference is narrower than it looks, but the exposure is
  one shot rather than the whole session. Dropping that machinery, and the
  vendored binaries and per-filesystem parsers it needs, is the point of the
  rewrite; the kernel mount is the price.

## Tested

qemu/KVM, Ventoy 1.1.17, OVMF and SeaBIOS, each system booted vanilla and
from the Ventoy disk in both firmware modes, plus a kernel reinstall to
check the hook survives:

| system | initramfs | bootloader | notes |
|---|---|---|---|
| Debian 13 | initramfs-tools | grub | BIOS boot partition is #14, Ventoy warns once (see Notes) |
| Ubuntu 24.04 | initramfs-tools | grub + shim | needs `linux-modules-extra` on the cloud kernel |
| Fedora 44 | dracut | grub2 + shim | |
| Fedora Silverblue 44 (bootc install) | dracut via rpm-ostree | grub2 + shim | `/boot` is read-only, remounted during install |
| openSUSE Tumbleweed | dracut | grub2 + shim | `kernel-default-base` lacks ntfs3/udf/uas |
| Arch | mkinitcpio (systemd hooks) | grub | |
| Arch | mkinitcpio (systemd hooks) | systemd-boot | grub i386-pc companion for BIOS |
| Arch | mkinitcpio (systemd hooks) | limine | |
| FreeBSD 14.3 (UFS) | mfsroot | loader.efi + gptboot | no `/run/ventoy`, see above; raw and fixed VHD, contiguous and fragmented |
| FreeBSD 14.3 (ZFS) | mfsroot | loader.efi + gptzfsboot | as above; the pool is imported from the nop after the reroot |
| openSUSE Tumbleweed, ThinkPad T480s (libreboot, SeaBIOS) | dracut | grub2 | real hardware, BIOS only; the `VTOY` table never reaches the kernel, the block is read from `/dev/mem` |

Ventoy partition formats exercised on Fedora 44, both firmware modes: exFAT,
NTFS, XFS, btrfs, ext2, ext3, ext4. Vdisk formats, same VM: raw, fixed VHD,
fixed VDI.

UDF does not work, and the bug is on Ventoy's side. In
`ventoy_get_block_list()` the running `sector` counter is shared by two
loops: UDF is the only filesystem that takes the generic extent walk *and*
the UDF fixup loop, which leaves `sector` at the image length, and the loop
that renumbers a `.img`/`.vhd`/`.vhdx`/`.vtoy` file then starts from that
value instead of 0. Every chunk is offset by the whole file, image sector 0
matches nothing, and Ventoy reads garbage where the partition table should
be: `No bootfile found for UEFI!` in UEFI mode, the same in BIOS mode.
ISOs are unaffected, since only the fixup loop runs for them. Present in
1.1.17 and still in upstream master; a one-line `sector = 0` before the
second loop fixes it. Nothing to work around from this side, so use any of
the formats above instead. UDF is also slow to write: 5m13s for the 5 GB
image here, against 15s on exFAT, nearly all of it system time in the
kernel's per-block allocation.

On real hardware: secureblue (Kinoite, LUKS root, composefs) from a UEFI
laptop.
`test/run-matrix.sh` is the script behind the table.

The FreeBSD VM gets the Ventoy stick on an EHCI port: qemu's xhci emulation
and FreeBSD's `umass` do not get along (the probe `INQUIRY` and every read
over 128 KB fail with `CCB request completed with an error`), which has
nothing to do with Ventoy; real xhci controllers are fine.

Secure Boot could not be exercised in qemu: with Secure Boot enabled in OVMF,
Ventoy 1.1.17's own grub crashes (`NULL pointer dereference` in the firmware
log) before any vdisk is reached. The chain that matters on the vdisk side,
shim as `BOOTX64.EFI` loading the distro's signed `grubx64.efi`, is the
distro's stock one and is left intact.

## Hacking

Every shell script here follows the Google shell style guide, and the five
files that run inside the initramfs or the mfsroot (`hook/ventoy-map.sh`,
`hook/mkinitcpio-hook`, `hook/initramfs-tools-hook`,
`hook/initramfs-tools-block`, `hook/freebsd-rc`) are POSIX `sh`, because
the initramfs shell is dash or busybox ash, never bash.

`.pre-commit-config.yaml` enforces all of that:

```sh
dnf install ShellCheck shfmt devscripts pre-commit   # or the local equivalent
pre-commit install
```

It runs `shellcheck -xo all`, `shfmt -i 2 -ci -bn`, an 80-column check, and
`checkbashisms` on the five POSIX files. `pre-commit run --all-files` checks
everything at once.

`test/param-test.sh` is the only test that needs neither a VM nor root: it
bind-mounts a synthetic ACPI `VTOY` table inside a user namespace and checks
that `hook/ventoy-map.sh` rejects a bad GUID, a bad checksum, and an image
path that would escape the Ventoy mount. Run it after touching the hook.

## License

GPL-3.0, like Ventoy.
