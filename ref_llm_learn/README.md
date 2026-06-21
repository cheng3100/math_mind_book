# Ref LLM Learn

这个目录用于记录：**从工程全链路理解 LLM，并以 GPU KMD / Memory Manager / firmware 为主线，将 LLM 推理作为典型 GPU workload 来学习。**

目标不是转向纯算法、Prompt、Agent 或 MCU/RTOS，而是建立下面这条链路的整体理解：

```text
LLM 模型与推理负载
  -> inference runtime / serving
  -> GPU 用户态 runtime / UMD
  -> GPU KMD / Memory Manager / UVM-HMM
  -> firmware / command processor
  -> GPU hardware / HBM / PCIe-NVLink-CXL / CPU-NUMA
```

当前技术背景和主线：

- 长期核心背景：WiFi / PCIe 等高速设备的 Linux Driver；
- 当前转向：GPU KMD Driver；
- 短期涉及：GPU bring-up 阶段的 firmware / RTOS；
- 学习目标：用最小 LLM 推理项目理解真实 workload，并映射到 GPU KMD、GPU MMU、显存管理、UVM/HMM、queue 和 firmware 的问题。

---

## 1. 完整 LLM 工程地图

完整 LLM 工程不是只有推理框架，也不只是 `UMD -> KMD -> firmware`。从模型产生到一次请求最终在硬件执行，可分为七层：

```text
┌──────────────────────────────────────────────────────────────┐
│ 1. 模型生产层                                                 │
│    数据清洗 / tokenizer 训练 / pre-training / SFT / RLHF-DPO │
│    输出：checkpoint、model config、tokenizer                 │
├──────────────────────────────────────────────────────────────┤
│ 2. 模型交付层                                                 │
│    safetensors / GGUF / vendor engine / chat template        │
│    FP16-BF16-FP8-INT8-INT4 量化、权重转换、部署配置          │
├──────────────────────────────────────────────────────────────┤
│ 3. 推理语义层                                                 │
│    tokenize -> prefill -> decode -> sampling -> next token   │
│    embedding / attention / MLP / norm / RoPE / KV cache      │
├──────────────────────────────────────────────────────────────┤
│ 4. 推理 runtime 与 serving 层                                │
│    llama.cpp / vLLM / SGLang / TensorRT-LLM                  │
│    graph、kernel dispatch、batching、KV allocator、API       │
├──────────────────────────────────────────────────────────────┤
│ 5. GPU 用户态软件层                                           │
│    PyTorch / CUDA-HIP / Triton / cuBLAS / NCCL / UMD          │
│    VA、BO、command buffer、submit、stream、event、sync       │
├──────────────────────────────────────────────────────────────┤
│ 6. GPU 内核态与 firmware 层                                  │
│    KMD: VM、GPU PTE、BO、queue、scheduler、fault、reset      │
│    firmware: CP、doorbell、IH、PM、watchdog、recovery        │
├──────────────────────────────────────────────────────────────┤
│ 7. 硬件与系统互连层                                           │
│    GPU core / Tensor Core / cache / TLB / MMU / HBM           │
│    PCIe / NVLink / CXL / DMA / IOMMU / ATS / PASID / NUMA     │
└──────────────────────────────────────────────────────────────┘
```

### 1.1 每层的定位

| 层级 | 主要输入/输出 | 主要问题 | 当前学习深度 |
| --- | --- | --- | --- |
| 模型生产 | 数据 -> checkpoint | 训练、后训练、优化器、分布式训练 | 建立地图即可 |
| 模型交付 | checkpoint -> 可部署模型 | 权重格式、量化、模型配置 | 理解其对显存/带宽的影响 |
| 推理语义 | prompt -> token stream | Transformer、KV cache、prefill/decode | 用最小项目跑通 |
| runtime / serving | 多请求 -> GPU workload | graph、batching、调度、KV 管理 | 逐步深入 |
| GPU 用户态 | workload -> GPU command | kernel launch、VA、BO、submit、sync | 与 KMD 对照理解 |
| KMD / firmware | command -> 硬件执行与完成 | VM、scheduler、fault、PM、interrupt | 主战场 |
| 硬件/互连 | 执行与数据移动 | HBM、cache、TLB、PCIe/NVLink、NUMA | 结合已有基础深入 |

