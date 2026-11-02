#!/usr/bin/env bash
# VM lifecycle test for hakopodOS. Needs KVM; intended for a throwaway CI host.
#
#   1. build images v1 and v2 (identical apart from /usr/lib/hakopod-os/version)
#   2. turn v1 into a raw disk with AuroraBoot and boot it under QEMU
#   3. install Hakopod with its stock installer
#   4. reboot, A/B upgrade to v2, then roll back to v1 via the fallback entry
#
# OS checks gate the job. Hakopod checks and timings are reported alongside.
set -euo pipefail

HAKOPOD_VERSION=${HAKOPOD_VERSION:-0.1.0-alpha.75}
FLAVOR=${FLAVOR:-metal}
AURORABOOT=quay.io/kairos/auroraboot:v0.28.0
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$PWD/.work}
OUT=${OUT:-$PWD/report}
mkdir -p "$WORK/build" "$OUT"
RESULTS=$OUT/results.jsonl
: > "$RESULTS"

record() { # record os|hakopod|timing <check> pass|fail <detail>
  python3 -c 'import json,sys; print(json.dumps(dict(zip(["kind","check","status","detail"], sys.argv[1:]))))' "$@" >> "$RESULTS"
  echo "[$1] $2: $3 ${4:0:300}"
}

KEY=$WORK/id_ed25519
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
vm()  { ssh "${SSH_OPTS[@]}" -p 2222 -o ConnectTimeout=10 kairos@127.0.0.1 "$@"; }
put() { scp "${SSH_OPTS[@]}" -P 2222 "$1" "kairos@127.0.0.1:$2"; }

wait_boot() { # wait_boot active_boot|passive_boot <timeout>
  local deadline=$((SECONDS + $2)) state=""
  while (( SECONDS < deadline )); do
    state=$(vm 'sudo kairos-agent state get boot' 2>/dev/null | tr -d '[:space:]') || true
    [[ $state == "$1" ]] && return 0
    sleep 3
  done
  echo "boot state: ${state:-unreachable}"
  return 1
}

reboot_vm() {
  REBOOT_AT=$SECONDS
  vm 'sudo systemctl reboot' || true
  sleep 15
}

slot() { vm 'cat /usr/lib/hakopod-os/version'; }

boot_timing() { # boot_timing <phase>
  local wall=$((SECONDS - ${REBOOT_AT:-$SECONDS}))
  # What keeps systemd from reaching "startup finished", immucore's own
  # timeline, and how long the previous boot took to shut down.
  vm 'systemctl list-jobs --no-pager; sudo cat /run/immucore/boot-timeline.json; echo; sudo journalctl -b -1 -o short-monotonic --no-pager | tail -120' > "$OUT/boot-$1-detail.txt" 2>&1 || true
  vm 'systemd-analyze critical-chain --no-pager; systemd-analyze blame --no-pager' > "$OUT/boot-$1.txt" 2>&1 || true
  # systemd-analyze cannot attribute initramfs time; keep the early journal.
  vm 'sudo journalctl -b -o short-monotonic --no-pager | head -600' > "$OUT/boot-$1-journal.txt" 2>&1 || true
  record timing "boot $1" pass "reboot to ssh ${wall}s; $(vm 'systemd-analyze 2>&1 | head -1' | tr '\n' ' ')"
}

