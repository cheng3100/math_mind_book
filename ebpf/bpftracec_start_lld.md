# bpftrace 起步：以 VKMS 构造可观测的 DRM Driver 实验环境

## 背景

`ebpf/README.md` 第 4 节建议学习顺序是：

```text
tracefs / ftrace
    -> bpftrace
        -> BCC
            -> libbpf + CO-RE
                -> driver 原生 tracepoint + 用户态分析器
```

本文件作为 `bpftrace` 阶段的第一个可执行拆解。目标不是先写复杂 BPF 程序，而是先建立一个稳定、可重复、可触发复杂 DRM/KMS 内部路径的实验环境。

本阶段选择 VKMS（Virtual Kernel Mode Setting）作为测试 driver：

- 不依赖真实 GPU 硬件；
- 走 DRM/KMS 的 modeset、atomic commit、page flip、vblank、writeback、plane、format、CRC 等通用路径；
- 适合作为后续映射 GPU KMD / Memory Manager / Scheduler / fence / IRQ 路径之前的最小 driver 观测对象。

本地参考 Linux 代码目录默认：

```text
/home/cheng/work/os/linux/linux
```

当前本地源码中 VKMS 关键文件：

```text
drivers/gpu/drm/vkms/vkms_drv.c
drivers/gpu/drm/vkms/vkms_crtc.c
drivers/gpu/drm/vkms/vkms_plane.c
drivers/gpu/drm/vkms/vkms_composer.c
drivers/gpu/drm/vkms/vkms_writeback.c
drivers/gpu/drm/vkms/vkms_connector.c
drivers/gpu/drm/vkms/vkms_config.c
drivers/gpu/drm/vkms/vkms_configfs.c
drivers/gpu/drm/vkms/vkms_colorop.c
```

## 本次子任务拆分

### TASK 1 / 子任务 1：QEMU + 自编译 Linux + VKMS 环境

目标：

```text
host Linux source
  -> 编译 bzImage / modules
  -> QEMU 启动最小 guest
  -> guest 内加载 vkms
  -> /dev/dri/card0 可用
  -> bpftrace 可 attach 内核函数和 tracepoint
```

关键要求：

- Linux 源码目录通过参数配置；
- 默认源码目录为 `/home/cheng/work/os/linux/linux`；
- VKMS 可以编进内核或作为模块，建议第一阶段用模块；
- guest 内必须有 `tracefs`、`debugfs`、`bpffs`；
- 内核需要开启 BPF、BTF、kprobe、ftrace、DRM、VKMS。

建议目录：

```text
ebpf/
├── env.sh
├── bpftracec_start_lld.md
└── vkms_lab/
    ├── task1_build_linux.sh
    ├── task1_prepare_busybox.sh
    ├── task1_run_qemu.sh
    ├── task2_fetch_drm_tools.sh
    ├── task2_build_drm_tools.sh
    ├── traces/
    │   ├── ioctl.bt
    │   ├── vkms-callback-count.bt
    │   ├── atomic-latency.bt
    │   └── vkms-async.bt
    ├── external/
    │   ├── libdrm/
    │   └── igt-gpu-tools/
    ├── tools-build/
    ├── tools-install/
    ├── rootfs/
    └── tests/
```

### TASK 2 / 子任务 2：VKMS 用户态触发器：优先使用 modetest + IGT

目标：

```text
modetest
  -> 轻量枚举 connector / crtc / plane / property
  -> 手动触发 modeset / plane update / atomic commit

IGT
  -> 系统化触发 KMS / DRM ioctl / dumb buffer / addfb
  -> 覆盖 atomic / page flip / vblank / CRC / cursor / plane / writeback
  -> 输出 pass/fail，便于和 eBPF trace 对齐
```

结论：`modetest` 和 IGT 对第一阶段 eBPF 抓取测试已经足够丰富，应替代手写 GTest 作为默认触发器。手写 GTest 只保留为补洞方案，用于构造现有工具不方便稳定触发的极窄路径。

### TASK 3 / 子任务 3：bpftrace 使用分层

目标：

```text
modetest / IGT action
  -> syscall / ioctl
  -> DRM core
  -> atomic helper
  -> VKMS callback
  -> vblank timer / composer workqueue / writeback
  -> bpftrace 输出可解释 timeline
```

使用方式分成两层：

- 简单命令行版本：只放短命令和 one-liner，用于环境检查、确认函数是否存在、快速计数；
- 独立 trace 文件：复杂过滤、状态关联、耗时统计、stack trace、异步路径关联都写入 `ebpf/vkms_lab/traces/*.bt`。

第一阶段优先使用：

