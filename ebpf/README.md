# eBPF：Linux Driver / GPU KMD 开发中的动态观测与诊断

> 这个目录用于学习和实践 eBPF，重点不是网络包处理，而是把 eBPF 用于 **Linux 驱动、PCIe/DMA、GPU KMD、调度、内存管理、IRQ、firmware 协作链路** 的动态调试。

核心目标：当系统已运行、复现成本高、不能方便地重编内核或重载驱动时，如何尽量低侵入地回答：

```text
发生了什么？
谁先卡住？
一个 submit 为什么没有完成？
是 KMD、CPU scheduler、IRQ、PCIe/MMIO、firmware，还是 GPU 硬件侧出现了断链？
```

---

## 1. 从驱动开发视角理解 eBPF

传统 Linux 驱动调试常用：

```text
printk / dev_dbg
ftrace / trace-cmd
perf
kprobe / tracepoint
crash / kdump
寄存器 dump
硬件波形 / PLD trace
```

这些工具都有效，但有明显边界：

- `printk` 需要改代码、重编、重载模块；高频路径中会扰动时序；
- 静态 tracepoint 的字段是预先定义的，未必包含当前故障需要的信息；
- 硬件波形最接近真实信号，但成本高，真机现场不一定可用；
- hang 发生后再补日志通常已经来不及。

**eBPF（extended Berkeley Packet Filter）** 允许用户在运行时把一小段受 verifier 约束的程序挂到内核事件点。程序可读取事件上下文、进行过滤和聚合，并把结构化事件上报到用户态。

对 driver 开发者，可以把它理解成：

```text
动态插桩点
  + 受限制的内核态事件处理
  + 低开销过滤/聚合
  + ring buffer 结构化上报
  = 不改或少改 driver 的动态观测能力
```

eBPF 不是普通 kernel module，也不是任意 kernel C 代码。BPF verifier 会检查内存访问、控制流、helper 调用和资源使用，因此它特别适合：

```text
观测、统计、调用链关联、延迟分析、故障前事件记录、有限策略控制
```

而不适合替代复杂的 KMD 状态机、reset/recovery、firmware 协议或硬件控制逻辑。

---

## 2. 能力边界：什么适合，什么不适合

### 2.1 eBPF 擅长的事情

| 能力 | Linux Driver / GPU KMD 中的价值 | 示例 |
| --- | --- | --- |
| 跟踪函数进入/退出 | 建立调用顺序、测量耗时、观察返回值 | submit ioctl、scheduler run_job、fence signal、reset |
| 跟踪内核 tracepoint | 读取稳定事件字段 | `sched_switch`、IRQ、workqueue、DRM tracepoint |
| 读取部分内核对象字段 | 获得 pid、queue/context、seqno、状态值 | `task_struct`、fence、driver 私有对象字段 |
| 用户/内核栈回溯 | 找到谁触发提交、映射、reset 或高频调用 | UMD → ioctl → KMD 调用链 |
| 计数、直方图、延迟统计 | 长期运行时发现异常分布 | fence wait latency、IRQ interval、DMA map duration |
| 事件关联 | 把多个事件组织为一次 transaction | submit → doorbell → IRQ → fence signal |
| ring buffer 输出 | 在用户态实时构建 timeline | hang 前最后 N 个关键事件 |
| uprobe | 关联用户态 runtime 与 KMD | Vulkan/CUDA/HIP/自研 runtime → ioctl |

### 2.2 不应对 eBPF 产生的误解

| 误解 | 实际边界 |
| --- | --- |
| “能替代 driver patch” | 不能。eBPF 无法任意调用 driver 内部函数或重写复杂控制流。 |
| “可以任意改 driver 返回值” | 只有特定 hook、函数和内核配置下才可能有限修改；只能用于严格受控实验。 |
| “能看到 GPU 内部所有状态” | 不能。它只能看到 CPU/Linux 侧可观测路径；GPU wave、cache、MMU、firmware 内部仍需寄存器、IH、firmware log、GPU PMU 或硬件 trace。 |
| “能解决 hard lockup” | 不能。CPU 已自旋死锁、PCIe read 阻塞或系统不再调度时，BPF 也可能无法执行或上报。 |
| “天然低开销” | 不一定。高频 kprobe、频繁 stack trace、每事件 ringbuf 输出都可能严重扰动时序。 |

