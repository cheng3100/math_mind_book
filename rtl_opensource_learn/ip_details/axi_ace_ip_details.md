# AXI-ACE IP Details for GPGPU Driver Bring-up

本文档从 **GPGPU 软件驱动 bring-up / KMD / UVM-HMM / coherent memory 调试** 的角度介绍 AXI-ACE。

AXI-ACE 可以粗略理解为：

```text
AXI read/write transaction
  +
cache coherency protocol
  +
snoop transaction
  +
shareability / domain attribute
  +
exclusive / atomic / barrier 相关语义
```

它不是简单给 AXI 增加几个 cache 属性，而是让多个带 cache 的 master，例如 CPU cluster、GPU/NPU、IO coherent master，可以在同一个 coherent domain 内维护缓存一致性。

## 1. 为什么 GPGPU KMD 需要理解 AXI-ACE

在 GPGPU 软件栈中，以下问题都可能涉及 ACE/CHI 类 coherent interconnect：

- CPU 写 ring buffer，GPU firmware 或 GPU engine 看不到；
- GPU 写 doorbell/status，CPU polling 看不到；
- `dma_alloc_coherent()` 内存与普通 `kmalloc()`/`vmalloc()` 内存行为不同；
- UVM/HMM 中 CPU 与 GPU 共享页出现 stale data；
- GPU atomic 对 CPU 是否可见；
- CPU cache maintenance 后数据仍不一致；
- PCIe / SMMU / NoC 上的 snoop 属性配置错误；
- 某个 master 是 ACE-Lite coherent，另一个 master 是 non-coherent，导致软件同步模型不同。

## 2. AXI、ACE、ACE-Lite 的区别

| 协议 | 主要能力 | 典型 master | 软件调试关注点 |
| --- | --- | --- | --- |
| AXI | 普通 read/write/burst/outstanding | DMA、寄存器访问、non-coherent master | 访问是否完成、地址/响应/属性是否正确 |
| ACE-Lite | IO coherent，支持被 snoop，但 master 自身通常不缓存 | PCIe、DMA、display、某些 accelerator | DMA coherency、snoop 属性、cache maintenance 是否需要 |
| ACE | full coherent master，支持 snoop、自身 cache line 状态管理 | CPU cluster、部分 GPU/NPU/accelerator | coherent shared memory、CPU/GPU cache 一致性、atomic/exclusive、share domain |

一个常见误区是：

> 只要走 AXI，就天然 cache coherent。

这是错误的。普通 AXI 只保证总线事务完成，不保证 CPU cache、GPU cache、DDR 中的数据副本一致。

## 3. ACE 比 AXI 多了什么

普通 AXI 有：

```text
AW / W / B / AR / R
```

ACE 在此基础上增加 snoop 相关通道，常见为：

```text
AC / CR / CD
```

| 通道 | 方向 | 作用 | 调试意义 |
| --- | --- | --- | --- |
| `AC` | Interconnect -> Master | Snoop address/control | interconnect 要求某个 cache master 检查/失效/回写某条 cache line |
| `CR` | Master -> Interconnect | Snoop response | master 告诉 interconnect 是否命中、是否 dirty、是否完成 |
| `CD` | Master -> Interconnect | Snoop data | 如果 cache 中有 dirty data，需要返回数据 |

从软件视角看，ACE 解决的是：

```text
CPU cache 中有一份数据
GPU cache / L2 中也可能有一份数据
DDR/HBM 中还有一份数据
```

谁是最新的？谁需要被 invalidate？谁需要 writeback？这些不是普通 AXI 能解决的，需要 coherent protocol。

## 4. ACE 中的软件相关概念

### 4.1 Shareability

Shareability 决定一个访问是否进入某个一致性域。

常见概念：

| 属性 | 含义 | 软件意义 |
| --- | --- | --- |
| Non-shareable | 不参与共享一致性域 | 需要显式 cache maintenance，或只被单 master 使用 |
| Inner Shareable | inner domain 内一致 | 通常 CPU cluster 内部或 SoC 内部 coherent domain |
| Outer Shareable | outer domain 内一致 | 多 cluster / IO coherent / system coherent 场景 |

