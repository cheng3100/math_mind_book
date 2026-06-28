#!/usr/bin/env bash
set -euo pipefail

# TASK 1: Build a static BusyBox from source for the QEMU initramfs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${1:-$SCRIPT_DIR/task1-runtime/busybox}"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.36.1}"
BUSYBOX_URL="${BUSYBOX_URL:-https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2}"
SRC_ARCHIVE="$WORK_DIR/busybox-${BUSYBOX_VERSION}.tar.bz2"
SRC_DIR="$WORK_DIR/busybox-${BUSYBOX_VERSION}"
BUILD_DIR="$WORK_DIR/build"
INSTALL_DIR="$WORK_DIR/install"
JOBS="${JOBS:-$(nproc)}"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "TASK 1 error: missing host tool '$1'. Run ebpf/env.sh or install it manually." >&2
    exit 1
  fi
}

for tool in make gcc bzip2 tar; do
  require_tool "$tool"
done

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "TASK 1 error: missing curl/wget. Run ebpf/env.sh or install one manually." >&2
  exit 1
fi

mkdir -p "$WORK_DIR" "$INSTALL_DIR"

if [ ! -f "$SRC_ARCHIVE" ]; then
  echo "TASK 1: downloading BusyBox source: $BUSYBOX_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -L "$BUSYBOX_URL" -o "$SRC_ARCHIVE"
  else
    wget -O "$SRC_ARCHIVE" "$BUSYBOX_URL"
  fi
fi

if [ ! -d "$SRC_DIR" ]; then
  tar -C "$WORK_DIR" -xf "$SRC_ARCHIVE"
fi

mkdir -p "$BUILD_DIR"

make -C "$SRC_DIR" O="$BUILD_DIR" defconfig

set_config() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" "$BUILD_DIR/.config"; then
    sed -i "s/^${key}=.*/${key}=${value}/" "$BUILD_DIR/.config"
  elif grep -q "^# ${key} is not set" "$BUILD_DIR/.config"; then
    sed -i "s/^# ${key} is not set/${key}=${value}/" "$BUILD_DIR/.config"
  else
    echo "${key}=${value}" >>"$BUILD_DIR/.config"
  fi
}

set_not_set() {
  local key="$1"

  if grep -q "^${key}=" "$BUILD_DIR/.config"; then
    sed -i "s/^${key}=.*/# ${key} is not set/" "$BUILD_DIR/.config"
  elif ! grep -q "^# ${key} is not set" "$BUILD_DIR/.config"; then
    echo "# ${key} is not set" >>"$BUILD_DIR/.config"
  fi
}

set_config CONFIG_STATIC y
set_not_set CONFIG_TC
set_not_set CONFIG_FEATURE_TC_INGRESS
set_not_set CONFIG_FEATURE_INETD_RPC

(yes "" || true) | make -C "$SRC_DIR" O="$BUILD_DIR" oldconfig
make -C "$SRC_DIR" O="$BUILD_DIR" -j"$JOBS" busybox

cp "$BUILD_DIR/busybox" "$INSTALL_DIR/busybox"

if ldd "$INSTALL_DIR/busybox" >/dev/null 2>&1; then
  echo "TASK 1 error: built BusyBox is dynamically linked; static libc support is missing." >&2
  echo "Run ebpf/env.sh or install static libc support manually." >&2
  exit 1
fi

echo "TASK 1 complete: busybox=$INSTALL_DIR/busybox"