推荐原则：

```text
先用 eBPF 证明问题和缩小范围
    -> 再用最小 driver patch 修复
    -> 最后把长期需要的观测能力沉淀为 tracepoint/debugfs/health check
```

---

## 3. 基本构成

一个典型工具包含用户态和 BPF 程序两部分：

```text
┌───────────────────────────────────────────────────────────────┐
│ 用户态 loader / consumer                                       │
│  - load BPF object                                             │
│  - attach hook                                                 │
│  - read ring buffer                                            │
│  - 输出 JSON / timeline / histogram                            │
└───────────────────────────┬───────────────────────────────────┘
                            │ maps / ringbuf
┌───────────────────────────▼───────────────────────────────────┐
│ BPF program（内核中、受 verifier 约束执行）                     │
│  event context -> filter -> map update -> event output        │
└───────────────────────────┬───────────────────────────────────┘
                            │ attach
┌───────────────────────────▼───────────────────────────────────┐
│ kernel event: tracepoint / fentry / kprobe / uprobe / PMU ... │
└───────────────────────────────────────────────────────────────┘
```

### 3.1 常用 hook 类型

| Hook | 适用场景 | Driver / GPU KMD 例子 | 说明 |
| --- | --- | --- | --- |
| tracepoint | 内核明确导出的稳定事件 | scheduler、IRQ、workqueue、DRM | 优先选择 |
| raw tracepoint | 高频、低层 tracepoint | 高吞吐事件统计 | 参数解析更依赖内核版本 |
| kprobe/kretprobe | 函数入口/返回 | ioctl、submit、fence、reset、IRQ handler | 灵活，但函数符号和实现可能变化 |
| fentry/fexit | BTF 类型化函数入口/退出 | 读取函数参数、返回值 | 依赖 BTF；通常优先于 kprobe |
| uprobe/uretprobe | 用户态函数 | UMD/runtime API 与 ioctl 关联 | 适合 UMD → KMD 链路 |
| perf event | CPU PMU/软件事件 | CPU cycles、context switch、cache miss | 不能替代 GPU PMU |
| LSM/cgroup | 有限安全策略 | 资源/权限策略 | 不属于 KMD 调试主路径 |

### 3.2 常用 BPF map

| Map | 作用 | KMD 调试例子 |
| --- | --- | --- |
| hash map | key → value 状态表 | `fence_seqno -> submit_timestamp` |
| LRU hash | 自动淘汰旧状态 | 长时间跟踪大量 context/BO |
| per-CPU map | 减少多 CPU 竞争 | 每 CPU IRQ 次数和延迟 |
| ring buffer | 结构化事件上报 | hang 前 submit/IRQ/reset timeline |
| stack trace map | stack ID 到调用栈 | 高频 `dma_map_*` 调用归因 |
| perf event array | 较老的事件输出方式 | 兼容旧内核 |

---

## 4. 工具路线：从最快验证到可维护工具

建议学习和使用顺序：

```text
tracefs / ftrace
    -> bpftrace
        -> BCC
            -> libbpf + CO-RE
                -> driver 原生 tracepoint + 用户态分析器
```

### 4.1 bpftrace：最快获得第一条证据

适合临时确认：某函数是否执行、调用频率、耗时是否异常。

```bash
# 统计自研 KMD submit 函数按进程的调用次数
sudo bpftrace -e '
kprobe:mygpu_submit {
  @[comm] = count();
}
'
```

```bash
# 观察 submit 函数的耗时分布
sudo bpftrace -e '
kprobe:mygpu_submit {
  @start[tid] = nsecs;
}

kretprobe:mygpu_submit /@start[tid]/ {
  @lat_us = hist((nsecs - @start[tid]) / 1000);
  delete(@start[tid]);
}
'
```

