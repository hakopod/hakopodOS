# hakopodOS

An immutable host OS for [Hakopod](https://github.com/hakopod/hakopod), built with [Kairos](https://kairos.io) on Debian 13 (trixie).

The root filesystem is an OCI image. Upgrades write a new image to the passive slot and switch on reboot; the previous image stays bootable as the fallback entry, and a recovery image sits beside both. Machine state lives on `COS_PERSISTENT`.

**Status:** experimental. Not for production use yet.

## Flavors

| Flavor | Kernel | Firmware | Artifacts |
| --- | --- | --- | --- |
| `metal` | `linux-image-amd64` | `firmware-linux` | installer ISO, EFI raw disk |
| `cloud` | `linux-image-cloud-amd64` | none | installer ISO, qcow2, EFI raw disk (AMI import), VHD (Azure) |

Debian's cloud kernel is the one its official AWS, Azure, GCE and OpenStack images use, so one flavor covers EC2, Azure, OpenStack, Proxmox and plain KVM.

```sh
docker build --build-arg FLAVOR=cloud --build-arg VERSION=v1 -t hakopod-os:cloud .
```

Recommended packages are off, and documentation, man pages and translations are left out. Copyright files are kept.

## How Hakopod fits on an immutable root

Hakopod is installed with its stock installer. Three things make that work:

- **Prerequisites in the image.** Python, curl, ACL tools and friends are baked in; `/usr` is read-only once deployed, so the bootstrap cannot `apt-get` them.
- **A persistent state layout.** `91_hakopod-layout.yaml` replaces the stock Kairos `PERSISTENT_STATE_PATHS`. The stock list pre-creates `/etc/kubernetes`, `/var/lib/etcd` and other directories for the Kairos k3s/k0s providers, which the Hakopod installer correctly reads as foreign cluster state. `/var/lib` is persisted whole. The file is placed on the OEM partition by `after-install`/`after-reset` hooks, because immucore resolves bind mounts early in the initramfs and an override in `/system/oem` does not reliably take effect.
- **Installer state moved to persistent storage.** `/etc` is rebuilt from the image on every boot, which would drop `/etc/hakopod` and the `hakopod-api`/`hakopod-dashboard` accounts. `hakopod-os-persist.path` fires when the installer marks the installation complete; `persist-hakopod` copies `/etc/hakopod` to `COS_PERSISTENT`, bind-mounts it immediately and records the accounts, which are re-added from the initramfs on every boot.

A Hakopod installer mode that understands image-based hosts would make the last part unnecessary.

## Testing

`tests/qemu/lifecycle.sh` runs in CI (`.github/workflows/vm-lifecycle.yml`) for each flavor on a GitHub-hosted runner with KVM. It builds v1 and v2 images, boots v1 from an AuroraBoot raw disk, installs Hakopod, then reboots, upgrades to v2 and rolls back to v1 through the fallback entry. OS checks gate the job; Hakopod health and boot timings are reported in the job summary.

## Measurements

QEMU/KVM with OVMF (UEFI) on a GitHub-hosted `ubuntu-24.04` runner, 4 vCPUs, 8 GiB RAM, Hakopod 0.1.0-alpha.76, 3 November 2026. Single runs, not benchmarks.

| Flavor | OS image | Idle, OS only | Idle, OS + Hakopod |
| --- | --- | --- | --- |
| `cloud` | 652 MB | 51 MiB held, 0.0 % CPU | 704 MiB held, 2.1 % CPU |
| `metal` | 888 MB | 56 MiB held, 0.0 % CPU | 752 MiB held, 1.9 % CPU |

"Held" is memory the kernel cannot reclaim: anonymous pages, shmem, unreclaimable slab, kernel stacks and page tables. With Hakopod, nearly all of it is K3s, PostgreSQL and the Hakopod services.

Reboot with Hakopod running, split from a host-timestamped serial console:

| | Shutdown | Firmware + GRUB | Reboot to SSH | Reboot to healthy API |
| --- | --- | --- | --- | --- |
| reboot | 4.5 to 5.4 s | 3.3 to 3.6 s | 28 to 29 s | 44 to 45 s |
| A/B upgrade | 4.6 to 5.8 s | 3.3 to 3.7 s | 29 to 30 s | 45 to 49 s |
| rollback | 4.7 s | 3.6 to 3.7 s | 29 to 30 s | 41 to 43 s |

Two fixes produced most of that. GRUB waited ten seconds at its menu on every boot: grub.cfg loads the first `/grub_oem_env` it finds, which is the copy on `COS_STATE`, so the timeout is now set there from the install, reset and upgrade hooks. And the Hakopod dashboard ignored SIGTERM until systemd killed it after 30 s; Hakopod 0.1.0-alpha.76 exits within five seconds. Before both, a reboot with Hakopod running took 67 to 71 s to SSH and 83 to 90 s to a healthy API.

| Artifact | `cloud` | `metal` |
| --- | --- | --- |
| installer ISO | 307 MB | 455 MB |
| qcow2 | 265 MB | |
| EFI raw disk, zstd | 210 MB | 324 MB |
| Azure VHD, zstd | 210 MB | |

What is left in a boot: the kernel (2 to 3 s), about 10 s in the initramfs, where immucore's mount steps each take close to one second, and userspace to SSH. K3s and the Hakopod services take another 15 s or so to report healthy.

## Hardening

- sshd accepts public keys only: no root login, no password or keyboard-interactive auth, no agent, X11 or remote forwarding. The policy ships in the image and is loaded through an `ssh.service` drop-in, so it follows upgrades.
- Kernel defaults in `/usr/lib/sysctl.d/90-hakopod-os.conf`: restricted kernel pointers and dmesg, no unprivileged BPF or perf, hardened BPF JIT, ptrace limited to ancestors, no kexec loading or SysRq, no ICMP redirects or source routing.

Planned: [Hakopod in the image](docs/design/hakopod-in-image.md), then Trusted Boot (signed UKI, dm-verity, TPM-sealed persistent partition) and SSH off by default.

## License

Apache License 2.0.
