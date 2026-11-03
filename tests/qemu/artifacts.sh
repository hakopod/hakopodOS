#!/usr/bin/env bash
# Boot the release artifacts the way a user would. Needs KVM.
#
#   tests/qemu/artifacts.sh <flavor> <version> <dist dir>
#
# Nothing is built into the artifacts, so the test user and key come from a
# NoCloud seed (a CD labelled cidata), which the Kairos cdrom datasource reads
# just as it reads EC2 or Azure user data.
#
#   installer ISO      automatic install onto an empty disk, then boot it
#   raw, qcow2, VHD    boot recovery, reset onto the disk, boot active
#
# Every artifact must reach active_boot with the expected version and flavor.
set -euo pipefail

flavor=$1 version=$2 dist=$(cd "$3" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$PWD/.work-artifacts}
OUT=${OUT:-$PWD/report-artifacts}
base=$dist/hakopod-os-$version-$flavor
mkdir -p "$WORK" "$OUT"
failed=0

KEY=$WORK/id_ed25519
[[ -f $KEY ]] || ssh-keygen -q -t ed25519 -N '' -f "$KEY"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
vm() { ssh "${SSH_OPTS[@]}" -p 2222 -o ConnectTimeout=10 kairos@127.0.0.1 "$@"; }

seed() { # seed <name> [install]: NoCloud seed ISO with the test user
  local dir=$WORK/seed-$1
  mkdir -p "$dir"
  sed "s|@SSH_PUBLIC_KEY@|$(cat "$KEY.pub")|" "$HERE/cloud-config.yaml" > "$dir/user-data"
  if [[ ${2:-} == install ]]; then
    printf '%s\n' 'install:' '  device: /dev/vda' '  auto: true' '  poweroff: true' >> "$dir/user-data"
  fi
  printf 'instance-id: %s\nlocal-hostname: hakopod-os\n' "$1" > "$dir/meta-data"
  genisoimage -quiet -output "$WORK/seed-$1.iso" -volid cidata -joliet -rock "$dir/user-data" "$dir/meta-data"
}

qemu() { # qemu <name> <extra args...>; foreground unless -daemonize is given
  local name=$1 limit=(); shift
  [[ -z ${QEMU_TIMEOUT:-} ]] || limit=(timeout "$QEMU_TIMEOUT")
  "${limit[@]}" qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 4096 -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$WORK/vars-$name.fd" \
    -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
    -display none -serial file:"$OUT/console-$name.log" "$@"
}

overlay() { # overlay <name> <file> <format>: 64G scratch disk backed by the artifact
  qemu-img create -q -f qcow2 -b "$2" -F "$3" "$WORK/disk-$1.qcow2" 64G
}

check() { # check <name>: wait for active_boot, then compare version and flavor
  local name=$1 deadline=$((SECONDS + 1500)) state="" got
  while (( SECONDS < deadline )); do
    state=$(vm 'sudo kairos-agent state get boot' 2>/dev/null | tr -d '[:space:]') || true
    [[ $state == active_boot ]] && break
    sleep 5
  done
  got=$(vm 'cat /usr/lib/hakopod-os/version /usr/lib/hakopod-os/flavor' 2>/dev/null | tr '\n' ' ') || true
  if [[ $state == active_boot && $got == "v$version $flavor " ]]; then
    echo "pass  $name: active_boot, $got"
    printf '| %s | pass | active_boot, %s|\n' "$name" "$got" >> "$OUT/summary.md"
  else
    echo "FAIL  $name: boot state ${state:-unreachable}, ${got:-no version}"
    printf '| %s | fail | boot state %s |\n' "$name" "${state:-unreachable}" >> "$OUT/summary.md"
    failed=1
  fi
  kill "$(cat "$WORK/qemu.pid")" 2>/dev/null || true
  sleep 3
}

boot_disk() { # boot_disk <name> <file> <format>
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORK/vars-$1.fd"
  overlay "$1" "$2" "$3"
  seed "$1"
  qemu "$1" -drive file="$WORK/disk-$1.qcow2",format=qcow2,if=virtio \
    -drive file="$WORK/seed-$1.iso",format=raw,media=cdrom,if=ide,index=3 \
    -daemonize -pidfile "$WORK/qemu.pid"
  check "$1"
}

boot_iso() {
  local name=iso
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORK/vars-$name.fd"
  qemu-img create -q -f qcow2 "$WORK/disk-$name.qcow2" 64G
  seed "$name" install
  # Installs and powers off; the second boot has the disk alone.
  if ! QEMU_TIMEOUT=1800 qemu "$name" -drive file="$WORK/disk-$name.qcow2",format=qcow2,if=virtio \
      -drive file="$base.iso",format=raw,media=cdrom,if=ide,index=2 \
      -drive file="$WORK/seed-$name.iso",format=raw,media=cdrom,if=ide,index=3; then
    echo "FAIL  iso: installer did not power off within 30 minutes"
    printf '| iso | fail | installer did not power off |\n' >> "$OUT/summary.md"
    failed=1; return
  fi
  mv "$OUT/console-$name.log" "$OUT/console-$name-install.log"
  qemu "$name" -drive file="$WORK/disk-$name.qcow2",format=qcow2,if=virtio \
    -daemonize -pidfile "$WORK/qemu.pid"
  check "$name"
}

printf '## %s artifacts\n\n| Artifact | Result | Detail |\n| --- | --- | --- |\n' "$flavor" > "$OUT/summary.md"

boot_iso
case $flavor in
  metal) zstd -q -d --long=27 "$base.raw.zst" -o "$WORK/disk.raw"
         boot_disk raw "$WORK/disk.raw" raw ;;
  cloud) boot_disk qcow2 "$base.qcow2" qcow2
         zstd -q -d --long=27 "$base.vhd.zst" -o "$WORK/disk.vhd"
         boot_disk vhd "$WORK/disk.vhd" vpc ;;
esac

[[ -z ${GITHUB_STEP_SUMMARY:-} ]] || { cat "$OUT/summary.md"; echo; } >> "$GITHUB_STEP_SUMMARY"
cat "$OUT/summary.md"
exit "$failed"
