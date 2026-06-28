# eBPF VKMS TASK 1/2 实施问题记录

## 背景

本文件记录实现 `ebpf/bpftracec_start_lld.md` 中 TASK 1/2 时遇到的实际问题、判断和修复方式。目标是后续 review 时能直接复核每个工程化选择，而不是只看最终脚本。

## TASK 1：Linux + QEMU + VKMS

### Linux build 输出目录不能默认放源码树

- 问题：默认把 kernel `O=` 输出放到 `/home/cheng/work/os/linux/linux/out-vkms-bpf` 时，当前工作区对 Linux 源码树只有读权限，无法写入。
- 修复：`task1_build_linux.sh` 默认改为输出到仓库内忽略目录 `ebpf/vkms_lab/task1-runtime/linux-build`。
- 影响：不污染外部 Linux 源码树，也符合本仓库只沉淀实验脚本和笔记的边界。

### BusyBox 不能依赖发行版二进制

- 问题：用户要求 BusyBox 这类实验材料尽量源码下载编译，而不是直接依赖宿主二进制。
- 修复：新增 `task1_prepare_busybox.sh`，从 BusyBox 官方 tarball 下载源码并构建 static busybox。
- 额外修复：BusyBox 没有 Linux kernel 那样的 `scripts/config`，脚本改为通过 `sed` 更新 `.config`；同时 `(yes "" || true) | make oldconfig` 避免 `pipefail` 下 `yes` 被 SIGPIPE 导致脚本失败。

### QEMU 需要可自动化自检

- 问题：默认 QEMU 进入 guest shell 会阻塞自动自检，无法无人值守确认 VKMS 是否加载成功。
- 修复：`task1_run_qemu.sh` 增加 `TASK1_SMOKE_TEST=1`，guest `/init` 检查 `/dev/dri/card0` 后执行 `poweroff -f`。
- 自检结果：QEMU guest 成功启动，`insmod vkms.ko` 成功，`/dev/dri/card0` 存在，tracefs 中可看到 DRM atomic/VKMS 相关可 probe 函数。

## TASK 2：modetest + IGT 源码构建

### 网络下载受沙箱限制

- 问题：首次执行 `task2_fetch_drm_tools.sh` 时无法访问 freedesktop GitLab。
- 修复：按权限流程请求网络访问后，从官方仓库下载 libdrm 和 IGT 源码。
- 当前记录：libdrm commit `35c7c536d5d1c0124a416a531df4432508d7d2f1`，IGT commit `4e472fee3a7fe2283b915781ed6386b38babdca2`。

### ccache 默认临时目录不可写

- 问题：Meson 使用 `/usr/bin/ccache cc`，ccache 尝试写 `/run/user/1000/ccache-tmp`，当前环境中该目录只读。
- 修复：`task2_build_drm_tools.sh` 显式设置 `CCACHE_DIR` 和 `CCACHE_TEMPDIR` 到 `ebpf/vkms_lab/tools-build/` 下。

### Debian multiarch pkg-config 路径遗漏

- 问题：libdrm 安装到 `tools-install/lib/x86_64-linux-gnu/pkgconfig`，脚本原先只设置 `lib/pkgconfig` 和 `lib64/pkgconfig`，导致 IGT 配置时误用系统 libdrm。
- 修复：通过 `gcc -print-multiarch` 自动加入 multiarch 的 pkg-config 和动态库路径。

### IGT 需要 libkmod 开发依赖

- 问题：IGT Meson 配置阶段要求 `dependency('libkmod')`。当前系统缺 `libkmod-dev`，执行 `ebpf/env.sh` 时 `sudo` 需要交互密码，无法在当前会话安装。
- 修复方向：`task2_fetch_drm_tools.sh` 增加官方 `kmod` 源码下载；`task2_build_drm_tools.sh` 在系统缺 `libkmod` 时，先本地构建并安装裁剪版 `libkmod` 到 `tools-install/`，再继续构建 IGT。
- 当前记录：kmod commit `41d9d6650973f05e69f9afda27b7f41764e6677e`。

### kmod 默认安装路径会写 /etc

- 问题：本地 `kmod` 编译成功后，`meson install` 仍尝试创建 `/etc/depmod.d`，当前环境中 `/etc` 不可写。
- 修复：构建 `kmod` 时显式传入 `--sysconfdir "$INSTALL_DIR/etc"`，把配置目录也重定向到 `tools-install/`。

### IGT 需要 libpci

- 问题：IGT Meson 配置继续要求 `dependency('libpci', required : true)`，该依赖不能通过现有 Meson 选项关闭。
- 修复：`task2_fetch_drm_tools.sh` 增加官方 `pciutils` 源码下载；`task2_build_drm_tools.sh` 使用 `install-lib` 只安装 `libpci`、头文件和 `libpci.pc` 到 `tools-install/`，并关闭 `ZLIB`、`DNS`、`LIBKMOD`、`HWDB` 额外探测。
- 额外修复：`pciutils` 的共享库目标名包含版本号，例如 `libpci.so.3.15.0`，不能硬编码为 `lib/libpci.so`；脚本改为直接调用 `make install-lib`，由上游 Makefile 自行构建依赖目标。
- 当前记录：pciutils commit `2c24fbf8bf88c297db991a0b45c1926309dc6145`。

