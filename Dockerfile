# hakopodOS: Debian 13 (trixie) built into an immutable Kairos image.
#
# FLAVOR selects the kernel:
#   metal  linux-image-amd64 and firmware, for bare metal
#   cloud  linux-image-cloud-amd64, no firmware: EC2, Azure, GCE, OpenStack,
#          Proxmox and other KVM or Hyper-V guests
#
# No Kairos Kubernetes provider is installed. Hakopod ships its own pinned
# K3s, and its installer refuses hosts that already carry cluster state.
FROM debian:13

ARG VERSION=v0.0.0
ARG FLAVOR=metal

# Keep copyright files; drop docs, man pages and translations.
RUN printf '%s\n' \
      'path-exclude=/usr/share/doc/*' 'path-include=/usr/share/doc/*/copyright' \
      'path-exclude=/usr/share/man/*' 'path-exclude=/usr/share/info/*' \
      'path-exclude=/usr/share/locale/*' 'path-include=/usr/share/locale/locale.alias' \
      > /etc/dpkg/dpkg.cfg.d/hakopod-os-excludes \
 && printf '%s\n' 'APT::Install-Recommends "false";' 'APT::Install-Suggests "false";' \
      > /etc/apt/apt.conf.d/90hakopod-os

# What the Hakopod bootstrap would otherwise apt-get at install time
# (installer/prerequisites.py). /usr is read-only once deployed.
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      python3 bash curl ca-certificates openssl iproute2 util-linux acl passwd kmod coreutils \
      openssh-server

RUN --mount=type=bind,from=quay.io/kairos/kairos-init:v0.17.3,src=/kairos-init,dst=/kairos-init \
    /kairos-init -s install --version "${VERSION}" --skip-step installKernel

RUN set -eu; \
    case "$FLAVOR" in \
      metal) sed -i 's/^Components: main$/Components: main non-free-firmware/' /etc/apt/sources.list.d/debian.sources; \
             apt-get update -qq; kernel="linux-image-amd64 firmware-linux" ;; \
      cloud) kernel=linux-image-cloud-amd64 ;; \
      *)     echo "unknown FLAVOR: $FLAVOR" >&2; exit 1 ;; \
    esac; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $kernel; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /usr/share/doc/*/changelog* /usr/share/man/* /usr/share/info/*; \
    find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name locale.alias -exec rm -rf {} +

COPY overlay/ /
RUN mkdir -p /usr/lib/systemd/system/multi-user.target.wants \
 && ln -s ../hakopod-os-persist.path /usr/lib/systemd/system/multi-user.target.wants/hakopod-os-persist.path

# Links whichever kernel is installed and builds the initramfs.
RUN --mount=type=bind,from=quay.io/kairos/kairos-init:v0.17.3,src=/kairos-init,dst=/kairos-init \
    /kairos-init -s init --version "${VERSION}"

RUN printf '%s\n' "${VERSION}" > /usr/lib/hakopod-os/version \
 && printf '%s\n' "${FLAVOR}" > /usr/lib/hakopod-os/flavor
