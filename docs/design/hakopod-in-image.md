# Hakopod in the image

Status: proposal.

## Problem

The stock installer puts executable code on the persistent partition:

| Path | Contents |
| --- | --- |
| `/opt/hakopod/tools` | K3s, Helm, Node, kubectl |
| `/opt/hakopod/releases/<version>`, `current` | `hakopod-server`, the dashboard |
| `/opt/hakopod/maintenance` | installer Python modules and pins |
| `/etc/systemd/system/hakopod-*.service` | units, rendered at install time |

The OS image is read-only and replaced atomically, but anything with root can swap these files and survive reboots and OS upgrades. It also forces Python, curl and the rest of the installer's prerequisites into every image.

## Proposal

Ship Hakopod as part of the OS image and keep only data and configuration on `COS_PERSISTENT`.

**Image build**

- Fetch the pinned Hakopod release for the target architecture. Verify `SHA256SUMS` and the GitHub build-provenance attestation before anything is unpacked; fail the build otherwise.
- Install to `/usr/lib/hakopod/<version>/` (`hakopod-server`, dashboard, tools) and `/usr/lib/hakopod/current`.
- Ship the units in `/usr/lib/systemd/system`. Values that vary per host (memory limits, addresses, ports) come from `EnvironmentFile=` and drop-ins under `/etc/hakopod`, not from rendering the unit itself.
- Declare `hakopod-api` and `hakopod-dashboard` in `/usr/lib/sysusers.d/hakopod.conf` with fixed UIDs/GIDs. `systemd-sysusers` creates them on every boot. This replaces the initramfs account restore.

**Install**

A new installer mode (in hakopod, e.g. `--image-root /usr/lib/hakopod/current`) that:

- verifies the preinstalled release instead of downloading and unpacking one;
- accepts existing accounts with the expected UIDs;
- installs no units and writes nothing under `/opt` or `/usr`;
- writes configuration and secrets to `/etc/hakopod` and data to `/var/lib/hakopod`, both persistent.

`persist-hakopod` and its path unit go away: `/etc/hakopod` becomes a declared persistent path, created empty by the layout, and the installer accepts an empty directory there in this mode.

**Upgrades and rollback**

The Hakopod version is the OS image version. An A/B upgrade moves both; the fallback slot holds both previous versions.

The catch is the database. Migrations only go forward, so booting the fallback slot after the new release has migrated PostgreSQL would run old code against a newer schema. Options, in order of preference:

1. Keep migrations compatible with the previous release for one version (expand/contract). Rollback is then always safe across one release.
2. Snapshot PostgreSQL before the first start of a new version and restore it on rollback. Simple, but loses writes made since the upgrade.
3. Refuse to boot the fallback slot once a newer migration has been recorded, and say so on the console.

(3) is the minimum for a first version; (1) is the long-term answer and a Hakopod release-process change.

## What it buys

- No executable Hakopod code on writable storage. `/opt` drops out of the persistent paths.
- Python, curl and the other installer prerequisites can leave the image once the installer itself runs from a container or a one-shot unit.
- One artifact per release, verified once at build time, upgraded and rolled back as a unit.

## Out of scope

Trusted Boot (signed UKI, dm-verity, TPM-sealed persistent partition), removing SSH by default and Hadron. They build on this and are tracked separately.
