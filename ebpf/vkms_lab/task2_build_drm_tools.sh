#!/usr/bin/env bash
set -euo pipefail

# TASK 2: Build modetest from libdrm and KMS tests from IGT.

BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
EXTERNAL_DIR="$BASE_DIR/external"
INSTALL_DIR="$BASE_DIR/tools-install"
BUILD_ROOT="$BASE_DIR/tools-build"
JOBS="${JOBS:-$(nproc)}"
MULTIARCH_TRIPLET="$(gcc -print-multiarch 2>/dev/null || true)"

LIBDRM_SRC="$EXTERNAL_DIR/libdrm"
IGT_SRC="$EXTERNAL_DIR/igt-gpu-tools"
KMOD_SRC="$EXTERNAL_DIR/kmod"
PCIUTILS_SRC="$EXTERNAL_DIR/pciutils"
LIBDRM_BUILD="$BUILD_ROOT/libdrm"
IGT_BUILD="$BUILD_ROOT/igt-gpu-tools"
KMOD_BUILD="$BUILD_ROOT/kmod"

for tool in meson ninja pkg-config gcc g++ python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "TASK 2 error: missing host tool '$tool'. Run ebpf/env.sh or install it manually." >&2
    exit 1
  fi
done

mkdir -p "$BUILD_ROOT" "$INSTALL_DIR"

# TASK 2: keep ccache state inside the ignored build tree. Some hosts route
# ccache temp files to /run/user/$UID, which may be read-only in this workflow.
export CCACHE_DIR="${CCACHE_DIR:-$BUILD_ROOT/ccache}"
export CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-$BUILD_ROOT/ccache-tmp}"
mkdir -p "$CCACHE_DIR" "$CCACHE_TEMPDIR"

if [ ! -d "$LIBDRM_SRC/.git" ] || [ ! -d "$IGT_SRC/.git" ] || \
   [ ! -d "$KMOD_SRC/.git" ] || [ ! -d "$PCIUTILS_SRC/.git" ]; then
  echo "TASK 2 error: missing sources, run task2_fetch_drm_tools.sh first" >&2
  exit 1
fi

meson_setup() {
  local build_dir="$1"
  local src_dir="$2"
  shift 2

  if [ -d "$build_dir/meson-info" ]; then
    meson setup --reconfigure "$build_dir" "$src_dir" "$@"
  else
    meson setup "$build_dir" "$src_dir" "$@"
  fi
}

meson_setup "$LIBDRM_BUILD" "$LIBDRM_SRC" \
  --prefix "$INSTALL_DIR" \
  -Dtests=true
ninja -C "$LIBDRM_BUILD" -j "$JOBS"
ninja -C "$LIBDRM_BUILD" install
mkdir -p "$INSTALL_DIR/bin"
install -m 0755 "$LIBDRM_BUILD/tests/modetest/modetest" "$INSTALL_DIR/bin/modetest"

PKG_CONFIG_DIRS=(
  "$INSTALL_DIR/lib/pkgconfig"
  "$INSTALL_DIR/lib64/pkgconfig"
)
LD_LIBRARY_DIRS=(
  "$INSTALL_DIR/lib"
  "$INSTALL_DIR/lib64"
)

if [ -n "$MULTIARCH_TRIPLET" ]; then
  PKG_CONFIG_DIRS+=("$INSTALL_DIR/lib/$MULTIARCH_TRIPLET/pkgconfig")
  LD_LIBRARY_DIRS+=("$INSTALL_DIR/lib/$MULTIARCH_TRIPLET")
fi

export PKG_CONFIG_PATH="$(IFS=:; echo "${PKG_CONFIG_DIRS[*]}"):${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$(IFS=:; echo "${LD_LIBRARY_DIRS[*]}"):${LD_LIBRARY_PATH:-}"

if ! pkg-config --exists libkmod; then
  meson_setup "$KMOD_BUILD" "$KMOD_SRC" \
    --prefix "$INSTALL_DIR" \
    --sysconfdir "$INSTALL_DIR/etc" \
    -Dtools=false \
    -Dmanpages=false \
    -Ddocs=false \
    -Dbuild-tests=false \
    -Dzstd=disabled \
    -Dxz=disabled \
    -Dzlib=disabled \
    -Dopenssl=disabled \
    -Dmbedtls=disabled \
    -Dbashcompletiondir=no \
    -Dfishcompletiondir=no \
    -Dzshcompletiondir=no
  ninja -C "$KMOD_BUILD" -j "$JOBS"
  ninja -C "$KMOD_BUILD" install
fi

if ! pkg-config --exists libkmod; then
  echo "TASK 2 error: missing libkmod even after local kmod build." >&2
  echo "Run ebpf/env.sh or install libkmod-dev/kmod-devel manually, then rerun task2_build_drm_tools.sh." >&2
  exit 1
fi

if ! pkg-config --exists libpci; then
  make -C "$PCIUTILS_SRC" -j "$JOBS" \
    PREFIX="$INSTALL_DIR" \
    LIBDIR="$INSTALL_DIR/lib/$MULTIARCH_TRIPLET" \
    PKGCFDIR="$INSTALL_DIR/lib/$MULTIARCH_TRIPLET/pkgconfig" \
    SHARED=yes \
    ZLIB=no \
    DNS=no \
    LIBKMOD=no \
    HWDB=no \
    install-lib
fi

if ! pkg-config --exists libpci; then
  echo "TASK 2 error: missing libpci even after local pciutils build." >&2
  echo "Run ebpf/env.sh or install pciutils/libpci development package manually, then rerun task2_build_drm_tools.sh." >&2
  exit 1
fi

meson_setup "$IGT_BUILD" "$IGT_SRC" \
  --prefix "$INSTALL_DIR" \
  -Dtests=enabled \
  -Ddocs=disabled \
  -Dman=disabled
ninja -C "$IGT_BUILD" -j "$JOBS"
ninja -C "$IGT_BUILD" install

echo "modetest:"
find "$INSTALL_DIR" "$LIBDRM_BUILD" -type f -name modetest -print

echo "IGT KMS tests:"
find "$INSTALL_DIR" "$IGT_BUILD" -type f \
  \( -name 'kms_atomic' -o -name 'kms_flip' -o -name 'kms_plane' -o -name 'kms_writeback' \) \
  -print
