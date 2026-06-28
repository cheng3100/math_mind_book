#!/usr/bin/env bash
set -euo pipefail

# TASK 1: Boot the built Linux image in QEMU and load VKMS inside the guest.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="${1:-/home/cheng/work/os/linux/linux}"
BUILD_DIR="${2:-$SCRIPT_DIR/task1-runtime/linux-build}"
WORK_DIR="${3:-$SCRIPT_DIR/task1-runtime}"
KERNEL="$BUILD_DIR/arch/x86/boot/bzImage"
VKMS_MODULE="$BUILD_DIR/drivers/gpu/drm/vkms/vkms.ko"
INITRAMFS_DIR="$WORK_DIR/initramfs"
INITRAMFS_IMG="$WORK_DIR/initramfs.cpio.gz"
PREPARED_BUSYBOX="$SCRIPT_DIR/task1-runtime/busybox/install/busybox"
TOOLS_DIR="$SCRIPT_DIR/tools-install"
TOOLS_LD_LIBRARY_PATH="$TOOLS_DIR/lib:$TOOLS_DIR/lib64:$TOOLS_DIR/lib/x86_64-linux-gnu:$TOOLS_DIR/libexec/igt-gpu-tools"
BUSYBOX="${BUSYBOX:-}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
TASK1_SMOKE_TEST="${TASK1_SMOKE_TEST:-0}"
TASK2_SMOKE_TEST="${TASK2_SMOKE_TEST:-0}"

if [ ! -f "$KERNEL" ]; then
  echo "TASK 1 error: missing kernel image: $KERNEL" >&2
  echo "Run task1_build_linux.sh first." >&2
  exit 1
fi

if [ ! -f "$VKMS_MODULE" ]; then
  echo "TASK 1 error: missing VKMS module: $VKMS_MODULE" >&2
  echo "Run task1_build_linux.sh first." >&2
  exit 1
fi

if [ -z "$BUSYBOX" ]; then
  if [ ! -x "$PREPARED_BUSYBOX" ]; then
    echo "TASK 1: static BusyBox not found; building it from source."
    "$SCRIPT_DIR/task1_prepare_busybox.sh"
  fi
  BUSYBOX="$PREPARED_BUSYBOX"
fi

if [ ! -x "$BUSYBOX" ]; then
  echo "TASK 1 error: busybox is required to build the initramfs: $BUSYBOX" >&2
  echo "Pass BUSYBOX=/path/to/static/busybox or run task1_prepare_busybox.sh." >&2
  exit 1
fi

if ldd "$BUSYBOX" >/dev/null 2>&1; then
  echo "TASK 1 error: busybox appears to be dynamically linked: $BUSYBOX" >&2
  echo "Use a static busybox, e.g. BUSYBOX=/path/to/busybox-static." >&2
  exit 1
fi

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "TASK 1 error: missing QEMU binary: $QEMU_BIN" >&2
  exit 1
fi

for tool in cpio gzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "TASK 1 error: missing host tool: $tool" >&2
    exit 1
  fi
done

mkdir -p "$INITRAMFS_DIR"/{bin,sbin,proc,sys,dev,tmp,mnt,kbuild,tools,sys/fs/bpf}
cp "$BUSYBOX" "$INITRAMFS_DIR/bin/busybox"

for applet in sh mount umount mkdir cat ls grep head tail sleep dmesg insmod modprobe uname test sync poweroff reboot; do
  ln -sf busybox "$INITRAMFS_DIR/bin/$applet"
done

copy_host_dep_to_initramfs() {
  local dep="$1"

  if [ -z "$dep" ] || [ ! -e "$dep" ]; then
    return 0
  fi

  case "$dep" in
    "$TOOLS_DIR"/*)
      return 0
      ;;
  esac

  mkdir -p "$INITRAMFS_DIR$(dirname "$dep")"
  cp -L "$dep" "$INITRAMFS_DIR$dep"
}

copy_binary_host_deps() {
  local binary="$1"

  if [ ! -x "$binary" ]; then
    return 0
  fi

  LD_LIBRARY_PATH="$TOOLS_LD_LIBRARY_PATH" ldd "$binary" |
    sed -n -e 's/.*=> \([^ ]*\) .*/\1/p' -e 's/^[[:space:]]*\(\/[^ ]*\) .*/\1/p' |
    while IFS= read -r dep; do
      copy_host_dep_to_initramfs "$dep"
    done
}

if [ "$TASK2_SMOKE_TEST" = "1" ]; then
  copy_binary_host_deps "$TOOLS_DIR/bin/modetest"
  copy_binary_host_deps "$TOOLS_DIR/libexec/igt-gpu-tools/kms_getfb"
fi

cat >"$INITRAMFS_DIR/init" <<'INIT'
#!/bin/sh
set -eu

echo "TASK 1 guest: booted initramfs"

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mount -t tmpfs none /tmp
mkdir -p /sys/kernel/tracing /sys/kernel/debug /sys/fs/bpf /mnt /kbuild /tools
mount -t tracefs nodev /sys/kernel/tracing || true
mount -t debugfs nodev /sys/kernel/debug || true
mount -t bpf bpffs /sys/fs/bpf || true
mount -t 9p -o trans=virtio,version=9p2000.L host0 /mnt || echo "TASK 1 guest warning: failed to mount host0"
mount -t 9p -o trans=virtio,version=9p2000.L kbuild /kbuild || echo "TASK 1 guest warning: failed to mount kbuild"
mount -t 9p -o trans=virtio,version=9p2000.L tools /tools || echo "TASK 1 guest warning: failed to mount tools"