- `tracepoint:syscalls:*`;
- `kprobe/kretprobe`;
- `tracepoint:sched:*`;
- `tracepoint:workqueue:*`;
- `tracepoint:drm:*`，如果目标内核导出；
- `profile` / `interval` 做周期性摘要。

## Host 依赖安装脚本

已实现 `ebpf/env.sh`，用于归纳 TASK 1/2 所需的系统级工具和开发库：

```bash
./ebpf/env.sh
```

边界：

- `env.sh` 只处理编译器、构建工具、QEMU、Meson/Ninja、内核构建依赖、IGT/libdrm 构建依赖；
- TASK 1 中 BusyBox 这类实验材料通过 `task1_prepare_busybox.sh` 从源码下载编译；
- TASK 2 中 libdrm/IGT 通过 `task2_fetch_drm_tools.sh` 从源码下载；
- 任务脚本不会自动执行 `env.sh`，缺系统工具时只报错并提示手动运行。

## TASK 1：Linux 编译脚本

已实现为 `ebpf/vkms_lab/task1_build_linux.sh`。脚本负责：

- 以 `/home/cheng/work/os/linux/linux` 为默认 Linux 源码目录；
- 输出目录默认是 `ebpf/vkms_lab/task1-runtime/linux-build`，避免修改 Linux 源码树；
- 配置 BPF / BTF / kprobe / ftrace / DRM / VKMS / 9p / virtio / initramfs；
- 编译 `bzImage` 和 modules；
- 检查 `arch/x86/boot/bzImage` 和 `drivers/gpu/drm/vkms/vkms.ko` 是否生成。
- 检查 `make`、`gcc`、`bc`、`bison`、`flex`、`pahole` 等 host 工具；缺失时提示执行 `ebpf/env.sh`。

使用方式：

```bash
cd ebpf/vkms_lab

# 默认 Linux 源码目录：/home/cheng/work/os/linux/linux
./task1_build_linux.sh

# 显式指定 Linux 源码和输出目录
./task1_build_linux.sh /home/cheng/work/os/linux/linux ./task1-runtime/linux-build
```

说明：

- `CONFIG_DEBUG_INFO_BTF` 用于后续从 bpftrace 过渡到 CO-RE；
- `CONFIG_DRM_VKMS=m` 便于通过 `insmod vkms.ko enable_*=` 参数组合触发不同路径；
- 如果构建机缺少 `pahole`，`CONFIG_DEBUG_INFO_BTF` 会失败，应先安装 `dwarves`；
- `scripts/config` 在 Linux 源码目录下，脚本里显式使用 `"$LINUX_DIR/scripts/config"`，避免依赖当前工作目录。

## TASK 1：QEMU 启动脚本

BusyBox 材料不依赖发行版二进制。已实现 `ebpf/vkms_lab/task1_prepare_busybox.sh`，用于从 BusyBox 源码下载并编译静态 busybox：

```bash
cd ebpf/vkms_lab
./task1_prepare_busybox.sh
```

已实现为 `ebpf/vkms_lab/task1_run_qemu.sh`。脚本负责：

- 检查 kernel image 和 `vkms.ko` 是否存在；
- 如果没有显式传入 `BUSYBOX`，优先使用 `task1_prepare_busybox.sh` 生成的静态 busybox；
- 使用静态 busybox 生成最小 initramfs；
- 自动选择 KVM 或 TCG；
- 通过 9p 挂载仓库目录、kernel build 目录和 `tools-install/`；
- guest `/init` 内挂载 `proc`、`sysfs`、`devtmpfs`、`tracefs`、`debugfs`、`bpffs`；
- guest 内执行 `insmod /kbuild/drivers/gpu/drm/vkms/vkms.ko ...`；
- 输出 `/dev/dri` 和 VKMS 可 probe 函数。

使用方式：

```bash
cd ebpf/vkms_lab

# 默认会在缺少静态 busybox 时自动调用 task1_prepare_busybox.sh。
./task1_run_qemu.sh

# 也可以显式指定已有的静态 busybox、Linux 源码和 build 目录。
BUSYBOX=/path/to/static/busybox \
  ./task1_run_qemu.sh /home/cheng/work/os/linux/linux ./task1-runtime/linux-build
```

如果宿主机没有 KVM 权限，脚本会自动使用 `-machine q35,accel=tcg -cpu max`。

如果后续想测试 configfs 动态拓扑，应改成：

```sh
insmod /kbuild/drivers/gpu/drm/vkms/vkms.ko create_default_dev=0
mount -t configfs none /sys/kernel/config
```

