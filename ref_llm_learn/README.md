# Ref LLM Learn

这个目录用于记录从参考代码角度学习 LLM 推理框架的路线。

这里的目标不是单纯学习 AI 应用，也不是把方向切到 MCU/RTOS，而是结合当前技术主线：

- 长期核心背景：WiFi / PCIe 等高速设备的 Linux Driver；
- 当前转向：GPU KMD Driver；
- 短期涉及：GPU bring-up 阶段的 firmware / RTOS 开发；
- 学习目标：从最小 LLM runtime 入手，逐步理解本地推理框架、GPU 推理系统，以及它们对 GPU KMD / Memory Manager / UVM / HMM 的压力。

## 1. Model 和推理框架的关系

LLM 本地部署系统通常可以拆成几层：

| 层级 | 例子 | 作用 |
| --- | --- | --- |
| 模型权重 | Qwen、Llama、DeepSeek、Gemma 的 GGUF / safetensors 文件 | 参数/数据，本身不会运行 |
| 极简 runtime | llama2.c | 用少量 C 代码执行 Transformer 推理 |
| 本地通用 runtime | llama.cpp | 加载模型、tokenizer、attention、MLP、KV cache、量化、CPU/GPU backend |
| Serving framework | vLLM、SGLang、TensorRT-LLM | 高吞吐推理、continuous batching、KV cache 管理、多 GPU |
| 用户侧工具 | Ollama、LM Studio、Open WebUI | 模型下载、管理、本地聊天/API |
| Agent / Coding 工具 | Continue、OpenHands、Cursor 类工作流 | 以模型 runtime 为后端进行代码阅读/修改 |

最关键的区分是：

```text
model = 权重/数据
runtime/framework = 执行这些权重的代码
```

例如：

```text
qwen3-32b.gguf
```

只是模型权重文件；真正执行 attention、MLP、KV cache 更新和 token sampling 的，是 llama.cpp、vLLM 或 TensorRT-LLM 这类 runtime/framework。

## 2. 为什么从小代码开始

vLLM、TensorRT-LLM 这类工业框架很强，但里面同时混合了很多层次：

- Transformer 数学；
- tokenizer 和模型格式；
- KV cache；
- quantization；
- CUDA kernel；
- GPU memory scheduling；
- batching；
- multi-GPU communication；
- serving API。

如果一开始直接看这些项目，很容易被工程复杂度淹没。

更好的路线是：

```text
先用极小代码看清楚完整推理闭环
    -> 再看本地通用 runtime
    -> 再看服务端推理系统
    -> 最后映射回 GPU KMD / Memory Manager
```

## 3. 推荐阅读路线

### Step 1: llama2.c

参考项目：`karpathy/llama2.c`

目标：

- 理解最小 LLaMA 风格推理循环；
- 看清楚一个 token 如何生成下一个 token；
- 把 Transformer 图中的模块对应到 C 数组和循环。

重点看：

- tokenizer 输入/输出；
- embedding lookup；
- RMSNorm；
- Q/K/V projection；
- attention score；
- RoPE position encoding；
- KV cache append / reuse；
- FFN / MLP；
- logits 和 sampling。

需要形成的主路径：

```text
prompt tokens
  -> embedding
  -> N transformer layers
  -> logits
  -> sampler
  -> next token
```

这一阶段最重要的是完整性，而不是性能。

### Step 2: llama.cpp

参考项目：`ggml-org/llama.cpp`

目标：

- 从教学级 runtime 过渡到实用本地推理 runtime；
- 理解真实本地模型如何加载、量化和运行。

重点看：

- GGUF 模型格式；
- tokenizer；
- quantization format；
- computation graph；
- CPU backend；
- CUDA / Metal / Vulkan backend；
- KV cache layout；
- prompt processing；
- sampling 参数。

Ollama 和 llama.cpp 的关系可以这样理解：

```text
Ollama 更接近本地模型管理/运行工具；
llama.cpp 更接近底层推理 runtime。
```

Ollama 不是模型本身，它负责拉取模型、管理模型、启动服务和提供 API/聊天入口。

### Step 3: vLLM / SGLang

目标：

- 从单用户本地推理进入服务端高吞吐推理；
- 理解推理系统如何变成调度和内存管理问题。

重点看：

- continuous batching；
- PagedAttention；
- KV cache block 管理；
- request scheduling；
- prefix cache；
- tensor parallelism；
- OpenAI-compatible serving API。

这一层和 GPU KMD 的联系开始变强，因为核心问题变成：

```text
如何在 GPU 上高效管理大量并发请求的计算和 memory residency。
```

### Step 4: TensorRT-LLM

目标：

- 理解 vendor-optimized GPU 推理栈；
- 看 Transformer operator 如何落到 CUDA / Tensor Core / NCCL / multi-GPU 上。

重点看：

- attention / MLP CUDA kernel；
- Tensor Core 使用；
- CUDA Graph；
- NCCL 通信；
- tensor parallel / pipeline parallel；
- memory planning；
- quantized kernel。

这一层更接近真实数据中心推理负载，也更能反映 GPU driver/runtime 会面对什么压力。

### Step 5: 映射回 GPU KMD

理解 LLM 推理负载后，可以把它映射回 GPU Driver / KMD 关心的问题。

| LLM 推理概念 | GPU KMD / Driver 视角 |
| --- | --- |
| model weights | 大块显存分配、映射、residency |
| KV cache | 动态显存管理、碎片、分页式分配 |
| continuous batching | command submission、queue scheduling、preemption pressure |
| tensor parallelism | multi-GPU 通信、peer access、DMA、IOMMU/ATS/PASID |
| CUDA Graph | command buffer 复用、launch overhead、同步 |
| long context | memory bandwidth、cache pressure、显存容量压力 |
| quantization | kernel selection、memory bandwidth 优化 |

这也是为什么本路线不是单纯学 AI，而是把 LLM 推理当成一种典型 GPU workload 来理解。

## 4. 本地部署规模参考

个人学习时不建议一开始追求最大模型，而应该优先选择能顺畅运行、方便 trace 的模型。

| 机器级别 | 可实践模型 | 说明 |
| --- | --- | --- |
| 8 GB VRAM | 7B / 8B quantized | 适合初次实验 |
| 16 GB VRAM | 14B quantized | 本地代码问答体验更好 |
| 24 GB VRAM | 32B quantized，需合理参数 | 个人工作站甜点区 |
| 48 GB VRAM | 70B quantized | 较强本地助手，成本更高 |
| 80 GB+ VRAM | 70B+ / 部分 MoE 部署 | 工作站/服务器级别 |

对于学习 runtime，模型越小越容易调试；对于实际代码辅助，32B/70B 的体验会明显更好。

## 5. 建议输出物

为了让这条路线服务于 Linux Driver / GPU KMD 转型，每一步最好形成具体笔记：

1. 画出 `llama2.c` forward pass call graph；
2. 给 KV cache 更新路径加注释；
3. 用 llama.cpp 跑小模型，记录不同 context length 下的内存变化；
4. 对比 CPU-only 和 GPU-offload 的执行路径；
5. 分析 vLLM 的 KV cache block 分配/复用机制；
6. 把 KV cache 行为映射到 GPU memory manager / paging-like 视角；
7. 总结 LLM inference workload 对 GPU KMD 的压力。

## 6. 当前一句话定位

使用 llama2.c / llama.cpp 这类小而完整的参考代码作为入口，但主线始终对齐高速 Linux Driver、GPU KMD、GPU Memory Manager、UVM/HMM 和推理系统负载分析。
