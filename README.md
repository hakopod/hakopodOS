# hakopodOS

An immutable host OS for [Hakopod](https://github.com/hakopod/hakopod), built with [Kairos](https://kairos.io) on Ubuntu 24.04.

The root filesystem is an OCI image. Upgrades write a new image to the passive slot and switch on reboot; the previous image stays bootable as the fallback entry, and a recovery image sits beside both. Machine state lives on `COS_PERSISTENT`.

**Status:** experimental. Not for production use yet.

## Flavors

| Flavor | Kernel | Firmware | Use |
| --- | --- | --- | --- |
| `metal` | `linux-image-generic` | yes | bare metal |
| `cloud` | `linux-image-virtual` | no | KVM guests: OpenStack, Proxmox, most VPS providers |
| `aws` | `linux-image-aws` | no | EC2 |

```sh
docker build --build-arg FLAVOR=cloud --build-arg VERSION=v1 -t hakopod-os:cloud .
```

All flavors leave out ZFS, unattended-upgrades, the Ubuntu Pro client, snapd, documentation, man pages and translations. Copyright files are kept.

## How Hakopod fits on an immutable root

Hakopod is installed with its stock installer. Three things make that work:

- **Prerequisites in the image.** Python, curl, ACL tools and friends are baked in; `/usr` is read-only once deployed, so the bootstrap cannot `apt-get` them.
- **A persistent state layout.** `91_hakopod-layout.yaml` replaces the stock Kairos `PERSISTENT_STATE_PATHS`. The stock list pre-creates `/etc/kubernetes`, `/var/lib/etcd` and other directories for the Kairos k3s/k0s providers, which the Hakopod installer correctly reads as foreign cluster state. `/var/lib` is persisted whole. The file is placed on the OEM partition by `after-install`/`after-reset` hooks, because immucore resolves bind mounts early in the initramfs and an override in `/system/oem` does not reliably take effect.
- **Installer state moved to persistent storage.** `/etc` is rebuilt from the image on every boot, which would drop `/etc/hakopod` and the `hakopod-api`/`hakopod-dashboard` accounts. `hakopod-os-persist.path` fires when the installer marks the installation complete; `persist-hakopod` copies `/etc/hakopod` to `COS_PERSISTENT`, bind-mounts it immediately and records the accounts, which are re-added from the initramfs on every boot.

A Hakopod installer mode that understands image-based hosts would make the last part unnecessary.

## Testing

`tests/qemu/lifecycle.sh` runs in CI (`.github/workflows/vm-lifecycle.yml`) for each flavor on a GitHub-hosted runner with KVM. It builds v1 and v2 images, boots v1 from an AuroraBoot raw disk, installs Hakopod, then reboots, upgrades to v2 and rolls back to v1 through the fallback entry. OS checks gate the job; Hakopod health and boot timings are reported in the job summary.

## Measurements

QEMU/KVM on a GitHub-hosted `ubuntu-24.04` runner, 4 vCPUs, 8 GiB RAM, Hakopod 0.1.0-alpha.74, 2 November 2026.

| Flavor | Image | Kernel + initrd + userspace |
| --- | --- | --- |
| `metal` | 1.62 GB | 4.0 + 10.4 + 6.5 = 20.9 s |
| `aws` | 956 MB | 3.8 + 10.8 + 4.4 = 19.0 s |
| `cloud` | 706 MB | 2.0 + 9.1 + 3.7 = 14.8 s |

With Hakopod installed (generic kernel, before the flavors were split): reboot to a healthy API took 78 s; after an A/B upgrade 51 s; after rollback 48 s. These are single runs, not benchmarks.

Most of the initrd time is immucore mounting the active image and its bind mounts. That is the next thing to look at, together with GRUB's timeout and pre-loading the K3s images into the OS image.

## License

Apache License 2.0.