然后通过 `/sys/kernel/config/vkms/` 创建 device、crtc、plane、encoder、connector，再触发 `vkms_create()`。

## modetest + IGT 触发器设计

### 是否足够替代手写 GTest

结论：满足，而且更适合作为第一阶段默认方案。

`modetest` 来自 libdrm，优点是轻量、参数透明、容易和 bpftrace 的一次观测窗口对齐。它适合做 smoke test 和手动构造单次 modeset / plane update / atomic commit。

IGT 是 DRM/KMS 的系统测试套件，覆盖面远高于临时手写 GTest。对 VKMS 来说，IGT 能稳定触发 KMS ioctl、dumb buffer、addfb、atomic commit、page flip、vblank、CRC、cursor、plane、writeback 等路径，并且每个测试自带 pass/fail 语义，便于把 eBPF trace 和行为结果对齐。

手写 GTest 的主要价值变成补洞：

- 需要精确控制某个 ioctl 参数组合，而 `modetest` 和 IGT 没有现成入口；
- 需要构造错误路径、边界参数或 race 窗口；
- 需要长期固定一个最小 reproducer，避免 IGT 子测试变更带来的干扰。

### 工具覆盖对比

| 触发目标 | modetest | IGT | 是否需要手写 GTest |
| --- | --- | --- | --- |
| open / close DRM fd | 支持 | 支持 | 不需要 |
| connector / crtc / plane / property 枚举 | 很适合 | 支持 | 不需要 |
| dumb buffer / addfb | modeset/plane 时隐式触发 | 多个测试覆盖 | 不需要 |
| legacy modeset | 支持 | 覆盖充分 | 不需要 |
| atomic modeset / commit | 支持，适合单次触发 | 覆盖充分 | 通常不需要 |
| primary plane update | 支持 | 覆盖充分 | 不需要 |
| cursor / overlay plane | 可手动指定 plane | 覆盖更系统 | 通常不需要 |
| page flip / vblank event | 有限 | 覆盖充分 | 不需要 |
| CRC / composer | 不适合 | 覆盖充分 | 不需要 |
| writeback connector | 不适合或依赖版本能力 | 覆盖更系统 | 通常不需要 |
| 错误路径 / 特定 race | 不适合 | 部分覆盖 | 可能需要 |

### 源码下载与编译原则

这里不直接依赖发行版预装的 `modetest` / IGT 二进制。原因是本阶段的目的不是单纯“跑测试”，而是明确每个测试到底调用了哪些 DRM ioctl、libdrm helper 和 IGT helper。

建议固定源码来源和 commit：

```text
libdrm:
  upstream: https://gitlab.freedesktop.org/mesa/drm.git
  关注文件: tests/modetest/modetest.c

IGT:
  upstream: https://gitlab.freedesktop.org/drm/igt-gpu-tools.git
  关注文件: tests/kms_*.c, tests/core_*.c, tests/dumb_buffer.c
  关键公共库: lib/igt_kms.c, lib/igt_fb.c, lib/drmtest.c
```

下载后必须记录：

- 上游仓库地址；
- checkout commit；
- 下载日期；
- 本次运行的测试二进制和子测试；
- 对应源码文件和核心函数。

### TASK 2 下载脚本

已实现为 `ebpf/vkms_lab/task2_fetch_drm_tools.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

# TASK 2: Fetch libdrm and IGT source code for source-level test analysis.

BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
EXTERNAL_DIR="$BASE_DIR/external"
LIBDRM_REPO="${LIBDRM_REPO:-https://gitlab.freedesktop.org/mesa/drm.git}"
IGT_REPO="${IGT_REPO:-https://gitlab.freedesktop.org/drm/igt-gpu-tools.git}"

# Set these explicitly for reproducible experiments.
LIBDRM_COMMIT="${LIBDRM_COMMIT:-}"
IGT_COMMIT="${IGT_COMMIT:-}"

mkdir -p "$EXTERNAL_DIR"

clone_or_update() {
  local repo_url="$1"
  local dst="$2"
  local commit="$3"

  if [ ! -d "$dst/.git" ]; then
    git clone "$repo_url" "$dst"
  else
    git -C "$dst" fetch --all --tags
  fi

  if [ -n "$commit" ]; then
    git -C "$dst" checkout "$commit"
  fi

  git -C "$dst" rev-parse HEAD
}

echo "libdrm commit:"
clone_or_update "$LIBDRM_REPO" "$EXTERNAL_DIR/libdrm" "$LIBDRM_COMMIT"

echo "igt-gpu-tools commit:"
clone_or_update "$IGT_REPO" "$EXTERNAL_DIR/igt-gpu-tools" "$IGT_COMMIT"
```