它适合第一轮探索，但不适合复杂对象解析、长期版本兼容和大型状态关联。

### 4.2 BCC：原型方便，部署有依赖

BCC 常在目标机动态编译 BPF C，适合快速试验；但生产或离线环境常缺少 clang、headers 或匹配构建环境。

### 4.3 libbpf + CO-RE：后续实践主线

CO-RE（Compile Once – Run Everywhere）利用 BTF 和 relocation，降低不同兼容内核间的适配成本。

建议后续按下面结构扩展：

```text
ebpf/
├── README.md
├── common/
│   ├── vmlinux.h
│   └── mygpu_bpf.h
├── submit_trace/
│   ├── submit_trace.bpf.c
│   ├── submit_trace.c
│   └── Makefile
├── irq_latency/
│   ├── irq_latency.bpf.c
│   ├── irq_latency.c
│   └── Makefile
└── hang_timeline/
    ├── hang_timeline.bpf.c
    ├── hang_timeline.c
    └── Makefile
```

---

## 5. 最小环境检查

```bash
# bpffs 是否挂载
mount | grep bpf

# CO-RE 通常需要的内核 BTF
ls -l /sys/kernel/btf/vmlinux

# 常用内核配置
zgrep -E 'CONFIG_BPF|CONFIG_BPF_SYSCALL|CONFIG_DEBUG_INFO_BTF|CONFIG_FTRACE' /proc/config.gz 2>/dev/null \
  || grep -E 'CONFIG_BPF|CONFIG_BPF_SYSCALL|CONFIG_DEBUG_INFO_BTF|CONFIG_FTRACE' /boot/config-$(uname -r)

# 可用 tracepoint
ls /sys/kernel/tracing/events

# 可探测函数的初步查询
sudo cat /sys/kernel/tracing/available_filter_functions | grep -E 'mygpu|amdgpu|drm_sched' | head
```

实际使用中还要考虑：

- root / capability 权限；
- kernel lockdown 与 Secure Boot 策略；
- 容器是否有 BPF、perf、tracefs 权限；
- vendor kernel 是否裁剪 BTF、kprobe、ftrace 或 BPF 功能；
- 函数是否被 inline、LTO 优化或根本没有可用符号。

第一次实验建议从 tracepoint 或简单 `bpftrace` 脚本开始，而不是直接写复杂 CO-RE 程序。

---

## 6. 典型应用场景一：动态插入 log / event trace

GPU KMD 的一条典型路径：

```text
userspace ioctl submit
  -> validate BO / VM mapping
  -> create job / fence
  -> scheduler enqueue
  -> ring write / doorbell
  -> firmware / CP consume
  -> IH interrupt
  -> fence signal
  -> userspace wakeup
```

直接在每一步插 `dev_info()` 的问题是：高频、时序扰动、日志淹没、需要重新编译。

更好的 eBPF 模式是：**只采集目标 pid/context 的关键事件，并用固定大小的 event 送到 ring buffer。**

```c
struct gpu_evt {
    __u64 ts_ns;
    __u64 ctx_id;
    __u64 seqno;
    __u32 pid;
    __u32 tgid;
    __u32 cpu;
    __u16 type;
    __s16 ret;
    __u64 arg0;
    __u64 arg1;
    char  comm[16];
};
```

建议事件类型至少包括：

```text
SUBMIT
SCHED_ENQUEUE
DOORBELL
IRQ_ENTRY
FENCE_SIGNAL
VM_FAULT
TIMEOUT
RESET_BEGIN
RESET_END
```

这样 eBPF 的价值不只是“多打印一行 log”，而是把事件组织成可排序的 timeline：

```text
T0  submit(ctx=7, seqno=100)
T1  doorbell(queue=2)
T2  IRQ_ENTRY(vector=13)
T3  fence_signal(seqno=100)
```

或异常路径：

```text
T0  submit(ctx=7, seqno=101)
T1  doorbell(queue=2)
T2  no completion
T3  timeout(seqno=101)
T4  reset_begin
```

### 对自研 KMD 的建议

