# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck shell=sh disable=SC2034
# Shared by the scripts in this directory. Local state (keys, builds, the VM disk) lives in .state/.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE=$ROOT/.state
KEY=$STATE/keys/id_ed25519
SSH_OPTS="-q -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ControlMaster=no -o ControlPath=none"

ensure_key() {
    mkdir -p "$STATE/keys"
    [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C os-images-demo -f "$KEY"
}

# The workbench's address, as c2vm-init printed it.
workbench_ip() {
    grep -o 'eth0: [0-9.]*' "$STATE/workbench.log" 2>/dev/null | tail -1 | cut -d' ' -f2
}