使用方式：

```bash
cd ebpf/vkms_lab

# 第一次可先不指定 commit，clone 后记录 HEAD；稳定实验应再固定到具体 commit。
./task2_fetch_drm_tools.sh "$PWD"

git -C external/libdrm rev-parse HEAD
git -C external/igt-gpu-tools rev-parse HEAD
```

### TASK 2 编译脚本

已实现为 `ebpf/vkms_lab/task2_build_drm_tools.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

# TASK 2: Build modetest from libdrm and KMS tests from IGT.

BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
EXTERNAL_DIR="$BASE_DIR/external"
INSTALL_DIR="$BASE_DIR/tools-install"
BUILD_ROOT="$BASE_DIR/tools-build"
JOBS="${JOBS:-$(nproc)}"

LIBDRM_SRC="$EXTERNAL_DIR/libdrm"
IGT_SRC="$EXTERNAL_DIR/igt-gpu-tools"
LIBDRM_BUILD="$BUILD_ROOT/libdrm"
IGT_BUILD="$BUILD_ROOT/igt-gpu-tools"

mkdir -p "$BUILD_ROOT" "$INSTALL_DIR"

if [ ! -d "$LIBDRM_SRC/.git" ] || [ ! -d "$IGT_SRC/.git" ]; then
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

export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig:$INSTALL_DIR/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:$INSTALL_DIR/lib64:${LD_LIBRARY_PATH:-}"

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
```

说明：

- `modetest` 来自 libdrm 源码，主要源码入口是 `external/libdrm/tests/modetest/modetest.c`；
- IGT 构建依赖较多，缺包时优先按 `meson setup` 的错误安装依赖，不要改源码绕过；
- `task2_build_drm_tools.sh` 会检查 `meson`、`ninja`、`pkg-config`、`gcc`、`g++`、`python3`；缺失时提示执行 `ebpf/env.sh`；
- 如果某个 Meson option 因版本变化不存在，先执行 `meson configure <build-dir>` 或查看对应项目的 `meson_options.txt`，再记录本次调整；
- 编译产物放在 `ebpf/vkms_lab/tools-build/` 和 `ebpf/vkms_lab/tools-install/`，不应纳入版本控制。
- `external/` 是下载的参考源码目录，若后续放入仓库，应按本仓库约定记录 commit；`tools-build/` 和 `tools-install/` 应加入 `.gitignore`。

### guest 中运行自编译工具

QEMU 启动脚本已经建议通过 9p 挂载 `rootfs` 和 kernel build dir。这里再增加一个 tools 挂载会更方便：

```bash
-virtfs local,path="$PWD/tools-install",mount_tag=tools,security_model=none,id=tools
```

guest `/init` 中挂载：

```sh
mkdir -p /tools
mount -t 9p -o trans=virtio tools /tools
export PATH=/tools/bin:/tools/libexec/igt-gpu-tools:/tools/libexec/installed-tests/igt-gpu-tools:$PATH
export LD_LIBRARY_PATH=/tools/lib:/tools/lib64:$LD_LIBRARY_PATH
```

不同 IGT 版本的安装路径不完全相同，进入 guest 后用源码编译产物定位真实路径：

```bash
find /tools -type f -name modetest
find /tools -type f \( -name 'kms_flip' -o -name 'kms_atomic' -o -name 'kms_writeback' \)
```

### 从源码反查每个测试做了什么

运行任何测试前，先定位源码入口：

```bash
rg -n "drmModeAtomicCommit|drmModeSetCrtc|drmModePageFlip|DRM_IOCTL_MODE_CREATE_DUMB|DRM_IOCTL_MODE_ADDFB2" \
  external/libdrm/tests/modetest \
  external/igt-gpu-tools/tests \
  external/igt-gpu-tools/lib

rg -n "igt_subtest|igt_describe|for_each_pipe|for_each_valid_output_on_pipe|igt_create_fb|igt_display_commit" \
  external/igt-gpu-tools/tests/kms_atomic.c \
  external/igt-gpu-tools/tests/kms_flip.c \
  external/igt-gpu-tools/tests/kms_plane.c \
  external/igt-gpu-tools/tests/kms_writeback.c \
  external/igt-gpu-tools/lib
```

第一阶段建议重点阅读：

