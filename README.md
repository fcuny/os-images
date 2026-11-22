# os-images

Working examples of image-based Linux systems: a read-only `/usr` checked by dm-verity, A/B updates, and automatic rollback. They go with the notes on [fcuny.net](https://fcuny.net/notes/).

For now there is one example, built with [mkosi](https://github.com/systemd/mkosi). A bootc example will follow.

## What the mkosi image does

The image is Fedora 45 for arm64, built with mkosi v27.1.

- The disk ships with an ESP, one `/usr` partition (erofs) and its verity hash partition. It has no root partition.
- The UKI's command line carries `usrhash=`, which mkosi adds. Its two halves are the partition UUIDs of `/usr` and of its verity data, so the UKI picks its own `/usr`.
- On first boot, systemd-repart in the initrd adds an empty second `/usr` slot and creates a btrfs root, which holds `/etc` and `/var`.
- `/etc` starts empty. systemd-tmpfiles links most of it back to a copy of the build's `/etc` inside `/usr/share/factory/etc`.
- `systemd-sysupdate` downloads a new `/usr` into the empty slot and a new UKI with 3 boot tries.
- A health gate (`demo-gate.service`) must pass before `boot-complete.target`. If it fails, the machine reboots. After 3 failed tries, systemd-boot goes back to the previous version.
- A boot that gets stuck also reboots. If the initrd or the system lands in emergency mode, `demo-stuck-boot-reboot.service` reboots after 30 seconds. It only runs while a version is being assessed (the boot entry has a counter), so a version already marked good can't reboot in a loop. Rebooting is what lets systemd-boot count the failed try.
- A kernel panic reboots after 10 seconds (`panic=10`). A hardware watchdog (`RuntimeWatchdogSec=30s`) reboots a hung kernel or PID 1. The watchdog doesn't help with emergency mode, since PID 1 is still running there and keeps the watchdog fed.

The layout follows systemd's [ParticleOS](https://github.com/systemd/particleos), without image signing.

## Layout

- `mkosi/`: the mkosi configuration.
  - `mkosi.repart/`: partitions created at build time.
  - `mkosi.extra/usr/lib/repart.d/`: partitions created at first boot.
  - `mkosi.extra/usr/lib/sysupdate.d/`: what an update downloads, and where it writes it.
  - `mkosi.initrd.conf/`: extra configuration for mkosi's default initrd.
  - `variants/broken-gate/`: an extra tree that makes the health gate fail, to test rollback.
- `scripts/`: build in a Linux VM, boot on the Mac, serve updates.

## Requirements

- macOS on Apple silicon.
- [c2vm](https://github.com/fcuny/c2vm) 0.2 or later, for builds. Set `C2VM` if the right one isn't first on your `PATH`.
- qemu from Homebrew (`brew install qemu`), which ships the edk2 UEFI firmware.

The build runs in a c2vm VM, since mkosi needs Linux. The image boots on the Mac itself with qemu and Apple's hypervisor (`-accel hvf`). Booting inside c2vm would need nested virtualization, which only M3 and later chips have.

## Walkthrough

Start the build VM in one terminal and leave it running:

```sh
scripts/workbench
```

Build two versions. The first build also builds mkosi's tools tree, which takes several minutes. Later builds take under a minute.

```sh
scripts/build 1
scripts/build 2
```

Serve updates in a second terminal, and publish version 2:

```sh
scripts/serve
scripts/publish 2
```

Boot version 1 from a fresh disk in a third terminal:

```sh
scripts/vm-reset 1
scripts/vm-start
```

Then update and reboot:

```sh
scripts/vm-wait
scripts/vm-ssh updatectl update
scripts/vm-ssh systemctl reboot
scripts/vm-wait
scripts/vm-ssh 'grep IMAGE_VERSION /usr/lib/os-release; bootctl list'
```

To watch a rollback, build a version whose health gate fails, publish it, and update to it:

```sh
scripts/build 3 --extra-tree=/work/src/variants/broken-gate
scripts/publish 3
scripts/vm-ssh updatectl update
scripts/vm-ssh systemctl reboot
```

The VM reboots three times by itself, marks version 3 bad (`demo_3+0-3.efi`), and comes back on version 2. The console is in `.state/vm/console.log`.

To watch a stuck boot, publish an update whose UKI can't find its `/usr`. Renaming the `/usr` file gives the partition a UUID that doesn't match the UKI's `usrhash=`:

```sh
scripts/publish 2
cd .state/updates
mv demo_2.usr-arm64.*.raw demo_2.usr-arm64.00000000000000000000000000000bad.raw
shasum -a 256 demo_* > SHA256SUMS
```

Then update and reboot as above. Each try waits for `/usr`, lands in emergency mode, and reboots 30 seconds later. After the third try, systemd-boot boots the previous version. It took about 4.5 minutes in our tests.

## Not done yet

- **Update files aren't signed.** The transfers set `Verify=no`. Signed `SHA256SUMS` and signed verity root hashes come with the secure boot note.
- **The UKI is large.** It weighs 107 MB, almost all of it mkosi's default initrd.
- **Builds aren't pinned.** Packages come from the current Fedora 45 mirrors. With `Snapshot=`, mkosi can only pin Fedora to the release compose, without updates.

## Credits

The partition layout, the transfer files, the tmpfiles links for `/etc` and the PAM move come from [ParticleOS](https://github.com/systemd/particleos), which is licensed under LGPL-2.1-or-later.
