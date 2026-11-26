# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck shell=bash
# Runs inside the workbench VM, as its command (see scripts/bootc-workbench).
set -euo pipefail
dnf -y -q install podman skopeo openssh-server e2fsprogs systemd-udev >/dev/null 2>&1
# bootc install reads partitions through udev, and checks /run/udev against the host's.
/usr/lib/systemd/systemd-udevd --daemon
udevadm trigger && udevadm settle
# podman's overlay driver can't use this VM's own overlay root as its upper
# layer, nor a virtiofs mount as its lower one. Give container storage, its
# temporary files and the build context real ext4 under /work.
truncate -s 75G /work.img
mkfs.ext4 -q -O verity /work.img
mkdir -p /work && mount -o loop /work.img /work
mkdir -p /work/containers /work/tmp /var/lib/containers && chmod 1777 /work/tmp
mount --bind /work/containers /var/lib/containers
mount --bind /work/tmp /var/tmp
# No systemd here: mount cgroup v2 ourselves (podman refuses v1), use plain cgroups and a file for podman's events.
mountpoint -q /sys/fs/cgroup || mount -t cgroup2 none /sys/fs/cgroup
mkdir -p /etc/containers/containers.conf.d
cat > /etc/containers/containers.conf.d/50-workbench.conf <<'CONF'
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
CONF
# A registry for the images: installs and updates pull from it. c2vm's kernel
# has no nftables for podman's own network, so containers use the host's.
podman run -d -q --name registry --network=host docker.io/library/registry:2 >/dev/null

cat > /usr/local/bin/bootc-build-image <<'BUILD'
#!/bin/bash
# bootc-build-image VERSION REGISTRY: build that version and push it as :vVERSION and :latest.
set -euo pipefail
v=$1 reg=$2 img=$2/debian-bootc
rm -rf /work/src && cp -a /src /work/src && cd /work/src
start=$(date +%s)
# podman bind-mounts its own /etc/hostname and /etc/hosts into RUN steps;
# without them, the image's own files can be removed.
podman build --no-hostname --no-hosts --network=host \
    --build-arg IMAGE_VERSION="$v" --build-arg REGISTRY="$reg" \
    -t "$img:v$v" -t "$img:latest" . > "/out/bootc-build-v$v.log" 2>&1 ||
    { tail -30 "/out/bootc-build-v$v.log"; exit 1; }
podman push -q --tls-verify=false "$img:v$v"
podman push -q --tls-verify=false "$img:latest"
echo "v$v built in $(( $(date +%s) - start ))s, pushed as $img:v$v and :latest"
BUILD

cat > /usr/local/bin/bootc-install-image <<'INSTALL'
#!/bin/bash
# bootc-install-image VERSION REGISTRY [KEYS]: install that version on a fresh 10G disk, into /out/bootc-disk.raw.
# The installed host tracks :latest, so `bootc upgrade` follows new builds.
# KEYS, a file under /keys, becomes root's authorized_keys, for hosts with no other way in.
set -euo pipefail
v=$1 img=$2/debian-bootc keys=()
[ -z "${3:-}" ] || keys=(--root-ssh-authorized-keys "$3")
rm -f /work/disk.raw && truncate -s 10G /work/disk.raw
# bootc runs from the image itself. It needs the host's devices, udev and
# container storage, and runs some steps in PID 1's mount namespace.
podman run --rm --network=host --privileged --pid=host --ipc=host --security-opt label=disable \
    -v /dev:/dev -v /run/udev:/run/udev -v /var/lib/containers:/var/lib/containers -v /work:/data -v /keys:/keys:ro \
    "$img:v$v" bootc install to-disk --via-loopback /data/disk.raw --wipe \
    --bootloader systemd --generic-image --target-imgref "$img:latest" "${keys[@]}" \
    > "/out/bootc-install-v$v.log" 2>&1 || { tail -30 "/out/bootc-install-v$v.log"; exit 1; }
cp --sparse=always /work/disk.raw /out/bootc-disk.raw
echo "v$v installed, tracking $img:latest"
INSTALL
chmod +x /usr/local/bin/bootc-build-image /usr/local/bin/bootc-install-image

install -d -m 700 /root/.ssh && install -m 600 /keys/id_ed25519.pub /root/.ssh/authorized_keys
ssh-keygen -A >/dev/null
echo "workbench ready, $(podman --version)"
exec /usr/sbin/sshd -D -e -o PermitRootLogin=prohibit-password