TOOLS_BASE=/tools
if [ ! -x /tools/bin/modetest ] && [ -x /mnt/tools-install/bin/modetest ]; then
  TOOLS_BASE=/mnt/tools-install
fi

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:$TOOLS_BASE/bin:$TOOLS_BASE/libexec/igt-gpu-tools:$TOOLS_BASE/libexec/installed-tests/igt-gpu-tools
export LD_LIBRARY_PATH=$TOOLS_BASE/lib:$TOOLS_BASE/lib64:$TOOLS_BASE/lib/x86_64-linux-gnu:$TOOLS_BASE/libexec/igt-gpu-tools:/lib:/lib64:/lib/x86_64-linux-gnu:/usr/lib:/usr/lib/x86_64-linux-gnu:/usr/local/lib:/usr/local/lib/x86_64-linux-gnu

echo "TASK 1 guest: kernel"
uname -a

echo "TASK 1 guest: loading vkms"
insmod /kbuild/drivers/gpu/drm/vkms/vkms.ko \
  enable_cursor=1 \
  enable_writeback=1 \
  enable_overlay=1 \
  enable_plane_pipeline=1 \
  create_default_dev=1 || {
    echo "TASK 1 guest error: failed to insmod vkms"
    dmesg | tail -80
    exec sh
  }

echo "TASK 1 guest: /dev/dri"
ls -l /dev/dri || true

echo "TASK 1 guest: VKMS symbols"
grep -E '(^| )vkms_|drm_atomic|drm_mode' /sys/kernel/tracing/available_filter_functions | head -80 || true

echo "TASK 1 guest: ready"
if [ "__TASK2_SMOKE_TEST__" = "1" ]; then
  TASK2_STATUS=0
  echo "TASK 2 guest: tools base $TOOLS_BASE"
  if [ ! -x "$TOOLS_BASE/bin/modetest" ]; then
    echo "TASK 2 guest error: missing $TOOLS_BASE/bin/modetest"
    ls -l /tools /mnt/tools-install 2>/dev/null || true
    TASK2_STATUS=1
  fi

  echo "TASK 2 guest: modetest connector enumeration"
  "$TOOLS_BASE/bin/modetest" -M vkms -c || {
    echo "TASK 2 guest error: modetest failed"
    dmesg | tail -120
    TASK2_STATUS=1
  }

  echo "TASK 2 guest: IGT kms_getfb getfb-handle-valid"
  IGT_FORCE_DRIVER=vkms "$TOOLS_BASE/libexec/igt-gpu-tools/kms_getfb" \
    --device drm:/dev/dri/card0 \
    --run-subtest getfb-handle-valid || {
    echo "TASK 2 guest error: IGT kms_getfb failed"
    dmesg | tail -120
    TASK2_STATUS=1
  }

  if [ "$TASK2_STATUS" = "0" ]; then
    echo "TASK 2 guest: smoke test passed"
  fi
fi

if [ "__TASK1_SMOKE_TEST__" = "1" ]; then
  if test -e /dev/dri/card0; then
    echo "TASK 1 guest: smoke test passed"
  else
    echo "TASK 1 guest error: missing /dev/dri/card0"
    dmesg | tail -120
  fi
  sync
  poweroff -f || reboot -f || exit 0
fi

exec sh
INIT

sed -i "s/__TASK1_SMOKE_TEST__/$TASK1_SMOKE_TEST/g" "$INITRAMFS_DIR/init"
sed -i "s/__TASK2_SMOKE_TEST__/$TASK2_SMOKE_TEST/g" "$INITRAMFS_DIR/init"

chmod +x "$INITRAMFS_DIR/init"

(
  cd "$INITRAMFS_DIR"
  find . -print0 | cpio --null -ov --format=newc | gzip -9 >"$INITRAMFS_IMG"
)

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  MACHINE_ARGS=(-machine q35,accel=kvm -cpu host)
else
  MACHINE_ARGS=(-machine q35,accel=tcg -cpu max)
fi

mkdir -p "$TOOLS_DIR"

echo "TASK 1: kernel: $KERNEL"
echo "TASK 1: initramfs: $INITRAMFS_IMG"
echo "TASK 1: VKMS module: $VKMS_MODULE"

exec "$QEMU_BIN" \
  "${MACHINE_ARGS[@]}" \
  -smp 4 \
  -m 4096 \
  -kernel "$KERNEL" \
  -initrd "$INITRAMFS_IMG" \
  -append "console=ttyS0 rdinit=/init nokaslr loglevel=7 drm.debug=0x1ff" \
  -nographic \
  -virtfs local,path="$SCRIPT_DIR",mount_tag=host0,security_model=none,id=host0 \
  -virtfs local,path="$BUILD_DIR",mount_tag=kbuild,security_model=none,id=kbuild \
  -virtfs local,path="$TOOLS_DIR",mount_tag=tools,security_model=none,id=tools