# Idle footprint after things settle. "held" is memory the kernel cannot
# reclaim: anonymous pages, shmem/tmpfs, unreclaimable slab, kernel stacks
# and page tables. MemTotal - MemAvailable is also given; it includes the
# free-memory reserves and some page cache. CPU is the share of time not
# idle over 30 s.
footprint() { # footprint <label>
  sleep 60
  record timing "idle $1" pass "$(vm 'awk "/^(AnonPages|Shmem|SUnreclaim|KernelStack|PageTables):/{h+=\$2} /MemTotal/{t=\$2} /MemAvailable/{a=\$2} END{printf \"%d MiB held, %d MiB total-available, \", h/1024, (t-a)/1024}" /proc/meminfo
    read -r _ a1 b1 c1 d1 e1 f1 g1 h1 _ < /proc/stat; sleep 30; read -r _ a2 b2 c2 d2 e2 f2 g2 h2 _ < /proc/stat
    busy=$(( (a2+b2+c2+f2+g2+h2) - (a1+b1+c1+f1+g1+h1) )); total=$(( busy + (d2+e2) - (d1+e1) ))
    awk -v b=$busy -v t=$total "BEGIN{printf \"cpu %.1f%% busy, \", 100*b/t}"
    echo "$(ls -d /proc/[0-9]* | wc -l) processes"' 2>&1 | tr '\n' ' ')"
}

# Where idle memory goes: meminfo, per-unit cgroup memory, largest processes,
# slab caches and tmpfs usage.
memory_report() { # memory_report <label>
  vm 'set -x
    cat /proc/meminfo
    for u in $(systemctl list-units --type=service --state=running --plain --no-legend | awk "{print \$1}"); do
      printf "%8d KiB  %s\n" $(( $(systemctl show -p MemoryCurrent --value $u | sed "s/\[not set\]/0/") / 1024 )) $u
    done | sort -rn | head -30
    ps -eo rss=,comm= --sort=-rss | head -25
    sudo awk "NR>2 {printf \"%10d KiB  %s\n\", \$3*\$4/1024, \$1}" /proc/slabinfo | sort -rn | head -15
    df -h -t tmpfs -t overlay
    cat /proc/cmdline
    /usr/sbin/losetup -l 2>/dev/null' > "$OUT/memory-$1.txt" 2>&1 || true
}

services() {
  vm 'for u in hakopod-k3s hakopod-api hakopod-dashboard; do printf "%s=%s " $u "$(systemctl is-active $u)"; done' 2>&1 || true
}

api_ready() { # api_ready <phase>
  [[ ${INSTALLED:-} ]] || return 0
  local deadline=$((SECONDS + 600))
  until [[ $(services) == *"hakopod-api=active"* ]] && vm 'curl -fsS -o /dev/null http://127.0.0.1:8080/healthz' 2>/dev/null; do
    (( SECONDS < deadline )) || { record timing "api ready after $1" fail "not healthy after 600s"; return; }
    sleep 3
  done
  record timing "api ready after $1" pass "reboot to healthy API $((SECONDS - REBOOT_AT))s"
}

hakopod_state() { # hakopod_state <phase>
  local s
  s=$(services)
  [[ $s == *"hakopod-k3s=active"*"hakopod-api=active"*"hakopod-dashboard=active"* ]] \
    && record hakopod "services after $1" pass "$s" || record hakopod "services after $1" fail "$s"
  s=$(vm 'for p in /etc/hakopod/installation.json /var/lib/hakopod /opt/hakopod/current; do test -e $p && printf "%s " $p || printf "%s=missing " $p; done; getent passwd hakopod-api >/dev/null && echo accounts || echo accounts=missing' 2>&1 || true)
  [[ $s != *missing* ]] && record hakopod "state after $1" pass "$s" || record hakopod "state after $1" fail "$s"
}

# --- images ---------------------------------------------------------------
for v in v1 v2; do
  docker build --build-arg VERSION="$v" --build-arg FLAVOR="$FLAVOR" -t "hakopod-os:$v" .
done
docker save hakopod-os:v2 -o "$WORK/hakopod-os-v2.tar"
record os "build" pass "$FLAVOR $(docker image ls hakopod-os --format '{{.Tag}}={{.Size}}' | tr '\n' ' ')"

ssh-keygen -q -t ed25519 -N '' -f "$KEY"
sed "s|@SSH_PUBLIC_KEY@|$(cat "$KEY.pub")|" "$HERE/cloud-config.yaml" > "$WORK/build/cloud-config.yaml"

docker run --rm --privileged -v /var/run/docker.sock:/var/run/docker.sock -v "$WORK/build:/aurora" "$AURORABOOT" \
  --set disable_http_server=true --set disable_netboot=true --set disk.bios=true \
  --set container_image=hakopod-os:v1 --set state_dir=/aurora --cloud-config /aurora/cloud-config.yaml
sudo chown -R "$(id -u):$(id -g)" "$WORK/build"
RAW=$(find "$WORK/build" -maxdepth 3 -name '*.raw' | head -1)
[[ -n $RAW ]] || { record os "raw disk" fail "AuroraBoot produced no raw image"; exit 1; }
qemu-img resize -f raw "$RAW" 64G
record os "raw disk" pass "$(basename "$RAW"), 64G"

# --- first boot -----------------------------------------------------------
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 8192 \
  -drive file="$RAW",format=raw,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22 \
  -display none -serial file:"$OUT/console.log" -daemonize -pidfile "$WORK/qemu.pid"

# The raw image boots recovery, resets onto the disk, then reboots to active.
if out=$(wait_boot active_boot 1500); then
  record os "first boot" pass "$(vm 'cat /usr/lib/hakopod-os/flavor; uname -r' | tr '\n' ' ')"
else
  record os "first boot" fail "$out"; exit 1
fi

sysctls=$(vm '/usr/sbin/sysctl -n kernel.kptr_restrict kernel.dmesg_restrict kernel.unprivileged_bpf_disabled kernel.kexec_load_disabled kernel.sysrq net.ipv4.conf.all.accept_redirects' | tr '\n' ' ')
# Ask the running sshd which methods it offers: a password-only client must be
# refused with publickey as the sole remaining method.
methods=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password,keyboard-interactive -o BatchMode=yes -o ConnectTimeout=10 \
  -p 2222 kairos@127.0.0.1 true 2>&1 | grep -o 'Permission denied ([^)]*)' || true)
if [[ $sysctls == "2 1 1 1 0 0 " && $methods == "Permission denied (publickey)" ]]; then
  record os "hardening" pass "sysctl ok; sshd offers publickey only"
else
  record os "hardening" fail "sysctl: $sysctls; sshd: ${methods:-no answer}"
fi
footprint os
memory_report os
if [[ ${PROFILE_ONLY:-} ]]; then
  kill "$(cat "$WORK/qemu.pid")" 2>/dev/null || true
  exit 0
fi

