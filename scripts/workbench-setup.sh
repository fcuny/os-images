# shellcheck shell=bash
# Runs inside the workbench VM, as its command (see scripts/workbench).
set -euo pipefail
MKOSI_VERSION=v27.1
# The Fedora mkosi package brings mkosi's dependencies; mkosi itself runs from git at a pinned tag.
dnf -y -q install git mkosi distribution-gpg-keys openssh-server >/dev/null 2>&1
git clone -q --depth 1 --branch "$MKOSI_VERSION" https://github.com/systemd/mkosi /opt/mkosi
ln -sf /opt/mkosi/bin/mkosi /usr/local/bin/mkosi
cat > /usr/local/bin/build-image <<'BUILD'
#!/bin/bash
# build-image VERSION [mkosi options]: build that version, copy the output to /out/vVERSION.
set -euo pipefail
v=$1; shift
mkdir -p /work/src && cp -a /src/. /work/src/   # mkosi.tools stays in /work/src between builds
cd /work/src
rm -f mkosi.output/demo_"$v"*   # -f keeps split files from older builds, whose names carry other UUIDs
start=$(date +%s)
mkosi --image-version="$v" "$@" -f build > "/out/build-v$v.log" 2>&1 || { tail -50 "/out/build-v$v.log"; exit 1; }
rm -rf "/out/v$v" && mkdir -p "/out/v$v" && cp -a mkosi.output/demo_"$v"* "/out/v$v/"
echo "v$v built in $(( $(date +%s) - start ))s"
BUILD
chmod +x /usr/local/bin/build-image
install -d -m 700 /root/.ssh && install -m 600 /keys/id_ed25519.pub /root/.ssh/authorized_keys
ssh-keygen -A >/dev/null
echo "workbench ready, mkosi $MKOSI_VERSION"
exec /usr/sbin/sshd -D -e -o PermitRootLogin=prohibit-password
