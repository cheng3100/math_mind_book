#!/usr/bin/env bash
set -euo pipefail

# Host dependency installer for the eBPF VKMS lab.
# This script is intentionally separate from TASK 1/2 scripts: run it manually
# when host build tools are missing.

PACKAGES_DEBIAN=(
  build-essential
  bc
  bison
  bzip2
  flex
  git
  curl
  ca-certificates
  cpio
  gzip
  rsync
  pkg-config
  meson
  ninja-build
  qemu-system-x86
  libssl-dev
  libelf-dev
  dwarves
  python3
  python3-pip
  python3-setuptools
  python3-wheel
  libc6-dev
  libpciaccess-dev
  libkmod-dev
  libudev-dev
  libdrm-dev
  libglib2.0-dev
  libpixman-1-dev
  # libproc2-dev
  libunwind-dev
  libdw-dev
  libjson-c-dev
  libcurl4-openssl-dev
  libxmlrpc-core-c3-dev
)

PACKAGES_FEDORA=(
  @development-tools
  bc
  bison
  bzip2
  flex
  git
  curl
  ca-certificates
  cpio
  gzip
  rsync
  pkgconf-pkg-config
  meson
  ninja-build
  qemu-system-x86
  openssl-devel
  elfutils-libelf-devel
  dwarves
  python3
  python3-pip
  glibc-static
  libpciaccess-devel
  kmod-devel
  systemd-devel
  libdrm-devel
  glib2-devel
  pixman-devel
  procps-ng-devel
  libunwind-devel
  elfutils-devel
  json-c-devel
  libcurl-devel
)

if command -v apt-get >/dev/null 2>&1; then
  echo "Installing Debian/Ubuntu packages for TASK 1/2."
  sudo apt-get update
  sudo apt-get install -y "${PACKAGES_DEBIAN[@]}"
elif command -v dnf >/dev/null 2>&1; then
  echo "Installing Fedora packages for TASK 1/2."
  sudo dnf install -y "${PACKAGES_FEDORA[@]}"
else
  echo "Unsupported package manager. Install the packages listed in ebpf/env.sh manually." >&2
  exit 1
fi