即使短期用 eBPF，长期仍应在 driver 中提供稳定 tracepoint，例如：

```text
trace_mygpu_submit(ctx_id, queue_id, seqno, ib_addr, ib_len)
trace_mygpu_doorbell(queue_id, value)
trace_mygpu_fence_signal(seqno, status)
trace_mygpu_reset(stage, reason)
trace_mygpu_vm_fault(vmid, va, status)
```

eBPF 最适合消费这些 tracepoint；这比依赖私有函数名和结构体布局更稳定。

---

## 7. 典型应用场景二：动态改变 driver 行为

这是一个容易被高估的能力。

常见设想：

```text
能否不重编 driver，临时跳过一次 reset？
能否让某函数故意返回失败，以验证 cleanup？
能否缩短 timeout，快速触发 recovery？
能否模拟 fence 永不完成？
```

### 7.1 正确结论

**eBPF 的主用途是观测，而不是通用的运行时代码 patch 系统。**

某些内核和 attach 类型允许受限的错误注入或返回值修改，例如内核已有 error-injection 标记的函数、特定 `fmod_ret` tracing 使用场景，或 LSM BPF 的 allow/deny 决策。

但这不意味着：

```text
任意 KMD 函数都能安全 hook 并修改逻辑
```

尤其 GPU KMD 中，随意跳过一个软件步骤可能造成：

```text
CPU software state 与 GPU / CP / firmware 硬件状态不一致
未释放 BO 或 DMA mapping
fence / refcount / lock 配对损坏
queue 仍在运行但上层已认为提交失败
reset 或 recovery 状态机不可恢复
```

### 7.2 推荐使用范围

| 目标 | 推荐方式 | eBPF 是否合适 |
| --- | --- | --- |
| 验证错误路径是否被正确清理 | kernel fault injection 或受控返回值注入 | 可作为隔离测试补充 |
| 模拟 allocation / DMA map 失败 | kernel fault injection 优先 | eBPF 非首选 |
| 缩短 watchdog timeout | module parameter / debugfs | 不建议通过 eBPF 改变量 |
| 跳过 GPU reset | 明确 debug 开关并保留 dump | 通常不建议 |
| 改 MMIO/doorbell 值 | test firmware、debugfs、仿真平台 | 不应使用 eBPF |
| 改 scheduler 行为 | KMD 内正式实验开关 | 不应使用 eBPF |

### 7.3 更可维护的设计

对自研 KMD，长期实验能力应沉淀为：

```text
module parameter
  -> timeout、log level、fault injection 开关

debugfs
  -> 查询 queue/fence、单次 reset、模拟特定故障

tracepoint
  -> 稳定观测事件

KUnit / fault injection
  -> 验证错误路径、资源释放和状态机

PLD / firmware test mode
  -> 模拟 doorbell 丢失、IH 丢中断、CP stall、PCIe 异常
```

---

## 8. 典型应用场景三：分析 Driver Hung / GPU Hang

### 8.1 先按现象分类

| CPU 侧现象 | 可能原因 | eBPF 的帮助 |
| --- | --- | --- |
| 进程卡在 ioctl / fence wait | job 未完成、fence 未 signal、scheduler stall | 高：关联 submit 与 completion |
| KMD worker 长时间运行 | software loop、锁竞争、超时轮询 | 高：函数耗时、调度状态、stack |
| 某 CPU soft lockup | spin loop、关抢占过久、IRQ storm | 中：可记录失控前事件，失控后未必能运行 |
| MMIO read 卡住 | PCIe completer timeout、链路/设备异常 | 中低：可显示调用点和前序事件，但未必能穿透阻塞点 |
| MMIO write 后无完成 | doorbell 未被消费、firmware/CP hang、posted write 后续依赖卡住 | 高：构建 write/IRQ/fence 时间线 |
| GPU reset 后恢复失败 | reset 顺序、firmware handshake、VM/fence 清理问题 | 高：对比 reset 前后状态路径 |

### 8.2 GPU hang 的基本时间线模型

把一次工作提交建模为：