| 工具/测试 | 源码入口 | 阅读重点 |
| --- | --- | --- |
| `modetest` | `external/libdrm/tests/modetest/modetest.c` | 参数解析、connector/plane 枚举、`drmModeSetCrtc`、atomic property commit |
| `kms_atomic` | `external/igt-gpu-tools/tests/kms_atomic.c` | atomic state 构造、property 设置、commit flag |
| `kms_flip` | `external/igt-gpu-tools/tests/kms_flip.c` | page flip、event、vblank 等待 |
| `kms_vblank` | `external/igt-gpu-tools/tests/kms_vblank.c` | vblank ioctl、event/sequence |
| `kms_plane` | `external/igt-gpu-tools/tests/kms_plane.c` | primary/overlay/cursor plane 更新 |
| `kms_cursor_crc` | `external/igt-gpu-tools/tests/kms_cursor_crc.c` | cursor plane + CRC |
| `kms_pipe_crc_basic` | `external/igt-gpu-tools/tests/kms_pipe_crc_basic.c` | CRC source 打开、读取、校验 |
| `kms_writeback` | `external/igt-gpu-tools/tests/kms_writeback.c` | writeback connector、output FB、out fence |
| IGT KMS helper | `external/igt-gpu-tools/lib/igt_kms.c` | display/pipe/output 抽象如何落到 DRM ioctl |
| IGT FB helper | `external/igt-gpu-tools/lib/igt_fb.c` | FB 创建、格式、modifier、dumb/BO 路径 |

### modetest 建议用法

先枚举资源：

```bash
modetest -M vkms -c
modetest -M vkms -p
modetest -M vkms -e
```

记录：

```text
connector_id
crtc_id
primary_plane_id
cursor_plane_id
overlay_plane_id
mode，例如 640x480 或 1024x768
format，例如 XR24 / AR24
```

触发一次 atomic modeset：

```bash
modetest -M vkms -a -s <connector_id>@<crtc_id>:640x480
```

触发 plane update：

```bash
modetest -M vkms -a \
  -s <connector_id>@<crtc_id>:640x480 \
  -P <plane_id>@<crtc_id>:640x480+0+0@XR24
```

触发 overlay 或 cursor 时，换成对应 plane id，并调整尺寸和位置：

```bash
modetest -M vkms -a \
  -s <connector_id>@<crtc_id>:640x480 \
  -P <primary_plane_id>@<crtc_id>:640x480+0+0@XR24 \
  -P <overlay_plane_id>@<crtc_id>:320x240+64+64@XR24
```

`modetest` 的作用边界：

- 很适合控制单次提交，方便观察 `DRM_IOCTL_MODE_ATOMIC -> vkms_* callback`；
- 不适合作为 CRC、writeback、长时间 page flip 压力和复杂断言的主工具；
- 不同 libdrm 版本的参数细节可能略有差异，实际以 `modetest -h` 为准。

### IGT 建议用法

先列出可用测试和子测试：

```bash
MODETEST_BIN="$(find /tools -type f -name modetest | head -1)"
IGT_TEST_DIR="$(dirname "$(find /tools -type f -name kms_flip | head -1)")"

"$MODETEST_BIN" -M vkms -c
ls "$IGT_TEST_DIR"/kms_*
"$IGT_TEST_DIR/kms_flip" --list-subtests
"$IGT_TEST_DIR/kms_atomic" --list-subtests
"$IGT_TEST_DIR/kms_plane" --list-subtests
"$IGT_TEST_DIR/kms_writeback" --list-subtests
```

QEMU guest 里只有 VKMS 一个 DRM device 时，通常不需要额外选择设备；如果有多个 DRM device，应优先使用 IGT 支持的 device 选择参数或环境变量，把测试限定到 `vkms`。

建议第一阶段按类别运行，而不是一上来跑完整 IGT：

| 类别 | 代表测试二进制 | 主要触发路径 |
| --- | --- | --- |
| 基础 ioctl / 资源枚举 | `core_*`、`drm_*`、`kms_getfb` | open、ioctl、object lookup |
| dumb buffer / framebuffer | `kms_addfb_basic`、`dumb_buffer` | GEM shmem、FB create/remove |
| atomic commit | `kms_atomic`、`kms_atomic_transition` | atomic check/commit/helper |
| page flip / vblank | `kms_flip`、`kms_vblank` | flip done、vblank event |
| plane / cursor | `kms_plane`、`kms_cursor_crc` | plane update、cursor update、CRC |
| CRC / composer | `kms_pipe_crc_basic`、`kms_cursor_crc`、`kms_plane` | `vkms_set_crc_source`、composer workqueue |
| writeback | `kms_writeback` | writeback job、row writeback |

建议执行顺序：

```text
modetest 资源枚举
  -> modetest 单次 atomic modeset
  -> modetest primary/overlay plane update
  -> IGT kms_addfb_basic / dumb_buffer
  -> IGT kms_atomic
  -> IGT kms_flip / kms_vblank
  -> IGT kms_pipe_crc_basic / kms_cursor_crc / kms_plane
  -> IGT kms_writeback
```

