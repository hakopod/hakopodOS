#!/usr/bin/env bash
# Build the release artifacts for one flavor from a local image.
#
#   release/build-artifacts.sh <flavor> <version> <image> <outdir>
#
#   metal  installer ISO, EFI raw disk (zstd)
#   cloud  installer ISO, qcow2 (OpenStack, Proxmox, plain KVM),
#          EFI raw disk (zstd, for import as an AMI), fixed VHD (zstd, Azure)
#
# No cloud-config is embedded: published images carry no users or keys.
# Machines get theirs from cloud user-data or the install configuration.
set -euo pipefail

flavor=$1 version=$2 image=$3 out=$4
AURORABOOT=quay.io/kairos/auroraboot:v0.28.0
# GitHub release assets are limited to 2 GiB each.
MAX_BYTES=$((2 * 1024 * 1024 * 1024 - 1))
base=hakopod-os-$version-$flavor
mkdir -p "$out"
work=$(mktemp -d)
trap 'sudo rm -rf "$work"' EXIT

aurora() { # aurora <state dir> <--set ...>
  local dir=$1; shift
  mkdir -p "$dir"
  docker run --rm --privileged -v /var/run/docker.sock:/var/run/docker.sock -v "$dir:/aurora" "$AURORABOOT" \
    --set disable_http_server=true --set disable_netboot=true \
    --set container_image="$image" --set state_dir=/aurora "$@" >&2
  sudo chown -R "$(id -u):$(id -g)" "$dir" >&2
}

pick() { # pick <dir> <glob>
  local f
  f=$(find "$1" -name "$2" -type f | head -1)
  [[ -n $f ]] || { echo "no $2 produced in $1" >&2; ls -R "$1" >&2; exit 1; }
  echo "$f"
}

iso() { aurora "$work/iso"; mv "$(pick "$work/iso" '*.iso')" "$out/$base.iso"; }
efi_raw() { [[ -f $work/efi/.done ]] || { aurora "$work/efi" --set disk.efi=true; touch "$work/efi/.done"; }; pick "$work/efi" '*.raw'; }

case $flavor in
  metal) iso; zstd -q -T0 -10 --long=27 "$(efi_raw)" -o "$out/$base.raw.zst" ;;
  cloud) iso
         raw=$(efi_raw)
         qemu-img convert -c -O qcow2 "$raw" "$out/$base.qcow2"
         zstd -q -T0 -10 --long=27 "$raw" -o "$out/$base.raw.zst"
         aurora "$work/vhd" --set disk.vhd=true
         zstd -q -T0 -10 --long=27 "$(pick "$work/vhd" '*.vhd')" -o "$out/$base.vhd.zst" ;;
  *)     echo "unknown flavor: $flavor" >&2; exit 1 ;;
esac

for f in "$out"/*; do
  size=$(stat -c %s "$f")
  (( size <= MAX_BYTES )) || { echo "$(basename "$f") is $size bytes, over the 2 GiB release asset limit" >&2; exit 1; }
  printf '%s\t%s\n' "$(basename "$f")" "$(numfmt --to=iec "$size")"
done
