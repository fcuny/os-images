# os-images

Working examples of image-based Linux systems: a read-only operating system checked by verity, atomic updates, and rollback. They go with the notes on [fcuny.net](https://fcuny.net/notes/).

There are two examples of the same idea: one built with [mkosi](https://github.com/systemd/mkosi), and one with [bootc](https://github.com/bootc-dev/bootc).

## What the mkosi image does

The image is Fedora 45 for arm64, built with mkosi v27.1.

- mkosi builds the operating system once, as a plain directory that keeps the package database (`mkosi.images/base`). The disk image and the extensions are built from it. The disk image drops the database, so a host has neither dnf nor rpm.
- The disk ships with an ESP, one `/usr` partition (erofs) and its verity hash partition. It has no root partition.
- The UKI's command line carries `usrhash=`, which mkosi adds. Its two halves are the partition UUIDs of `/usr` and of its verity data, so the UKI picks its own `/usr`.
- On first boot, systemd-repart in the initrd adds an empty second `/usr` slot and creates a btrfs root, which holds `/etc` and `/var`.
- `/etc` starts empty. systemd-tmpfiles links most of it back to a copy of the build's `/etc` inside `/usr/share/factory/etc`.
- `systemd-sysupdate` downloads a new `/usr` into the empty slot and a new UKI with 3 boot tries.
- A health gate (`demo-gate.service`) must pass before `boot-complete.target`. If it fails, the machine reboots. After 3 failed tries, systemd-boot goes back to the previous version.
- A boot that gets stuck also reboots. If the initrd or the system lands in emergency mode, `demo-stuck-boot-reboot.service` reboots after 30 seconds. It only runs while a version is being assessed (the boot entry has a counter), so a version already marked good can't reboot in a loop. systemd-boot already counted the try when it booted the version. Rebooting is what gives it the next one.
- System extensions add to the read-only `/usr` without a new image: `debug` (strace and tcpdump, signed) and `extra-modules` (Fedora's kernel-modules-extra). `demo-config` is a configuration extension for `/etc`. The image only merges signed system extensions at boot (`/usr/lib/systemd/sysext.conf.d/10-signed.conf`), and trusts the certificate mkosi installs in `/usr/lib/verity.d/`.
- A kernel panic reboots after 10 seconds (`panic=10`). A hardware watchdog (`RuntimeWatchdogSec=30s`) reboots a hung kernel or PID 1. The watchdog doesn't help with emergency mode, since PID 1 is still running there and keeps the watchdog fed.

Logins use SSH certificates: the image trusts a CA whose public key ships in `/usr/share/demo/` (`TrustedUserCAKeys`), so a machine needs no keys of its own. `scripts/build` makes the CA and signs the demo key.

The `debian` profile builds the same image on Debian testing (forky), for the GCE example. It pins every package to one snapshot of snapshot.debian.org.

The layout follows systemd's [ParticleOS](https://github.com/systemd/particleos), without image signing.

## Layout

- `mkosi/`: the mkosi configuration.
  - `mkosi.images/base/`: the operating system, as a directory. The disk image (`mkosi.conf`) and the extensions are built on top of it.
  - `mkosi.images/debug/`, `mkosi.images/extra-modules/`: system extensions.
  - `mkosi.images/demo-config/`: a configuration extension.
  - `mkosi.repart/`: partitions created at build time.
  - `mkosi.profiles/debian/`: the Debian variant.
  - `mkosi.extra/usr/lib/repart.d/`: partitions created at first boot.
  - `mkosi.extra/usr/lib/sysupdate.d/`: what an update downloads, and where it writes it.
  - `mkosi.initrd.conf/`: extra configuration for mkosi's default initrd.
  - `variants/broken-gate/`: an extra tree that makes the health gate fail, to test rollback.
- `bootc/`: the bootc image, a `Containerfile` and the files it copies in (`rootfs/`).
- `scripts/`: build in a Linux VM, boot on the Mac, serve updates.

## Requirements

- macOS on Apple silicon.
- [c2vm](https://github.com/fcuny/c2vm) 0.2 or later, for builds. Set `C2VM` if the right one isn't first on your `PATH`.
- qemu from Homebrew (`brew install qemu`), which ships the edk2 UEFI firmware.
- openssl, to make the demo key that signs the debug extension. `scripts/build` makes it in `mkosi/mkosi.key` the first time; it isn't committed.

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

`scripts/vm-stop` powers off the VM, and `scripts/workbench-stop` stops the build VM.

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

To try an extension, copy it into the VM and merge it:

```sh
scripts/vm-ssh 'mkdir -p /var/lib/extensions && cat > /var/lib/extensions/debug.raw' < .state/out/v1/debug.raw
scripts/vm-ssh 'systemd-sysext merge && strace -V'
```

The `extra-modules` extension merges, but `modprobe` doesn't find its modules: the module index comes from the base image, and merging doesn't rebuild it. `insmod` with the full path works. It's also unsigned, so with the image's policy it stops every extension from merging at boot.

To watch a stuck boot, publish an update whose UKI can't find its `/usr`. Renaming the `/usr` file gives the partition a UUID that doesn't match the UKI's `usrhash=`:

```sh
scripts/publish 2
cd .state/updates
mv demo_2.usr-arm64.*.raw demo_2.usr-arm64.00000000000000000000000000000bad.raw
shasum -a 256 demo_* > SHA256SUMS
```

Then update and reboot as above. Each try waits for `/usr`, lands in emergency mode, and reboots 30 seconds later. After the third try, systemd-boot boots the previous version. It took about 4.5 minutes in our tests.

## On Google Cloud

The Debian variant boots on a C4A machine (Google Axion, arm64), and updates from a public Cloud Storage bucket. Set the project, a zone with C4A machines, a private bucket for the image upload, and a public bucket for the update files (Cloud Storage can't make one folder of a bucket public):

```sh
export GCE_PROJECT=my-project GCE_ZONE=us-central1-b GCE_BUCKET=my-images GCE_UPDATES_BUCKET=my-updates
```

Then, with the workbench running:

```sh
scripts/gce-build 1      # the Debian image, fetching updates from the public bucket
scripts/gce-build 2
scripts/gce-image 1      # upload it and create the image demo-1
scripts/gce-updates 2    # publish version 2
scripts/gce-vm 1         # start a c4a-standard-1 named demo, and print its IP
ssh -i .state/keys/id_ed25519 root@<IP> /usr/lib/systemd/systemd-sysupdate update
```

Debian testing has no `updatectl`, so call `systemd-sysupdate` directly. Delete the VM, the image and the buckets when you're done.

## The bootc image

The image is Debian testing (forky) for arm64, built as a container image with podman, and installed and updated with bootc v1.17.5 on its composefs backend.

- Nobody publishes a Debian bootc base image, so the `Containerfile` builds one from `debian:forky`. Debian doesn't package bootc either: the first stage builds it from its git tag.
- An empty `/usr/lib/composefs/setup-root-conf.toml` marks the image for the composefs backend, and dracut adds bootc's module to the initramfs. The kernel and the initramfs live in `/usr/lib/modules/<version>/`, where bootc looks for them.
- `bootc install to-disk` makes a GPT disk with an ESP and an ext4 root with fs-verity. The root holds the composefs object store, and a writable `/etc` and `/var` for each deployment. The boot entry has no `root=`: the initramfs finds the root by its partition type.
- `/` is a read-only composefs mount, checked by fs-verity. `/root`, `/home`, `/srv`, `/mnt` and `/opt` are links into `/var`, since the image can't be written.
- An update pulls the changed layers from a registry, and stages a new deployment, which bootc writes to the ESP at shutdown. `/etc` is merged: local changes carry over to the new version.
- bootc needs podman on the host, to manage its image storage, even if nothing else runs containers.
- dpkg's database lives in the image, at `/usr/lib/sysimage/dpkg`, with a link from `/var/lib/dpkg`. In `/var`, which bootc only unpacks at install, it would describe the installed version after an update. In the image, `dpkg -l` lists what the booted version ships, read-only, and images built `FROM` this one can use `apt`.
- Automatic updates are off. bootc's preset enables `bootc-fetch-apply-updates.timer`, systemd applies presets on a host's first boot, and the image's own preset (`80-demo.preset`) disables it.
- Each host makes its own machine ID and SSH host keys on its first boot. Installing the packages made both in the image, so the build removes them and leaves `/etc/machine-id` as `uninitialized`.
- There's no automatic rollback. The composefs backend doesn't set up boot counting, so `bootc rollback` is the only way back.

The registry runs in the workbench and serves over plain HTTP. Its address is the workbench's IP, which is built into the image (`/etc/containers/registries.conf.d/50-demo-registry.conf`) and into the image name the host tracks. If the workbench comes back with another IP, rebuild and reinstall.

### bootc walkthrough

The workbench needs a kernel with fs-verity, EROFS, VFAT and GPT support. c2vm's default kernel doesn't have them yet ([fcuny/c2vm#116](https://github.com/fcuny/c2vm/pull/116)). Until it does, pass a kernel built by that PR's CI in `KERNEL` (the directory with `boot/kernel`):

```sh
KERNEL=path/to/arm64 scripts/bootc-workbench
```

Build version 1, install it on a fresh disk, and boot it. The first build compiles bootc, which takes about 6 minutes. A rebuild takes seconds.

```sh
scripts/bootc-build 1
scripts/bootc-install 1
scripts/bootc-vm-start
```

Each build is pushed as `:vN` and as `:latest`, and the installed host tracks `:latest`. Build version 2, then update and reboot:

```sh
scripts/vm-wait
scripts/bootc-build 2
scripts/vm-ssh bootc upgrade
scripts/vm-ssh systemctl reboot
scripts/vm-wait
scripts/vm-ssh 'cat /usr/lib/demo-version; bootc status'
```

Version 2 changes one layer of 170 bytes, and the update downloads about 15 KiB. To go back:

```sh
scripts/vm-ssh bootc rollback
scripts/vm-ssh systemctl reboot
```

`scripts/bootc-vm-stop` powers off the VM and keeps its disk. `scripts/workbench-stop` stops the workbench, and its registry goes with it.

## Not done yet

- **Update files aren't signed.** The transfers set `Verify=no`. Signed `SHA256SUMS` and signed verity root hashes come with the secure boot note.
- **The UKI is large.** It weighs 107 MB: the kernel (18 MB), mkosi's default initrd (34 MB), and a second initrd with the kernel's modules, which is most of the rest. The base image also pulls in dracut, which never runs.
- **Fedora builds aren't pinned.** Packages come from the current Fedora 45 mirrors. With `Snapshot=`, mkosi can only pin Fedora to the release compose, without updates. The Debian profile is pinned: with a fixed `--seed` and `--source-date-epoch`, two builds gave identical `/usr`, verity and UKI files. The tools tree isn't pinned yet (`ToolsTreeSnapshot=`).
- **bootc images aren't signed.** The host pulls with `ostree-unverified-image:`, so nothing checks who built an update.
- **The hostname on GCE stays `localhost`.** systemd-imds reads it from the metadata server, but imports it in the initrd, which has neither the imds package nor networking here, and systemd-firstboot, which applies it, is turned off.

## License

The scripts and the configuration are licensed under LGPL-2.1-or-later, the same license as the ParticleOS files they build on. See [LICENSE](LICENSE).

## Credits

The partition layout, the transfer files, the tmpfiles links for `/etc` and the PAM move come from [ParticleOS](https://github.com/systemd/particleos), which is licensed under LGPL-2.1-or-later.

The base image and the extensions follow mkosi's guide, [Building system extensions with mkosi](https://github.com/systemd/mkosi/blob/v27.1/docs/sysext.md).

The bootc image follows bootc's [requirements for compatible images](https://github.com/bootc-dev/bootc/blob/main/docs/src/bootc-compatible-images.7.md), and [bootcrew](https://github.com/bootcrew/mono)'s Debian image, which showed that the composefs backend works on Debian.