直接运行单个 IGT 测试时，先用 `--list-subtests` 挑最小子测试，再运行：

```bash
"$IGT_TEST_DIR/kms_atomic" --list-subtests
"$IGT_TEST_DIR/kms_atomic" --run-subtest <subtest>

"$IGT_TEST_DIR/kms_flip" --list-subtests
"$IGT_TEST_DIR/kms_flip" --run-subtest <subtest>
```

第一阶段建议直接运行单个测试并保存日志，后续和 bpftrace 日志按时间对齐：

```bash
"$IGT_TEST_DIR/kms_atomic" --run-subtest <subtest> 2>&1 | tee /tmp/igt-kms_atomic.log
"$IGT_TEST_DIR/kms_flip" --run-subtest <subtest> 2>&1 | tee /tmp/igt-kms_flip.log
"$IGT_TEST_DIR/kms_plane" --run-subtest <subtest> 2>&1 | tee /tmp/igt-kms_plane.log
```

如果后续要批量跑测试，再使用同一份 IGT 源码编译出的 `igt-runner`；具体参数以 `/tools` 中的 `igt-runner --help` 为准。

IGT 的作用边界：

- 覆盖足够丰富，适合作为 bpftrace 抓取的主触发器；
- 子测试数量多，直接全量运行会产生大量 trace 噪声；
- 某些子测试可能因为 VKMS 能力、内核版本、rootfs 权限或缺少 debugfs/CRC 支持而 skip；
- 对 eBPF 学习而言，优先选择单个子测试并固定命令，避免一次 trace 里混入太多 transaction。

## bpftrace 使用：命令行短命令

### 环境检查

```bash
mount | grep -E 'tracefs|debugfs|bpf'
ls -l /sys/kernel/btf/vmlinux
sudo bpftrace --info
sudo bpftrace -l 'kprobe:vkms_*'
sudo bpftrace -l 'kprobe:drm_atomic*'
sudo bpftrace -l 'tracepoint:drm:*'
sudo bpftrace -l 'tracepoint:workqueue:*'
```

如果 `kprobe:vkms_*` 查不到，优先检查：

- `vkms.ko` 是否已加载；
- `/proc/kallsyms` 是否可读；
- `kptr_restrict`；
- 内核是否开启 `CONFIG_KPROBES` / `CONFIG_KPROBE_EVENTS`。

### 快速确认 ioctl 是否发生

```bash
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_ioctl { @[comm] = count(); }'
```

用途：

- 先确认当前测试是否产生 ioctl；
- 只用于粗筛，不做复杂进程过滤。

### 快速确认 VKMS callback 是否触发

```bash
sudo bpftrace -e 'kprobe:vkms_* { @[probe] = count(); }'
```

用途：

- 先看 `modetest` / IGT 是否进入 VKMS；
- 如果输出太多，改用 `traces/vkms-callback-count.bt`。

### 快速确认 atomic commit 入口

```bash
sudo bpftrace -e 'kprobe:drm_atomic_commit,kprobe:drm_atomic_nonblocking_commit { printf("%s %s tid=%d\n", comm, probe, tid); }'
```

用途：

- 只确认是否走 atomic commit；
- 延迟统计使用 `traces/atomic-latency.bt`。

### 快速确认 composer / writeback

```bash
sudo bpftrace -e 'kprobe:vkms_crtc_handle_vblank_timeout,kprobe:vkms_composer_worker,kprobe:vkms_wb_atomic_commit { @[probe] = count(); }'
```

预期：

- 未打开 CRC / composer 时，vblank 可能出现，但 composer worker 不一定频繁执行；
- 打开 CRC source 后，`vkms_crtc_handle_vblank_timeout()` 会设置 `crc_pending` 并 queue `vkms_composer_worker()`；
- overlay、plane pipeline、writeback 会增加 composer 内部工作。

## bpftrace 使用：独立 trace 文件

复杂观测统一放到 `ebpf/vkms_lab/traces/*.bt`。运行方式：

```bash
sudo bpftrace ebpf/vkms_lab/traces/ioctl.bt
sudo bpftrace ebpf/vkms_lab/traces/vkms-callback-count.bt
sudo bpftrace ebpf/vkms_lab/traces/atomic-latency.bt
sudo bpftrace ebpf/vkms_lab/traces/vkms-async.bt
```

trace 文件分工：