grub=$(vm 'e=$(command -v grub2-editenv || command -v grub-editenv); sudo "$e" /oem/grub_oem_env list 2>&1 | grep "^timeout="' 2>&1 || true)
if [[ $grub == "timeout=1" ]]; then
  record os "grub timeout" pass "$grub"
else
  record os "grub timeout" fail "grub_oem_env: ${grub:-no timeout}; $(vm 'ls /oem; command -v grub2-editenv grub-editenv' 2>&1 | tr '\n' ' ')"
fi

if vm 'mountpoint -q /var/lib && test -f /oem/91_hakopod-layout.yaml'; then
  record os "state layout" pass "$(vm 'findmnt -no SOURCE /var/lib; df -h --output=size /var/lib | tail -1' | tr '\n' ' ')"
else
  vm 'ls /oem; cat /run/cos/cos-layout.env; findmnt /var /var/lib; sudo journalctl -b --no-pager | grep -i hakopod-os' > "$OUT/layout.txt" 2>&1 || true
  record os "state layout" fail "/var/lib is not on the persistent partition; see layout.txt"
fi

# --- Hakopod --------------------------------------------------------------
sed "s|@HAKOPOD_VERSION@|$HAKOPOD_VERSION|" "$HERE/hakopod-install.json" > "$WORK/install.json"
put "$WORK/install.json" /tmp/install.json
if vm "curl -fsSL https://github.com/hakopod/hakopod/releases/download/v$HAKOPOD_VERSION/installer.sh -o /tmp/installer.sh \
    && sudo timeout 2400 sh /tmp/installer.sh --version $HAKOPOD_VERSION --config /tmp/install.json --yes" > "$OUT/hakopod-install.log" 2>&1; then
  INSTALLED=1
  record hakopod "install $HAKOPOD_VERSION" pass "stock installer"
  if out=$(vm 'for i in $(seq 60); do mountpoint -q /etc/hakopod && break; sleep 2; done; mountpoint /etc/hakopod' 2>&1); then
    record hakopod "installer state persisted" pass "$out"
  else
    record hakopod "installer state persisted" fail "$(vm 'systemctl status hakopod-os-persist.path hakopod-os-persist.service --no-pager' 2>&1 | tail -6 | tr '\n' ' ')"
  fi
else
  record hakopod "install $HAKOPOD_VERSION" fail "$(tail -3 "$OUT/hakopod-install.log" | tr '\n' ' ')"
fi
hakopod_state install

# --- reboot ---------------------------------------------------------------
reboot_vm
if out=$(wait_boot active_boot 900); then
  record os "reboot" pass "slot $(slot)"; boot_timing reboot
else
  record os "reboot" fail "$out"
fi
api_ready reboot
hakopod_state reboot
[[ ${INSTALLED:-} ]] && footprint "os + hakopod"

# --- A/B upgrade ----------------------------------------------------------
put "$WORK/hakopod-os-v2.tar" /tmp/hakopod-os-v2.tar
if vm 'sudo mkdir -p /usr/local/upgrade && sudo mv /tmp/hakopod-os-v2.tar /usr/local/upgrade/ \
    && sudo kairos-agent upgrade --source ocifile:/usr/local/upgrade/hakopod-os-v2.tar' > "$OUT/upgrade.log" 2>&1; then
  reboot_vm
  if wait_boot active_boot 900 >/dev/null && [[ $(slot) == v2 ]]; then
    record os "upgrade" pass "active slot runs v2"; boot_timing upgrade
  else
    record os "upgrade" fail "$(vm 'cat /usr/lib/hakopod-os/version; sudo kairos-agent state get boot' 2>&1 | tr '\n' ' ')"
  fi
else
  record os "upgrade" fail "$(tail -3 "$OUT/upgrade.log" | tr '\n' ' ')"
fi
api_ready upgrade
hakopod_state upgrade

# --- rollback -------------------------------------------------------------
vm 'sudo kairos-agent bootentry --select fallback' > "$OUT/rollback.log" 2>&1 || true
reboot_vm
if wait_boot passive_boot 900 >/dev/null && [[ $(slot) == v1 ]]; then
  record os "rollback" pass "fallback slot runs v1"; boot_timing rollback
else
  record os "rollback" fail "$(vm 'cat /usr/lib/hakopod-os/version; sudo kairos-agent state get boot' 2>&1 | tr '\n' ' ')"
fi
api_ready rollback
hakopod_state rollback

vm 'sudo journalctl -b --no-pager -n 400' > "$OUT/journal.log" 2>&1 || true
kill "$(cat "$WORK/qemu.pid")" 2>/dev/null || true

python3 - "$RESULTS" <<'PY'
import json, os, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
table = ["| | Check | Result | Detail |", "| --- | --- | --- | --- |"]
table += [f"| {r['kind']} | {r['check']} | {r['status']} | {r['detail'][:200].replace('|', '/')} |" for r in rows]
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as out:
        out.write(f"## {os.environ.get('FLAVOR', 'metal')}\n\n" + "\n".join(table) + "\n\n")
print("\n".join(table))
sys.exit(1 if any(r["kind"] == "os" and r["status"] == "fail" for r in rows) else 0)
PY