### modetest 默认没有安装到 tools-install/bin

- 问题：libdrm 的 `modetest` 是 tests 目标，`ninja install` 不会把它放进 `tools-install/bin`；而 QEMU 只挂载 `tools-install/` 作为 `/tools`。
- 修复：`task2_build_drm_tools.sh` 在 libdrm 构建后显式 `install -m 0755 "$LIBDRM_BUILD/tests/modetest/modetest" "$INSTALL_DIR/bin/modetest"`。

### QEMU guest 需要 TASK 2 smoke test

- 问题：TASK 1 smoke 只验证 `vkms.ko` 和 `/dev/dri/card0`，没有验证 TASK 2 的用户态触发器是否能在 guest 内实际运行。
- 修复：`task1_run_qemu.sh` 增加 `TASK2_SMOKE_TEST=1`，在 guest 中运行 `/tools/bin/modetest -M vkms -c`，以及带 `IGT_FORCE_DRIVER=vkms --device drm:/dev/dri/card0` 的 `kms_getfb --run-subtest getfb-handle-valid`。
- 额外修复：guest `LD_LIBRARY_PATH` 增加 `/tools/lib/x86_64-linux-gnu`，匹配 Debian multiarch 安装路径。

### QEMU guest 中 TASK 2 工具路径需要回退

- 问题：`tools-install/` 已在宿主侧生成 `modetest` 和 IGT 测试，但 guest 内 `/tools` 9p 挂载不可见时会报 `/tools/bin/modetest: not found`。
- 修复：`task1_run_qemu.sh` 在 guest init 中保留 `/tools` 为优先路径；如果 `/tools/bin/modetest` 不存在但 `/mnt/tools-install/bin/modetest` 存在，则自动切换到整体仓库挂载下的 `/mnt/tools-install`。
- 额外修复：TASK 2 smoke 现在会打印 `TOOLS_BASE`，并在成功时输出 `TASK 2 guest: smoke test passed`，便于区分真正通过和只完成关机流程。

### TASK 2 工具是动态 ELF，需要 initramfs 提供 loader

- 问题：guest 中执行 `/tools/bin/modetest` 报 `not found`，但宿主侧文件实际存在；根因是 `modetest` 和 IGT 测试是动态链接 ELF，最小 BusyBox initramfs 里缺少 `/lib64/ld-linux-x86-64.so.2` 和系统共享库。
- 修复：`task1_run_qemu.sh` 在 `TASK2_SMOKE_TEST=1` 时对 `tools-install/bin/modetest` 和 `tools-install/libexec/igt-gpu-tools/kms_getfb` 执行 `ldd`，把动态 loader 与非 `tools-install/` 的宿主系统库复制进 initramfs。
- 设计取舍：`libdrm/libigt` 等由 TASK2 源码编译出的库仍通过 `/tools` 9p 挂载使用，便于确认实际运行的是本次源码构建产物。
- 额外修复：guest `LD_LIBRARY_PATH` 补充 `/lib*`、`/usr/lib*` 和 `/usr/local/lib*`，覆盖 `ldd` 收集到的宿主系统库位置。

### IGT 默认 DRIVER_ANY 会排除 VKMS

- 问题：`kms_getfb --run-subtest getfb-handle-valid` 能启动后返回 SKIP，日志为 `No known gpu found`；IGT 的 `DRIVER_ANY` 在 `lib/drmtest.h` 中排除了 `DRIVER_VKMS`。
- 修复：TASK 2 smoke 对 IGT 命令增加 `IGT_FORCE_DRIVER=vkms` 和 `--device drm:/dev/dri/card0`，让 `drm_open_driver(DRIVER_ANY)` 走 IGT 中为 forced driver 保留的 VKMS 路径。

## 最终自检结果

- `bash -n ebpf/vkms_lab/task1_prepare_busybox.sh ebpf/vkms_lab/task1_build_linux.sh ebpf/vkms_lab/task1_run_qemu.sh ebpf/vkms_lab/task2_fetch_drm_tools.sh ebpf/vkms_lab/task2_build_drm_tools.sh ebpf/env.sh`：通过。
- `TASK1_SMOKE_TEST=1 TASK2_SMOKE_TEST=1 ./task1_run_qemu.sh`：通过。
- guest 结果：`vkms.ko` 加载成功，`/dev/dri/card0` 存在，`modetest -M vkms -c` 枚举到 `Virtual-1` connector，IGT `kms_getfb/getfb-handle-valid` 输出 `SUCCESS`，最后打印 `TASK 2 guest: smoke test passed` 和 `TASK 1 guest: smoke test passed`。

## .gitignore

- 已新增仓库根 `.gitignore`，忽略 `ebpf/vkms_lab/external/`、`task1-runtime/`、`tools-build/`、`tools-install/`、`rootfs/` 和日志。
- 已更新 `ebpf/vkms_lab/.gitignore`，补充忽略 initramfs 相关归档。