如果页表属性、SMMU 属性、NoC 属性或 master 发出的 AxDOMAIN/AxCACHE 等组合错误，即使物理地址相同，CPU 和 GPU 也可能看到不同的数据。

### 4.2 Snoop

Snoop 是 coherent interconnect 主动询问其他 cache master 的过程。

例如 GPU 要读取一个 cache line，但 CPU cache 里有 dirty copy：

```text
GPU read shared memory
  -> coherent interconnect
  -> snoop CPU cache
  -> CPU cache writeback or provide data
  -> GPU 获得最新数据
```

如果 snoop 没发生，GPU 可能读到 DDR 中的旧值。

### 4.3 Clean / Invalidate / MakeUnique

这些事务本质上和 cache line ownership 有关：

| 操作 | 粗略含义 | 软件场景 |
| --- | --- | --- |
| Clean | 把 dirty data 写回到下层 | CPU flush cache for device |
| Invalidate | 让某 cache line 无效 | device 写完后 CPU 重新读取 |
| MakeUnique / ReadUnique | 获取独占修改权限 | 原子操作、写共享 cache line 前 |
| ReadShared | 共享读 | 多 master 读同一 cache line |

### 4.4 Barrier

Barrier 约束事务顺序。软件中的 memory barrier、DMA barrier、device barrier，最终需要硬件路径支持相应 ordering。

但要注意：

```text
barrier 解决顺序问题
coherency 解决副本一致问题
atomic 解决 RMW 不可分问题
```

这三者相关，但不是同一个概念。

## 5. Atomic operation 与 AXI-ACE 的关系

软件中的 atomic，例如：

```text
CPU atomic_fetch_add()
GPU atomicAdd()
firmware atomic CAS lock
```

本质是 read-modify-write。它要求：

1. 读旧值；
2. 修改；
3. 写回新值；
4. 这个过程不能被其他 master 对同一地址的修改插入。

普通 AXI read + write 不能天然保证跨 master RMW 原子性。

ACE/ACE 类 coherent protocol 可以通过 exclusive ownership、snoop、exclusive/atomic transaction 等机制，帮助 coherent domain 内的 master 实现跨 cache 的原子语义。

但从 KMD 视角必须区分：

| 场景 | 是否一定由 ACE 保证 | 说明 |
| --- | --- | --- |
| GPU workgroup 内 shared memory atomic | 否 | 多数在 GPU SM/CU 内部完成 |
| GPU global memory atomic 到显存 | 不一定 | 多数在 GPU L2/MC atomic unit 完成 |
| CPU 与 GPU 对同一 coherent shared memory atomic | 依赖平台 | 需要 coherent interconnect、统一内存模型、scope 和 ISA 支持 |
| PCIe 设备对 host memory atomic | 通常不是 ACE | 可能走 PCIe AtomicOp、CXL、NVLink 或平台私有协议 |
| firmware core 使用 LDREX/STREX 或 CAS lock | 可能相关 | 依赖 interconnect/slave exclusive monitor 支持 |

因此，不能简单说：

```text
CUDA atomicAdd == AXI-ACE atomic
```

更准确的链路是：

```text
CUDA/OpenCL atomic API
  -> GPU ISA atomic instruction
  -> GPU L1/L2/MC atomic unit
  -> 如果目标地址跨 CPU/GPU coherent domain
     还需要 ACE/CHI/CXL/NVLink/PCIe AtomicOp 等平台能力
```

## 6. 常见软件现象与 ACE 问题映射

### 6.1 CPU 写 ring buffer，GPU 看不到

可能原因：

1. CPU mapping 是 cacheable，但没有 flush；
2. 该 buffer 没有被映射为 coherent；
3. SMMU/IOMMU 属性没有使能 shareable/coherent；
4. GPU master 没有发起 snoop；
5. interconnect 中该 master 不在相同 share domain；
6. doorbell 写早于数据写可见，缺少 barrier；
7. ring buffer 在 host memory，GPU 通过 PCIe 访问，不具备系统 cache coherent 能力。