```text
A. UMD submit
B. KMD ioctl enter
C. BO/VM validate
D. job enqueue
E. ring write / doorbell
F. CP/firmware consume
G. GPU execute
H. IH interrupt
I. KMD fence signal
J. userspace wakeup
```

eBPF 能直接看清的通常是 A–E、H–J，以及部分 F 的 CPU/firmware 交互；G 需要 GPU 侧计数器、寄存器、IH 或硬件 trace 补齐。

诊断目标并非一开始解释全部原因，而是先定位“最后一个确定发生的事件”：

```text
有 submit，无 doorbell
  -> KMD submit/queue 路径问题

有 doorbell，无 IRQ
  -> CP/firmware/GPU 执行，或 IH/MSI 路径问题

有 IRQ，无 fence signal
  -> IRQ handler、fence decode、bottom half/workqueue 问题

有 fence signal，用户仍等待
  -> sync object、wait condition、用户态 runtime 路径问题
```

### 8.3 一个推荐的 hang timeline 工具

第一版工具只做四件事：

1. 捕获 submit；
2. 捕获 doorbell 或 scheduler run；
3. 捕获 IRQ / fence completion；
4. 捕获 timeout / reset。

使用 `(ctx_id, queue_id, seqno)` 作为关联主键，并在用户态按时间排序。

输出目标类似：

```text
12.001234  pid=1803 ctx=7 seq=100 SUBMIT
12.001280  pid=1803 ctx=7 seq=100 ENQUEUE
12.001300  cpu=4  queue=2       DOORBELL
12.005900  cpu=9  vector=13     IRQ
12.005930  cpu=9  ctx=7 seq=100 FENCE_SIGNAL
```

对于 hang：

```text
13.100000  pid=1803 ctx=7 seq=101 SUBMIT
13.100055  cpu=4  queue=2       DOORBELL
18.100100  worker=... seq=101   TIMEOUT
18.100300  reset reason=job_timeout RESET_BEGIN
```

这会把“GPU 卡住了”的模糊现象缩小成明确的链路断点。

---

## 9. 典型应用场景四：分析 IRQ、workqueue 与调度问题

GPU KMD 的 completion 通常不止一个硬中断函数：

```text
MSI/MSI-X
  -> top half
  -> threaded IRQ / tasklet / NAPI-like poll / workqueue
  -> fence signal
  -> wake_up / dma_fence callback
```

常见问题包括：

- IRQ 到达但 affinity 不合理，completion CPU 过载；
- top half 很快，但 bottom half 长时间得不到调度；
- workqueue 被单线程 work 或锁竞争堵住；
- 某次 IRQ storm 使 submit 或 recovery 路径饥饿；
- task migration 导致 context/lock/NUMA 局部性变差。

有用的 eBPF 观察点：

```text
irq:irq_handler_entry / irq:irq_handler_exit
sched:sched_switch
workqueue:workqueue_queue_work
workqueue:workqueue_execute_start
workqueue:workqueue_execute_end
```

可以回答：

```text
IRQ 是否真正到达？
IRQ handler 跑在哪个 CPU？耗时多久？
完成工作什么时候入队、什么时候真正开始执行？
等待 fence 的任务是否一直 runnable，还是一直 sleep？
```

---

## 10. 典型应用场景五：DMA、IOMMU、内存映射与 UVM/HMM 辅助诊断

eBPF 看不到所有 GPU MMU 细节，但可在 CPU/KMD 侧辅助确认关键路径：

```text
pin_user_pages / unpin_user_page
dma_map_* / dma_unmap_*
mmu_notifier invalidate
mmap / munmap / mprotect
page fault
IOMMU map/unmap
```

适用问题：

- 某进程退出后 pin page 是否没有释放；
- `dma_map_*` 和 `dma_unmap_*` 是否数量或调用路径不对称；
- 某次 `munmap` / `mprotect` 后 KMD 是否收到 invalidate；
- GPU fault 前是否发生了 CPU VA 失效或 IOMMU 映射变化；
- 某类 BO / host-register 路径是否造成异常长延迟。

注意：