| 文件 | 作用 |
| --- | --- |
| `ioctl.bt` | 过滤 `modetest` / IGT 进程，输出 ioctl cmd 和 pid/tid |
| `vkms-callback-count.bt` | 聚合 VKMS / DRM atomic callback 调用次数 |
| `atomic-latency.bt` | 关联 atomic commit enter/exit，输出返回值和耗时直方图 |
| `vkms-async.bt` | 观察 vblank、composer workqueue、writeback 的异步路径 |

### 高级特性放入 trace 文件的原则

- 多 probe 组合；
- `kprobe` + `kretprobe` 关联；
- `@start[tid]` 这类状态表；
- 直方图、top-N、周期性清理；
- 用户栈 / 内核栈；
- 结构体字段读取；
- vblank / workqueue / writeback 这类异步路径观察。

示例：需要抓用户栈和内核栈时，不写成很长的命令行，而是在新文件里增加，例如 `traces/atomic-stack.bt`：

```bpftrace
kprobe:vkms_atomic_commit_tail
/comm == "modetest" ||
 comm == "kms_atomic" ||
 comm == "kms_flip" ||
 comm == "kms_plane" ||
 comm == "kms_writeback"/
{
  printf("vkms_atomic_commit_tail comm=%s tid=%d\n", comm, tid);
  print(ustack(8));
  print(kstack(16));
}
```

高频路径不要长期打开 stack trace；先用计数定位，再临时打开 stack 文件。

## modetest / IGT 动作与预期 trace

### `OpenClose`

预期主路径：

```text
open /dev/dri/card0
  -> drm_open
  -> drm_file_alloc
close
  -> drm_release
```

bpftrace 验证：

```bash
sudo bpftrace -e '
kprobe:drm_open,kprobe:drm_file_alloc,kprobe:drm_release
/comm == "modetest" ||
 comm == "kms_atomic" ||
 comm == "kms_flip" ||
 comm == "kms_plane" ||
 comm == "kms_writeback" ||
 comm == "kms_addfb_basic" ||
 comm == "kms_cursor_crc" ||
 comm == "kms_pipe_crc_ba"/
{
  printf("%s tid=%d\n", probe, tid);
}
'
```

### `GetResources`

预期主路径：

```text
DRM_IOCTL_MODE_GETRESOURCES
  -> drm_ioctl_kernel
  -> DRM mode resource enumeration
  -> connector / crtc / encoder / plane object ids copied to userspace
```

重点不是 VKMS 私有函数，而是确认 DRM ioctl 入口和 mode object 查询。

### `DumbFbLifecycle`

预期主路径：

```text
DRM_IOCTL_MODE_CREATE_DUMB
  -> GEM shmem object create
DRM_IOCTL_MODE_ADDFB2
  -> drm_gem_fb_create
DRM_IOCTL_MODE_RMFB
  -> framebuffer cleanup
DRM_IOCTL_MODE_DESTROY_DUMB
  -> GEM object release
```

建议观测：

```bash
sudo bpftrace -e '
kprobe:drm_gem_fb_create,
kprobe:drm_gem_shmem_create,
kprobe:drm_mode_rmfb
/comm == "modetest" ||
 comm == "kms_addfb_basic" ||
 comm == "kms_atomic" ||
 comm == "kms_flip" ||
 comm == "kms_plane"/
{
  printf("%s\n", probe);
}
'
```

### `AtomicModeset`

预期主路径：

```text
DRM_IOCTL_MODE_ATOMIC
  -> drm_atomic_commit
  -> drm_atomic_check_only
  -> vkms_atomic_check
  -> drm_atomic_helper_check
  -> vkms_crtc_atomic_check
  -> vkms_plane_atomic_check
  -> drm_atomic_helper_commit
  -> vkms_atomic_commit_tail
  -> drm_atomic_helper_commit_modeset_disables
  -> drm_atomic_helper_commit_planes
  -> vkms_crtc_atomic_begin
  -> vkms_plane_atomic_update
  -> vkms_crtc_atomic_flush
  -> drm_atomic_helper_fake_vblank
  -> drm_atomic_helper_wait_for_flip_done
  -> drm_atomic_helper_cleanup_planes
```

正确 trace 特征：

- `vkms_atomic_check` 先于 `vkms_atomic_commit_tail`；
- `vkms_plane_atomic_check` 先于 `vkms_plane_atomic_update`；
- `vkms_crtc_atomic_begin` 与 `vkms_crtc_atomic_flush` 成对出现；
- `vkms_prepare_fb` / `vkms_cleanup_fb` 围绕 FB 生命周期出现；
- 如果 atomic 属性缺失，通常只能看到 check 路径并以负返回值结束。

### `PageFlip`

预期主路径：