### 6.2 GPU 写 status，CPU polling 看不到

可能原因：

1. CPU cache 中有旧值，没有 invalidate；
2. buffer 不是 coherent DMA memory；
3. GPU 写没有进入 CPU coherent domain；
4. CPU 使用普通 cached mapping polling device-updated memory；
5. GPU write posted/buffered，缺少 fence/doorbell/interrupt ordering。

### 6.3 `dma_alloc_coherent()` 正常，`kmalloc()` + dma_map 异常

可能原因：

1. `dma_alloc_coherent()` 返回的是适合设备一致性访问的内存；
2. 普通 `kmalloc()` 内存如果用于 DMA，需要正确 `dma_map_*()` 和 `dma_sync_*()`；
3. 非 coherent 平台必须显式 cache maintenance；
4. coherent 平台也需要正确 DMA API，不能绕过 DMA mapping。

### 6.4 CPU/GPU atomic 结果不符合预期

可能原因：

1. GPU atomic 只在 GPU memory scope 内原子；
2. CPU atomic 只在 CPU coherent domain 内原子；
3. 二者没有共同的 atomic domain；
4. 目标内存位于 host memory，但 PCIe path 不支持 AtomicOp 或未启用；
5. cacheability/shareability/page attribute 与实际访问模型不匹配；
6. 缺少 acquire/release 或 system-scope memory ordering。

## 7. Bring-up 检查表

调试 CPU/GPU shared memory 或 coherent 访问异常时，建议按以下顺序检查：

1. 这块内存到底来自哪里：`dma_alloc_coherent()`、`dma_alloc_attrs()`、`kmalloc()`、`vmalloc()`、`cudaHostRegister()`、UVM managed memory、device VRAM？
2. CPU mapping 是否 cacheable？
3. GPU/firmware 访问该地址时使用的是 system address、IOVA、GPU VA 还是 AXI physical address？
4. IOMMU/SMMU 页表属性是否标记 coherent/shareable？
5. NoC/interconnect 是否把该 master 纳入 coherent domain？
6. ACE/ACE-Lite/CHI snoop 信号是否真的发生？
7. 是否需要 `dma_sync_single_for_device()` / `dma_sync_single_for_cpu()`？
8. doorbell 前是否有 write memory barrier？
9. interrupt handler 读 status 前是否需要 read barrier / invalidate？
10. GPU firmware 是否需要 explicit cache clean/invalidate？
11. atomic 的 memory scope 是 GPU device scope 还是 system scope？
12. 如果跨 PCIe，平台是否支持 PCIe AtomicOp / ATS / PRI / PASID / cache coherency？

## 8. RTL 波形关注点

ACE/ACE-Lite 调试除了 AXI 的 `AW/W/B/AR/R`，还要看：

```text
ACVALID / ACREADY / ACADDR
CRVALID / CRREADY / CRRESP
CDVALID / CDREADY / CDDATA
```

以及实现中对应的：

- snoop request type；
- cache line state；
- dirty / clean response；
- shareability domain；
- barrier transaction；
- exclusive transaction；
- NoC snoop filter hit/miss；
- home node / directory 状态，如果是 CHI 类系统。

## 9. 与 AXI 文档的关系

AXI 文档主要解决：

```text
这次访问有没有完成？
地址/数据/响应/属性是否正确？
为什么 readl/writel stuck？
```

AXI-ACE 文档主要解决：

```text
多个 master 的 cache 副本是否一致？
CPU/GPU/DMA 是否在同一 coherent domain？
为什么数据已经写了但对方看不到？
为什么 atomic 在单设备内正确，跨 CPU/GPU 后不正确？
```

## 10. 一句话总结

AXI-ACE 对 GPGPU KMD 的核心意义是：

> 它把“CPU/GPU/IO 共享内存是否真的一致”这个软件问题，映射到硬件层面的 snoop、shareability、cache line ownership、barrier 和 atomic/coherent transaction。

如果 AXI 主要帮助定位访问是否完成，那么 ACE/CHI 主要帮助定位数据是否在正确的一致性域内以正确顺序可见。