# hakopodOS: Ubuntu 24.04 built into an immutable Kairos image.
#
# FLAVOR selects the kernel:
#   metal  linux-image-generic + linux-firmware
#   cloud  linux-image-virtual, no firmware (KVM, OpenStack and similar)
#   aws    linux-image-aws, no firmware (EC2)
#
# No Kairos Kubernetes provider is installed. Hakopod ships its own pinned
# K3s, and its installer refuses hosts that already carry cluster state.
FROM ubuntu:24.04

ARG VERSION=v0.0.0
ARG FLAVOR=metal

# Keep copyright files; drop docs, man pages and translations.
RUN printf '%s\n' \
      'path-exclude=/usr/share/doc/*' 'path-include=/usr/share/doc/*/copyright' \
      'path-exclude=/usr/share/man/*' 'path-exclude=/usr/share/info/*' \
      'path-exclude=/usr/share/locale/*' 'path-include=/usr/share/locale/locale.alias' \
      > /etc/dpkg/dpkg.cfg.d/hakopod-os-excludes

# What the Hakopod bootstrap would otherwise apt-get at install time
# (installer/prerequisites.py). /usr is read-only once deployed.
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      python3 bash curl ca-certificates openssl iproute2 util-linux acl passwd kmod coreutils \
      openssh-server

RUN --mount=type=bind,from=quay.io/kairos/kairos-init:v0.17.3,src=/kairos-init,dst=/kairos-init \
    /kairos-init -s install --version "${VERSION}" --skip-step installKernel

RUN set -eu; \
    case "$FLAVOR" in \
      metal) kernel="linux-image-generic linux-firmware" ;; \
      cloud) kernel=linux-image-virtual ;; \
      aws)   kernel=linux-image-aws ;; \
      *)     echo "unknown FLAVOR: $FLAVOR" >&2; exit 1 ;; \
    esac; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $kernel; \
    unused="zfsutils-linux zfs-zed unattended-upgrades ubuntu-pro-client ubuntu-advantage-tools snapd motd-news-config"; \
    [ "$FLAVOR" = metal ] || unused="$unused linux-firmware"; \
    purge=""; for p in $unused; do dpkg -s "$p" >/dev/null 2>&1 && purge="$purge $p"; done; \
    [ -z "$purge" ] || DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq --auto-remove $purge; \
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
