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

QEMU/KVM with OVMF (UEFI) on a GitHub-hosted `ubuntu-24.04` runner, 4 vCPUs, 8 GiB RAM, kairos-init v4.4.0, Hakopod 0.1.0-alpha.76, 3 November 2026. Ranges cover two CI runs on different runners; these are not benchmarks.

| Flavor | OS image | Idle, OS only | Idle, OS + Hakopod |
| --- | --- | --- | --- |
| `cloud` | 692 MB | 52 MiB held, 0.0 % CPU | 715 MiB held, 1.6 % CPU |
| `metal` | 929 MB | 56 MiB held, 0.0 % CPU | 743 MiB held, 2.0 % CPU |

"Held" is memory the kernel cannot reclaim: anonymous pages, shmem, unreclaimable slab, kernel stacks and page tables. With Hakopod, nearly all of it is K3s, PostgreSQL and the Hakopod services.

Reboot with Hakopod running:

| Flavor | Shutdown | Reboot to SSH | Reboot to healthy API |
| --- | --- | --- | --- |
| `cloud` | 4.2 to 4.6 s | 19 to 22 s | 28 to 42 s |
| `metal` | 4.2 to 4.7 s | 22 to 25 s | 38 to 45 s |

The same holds after an A/B upgrade and after rollback. A cloud boot is 2.4 s of kernel, 4.3 s of initramfs and 5.5 s of userspace (12.1 s), Firmware and GRUB take another 2.8 to 3.7 s before that, or 3.6 to 4.0 s on `metal`.

Three changes brought a reboot with Hakopod running down from 67 to 71 s to SSH and 83 to 90 s to a healthy API:

- **GRUB** waited ten seconds at its menu on every boot. grub.cfg loads the first `/grub_oem_env` it finds, which is the copy on `COS_STATE`, so the timeout is now set there from the install, reset and upgrade hooks.
- **The Hakopod dashboard** ignored SIGTERM until systemd killed it after 30 s. Hakopod 0.1.0-alpha.76 exits within five seconds.
- **immucore** in kairos-init v0.17.3 waited a full second before every mount attempt. kairos-init v4.4.0 mounts immediately and retries every 250 ms, taking the initramfs from about 10 s to 4.3 s.

| Artifact | `cloud` | `metal` |
| --- | --- | --- |
| installer ISO | 307 MB | 455 MB |
| qcow2 | 265 MB | |
| EFI raw disk, zstd | 210 MB | 324 MB |
| Azure VHD, zstd | 210 MB | |

Artifact sizes were measured before the move to kairos-init v4.4.0, which made the OS image about 40 MB larger.

## Hardening

- sshd accepts public keys only: no root login, no password or keyboard-interactive auth, no agent, X11 or remote forwarding. The policy ships in the image and is loaded through an `ssh.service` drop-in, so it follows upgrades.
- Kernel defaults in `/usr/lib/sysctl.d/90-hakopod-os.conf`: restricted kernel pointers and dmesg, no unprivileged BPF or perf, hardened BPF JIT, ptrace limited to ancestors, no kexec loading or SysRq, no ICMP redirects or source routing.

Planned: [Hakopod in the image](docs/design/hakopod-in-image.md), then Trusted Boot (signed UKI, dm-verity, TPM-sealed persistent partition) and SSH off by default.

## License

Apache License 2.0.