---

## 2. 两条相互关联但不同的链路

### 2.1 模型生产链路：当前只需有全貌

```text
raw data
  -> cleaning / dedup / packing
  -> tokenizer training
  -> pre-training
  -> SFT
  -> preference optimization / RLHF / DPO
  -> checkpoint
  -> export / quantization
  -> deployable model
```

这条链决定模型从何而来，但不是当前主线。当前只需知道其典型基础设施压力：

- pre-training：大规模 GEMM、all-reduce、checkpoint I/O；
- MoE：token routing、all-to-all、expert memory pressure；
- RLHF：rollout 推理与训练混合；
- 大规模训练：NCCL/RDMA/网络和集群调度。

### 2.2 推理执行链路：当前主线

```text
user request
  -> tokenizer
  -> prefill / decode execution plan
  -> attention / MLP / norm / logits kernels
  -> GPU runtime / UMD
  -> command buffer / queue submission
  -> KMD scheduler / GPU VM / BO mapping
  -> firmware / command processor
  -> GPU core + HBM + interconnect
  -> completion / sampled next token / streamed response
```

这条链直接把上层 LLM 行为变成 GPU workload，因此是当前学习和工作最相关的部分。

---

## 3. 推理框架、UMD、KMD、firmware 的关系

### 3.1 关键区分

```text
model = 权重、配置、tokenizer 等数据
runtime / framework = 执行模型的代码
UMD = 用户态 GPU 资源管理与 command 构建/提交
KMD = 内核态 GPU VM、调度、内存与恢复机制
firmware = GPU 控制面、命令处理、PM、IH、fault/recovery 协作
```

例如 `qwen*.safetensors` 或 `*.gguf` 只是权重和元数据；真正执行 attention、MLP、KV cache 更新和 sampling 的是 llama.cpp、vLLM、SGLang 或 TensorRT-LLM 等 runtime。

### 3.2 从 LLM 概念映射到 GPU 软件栈

| LLM 推理概念 | runtime / UMD 视角 | KMD / firmware 视角 |
| --- | --- | --- |
| model weights | 模型加载、tensor/BO 分配、长期驻留 | 大块 VRAM 分配、GPU VA 映射、residency、DMA 搬运 |
| KV cache | 追加、读取、复用、块化分配 | 动态 BO/页管理、碎片、TLB/cache 压力、回收策略 |
| prefill | 长序列并行计算、较大 attention workload | 高吞吐 queue、HBM 带宽、功耗与调度压力 |
| decode | 每次只生成少量 token，频繁读 weights/KV | latency、memory-bound、提交/同步开销、cache/TLB 行为 |
| continuous batching | 多请求合并、动态 batch | 多 queue/context 调度、sync、preemption 压力 |
| PagedAttention | KV block table 和 block allocator | 分页式显存管理类比、碎片/局部性、地址转换压力 |
| CUDA Graph | 复用预构建执行图 | command buffer / IB 复用、低 launch/submit overhead |
| tensor parallel | 多 GPU 间切分 tensor | peer mapping、P2P DMA、PCIe/NVLink、IOMMU/ATS/PASID |
| long context | 更大 KV cache、更重 attention | HBM 容量/带宽、cache/TLB、residency 和 eviction 压力 |
| quantization | 特殊数据格式和 kernel 路径 | 更低带宽/容量，但要求不同 kernel、layout 与硬件支持 |

最终要形成的习惯是：

```text
看到一个 LLM runtime 机制
  -> 它制造了什么计算、显存、同步或互连压力？
  -> UMD 如何表达这种压力为资源和 command？
  -> KMD / firmware 需要什么机制承接？
```

---

## 4. 当前学习重心

### 第一圈：长期深入，直接服务 GPU KMD

```text
GPU virtual memory / GPU page table / BO / VA / VM bind
GPU fault / residency / eviction / migration
UVM / HMM / shared virtual memory
command submission / queue / scheduler / preemption
fence / syncobj / doorbell / interrupt / reset / recovery
PCIe / DMA / IOMMU / ATS / PASID
HBM / cache / TLB / memory bandwidth / multi-GPU interconnect
firmware: CP、IH、PM、watchdog、bring-up
```