```text
atomic update primary plane FB_ID
  -> vkms_plane_atomic_check
  -> vkms_plane_atomic_update
  -> vkms_crtc_atomic_flush
  -> vblank event armed/sent
  -> vkms_crtc_handle_vblank_timeout
```

正确 trace 特征：

- 每次换 FB 至少出现一次 plane update；
- 如果请求 event，`vkms_crtc_atomic_flush()` 中会处理 `crtc->state->event`；
- vblank timeout 路径由 DRM vblank timer 触发，执行上下文通常不是 `modetest` 或 IGT 测试线程。

### `CrcCapture`

预期主路径：

```text
enable crc source
  -> vkms_set_crc_source
vblank
  -> vkms_crtc_handle_vblank_timeout
  -> queue_work(composer_work)
workqueue
  -> vkms_composer_worker
  -> compose active planes
  -> produce crc
```

正确 trace 特征：

- `vkms_set_crc_source` 出现在开启 CRC 时；
- `vkms_composer_worker` 与 vblank 相关，但不一定一一对应；
- 如果 worker 落后，VKMS 代码中会走 `crc_pending` 相关逻辑。

### `OverlayPlane`

预期主路径：

```text
atomic commit with primary + overlay
  -> vkms_crtc_atomic_check
  -> active_planes 收集多个 visible plane
  -> vkms_plane_atomic_update
  -> composer worker 混合多个 plane
```

正确 trace 特征：

- `vkms_crtc_atomic_check` 中 active plane 数量应大于 1；
- `vkms_plane_atomic_update` 次数随被更新 plane 数变化；
- composer 路径比单 primary plane 更重。

### `Writeback`

预期主路径：

```text
atomic commit with writeback connector
  -> vkms_wb_atomic_check
  -> vkms_wb_prepare_job
  -> vkms_wb_atomic_commit
  -> composer/writeback
  -> vkms_writeback_row
  -> vkms_wb_cleanup_job
```

正确 trace 特征：

- 没有 writeback connector 或没有输出 FB 时，不应出现完整 `vkms_wb_*` 链路；
- `vkms_writeback_row` 调用次数与输出高度相关，建议用计数或聚合，不要逐行打印。

## 后续扩展方向

### 参数解析

bpftrace 第一阶段只统计函数是否出现、耗时和调用栈。后续可以逐步读取参数：

- `struct drm_atomic_commit *state`；
- `struct drm_crtc *crtc`；
- `struct drm_plane *plane`；
- `struct drm_plane_state *state`；
- `struct drm_framebuffer *fb`。

如果内核 BTF 可用，可以在 bpftrace 中用结构体字段访问；否则只做地址关联和 stack trace。

### transaction 关联

后续将一次 atomic commit 建模为 transaction：

```text
tid
  -> ioctl cmd
  -> drm_atomic_commit state pointer
  -> vkms callbacks
  -> vblank / workqueue async path
  -> completion / event
```

这会自然过渡到 GPU KMD 中更重要的链路：

```text
UMD ioctl
  -> KMD submit
  -> scheduler entity/job
  -> fence
  -> IRQ
  -> fence signal
  -> userspace wait returns
```

### 从 VKMS 映射到真实 GPU KMD

VKMS 对应真实 GPU driver 的学习价值：

| VKMS 路径 | 真实 GPU KMD 对应问题 |
| --- | --- |
| atomic commit | modeset/page flip commit 状态机 |
| plane update | scanout buffer / FB pin / format / modifier |
| vblank timer | hardware vblank IRQ |
| composer worker | display pipe / composition / writeback engine |
| writeback | copy/encode/display writeback job |
| GEM shmem dumb buffer | BO create/map/pin 基础路径 |
| CRC | display validation / pipe CRC |

VKMS 没有真实 MMIO、DMA、GPU scheduler、firmware 和硬件 IRQ，因此下一阶段应切到 `drm_sched`、`dma_fence`、`dma_resv`、GEM/TTM 或具体 GPU driver 路径。

## 待继续追踪的问题

- 是否采用 BusyBox rootfs、Debian initramfs，还是直接复用已有发行版 rootfs；
- 是否需要把 `external/libdrm`、`external/igt-gpu-tools` 作为长期参考源码保留，并为每次实验记录 commit；
- 是否保留少量手写 GTest，用于补充 IGT 不方便构造的错误路径或 race 窗口；
- bpftrace 是否能在目标 guest 内直接读取 BTF 类型；
- `tracepoint:drm:*` 在目标内核中实际导出了哪些事件；
- 是否需要为高频路径切换到 libbpf ring buffer，避免 bpftrace printf 扰动。
