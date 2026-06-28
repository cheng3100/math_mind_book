#!/usr/bin/env bash
set -euo pipefail

# TASK 1: Build a Linux kernel image and VKMS module for the QEMU VKMS lab.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="${1:-/home/cheng/work/os/linux/linux}"
BUILD_DIR="${2:-$SCRIPT_DIR/task1-runtime/linux-build}"
ARCH="${ARCH:-x86_64}"
JOBS="${JOBS:-$(nproc)}"

if [ ! -d "$LINUX_DIR" ]; then
  echo "TASK 1 error: missing Linux source directory: $LINUX_DIR" >&2
  exit 1
fi

if [ ! -x "$LINUX_DIR/scripts/config" ]; then
  echo "TASK 1 error: missing scripts/config under Linux source: $LINUX_DIR" >&2
  exit 1
fi

for tool in make gcc bc bison flex; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "TASK 1 error: missing host tool '$tool'. Run ebpf/env.sh or install it manually." >&2
    exit 1
  fi
done

if ! command -v pahole >/dev/null 2>&1; then
  echo "TASK 1 error: missing host tool 'pahole' required by CONFIG_DEBUG_INFO_BTF." >&2
  echo "Run ebpf/env.sh or install dwarves manually." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

echo "TASK 1: Linux source: $LINUX_DIR"
echo "TASK 1: build directory: $BUILD_DIR"

make -C "$LINUX_DIR" O="$BUILD_DIR" ARCH="$ARCH" x86_64_defconfig

"$LINUX_DIR/scripts/config" --file "$BUILD_DIR/.config" \
  --enable CONFIG_BPF \
  --enable CONFIG_BPF_SYSCALL \
  --enable CONFIG_BPF_JIT \
  --enable CONFIG_BPF_EVENTS \
  --enable CONFIG_KPROBES \
  --enable CONFIG_KPROBE_EVENTS \
  --enable CONFIG_UPROBES \
  --enable CONFIG_UPROBE_EVENTS \
  --enable CONFIG_FTRACE \
  --enable CONFIG_FUNCTION_TRACER \
  --enable CONFIG_FUNCTION_GRAPH_TRACER \
  --enable CONFIG_STACKTRACE \
  --enable CONFIG_DEBUG_INFO \
  --enable CONFIG_DEBUG_INFO_DWARF5 \
  --enable CONFIG_DEBUG_INFO_BTF \
  --enable CONFIG_DEBUG_FS \
  --enable CONFIG_TRACEFS_FS \
  --enable CONFIG_DRM \
  --enable CONFIG_DRM_KMS_HELPER \
  --module CONFIG_DRM_VKMS \
  --enable CONFIG_DRM_GEM_SHMEM_HELPER \
  --enable CONFIG_CONFIGFS_FS \
  --enable CONFIG_TMPFS \
  --enable CONFIG_DEVTMPFS \
  --enable CONFIG_DEVTMPFS_MOUNT \
  --enable CONFIG_BLK_DEV_INITRD \
  --enable CONFIG_BINFMT_ELF \
  --enable CONFIG_VIRTIO \
  --enable CONFIG_VIRTIO_PCI \
  --enable CONFIG_VIRTIO_BLK \
  --enable CONFIG_NET_9P \
  --enable CONFIG_NET_9P_VIRTIO \
  --enable CONFIG_9P_FS \
  --enable CONFIG_9P_FS_POSIX_ACL

make -C "$LINUX_DIR" O="$BUILD_DIR" ARCH="$ARCH" olddefconfig
make -C "$LINUX_DIR" O="$BUILD_DIR" ARCH="$ARCH" -j"$JOBS" bzImage modules

KERNEL_IMAGE="$BUILD_DIR/arch/x86/boot/bzImage"
VKMS_MODULE="$BUILD_DIR/drivers/gpu/drm/vkms/vkms.ko"

if [ ! -f "$KERNEL_IMAGE" ]; then
  echo "TASK 1 error: kernel image was not produced: $KERNEL_IMAGE" >&2
  exit 1
fi

if [ ! -f "$VKMS_MODULE" ]; then
  echo "TASK 1 error: VKMS module was not produced: $VKMS_MODULE" >&2
  exit 1
fi

echo "TASK 1 complete"
echo "kernel_image=$KERNEL_IMAGE"
echo "vkms_module=$VKMS_MODULE"
echo "build_dir=$BUILD_DIR"