### 第二圈：必须通过最简项目跑通

```text
Transformer inference semantic
model format / tokenizer / quantization basic
KV cache
CPU/GPU backend
single-request inference -> serving scheduler -> multi-request inference
```

### 第三圈：先建立地图，按工作需要再深入

```text
pre-training / optimizer / SFT / RLHF-DPO
training parallelism / large-scale cluster scheduling
RAG / Agent / application workflow
```

---

## 5. llama2.c 在完整地图中的位置

当前最需要额外进行的最简实践入口是：`karpathy/llama2.c`。

它位于完整地图的 **“模型交付层之后、推理 runtime/语义层之前端”**：

```text
model checkpoint / tokenizer
  -> llama2.c
       - model loading
       - tokenization
       - Transformer forward
       - KV cache update/reuse
       - sampling
  -> generated token stream
```

其位置更准确地说是：

```text
[模型格式/权重]
       ↓
[最小单请求推理 runtime]  <--- llama2.c 的位置
       ↓
[生产级 runtime / backend / serving]
       ↓
[CUDA-HIP / UMD / KMD / firmware / hardware]
```

`llama2.c` 不负责工业级 serving、continuous batching、多 GPU、真实 CUDA backend 或 UMD/KMD 实现；它的价值在于用非常少的代码，把一轮 decoder-only Transformer 推理的语义闭环暴露出来。

### 5.1 llama2.c 的最小闭环

```text
prompt text
  -> tokenizer
  -> token ids
  -> embedding lookup
  -> N transformer layers
       - RMSNorm
       - Q/K/V projection
       - RoPE
       - attention score + weighted sum
       - KV cache append/reuse
       - FFN / MLP
  -> final norm + logits
  -> sampler
  -> next token
  -> repeat (decode)
```

这一阶段目标不是性能，而是回答：**一个 token 为什么能变成下一个 token？每一轮 decode 有哪些状态被保留和复用？**

---

## 6. 学 llama2.c 时重点额外涉及的问题

除了 Transformer 的数学组件，`llama2.c` 会第一次把下面这些工程问题摆到台前；这些正是它与 UMD/KMD 建立联系的入口。

### 6.1 模型权重与模型格式

需要理解：

- 权重不是代码，而是大块只读参数数据；
- 模型 config 决定 layer 数、hidden size、head 数、vocab size、context length；
- 权重布局决定后续 GEMM/访存 layout；
- 权重精度决定容量、带宽和 kernel 选择。

与 UMD/KMD 的关系：

```text
weight file
  -> host memory / device memory allocation
  -> GPU VA mapping
  -> long-lived VRAM residency
  -> HBM capacity + bandwidth pressure
```

### 6.2 KV cache：最重要的额外状态

需要理解：

- decoder 每生成一个 token，都需要当前 token 的 K/V；
- 历史 token 的 K/V 不必重复计算，因此写入 KV cache；
- context 增长时，KV cache 近似线性增长；
- decode 会不断读取历史 KV，同时追加当前 token 的 KV。

与 UMD/KMD 的关系：

```text
KV cache allocator
  -> dynamic device-memory allocation / address management
  -> GPU PTE / TLB / cache locality
  -> fragmentation / residency / eviction pressure
```

`llama2.c` 的 KV cache 是连续、教学式的；vLLM 的 PagedAttention 则将它扩展为服务端的 block/page 管理问题。

### 6.3 Prefill 与 decode 的不同 workload

需要理解：

- prefill：处理整个 prompt，计算量较大，容易利用并行；
- decode：通常一次只生成一个或少量 token，频繁读取 weights 和历史 KV，常更接近 latency / memory-bound；
- 这两者不应被简单视为同一种 GPU workload。

与 UMD/KMD 的关系：

```text
prefill -> larger kernels / high throughput / HBM bandwidth pressure
decode  -> small repeated work / latency sensitivity / launch-submit-sync overhead
```