```text
不要把 eBPF 观察到的“CPU 侧 map/unmap 事件”直接等同于“GPU PTE 已经正确更新”。
```

GPU PTE、TLB invalidate、firmware ACK 与硬件最终可见性仍需要 KMD 自己的 tracepoint、寄存器/queue dump 或 firmware log 交叉验证。

---

## 11. 性能与可靠性原则

高频 KMD 路径中，默认遵循：

```text
先 filter，再 collect
先 aggregate，再 output
先记录 ID 和时间戳，再考虑栈
先使用 tracepoint/fentry，再考虑 kprobe
```

### 11.1 不推荐的做法

```text
每个 submit 都抓 kernel + user stack
每次 IRQ 都 ringbuf 输出完整结构
在高频 kprobe 中读取深层嵌套私有对象
全系统无过滤地 attach 到所有 scheduler 事件
```

### 11.2 推荐的做法

```text
按 target_tgid / target_ctx / target_queue 过滤
只在 latency 超阈值时输出详细事件
每 CPU 聚合 IRQ 计数和时延直方图
采样而不是记录全部高频事件
ringbuf 只输出固定大小的关键字段
故障发生前保留最近 N 秒的用户态循环缓冲
```

---

## 12. 建议的学习与实践路线

### 阶段 1：会使用，不写复杂程序

```text
1. 使用 tracefs/ftrace 查看已有事件
2. 用 bpftrace 跟踪一个函数调用次数与耗时
3. 跟踪 scheduler switch 与 IRQ handler
4. 学会区分 tracepoint、kprobe、fentry、uprobe
```

### 阶段 2：做一个最小 CO-RE 工具

```text
目标：submit trace

输入：target pid / context id
事件：submit enter/exit
输出：timestamp、pid、ctx_id、seqno、return value
```

### 阶段 3：构造一条 KMD completion 时间线

```text
submit
  -> scheduler enqueue
  -> doorbell
  -> IRQ
  -> fence signal
  -> userspace wakeup
```

### 阶段 4：面向真实 hang 的工具

```text
目标：hang_timeline

关键能力：
- 按 ctx/queue/seqno 关联
- timeout 后自动导出最后一段 timeline
- 记录 reset 前后关键事件
- 可选采集调用栈
- 输出 JSON，便于和 firmware log / PLD 波形对齐
```

---

## 13. 与 GPU KMD 工作的最终映射

希望最终形成下面的调试习惯：

```text
现象：用户进程卡住

先问：最后完成到哪一步？
  -> eBPF timeline：submit / doorbell / IRQ / fence

再问：CPU 侧是否有调度、锁或 workqueue 问题？
  -> sched / IRQ / workqueue tracing

再问：KMD 是否收到正确硬件反馈？
  -> driver tracepoint + register dump + firmware log

最后问：GPU/firmware/PCIe 的真实硬件状态是什么？
  -> IH status、queue state、CP firmware log、MMIO、PLD/硬件 trace
```

eBPF 的定位不是替代 driver、firmware 或硬件调试，而是在它们之间补上一层高质量的 **CPU/Linux 侧因果证据**。

---

## 14. 后续建议实践题目

1. `submit_trace`：记录自研 KMD 的 submit 入口、context、queue、seqno、返回值和耗时。
2. `fence_latency`：统计 submit 到 fence signal 的延迟直方图，并按 context/queue 分类。
3. `irq_to_fence`：统计 MSI-X IRQ 到 fence signal 的时延，识别 bottom half/workqueue 延迟。
4. `hang_timeline`：在 timeout/reset 时输出最后一段 submit → doorbell → IRQ → fence 时间线。
5. `mmu_invalidate_watch`：观察 host-register/UVM-like 路径中的 invalidate、unmap、pin/unpin 关联。
6. `pcie_mmio_callsite`：只针对测试环境，统计特定 MMIO helper 的调用点、频率和异常长间隔；不要用它替代设备侧协议验证。

下一步建议先实现 `submit_trace`：它最小、最容易验证，也能直接建立 UMD/KMD/queue/fence 之间的关联意识。