这会进一步影响 queue 策略、kernel fusion、CUDA Graph、preemption 和功耗管理的设计取舍。

### 6.4 Attention 的访存和地址模式

需要理解：

- Q/K/V projection 本质上是矩阵乘法；
- attention 会访问当前 query 与历史 K/V；
- 长 context 会扩大 KV 读取范围；
- RoPE 是位置相关的变换，不是单纯的元数据。

与 UMD/KMD 的关系：

```text
operator tensor layout
  -> device virtual address ranges
  -> GPU memory transactions
  -> HBM/cache/TLB utilization
```

这里不需要一开始写 CUDA kernel，但需要建立“张量 layout 和访问模式最终会变成 GPU VA/HBM 访问”的意识。

### 6.5 Sampling 和控制路径

需要理解：

- logits 是 vocab 上的概率前的分数；
- greedy、temperature、top-k、top-p 决定 token 选择；
- sampling 本身通常不是主要 GPU 重负载，但属于每轮 decode 的控制闭环。

与 UMD/KMD 的关系：

- 它提示我们区分 compute-heavy data path 与 host-side/control path；
- 在工业系统中，host 调度、GPU completion、下一轮 token 的依赖关系，会共同决定端到端 latency。

---

## 7. llama2.c 的学习边界：看什么、不急着看什么

### 7.1 当前必须看清楚

1. `prompt -> token -> forward -> logits -> sample -> next token` 的完整调用链；
2. model config 和权重数组如何对应 Transformer 模块；
3. Q/K/V、RoPE、attention、FFN、RMSNorm 的数据流；
4. KV cache 的分配、写入、读取、随 position 增长的行为；
5. prefill 与逐 token decode 在执行方式上的区别；
6. 统计并记录：权重占用、KV cache 占用、context length 对内存的影响。

### 7.2 当前不必追求

- 一开始手写高性能 CUDA kernel；
- 立刻把 llama2.c 改造成 GPU runtime；
- 一开始理解所有 Transformer 变体、MoE、RLHF；
- 一开始进入 vLLM / TensorRT-LLM 的所有工业实现细节。

正确顺序是：

```text
llama2.c：看清推理语义和状态
  -> llama.cpp：看模型格式、量化、backend、真实本地 runtime
  -> vLLM / SGLang：看 serving、batching、KV block 管理
  -> TensorRT-LLM：看 vendor-optimized execution、multi-GPU
  -> 持续映射回 UMD / KMD / firmware
```

---

## 8. 当前建议的最简实践输出

每一步都应有可复核的文档、trace 或实验结果，而不是只读代码。

### 8.1 llama2.c 阶段

- 画出 forward pass call graph；
- 标注每个 Transformer 子模块的输入、输出和主要 tensor；
- 给 KV cache 分配、append、read 路径写注释；
- 区分 prefill 与 decode 的调用/循环行为；
- 记录一个小模型在不同 context length 下的：weight size、KV cache size、总内存；
- 写一页 `llama2.c -> UMD/KMD` 映射笔记：哪些内容已可映射，哪些仍被该教学项目抽象掉。

### 8.2 后续 llama.cpp 阶段

- 追模型加载、GGUF、量化和 backend dispatch；
- 对比 CPU-only、GPU offload、不同 context length 的内存行为；
- 观察 KV cache layout 和 GPU memory allocation 路径；
- 明确哪些部分仍停留在 runtime，哪些开始进入 CUDA/HIP/UMD。

### 8.3 后续 vLLM / SGLang 阶段

- 分析 continuous batching；
- 分析 PagedAttention 的 block table、allocator、free/reuse；
- 将 KV block 管理映射到 GPU memory manager / paging-like 视角；
- 分析多请求下 scheduler 对 queue、memory、preemption 的潜在压力。

---

## 9. 当前一句话定位

```text
用 llama2.c 建立“单请求 Transformer 推理语义 + KV cache”的最小闭环；
用 llama.cpp、vLLM/SGLang、TensorRT-LLM 逐渐观察真实 runtime 与 serving；
但始终把重点放在：LLM workload 如何映射为 UMD、KMD、GPU memory manager、UVM/HMM 和 firmware 的问题。
```
